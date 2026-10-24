import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "android_packages", Path(__file__).resolve().parents[2] / "scripts/verify-android-packages.py"
)
PACKAGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGES)


def icon_font(points):
    groups = b"".join(struct.pack(">III", point, point, index + 1)
                      for index, point in enumerate(sorted(points)))
    table = struct.pack(">HHIII", 12, 0, 16 + len(groups), 0, len(points)) + groups
    cmap = struct.pack(">HHHHI", 0, 1, 3, 10, 12) + table
    return (struct.pack(">IHHHH", 0x10000, 1, 16, 0, 0)
            + b"cmap" + struct.pack(">III", 0, 28, len(cmap)) + cmap)


class PackagePayloadTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lanflow-apk-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.required_icons = {0xE001, 0xE002}
        self.shared = {
            "AndroidManifest.xml": b"same application id and version code",
            "classes.dex": b"all application logic",
            "assets/flutter_assets/NOTICES.Z": b"licenses",
            PACKAGES.FONT: icon_font(self.required_icons),
        }
        self.entries = dict(self.shared)
        for abi in PACKAGES.ABIS:
            for library in (*PACKAGES.CORE_LIBRARIES, "libdartjni.so"):
                self.entries[f"lib/{abi}/{library}"] = (abi + library).encode() * 64
        self.universal = self.root / "universal.apk"
        self.write(self.universal, self.entries)
        self.splits = {}
        for abi in PACKAGES.ABIS:
            path = self.root / f"{abi}.apk"
            self.write(path, self.payload(abi))
            self.splits[abi] = path

    def payload(self, abi):
        return {name: data for name, data in self.entries.items()
                if not name.startswith("lib/") or name.startswith(f"lib/{abi}/")}

    def write(self, path, entries):
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)

    def verify(self):
        return PACKAGES.verify(self.universal, self.splits, self.required_icons)

    def test_only_other_architectures_are_removed(self):
        sizes = self.verify()
        self.assertEqual(set(sizes), {"universal", *PACKAGES.ABIS})
        self.assertTrue(all(sizes[abi] < sizes["universal"] for abi in PACKAGES.ABIS))

    def test_modified_manifest_assets_and_native_code_are_rejected(self):
        abi = PACKAGES.ABIS[0]
        for changed in ("AndroidManifest.xml", "classes.dex", PACKAGES.FONT, f"lib/{abi}/liblanflow_core.so"):
            with self.subTest(changed=changed):
                payload = self.payload(abi)
                payload[changed] += b" changed"
                self.write(self.splits[abi], payload)
                with self.assertRaisesRegex(ValueError, "payload changed"):
                    self.verify()

    def test_missing_plugin_or_extra_architecture_is_rejected(self):
        abi = PACKAGES.ABIS[0]
        payload = self.payload(abi)
        del payload[f"lib/{abi}/libdartjni.so"]
        self.write(self.splits[abi], payload)
        with self.assertRaisesRegex(ValueError, "payload entries differ"):
            self.verify()
        payload = self.payload(abi)
        payload["lib/x86_64/extra.so"] = b"unwanted"
        self.write(self.splits[abi], payload)
        with self.assertRaisesRegex(ValueError, "Unexpected architectures"):
            self.verify()

    def test_truncated_icon_font_in_every_variant_is_rejected(self):
        self.entries[PACKAGES.FONT] = b"incomplete"
        self.write(self.universal, self.entries)
        with self.assertRaisesRegex(ValueError, "Invalid release icon font"):
            self.verify()

    def test_subset_must_keep_all_used_glyphs(self):
        self.entries[PACKAGES.FONT] = icon_font({0xE001})
        self.write(self.universal, self.entries)
        with self.assertRaisesRegex(ValueError, "missing used glyphs"):
            self.verify()

    def test_required_glyphs_follow_application_source(self):
        source = self.root / "lib"
        source.mkdir()
        (source / "view.dart").write_text("Icon(Icons.chat); Icon(Icons.send)")
        definitions = self.root / "icons.dart"
        definitions.write_text("static const IconData chat = IconData(0xe001);\n"
                               "static const IconData send = IconData(0xe002);\n"
                               "static const IconData unused = IconData(0xe003);\n")
        self.assertEqual(PACKAGES.used_icon_codepoints(source, definitions), self.required_icons)


if __name__ == "__main__":
    unittest.main()
