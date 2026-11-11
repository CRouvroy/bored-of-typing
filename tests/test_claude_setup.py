"""Isolated Claude setup checks. No real user configs, camera, or model calls."""

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/setup-claude-mcp.py"
SPEC = importlib.util.spec_from_file_location("board_claude_setup", SCRIPT)
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)


class ClaudeSetupChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.config = self.root / "Claude/claude_desktop_config.json"
        self.expected = setup.expected_entry(Path(sys.executable).resolve(), self.root / "Board.app/board-mcp.py")
        self.original = {"preferences": {"locale": "fr"}, "opaquePrivateSetting": "PRIVATE_SENTINEL",
                         "mcpServers": {"other": {"command": "existing", "env": {"SECRET": "PRIVATE_SENTINEL"}}}}

    def write(self, value=None):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(json.dumps(self.original if value is None else value))

    def backups(self):
        return list(self.config.parent.glob(".*.board-backup-*"))

    def fake_cli(self, mode="success"):
        """Run an actual child process with its own explicit fixture path."""
        script = self.root / "fake-claude"
        source = """#!PYTHON
import json, pathlib, sys
path = pathlib.Path(CONFIG)
args = sys.argv[1:]
assert args[:7] == ['mcp', 'add', '--transport', 'stdio', '--scope', 'user', 'board']
assert args[7] == '--'
if MODE == 'failure':
    print('PRIVATE_SENTINEL', file=sys.stderr)
    raise SystemExit(7)
data = json.loads(path.read_text()) if path.exists() else {}
data.setdefault('mcpServers', {})['board'] = {'type': 'stdio', 'command': args[8], 'args': args[9:], 'env': {}}
if MODE == 'other-change': data['preferences'] = {'locale': 'changed'}
if MODE == 'first-run': data['firstStartVersion'] = 'fixture-version'
path.write_text(json.dumps(data))
"""
        script.write_text(source.replace("PYTHON", sys.executable).replace("CONFIG", repr(str(self.config))).replace("MODE", repr(mode)))
        script.chmod(0o700)
        return script

    def test_desktop_creates_private_config(self):
        result = setup.configure_desktop(self.config, self.expected)
        self.assertEqual(result["status"], "connected")
        self.assertEqual(json.loads(self.config.read_text()), {"mcpServers": {"board": self.expected}})
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_desktop_preserves_settings_permissions_and_private_backup(self):
        self.write()
        original_bytes = self.config.read_bytes()
        self.config.chmod(0o640)
        result = setup.configure_desktop(self.config, self.expected)
        config = json.loads(self.config.read_text())
        self.assertEqual(setup.unrelated_settings(config), self.original)
        self.assertEqual(config["mcpServers"]["board"], self.expected)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o640)
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(self.backups()[0].read_bytes(), original_bytes)
        self.assertEqual(stat.S_IMODE(self.backups()[0].stat().st_mode), 0o600)
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(result))

    def test_desktop_idempotent_without_backup_or_rewrite(self):
        self.write({"mcpServers": {"board": self.expected}})
        before = setup.fingerprint(self.config.stat())
        self.assertEqual(setup.configure_desktop(self.config, self.expected)["status"], "unchanged")
        self.assertEqual(setup.fingerprint(self.config.stat()), before)
        self.assertEqual(self.backups(), [])

    def test_desktop_check_does_not_create_directory(self):
        self.assertEqual(setup.configure_desktop(self.config, self.expected, check=True)["status"], "missing")
        self.assertFalse(self.config.parent.exists())

    def test_rejects_corrupt_duplicate_future_and_unsupported_config(self):
        self.config.parent.mkdir()
        for data in [b"{", b'{"a":1,"a":2}', b"[]", b'{"mcpServers": []}', b'{"schemaVersion": 2}']:
            with self.subTest(data=data):
                self.config.write_bytes(data)
                with self.assertRaises(setup.SetupError):
                    setup.configure_desktop(self.config, self.expected)
                self.assertEqual(self.config.read_bytes(), data)
                self.assertEqual(self.backups(), [])

    def test_rejects_symlink_file(self):
        target = self.root / "real-config"
        target.write_text("{}")
        self.config.parent.mkdir()
        self.config.symlink_to(target)
        with self.assertRaises(setup.SetupError):
            setup.configure_desktop(self.config, self.expected)
        self.assertEqual(target.read_text(), "{}")

    def test_rejects_symlink_directory(self):
        target = self.root / "real-directory"
        target.mkdir()
        self.config.parent.symlink_to(target)
        with self.assertRaises(setup.SetupError):
            setup.configure_desktop(self.config, self.expected)
        self.assertEqual(list(target.iterdir()), [])

    def test_rejects_special_file_without_blocking(self):
        self.config.parent.mkdir()
        os.mkfifo(self.config)
        with self.assertRaises(setup.SetupError):
            setup.configure_desktop(self.config, self.expected)

    def test_rejects_large_config(self):
        self.write()
        with mock.patch.object(setup, "MAX_CONFIG_BYTES", 8):
            with self.assertRaises(setup.SetupError):
                setup.configure_desktop(self.config, self.expected)

    def test_existing_different_board_is_preserved(self):
        self.write({"mcpServers": {"board": {"command": "someone-elses-board"}}})
        original = self.config.read_bytes()
        for operation in [lambda: setup.configure_desktop(self.config, self.expected),
                          lambda: setup.configure_code(self.config, self.expected, "unused", runner=mock.Mock())]:
            with self.assertRaisesRegex(setup.SetupError, "already has different"):
                operation()
            self.assertEqual(self.config.read_bytes(), original)
        self.assertEqual(self.backups(), [])

    def test_concurrent_edit_is_not_overwritten(self):
        self.write()
        snapshot, value = setup.read_config(self.config)
        value.setdefault("mcpServers", {})["board"] = self.expected
        concurrent = {"newSetting": "written-by-Claude"}
        self.write(concurrent)
        with self.assertRaisesRegex(setup.SetupError, "changed during"):
            setup.atomic_config_write(self.config, snapshot, value)
        self.assertEqual(json.loads(self.config.read_text()), concurrent)
        self.assertEqual(self.backups(), [])

    def test_concurrent_edit_after_temp_write_is_not_overwritten(self):
        self.write()
        snapshot, value = setup.read_config(self.config)
        real_compare = setup.same_snapshot
        calls = 0
        def compare(path, initial):
            nonlocal calls
            calls += 1
            if calls == 2:
                self.write({"changed": True})
            return real_compare(path, initial)
        with mock.patch.object(setup, "same_snapshot", side_effect=compare):
            with self.assertRaisesRegex(setup.SetupError, "changed during"):
                setup.atomic_config_write(self.config, snapshot, value)
        self.assertEqual(json.loads(self.config.read_text()), {"changed": True})
        self.assertEqual(list(self.config.parent.glob(".board-setup-*")), [])

    def test_code_uses_official_cli_and_preserves_other_settings(self):
        self.write()
        result = setup.configure_code(self.config, self.expected, self.fake_cli())
        self.assertEqual(result["status"], "connected")
        config = json.loads(self.config.read_text())
        self.assertTrue(setup.entry_matches(config["mcpServers"]["board"], self.expected))
        self.assertEqual(setup.unrelated_settings(config), self.original)
        self.assertEqual(len(self.backups()), 1)
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(result))

    def test_code_existing_entry_never_runs_cli(self):
        self.write({"mcpServers": {"board": dict(self.expected, type="stdio", env={})}})
        runner = mock.Mock()
        self.assertEqual(setup.configure_code(self.config, self.expected, "unused", runner=runner)["status"], "unchanged")
        runner.assert_not_called()

    def test_code_failed_cli_never_exposes_output(self):
        self.write()
        before = self.config.read_bytes()
        with self.assertRaises(setup.SetupError) as error:
            setup.configure_code(self.config, self.expected, self.fake_cli("failure"))
        self.assertNotIn("PRIVATE_SENTINEL", str(error.exception))
        self.assertEqual(self.config.read_bytes(), before)

    def test_code_detects_unrelated_mutation(self):
        self.write()
        with self.assertRaisesRegex(setup.SetupError, "changed other settings"):
            setup.configure_code(self.config, self.expected, self.fake_cli("other-change"))
        self.assertEqual(json.loads(self.backups()[0].read_text()), self.original)

    def test_code_allows_its_own_new_initialization_metadata(self):
        self.write()
        result = setup.configure_code(self.config, self.expected, self.fake_cli("first-run"))
        self.assertEqual(result["status"], "connected")
        config = json.loads(self.config.read_text())
        self.assertEqual(config["firstStartVersion"], "fixture-version")
        self.assertEqual(config["preferences"], self.original["preferences"])

    def test_code_custom_config_directory_is_respected(self):
        with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(self.root)}), \
             mock.patch.object(setup, "resolve_executable", return_value=Path("/fixture/claude")), \
             mock.patch.object(setup, "configure_code", return_value={"status": "connected"}) as configure:
            setup.run_setup("code", Path(sys.executable), self.root / "board-mcp.py")
        self.assertEqual(configure.call_args.args[0], self.root / ".claude.json")

    def test_code_timeout_is_verified_without_retry(self):
        self.write()
        def timed_out(command, **kwargs):
            subprocess.run(command, check=True)
            raise subprocess.TimeoutExpired(command, 20)
        runner = mock.Mock(side_effect=timed_out)
        result = setup.configure_code(self.config, self.expected, self.fake_cli(), runner=runner)
        self.assertEqual(result["status"], "connected")
        self.assertIn("verified", result["message"])
        self.assertEqual(runner.call_count, 1)

    def test_missing_clients_are_skipped(self):
        with mock.patch.object(setup.Path, "home", return_value=self.root), \
             mock.patch.object(setup.Path, "is_dir", return_value=False), \
             mock.patch.object(setup, "resolve_executable", return_value=None):
            results = setup.run_setup("all", sys.executable, self.root / "board-mcp.py")
        self.assertEqual([item["status"] for item in results], ["skipped", "skipped"])

    def test_cli_invalid_paths_return_sanitized_json(self):
        completed = subprocess.run([sys.executable, str(SCRIPT), "--python", "/nonexistent/python", "--json"],
                                   capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, 1)
        report = json.loads(completed.stdout)
        self.assertFalse(report["ok"])
        self.assertEqual(completed.stderr, "")


if __name__ == "__main__":
    unittest.main()
