#!/usr/bin/env bash
set -euo pipefail
umask 077
source_root=$(realpath "$1")
target=$2
setup=$3
tests=$4
jobs=${5:-2}
case "$target" in all|android|nas|check|rust-android|windows-core) ;; *) echo 'Unknown build target' >&2; exit 1 ;; esac
[[ $jobs =~ ^[1-4]$ ]] || exit 1
if [[ ($target == all || $target == android) && ! -f $source_root/platforms/android/key.properties ]]; then
  echo 'Release packaging requires platforms/android/key.properties and your own signing key. Use flutter run or flutter build apk --debug for development.' >&2
  exit 1
fi

[[ -f $HOME/.config/build-tools/env.sh ]] || { echo 'Configure the shared Debian build tools first.' >&2; exit 1; }
source "$HOME/.config/build-tools/env.sh"
export LANFLOW_BUILD_HOME="$DEVTOOLS_HOME"
case $(stat -f -c %T "$LANFLOW_BUILD_HOME") in 9p|drvfs|ntfs*) echo 'Build home must be on the Linux filesystem.' >&2; exit 1 ;; esac
export PATH="$CARGO_HOME/bin:$LANFLOW_BUILD_HOME/flutter/bin:$JAVA_HOME/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_BUILD_JOBS="$jobs" RUST_TEST_THREADS="$jobs" CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DASH__SUPPRESS_ANALYTICS=true

project_id=$(printf '%s' "$source_root" | sha256sum | cut -c1-12)
project_root="$LANFLOW_BUILD_HOME/projects/$project_id"
mkdir -p "$project_root"
exec 9>"$project_root/build.lock"
flock -n 9 || { echo 'A build for this project is already running in Debian.' >&2; exit 1; }
workspace="$project_root/source"
export CARGO_TARGET_DIR="$DEVTOOLS_HOME/targets"
export TMPDIR="$project_root/tmp"
mkdir -p "$TMPDIR" "$workspace"
if [[ ! -f $workspace/.lanflow-build-source ]]; then
  [[ -z $(find "$workspace" -mindepth 1 -maxdepth 1 -print -quit) ]] || { echo 'Refusing to synchronize into an unowned directory.' >&2; exit 1; }
  printf '%s\n' "$source_root" > "$workspace/.lanflow-build-source"
fi
[[ $(cat "$workspace/.lanflow-build-source") == "$source_root" ]] || exit 1
[[ $(realpath "$workspace") == "$LANFLOW_BUILD_HOME/projects/$project_id/source" ]] || exit 1

if [[ $setup == setup ]]; then bash "$source_root/scripts/wsl-setup.sh" "$source_root" "$target"; fi
command -v cargo >/dev/null || { echo 'Run the WSL build without -SkipSetup first.' >&2; exit 1; }

# Synchronize only source directories. Linux-generated paths and signing files
# are excluded from both copying and deletion, and never point back into /mnt/c.
for directory in lib native android windows platforms/docker test scripts; do
  directory_source="$source_root/$directory"
  case "$directory" in android|windows) directory_source="$source_root/platforms/$directory" ;; esac
  mkdir -p "$workspace/$directory"
  rsync -a --delete --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= \
    --exclude target/ --exclude build/ --exclude .gradle/ --exclude .kotlin/ \
    --exclude .cxx/ --exclude ephemeral/ --exclude jniLibs/ \
    --exclude local.properties --exclude key.properties --exclude '*.jks' --exclude '*.keystore' \
    "$directory_source/" "$workspace/$directory/"
done
for file in pubspec.yaml pubspec.lock analysis_options.yaml .gitignore; do cp -- "$source_root/$file" "$workspace/$file"; done
chmod u+x "$workspace/android/gradlew"
cd "$workspace"
printf 'Linux build source: %s\nLinux Rust cache: %s\n' "$workspace" "$CARGO_TARGET_DIR"
mkdir -p build/native artifacts
version=$(sed -n 's/^version: \([0-9][0-9.]*\).*/\1/p' pubspec.yaml)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1

if [[ $target == windows-core ]]; then
  cross_target=x86_64-pc-windows-gnu
  rustup target list --installed | grep -Fxq "$cross_target" || { echo 'Install the Windows GNU target in the shared Rust toolchain.' >&2; exit 1; }
  if [[ $tests == test ]]; then
    CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 cargo test --locked --manifest-path native/Cargo.toml --target "$cross_target" --lib -- --test-threads="$jobs"
  fi
  cargo build --locked --release --manifest-path native/Cargo.toml --target "$cross_target" --lib
  destination="$source_root/build/native/lanflow_core.dll"
  mkdir -p "$(dirname "$destination")"
  library="$CARGO_TARGET_DIR/$cross_target/release/lanflow_core.dll"
  if ! cmp -s -- "$library" "$destination"; then
    cp -- "$library" "$destination.pending"
    mv -- "$destination.pending" "$destination"
  fi
  printf 'Windows Rust core built in Debian: %s\n' "$destination"
  exit 0
