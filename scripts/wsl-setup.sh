#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --system ]]; then
  [[ $EUID == 0 ]] || { echo 'System dependency setup requires root.' >&2; exit 1; }
  packages=(build-essential ca-certificates curl git python3 rsync unzip zip xz-utils openjdk-21-jdk-headless libglu1-mesa libgtk-3-0t64 libfontconfig1 ninja-build)
  missing=()
  for package in "${packages[@]}"; do
    [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == 'install ok installed' ]] || missing+=("$package")
  done
  if ((${#missing[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install --no-install-recommends -y "${missing[@]}"
  fi
  exit 0
fi

# Called by wsl-build.sh with Linux-only cache/tool paths already exported.
source_root=$1
target=$2
[[ -f $HOME/.config/build-tools/env.sh ]] || { echo 'Configure shared Debian build tools first.' >&2; exit 1; }
source "$HOME/.config/build-tools/env.sh"
export LANFLOW_BUILD_HOME="$DEVTOOLS_HOME"
mkdir -p "$LANFLOW_BUILD_HOME/downloads"
exec 8>"$LANFLOW_BUILD_HOME/setup.lock"
flock 8

download() {
  local url=$1 destination=$2 checksum=$3
  if [[ -f $destination ]] && echo "$checksum  $destination" | sha256sum --check --status; then return; fi
  curl --fail --location --retry 3 --connect-timeout 20 "$url" -o "$destination.pending"
  echo "$checksum  $destination.pending" | sha256sum --check --status
  mv -- "$destination.pending" "$destination"
}

if [[ ! -x $CARGO_HOME/bin/cargo ]]; then
  curl --fail --location --retry 3 https://sh.rustup.rs -o "$LANFLOW_BUILD_HOME/downloads/rustup-init.sh"
  bash "$LANFLOW_BUILD_HOME/downloads/rustup-init.sh" -y --profile minimal --no-modify-path --default-toolchain 1.99.1
fi
if [[ ! -f $CARGO_HOME/.lanflow-cache-seeded ]]; then
  if [[ -d $source_root/.tooling/cargo/registry ]]; then
    mkdir -p "$CARGO_HOME/registry"
    rsync -a --ignore-existing --exclude '*.lock' "$source_root/.tooling/cargo/registry/" "$CARGO_HOME/registry/"
  fi
  touch "$CARGO_HOME/.lanflow-cache-seeded"
fi
if [[ $target == windows-core ]]; then rustup target add x86_64-pc-windows-gnu; exit 0; fi
if [[ $target == nas ]]; then exit 0; fi

if [[ ! -x $LANFLOW_BUILD_HOME/flutter/bin/flutter ]]; then
  archive="$LANFLOW_BUILD_HOME/downloads/flutter-3.47.7-linux.tar.xz"
  download 'https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.7-stable.tar.xz' "$archive" af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230
  tar -xJf "$archive" -C "$LANFLOW_BUILD_HOME"
  rm -- "$archive"
fi

if [[ ! -f $PUB_CACHE/.lanflow-cache-seeded ]]; then
  mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME/caches/modules-2" "$GRADLE_USER_HOME/wrapper"
  for directory in hosted hosted-hashes; do
    if [[ -d $source_root/.pub-cache/$directory ]]; then
      mkdir -p "$PUB_CACHE/$directory"
      rsync -a --ignore-existing "$source_root/.pub-cache/$directory/" "$PUB_CACHE/$directory/"
    fi
  done
  if [[ -d $source_root/.tooling/gradle-cache/caches/modules-2 ]]; then
    rsync -a --ignore-existing --exclude '*.lock' "$source_root/.tooling/gradle-cache/caches/modules-2/" "$GRADLE_USER_HOME/caches/modules-2/"
  fi
  if [[ -d $source_root/.tooling/gradle-cache/wrapper ]]; then
    rsync -a --ignore-existing "$source_root/.tooling/gradle-cache/wrapper/" "$GRADLE_USER_HOME/wrapper/"
  fi
  touch "$PUB_CACHE/.lanflow-cache-seeded"
fi

if [[ ! -x $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager ]]; then
  archive="$LANFLOW_BUILD_HOME/downloads/android-commandline-linux.zip"
  download 'https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip' "$archive" 4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  unzip -q "$archive" -d "$ANDROID_HOME/cmdline-tools"
  mv -- "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -- "$archive"
fi
sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [[ ! -f $ANDROID_HOME/.lanflow-ready ]]; then
  # Accept licenses for the SDK packages required by this project's build.
  set +o pipefail
  yes | "$sdkmanager" --sdk_root="$ANDROID_HOME" --licenses >/dev/null
  sdk_status=${PIPESTATUS[1]}
  set -o pipefail
  [[ $sdk_status == 0 ]] || exit "$sdk_status"
  "$sdkmanager" --sdk_root="$ANDROID_HOME" 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358' 'cmake;3.22.1'
  touch "$ANDROID_HOME/.lanflow-ready"
fi
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
if [[ ! -f $LANFLOW_BUILD_HOME/.flutter-ready ]]; then
  flutter config --no-analytics --android-sdk "$ANDROID_HOME" --jdk-dir "$JAVA_HOME"
  flutter precache --android
  touch "$LANFLOW_BUILD_HOME/.flutter-ready"
fi
