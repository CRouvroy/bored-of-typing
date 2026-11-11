#!/usr/bin/env python3
"""Connect Board to local Claude clients. No model requests or authentication.

Existing client settings are opaque: only mcpServers.board is inspected/changed.
Config backups remain beside the original config with mode 0600. Nothing from
those settings, or from Claude's subprocess output, is included in our output.
"""

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid


MAX_CONFIG_BYTES = 4 * 1024 * 1024


class SetupError(Exception):
    """A deliberately sanitized, user-visible setup error."""


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SetupError("The Claude config has duplicate keys; it was left unchanged.")
        result[key] = value
    return result


def safe_directory(path, create=False):
    """Reject symlinked config directories instead of following them."""
    path = Path(path).absolute()
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if not create:
                return False
            try:
                current.mkdir(mode=0o700)
            except FileExistsError:
                pass
            info = current.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise SetupError("The Claude config directory is not a regular directory; it was left unchanged.")
    return True


def read_config(path):
    """Read a bounded regular file without following a final symlink."""
    if not safe_directory(path.parent):
        return None, {}
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None, {}
    except OSError:
        raise SetupError("The Claude config cannot be safely opened; it was left unchanged.") from None
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_CONFIG_BYTES:
            raise SetupError("The Claude config is not a supported regular file; it was left unchanged.")
        data = stream.read(MAX_CONFIG_BYTES + 1)
        after = os.fstat(stream.fileno())
    if len(data) > MAX_CONFIG_BYTES or fingerprint(info) != fingerprint(after):
        raise SetupError("The Claude config changed during setup. Try again after closing Claude.")
    try:
        value = json.loads(data, object_pairs_hook=no_duplicate_keys)
    except (ValueError, UnicodeError):
        raise SetupError("The Claude config is not valid JSON; it was left unchanged.") from None
    if not isinstance(value, dict) or ("mcpServers" in value and not isinstance(value["mcpServers"], dict)):
        raise SetupError("The Claude config format is unsupported; it was left unchanged.")
    # Neither client's documented config has a schemaVersion. Do not guess at a
    # future versioned format; unrelated current setting values are preserved.
    if "schemaVersion" in value:
        raise SetupError("This versioned Claude config is unsupported; it was left unchanged.")
    return (fingerprint(after), data, stat.S_IMODE(after.st_mode)), value


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def same_snapshot(path, snapshot):
    current, _ = read_config(path)
    return current == snapshot


@contextmanager
def config_lock(path):
    safe_directory(path.parent, create=True)
    lock_path = path.with_name("." + path.name + ".board-setup.lock")
    try:
        descriptor = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            os.close(descriptor)
            raise SetupError("The Claude config lock is not a regular file.")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        if "descriptor" in locals():
            os.close(descriptor)
        raise SetupError("Claude setup is already running, or its config cannot be locked.") from None
    try:
        yield
    finally:
        os.close(descriptor)