fi

if [[ $tests == test ]]; then cargo test --locked --manifest-path native/Cargo.toml --features hub -- --test-threads="$jobs"; fi
cargo build --locked --release --manifest-path native/Cargo.toml --features hub --bin lanflow-hub
cargo build --locked --release --manifest-path native/Cargo.toml --lib
cp -- "$CARGO_TARGET_DIR/release/lanflow-hub" build/native/lanflow-hub
cp -- "$CARGO_TARGET_DIR/release/liblanflow_core.so" build/native/liblanflow_core.so

if [[ $target != nas ]]; then
  command -v flutter >/dev/null || { echo 'Linux Flutter is missing; run without -SkipSetup.' >&2; exit 1; }
  printf 'sdk.dir=%s\nflutter.sdk=%s\n' "$ANDROID_HOME" "$LANFLOW_BUILD_HOME/flutter" > android/local.properties
  mkdir -p "$GRADLE_USER_HOME"
  cat > "$GRADLE_USER_HOME/gradle.properties" <<EOF
org.gradle.jvmargs=-Xmx2G -XX:MaxMetaspaceSize=512m -XX:ReservedCodeCacheSize=128m -XX:ActiveProcessorCount=$jobs
org.gradle.workers.max=$jobs
org.gradle.parallel=false
org.gradle.daemon=false
kotlin.compiler.execution.strategy=in-process
EOF
  flutter pub get --enforce-lockfile
  flutter analyze --no-pub
  if [[ $tests == test ]]; then flutter test --no-pub --concurrency="$jobs" --reporter expanded --timeout 60s; fi
fi

