import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile


ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
CORE_LIBRARIES = {"libapp.so", "libflutter.so", "liblanflow_core.so"}
FONT = "assets/flutter_assets/fonts/MaterialIcons-Regular.otf"


def used_icon_codepoints(source, icons_source):
    definitions = dict(re.findall(
        r"static const IconData\s+(\w+)\s*=\s*IconData\(\s*(0x[\da-fA-F]+)",
        icons_source.read_text(encoding="utf-8"),
    ))
    names = set()
    for path in source.rglob("*.dart"):
        text = path.read_text(encoding="utf-8")
        names.update(re.findall(r"\bIcons\.(\w+)", text))
    missing = names - definitions.keys()
    if missing or not names:
        raise ValueError(f"Cannot resolve application icons: {sorted(missing)}")
    return {int(definitions[name], 16) for name in names}


def font_codepoints(data):
    """Read Unicode cmap entries without depending on a system font package."""
    def u16(offset):
        return struct.unpack_from(">H", data, offset)[0]

    def u32(offset):
        return struct.unpack_from(">I", data, offset)[0]

    try:
        if data[:4] not in (b"OTTO", b"\x00\x01\x00\x00"):
            raise ValueError("Invalid release icon font")
        cmap = next(u32(offset + 8) for offset in range(12, 12 + u16(4) * 16, 16)
                    if data[offset:offset + 4] == b"cmap")
        result = set()
        for record in range(cmap + 4, cmap + 4 + u16(cmap + 2) * 8, 8):
            platform, encoding = u16(record), u16(record + 2)
            if platform != 0 and (platform != 3 or encoding not in (1, 10)):
                continue
            table = cmap + u32(record + 4)
            kind = u16(table)
            if kind == 12:
                for group in range(table + 16, table + 16 + u32(table + 12) * 12, 12):
                    first, last, glyph = struct.unpack_from(">III", data, group)
                    if first > last or last > 0x10FFFF:
                        raise ValueError("Invalid release icon font range")
                    result.update(range(first + (glyph == 0), last + 1))
            elif kind == 4:
                segments = u16(table + 6) // 2
                ends = table + 14
                starts = ends + segments * 2 + 2
                deltas = starts + segments * 2
                ranges = deltas + segments * 2
                for segment in range(segments):
                    first, last = u16(starts + segment * 2), u16(ends + segment * 2)
                    delta = u16(deltas + segment * 2)
                    location = ranges + segment * 2
                    distance = u16(location)
                    for point in range(first, min(last, 0xFFFE) + 1):
                        glyph = u16(location + distance + (point - first) * 2) if distance else point
                        if (not distance or glyph) and (glyph + delta) & 0xFFFF:
                            result.add(point)
        if not result:
            raise ValueError("Release icon font has no Unicode glyphs")
        return result
    except (struct.error, StopIteration) as error:
        raise ValueError("Invalid release icon font") from error


def signing_entry(name):
    upper = name.upper()
    return upper == "META-INF/MANIFEST.MF" or (
        upper.startswith("META-INF/")
        and upper.endswith((".SF", ".RSA", ".DSA", ".EC"))
    )


def contents(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError(f"Duplicate APK entries: {path.name}")
        return {
            name: hashlib.sha256(archive.read(name)).hexdigest()
            for name in names
            if not name.endswith("/") and not signing_entry(name)
        }


def architectures(entries):
    return {name.split("/")[1] for name in entries if name.startswith("lib/")}


def verify(universal, splits, required_icons):
    if set(splits) != set(ABIS):
        raise ValueError("All three independent Android architectures are required")
    reference = contents(universal)
    if architectures(reference) != set(ABIS):
        raise ValueError("Universal APK must retain all supported architectures")
    with zipfile.ZipFile(universal) as archive:
        missing = required_icons - font_codepoints(archive.read(FONT))
    if missing:
        raise ValueError(f"Release icon font is missing used glyphs: {sorted(missing)}")
    for abi in ABIS:
        required = {f"lib/{abi}/{name}" for name in CORE_LIBRARIES}
        if not required.issubset(reference):
            raise ValueError(f"Required native libraries are missing for {abi}")
    sizes = {"universal": universal.stat().st_size}
    for abi, path in splits.items():
        actual = contents(path)
        if architectures(actual) != {abi}:
            raise ValueError(f"Unexpected architectures in {path.name}")
        expected = {
            name: digest for name, digest in reference.items()
            if not name.startswith("lib/") or name.startswith(f"lib/{abi}/")
        }
        # Compare executable code, the manifest (including version/permissions),
        # native plugins, every asset and the used icon font byte-for-byte.
        # ABI splitting must only remove the other processors' native libraries.
        if actual.keys() != expected.keys():
            raise ValueError(f"APK payload entries differ: {path.name}")
        mismatched = [name for name in expected if actual[name] != expected[name]]
        if mismatched:
            raise ValueError(f"APK payload changed in {path.name}: {mismatched[:5]}")
        sizes[abi] = path.stat().st_size
        if sizes[abi] >= sizes["universal"]:
            raise ValueError(f"Split APK is not smaller: {path.name}")
    return sizes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--universal", type=Path, required=True)
    parser.add_argument("--arm64", type=Path, required=True)
    parser.add_argument("--arm32", type=Path, required=True)
    parser.add_argument("--x64", type=Path, required=True)
    parser.add_argument("--icons-source", type=Path, required=True)
    parser.add_argument("--app-source", type=Path, default=Path("lib"))
    args = parser.parse_args()
    required = used_icon_codepoints(args.app_source, args.icons_source)
    sizes = verify(args.universal, dict(zip(ABIS, (args.arm64, args.arm32, args.x64))), required)
    print("Android APK contents verified: identical features, versions, assets and native code.")
    print(json.dumps({"apkBytes": sizes}, ensure_ascii=False))


if __name__ == "__main__":
    main()
