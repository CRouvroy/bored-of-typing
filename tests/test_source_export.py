import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("board_source_export", ROOT / "scripts/export-source.py")
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)


class SourceExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="BoardSourceExport-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "source"
        self.root.mkdir()
        for name in EXPORT.ROOT_FILES:
            (self.root / name).write_text("Example project\n")
        for name in EXPORT.SOURCE_SUFFIXES:
            (self.root / name).mkdir()
        (self.root / "Sources/App.swift").write_text("import Foundation\n")
        self.build = self.root / "scripts/build-app"
        self.build.write_text("#!/bin/bash\nexit 0\n")
        self.build.chmod(0o755)

    def test_export_excludes_local_data_and_keeps_build_inputs(self):
        excluded = [
            ".build/private.log", "dist/Board.app/Contents/Resources/auth.json",
            ".env", "library.json", "live-annotations.json", "overlays.json",
            "originals/board.png", "exports/capture.png", "revisions/previous.json",
            "collaboration/image.png", "scripts/__pycache__/private.pyc",
            "scripts/.env", "tests/research-board.png", "tests/session.json",
        ]
        for relative in excluded:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"PRIVATE FIXTURE MUST STAY LOCAL")
        archive_path = self.root / "dist/source.zip"
        count = EXPORT.export_source(self.root, archive_path)
        with zipfile.ZipFile(archive_path) as archive:
            names = set(archive.namelist())
            self.assertEqual(len(names), count + 1)
            self.assertIn("Board/Sources/App.swift", names)
            self.assertIn("Board/scripts/build-app", names)
            self.assertTrue(all("Board/" + name not in names for name in excluded))
            self.assertTrue(all(b"PRIVATE FIXTURE" not in archive.read(name) for name in names))
            manifest = json.loads(archive.read("Board/SOURCE-MANIFEST.json"))
            self.assertEqual(set(manifest["files"]), {name.removeprefix("Board/") for name in names if not name.endswith("SOURCE-MANIFEST.json")})
            for name, digest in manifest["files"].items():
                self.assertEqual(hashlib.sha256(archive.read("Board/" + name)).hexdigest(), digest)
            self.assertEqual((archive.getinfo("Board/scripts/build-app").external_attr >> 16) & 0o777, 0o755)

    def test_export_is_reproducible_without_personal_metadata(self):
        first, second = self.root / "first.zip", self.root / "second.zip"
        EXPORT.export_source(self.root, first)
        EXPORT.export_source(self.root, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with zipfile.ZipFile(first) as archive:
            for item in archive.infolist():
                self.assertEqual(item.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertEqual(item.extra, b"")
                self.assertFalse(item.filename.startswith("/"))

    def test_source_symlinks_are_rejected_without_copying_targets(self):
        outside = Path(self.temporary.name) / "outside.swift"
        outside.write_text("PRIVATE OUTSIDE FIXTURE")
        (self.root / "Sources/Linked.swift").symlink_to(outside)
        with self.assertRaises(EXPORT.ExportError):
            EXPORT.export_source(self.root, self.root / "source.zip")
        self.assertFalse((self.root / "source.zip").exists())

    def test_source_directory_symlinks_are_rejected(self):
        outside = Path(self.temporary.name) / "private"
        outside.mkdir()
        (self.root / "Sources/Linked").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(EXPORT.ExportError):
            EXPORT.export_source(self.root, self.root / "source.zip")

    def test_credential_literals_fail_without_echoing_values(self):
        secret = "synthetic-" + "private-fixture"
        source = self.root / "scripts/helper.py"
        source.write_text("api" + "_key = " + repr(secret) + "\n")
        with self.assertRaises(EXPORT.ExportError) as error:
            EXPORT.export_source(self.root, self.root / "source.zip")
        self.assertIn("credential literal", str(error.exception))
        self.assertNotIn(secret, str(error.exception))
        self.assertFalse((self.root / "source.zip").exists())

    def test_provider_keys_and_private_keys_fail(self):
        source = self.root / "scripts/helper.py"
        values = ["sk-" + "x" * 40, "-----BEGIN " + "PRIVATE KEY-----"]
        for value in values:
            with self.subTest(kind=value[:3]):
                source.write_text(value)
                with self.assertRaises(EXPORT.ExportError) as error:
                    EXPORT.export_source(self.root, self.root / "source.zip")
                self.assertNotIn(value, str(error.exception))

    def test_public_registry_header_prefix_is_not_a_saved_credential(self):
        source = self.root / "scripts/helper.py"
        source.write_text("headers = {'Authorization': 'Bearer ' + token}\n")
        EXPORT.export_source(self.root, self.root / "source.zip")

    def test_personal_home_paths_block_export(self):
        source = self.root / "README.md"
        source.write_text("/Us" + "ers/researcher/private/Board\n")
        with self.assertRaisesRegex(EXPORT.ExportError, "personal home path"):
            EXPORT.export_source(self.root, self.root / "source.zip")

    def test_repository_export_inputs_pass_privacy_checks(self):
        for path in EXPORT.source_paths(ROOT):
            with self.subTest(file=str(path.relative_to(ROOT))):
                EXPORT.checked_source(ROOT, path)

    def test_repository_exports_every_required_build_input(self):
        required = {
            "Package.swift", "scripts/build-app", "scripts/macos-sdk",
            "scripts/prepare-opencv-runtime", "scripts/swift-build",
            "scripts/make-icon.swift", "scripts/board-mcp.py",
            "scripts/setup-claude-mcp.py",
        }
        archive_path = Path(self.temporary.name) / "Board-source.zip"
        EXPORT.export_source(ROOT, archive_path)
        with zipfile.ZipFile(archive_path) as archive:
            names = {name.removeprefix("Board/") for name in archive.namelist()}
            self.assertTrue(required <= names, "Missing build inputs: " + str(sorted(required - names)))
            for name in required:
                if (ROOT / name).stat().st_mode & 0o111:
                    self.assertTrue((archive.getinfo("Board/" + name).external_attr >> 16) & 0o111,
                                    "Lost executable permission: " + name)


if __name__ == "__main__":
    unittest.main()