if [[ $target == all || $target == android || $target == rust-android ]]; then
  ndk="$ANDROID_HOME/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"
  for spec in 'aarch64-linux-android:aarch64-linux-android:arm64-v8a' 'armv7-linux-androideabi:armv7a-linux-androideabi:armeabi-v7a' 'x86_64-linux-android:x86_64-linux-android:x86_64'; do
    IFS=: read -r triple compiler abi <<< "$spec"
    key=${triple//-/_}
    env "CARGO_TARGET_${key^^}_LINKER=$ndk/${compiler}24-clang" "CC_$key=$ndk/${compiler}24-clang" "AR_$key=$ndk/llvm-ar" "CFLAGS_$key=-D__ANDROID_API__=24" \
      cargo build --locked --release --manifest-path native/Cargo.toml --target "$triple" --lib
    mkdir -p "android/app/src/main/jniLibs/$abi"
    cp -- "$CARGO_TARGET_DIR/$triple/release/liblanflow_core.so" "android/app/src/main/jniLibs/$abi/liblanflow_core.so"
  done
fi

if [[ $target == all || $target == android ]]; then
  # Copy the existing key without printing credentials or creating a new identity.
  python3 - "$source_root" "$project_root" <<'PY'
import os, pathlib, re, shutil, subprocess, sys
source, build = map(pathlib.Path, sys.argv[1:])
original = source / 'platforms/android/key.properties'
text = original.read_text(encoding='utf-8-sig')
match = re.search(r'^storeFile=(.+)$', text, re.M)
if not match:
    raise SystemExit('Existing release signing configuration is required.')
key_path = match.group(1).strip()
if re.match(r'^[A-Za-z]:', key_path):
    key_path = subprocess.check_output(['wslpath', '-u', key_path], text=True).strip()
else:
    key_path = str(source / 'platforms/android/app' / key_path)
destination = build / 'signing/release.jks'
destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
shutil.copyfile(key_path, destination)
os.chmod(destination, 0o600)
text = re.sub(r'^storeFile=.+$', lambda _: 'storeFile=' + str(destination), text, flags=re.M)
output = build / 'source/android/key.properties'
output.write_text(text, encoding='utf-8')
os.chmod(output, 0o600)
PY
  symbols="$project_root/symbols/$version/android"
  flutter build apk --release --no-pub --split-debug-info="$symbols"
  apk=build/app/outputs/flutter-apk/app-release.apk
  cp -- "$apk" "artifacts/LanFlow-$version-android.apk"
  # Keep the universal package for unknown devices, and produce independently
  # installable APKs containing only the selected processor's native libraries.
  # Flutter normally offsets split version codes by ABI: disable that so users
  # can update between the universal and matching architecture without a downgrade.
  flutter build apk --release --no-pub --split-debug-info="$symbols" --split-per-abi \
    --android-project-arg=force-version-code-ignoring-abi=true
  for abi in arm64-v8a armeabi-v7a x86_64; do
    cp -- "build/app/outputs/flutter-apk/app-$abi-release.apk" "artifacts/LanFlow-$version-android-$abi.apk"
  done
  python3 test/android/package_payload_test.py
  python3 scripts/verify-android-packages.py \
    --universal "artifacts/LanFlow-$version-android.apk" \
    --arm64 "artifacts/LanFlow-$version-android-arm64-v8a.apk" \
    --arm32 "artifacts/LanFlow-$version-android-armeabi-v7a.apk" \
    --x64 "artifacts/LanFlow-$version-android-x86_64.apk" \
    --icons-source "$LANFLOW_BUILD_HOME/flutter/packages/flutter/lib/src/material/icons.dart"
  LANFLOW_RELEASE_ICON_FONT=build/app/intermediates/flutter/release/flutter_assets/fonts/MaterialIcons-Regular.otf \
    LANFLOW_MATERIAL_ICONS_SOURCE="$LANFLOW_BUILD_HOME/flutter/packages/flutter/lib/src/material/icons.dart" \
    flutter test --no-pub test/previews/verify_release_icons.dart --reporter expanded
  signer="$ANDROID_HOME/build-tools/36.0.0/apksigner"
  certificate=$("$signer" verify --print-certs "artifacts/LanFlow-$version-android.apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
  [[ -n $certificate ]] || { echo 'Release signing certificate could not be verified.' >&2; exit 1; }
  for suffix in '' -arm64-v8a -armeabi-v7a -x86_64; do
    candidate="artifacts/LanFlow-$version-android$suffix.apk"
    "$signer" verify --verbose "$candidate"
    actual=$("$signer" verify --print-certs "$candidate" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
    [[ $actual == "$certificate" ]] || { echo 'APK signing certificate differs between architectures.' >&2; exit 1; }
  done
  if [[ -f $source_root/artifacts/LanFlow-$version-android.apk ]]; then
    before=$("$signer" verify --print-certs "$source_root/artifacts/LanFlow-$version-android.apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
    [[ -n $before && $before == "$certificate" ]] || { echo 'APK signing certificate changed; original package preserved.' >&2; exit 1; }
  fi
  # Keep crash symbols available for diagnosis without shipping them in APKs.
  mkdir -p "$source_root/build/symbols/$version/android"
  rsync -a "$symbols/" "$source_root/build/symbols/$version/android/"
  if [[ -d build/app/outputs/mapping/release ]]; then
    rsync -a build/app/outputs/mapping/release/ "$source_root/build/symbols/$version/android/r8/"
  fi
fi

if [[ $target == all || $target == nas ]]; then
  cp -- build/native/lanflow-hub "artifacts/LanFlow-$version-nas-linux-x64"
  python3 - "$version" <<'PY'
import pathlib, re, sys, zipfile
root = pathlib.Path.cwd()
version = sys.argv[1]
compose = (root / 'platforms/docker/compose.yaml').read_text()
compose = re.sub(r'^# Preserve the project/data-volume name used before this directory was renamed\.\n', '', compose, flags=re.M)
compose = re.sub(r'^name: nas\n', '', compose, flags=re.M)
compose = compose.replace('context: ../..', 'context: .').replace('dockerfile: platforms/docker/Dockerfile', 'dockerfile: Dockerfile')
with zipfile.ZipFile(root / f'artifacts/LanFlow-{version}-nas.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('compose.yaml', compose)
    for name in ('Dockerfile', 'Dockerfile.dockerignore'):
        archive.write(root / 'platforms/docker' / name, name)
    for path in [root/'native/Cargo.toml', root/'native/Cargo.lock', *sorted((root/'native/src').rglob('*'))]:
        if path.is_file():
            archive.write(path, path.relative_to(root).as_posix())
PY
fi

# Only completed artifacts cross the filesystem boundary; all intermediate I/O stays in Linux.
mkdir -p "$source_root/artifacts"
publish() {
  local name=$1
  cp -- "artifacts/$name" "$source_root/artifacts/$name.pending"
  cmp -- "artifacts/$name" "$source_root/artifacts/$name.pending"
  mv -f -- "$source_root/artifacts/$name.pending" "$source_root/artifacts/$name"
}
if [[ $target == all || $target == android ]]; then
  for suffix in '' -arm64-v8a -armeabi-v7a -x86_64; do
    publish "LanFlow-$version-android$suffix.apk"
  done
fi
if [[ $target == all || $target == nas ]]; then
  publish "LanFlow-$version-nas.zip"
  publish "LanFlow-$version-nas-linux-x64"
fi
if [[ $target == rust-android ]]; then
  mkdir -p "$source_root/platforms/android/app/src/main/jniLibs"
  rsync -a android/app/src/main/jniLibs/ "$source_root/platforms/android/app/src/main/jniLibs/"
fi
printf 'Debian build complete: %s\n' "$target"