def write_backup(path, data):
    backup = path.with_name("." + path.name + ".board-backup-" + uuid.uuid4().hex)
    descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def atomic_config_write(path, snapshot, value):
    if not same_snapshot(path, snapshot):
        raise SetupError("The Claude config changed during setup. Try again after closing Claude.")
    descriptor, temporary = tempfile.mkstemp(prefix=".board-setup-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), snapshot[2] if snapshot else 0o600)
            stream.write((json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
        if not same_snapshot(path, snapshot):
            raise SetupError("The Claude config changed during setup. Try again after closing Claude.")
        if snapshot:
            write_backup(path, snapshot[1])
        if not same_snapshot(path, snapshot):
            raise SetupError("The Claude config changed during setup. Try again after closing Claude.")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def expected_entry(python, server_script):
    return {"command": str(python), "args": [str(server_script)]}


def entry_matches(entry, expected):
    # Claude Code serializes explicit stdio + empty env; Desktop need not.
    return isinstance(entry, dict) and entry.get("command") == expected["command"] \
        and entry.get("args") == expected["args"] \
        and entry.get("type", "stdio") == "stdio" and entry.get("env", {}) == {} \
        and set(entry).issubset({"command", "args", "type", "env"})


def entry_state(config, expected):
    servers = config.get("mcpServers", {})
    if "board" not in servers:
        return "missing"
    if entry_matches(servers["board"], expected):
        return "unchanged"
    raise SetupError("An MCP named board already has different settings; it was left unchanged.")


def result(client, status, message):
    return {"client": client, "status": status, "message": message}


def configure_desktop(config_path, expected, check=False):
    client = "Claude Desktop"
    if check:
        _, value = read_config(config_path)
        state = entry_state(value, expected)
        return result(client, state, "Already connected." if state == "unchanged" else "Ready to connect.")
    with config_lock(config_path):
        snapshot, value = read_config(config_path)
        if entry_state(value, expected) == "unchanged":
            return result(client, "unchanged", "Already connected. Restart Claude if Board is not listed.")
        value.setdefault("mcpServers", {})["board"] = expected
        atomic_config_write(config_path, snapshot, value)
    return result(client, "connected", "Connected. Restart Claude.")


def unrelated_settings(config):
    # Used only for in-memory verification; never logged or returned.
    value = dict(config)
    servers = dict(value.pop("mcpServers", {}))
    servers.pop("board", None)
    if servers:
        value["mcpServers"] = servers
    return value


def configure_code(config_path, expected, executable, check=False, runner=subprocess.run):
    client = "Claude Code"
    if check:
        _, value = read_config(config_path)
        state = entry_state(value, expected)
        return result(client, state, "Already connected." if state == "unchanged" else "Ready to connect.")
    with config_lock(config_path):
        snapshot, before = read_config(config_path)
        if entry_state(before, expected) == "unchanged":
            return result(client, "unchanged", "Already connected. Start a new Claude Code session.")
        if snapshot:
            write_backup(config_path, snapshot[1])
        if not same_snapshot(config_path, snapshot):
            raise SetupError("The Claude config changed during setup. Try again after closing Claude.")
        command = [str(executable), "mcp", "add", "--transport", "stdio", "--scope", "user", "board", "--",
                   expected["command"], *expected["args"]]
        try:
            # No health check, server launch, provider login, or model call.
            # Discard CLI output because unrelated settings may include secrets.
            completed = runner(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=20, check=False)
            succeeded = completed.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            succeeded = False
        _, after = read_config(config_path)
        installed = entry_matches(after.get("mcpServers", {}).get("board"), expected)
        before_settings, after_settings = unrelated_settings(before), unrelated_settings(after)
        # Claude may add its own first-run/migration metadata. Existing values
        # and all previously configured servers must remain intact.
        if any(key not in after_settings or after_settings[key] != value for key, value in before_settings.items()):
            raise SetupError("Claude Code changed other settings during setup. A private backup was kept beside its config; review it before retrying.")
        if not installed:
            raise SetupError("Claude Code did not finish connecting Board. Its output was omitted to keep your settings private.")
        # A timed-out CLI can have completed its config write. Verify instead of
        # rerunning an action with an uncertain outcome.
        message = "Connected. Start a new Claude Code session."
        if not succeeded:
            message = "Connection verified. Start a new Claude Code session."
        return result(client, "connected", message)


def resolve_executable(candidates):
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return path.resolve()
    return None


def run_setup(client, python, server_script, check=False):
    task_home = Path.home()
    expected = expected_entry(python, server_script)
    outcomes = []
    desktop_path = task_home / "Library/Application Support/Claude/claude_desktop_config.json"
    for selected in ("desktop", "code"):
        if client not in ("all", selected):
            continue
        label = "Claude Desktop" if selected == "desktop" else "Claude Code"
        try:
            if selected == "desktop":
                installed = any(path.is_dir() for path in (Path("/Applications/Claude.app"), task_home / "Applications/Claude.app"))
                if not installed:
                    outcomes.append(result(label, "skipped", "Not installed."))
                    continue
                outcomes.append(configure_desktop(desktop_path, expected, check))
            else:
                executable = resolve_executable([shutil.which("claude"), task_home / ".local/bin/claude",
                                                 "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
                if not executable:
                    outcomes.append(result(label, "skipped", "Not installed."))
                    continue
                custom_directory = os.environ.get("CLAUDE_CONFIG_DIR")
                config_directory = Path(custom_directory).expanduser() if custom_directory else task_home
                if not config_directory.is_absolute():
                    raise SetupError("Claude Code's custom config directory must use an absolute path.")
                outcomes.append(configure_code(config_directory / ".claude.json", expected, executable, check))
        except SetupError as error:
            outcomes.append(result(label, "error", str(error)))
        except OSError:
            outcomes.append(result(label, "error", "The Claude config could not be updated. Check its file permissions."))
    return outcomes


def main():
    parser = argparse.ArgumentParser(description="Connect Board's local MCP to Claude Desktop and Claude Code.")
    parser.add_argument("--client", choices=("desktop", "code", "all"), default="all")
    parser.add_argument("--python", default=sys.executable, help="Absolute Python 3 executable used by Claude.")
    parser.add_argument("--server-script", type=Path, default=Path(__file__).resolve().with_name("board-mcp.py"))
    parser.add_argument("--check", action="store_true", help="Check without changing any settings or launching servers.")
    parser.add_argument("--json", action="store_true", help="Print only sanitized structured results.")
    arguments = parser.parse_args()
    python = resolve_executable([arguments.python])
    server = arguments.server_script.expanduser().resolve()
    if not python or not Path(arguments.python).is_absolute() or not server.is_file() or server.name != "board-mcp.py":
        outcomes = [result("Board", "error", "Board's bundled MCP or Python 3 is missing.")]
    else:
        outcomes = run_setup(arguments.client, python, server, arguments.check)
    ok = any(item["status"] in ("connected", "unchanged", "missing") for item in outcomes)
    if arguments.json:
        print(json.dumps({"ok": ok, "results": outcomes}))
    else:
        for item in outcomes:
            print(item["client"] + ": " + item["message"])
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
