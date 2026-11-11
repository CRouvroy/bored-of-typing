#!/usr/bin/env python3
"""Export only reviewed text-source inputs, never build output or board data."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import zipfile


ROOT_FILES = (".gitignore", "AGENTS.md", "LICENSE", "Package.swift", "README.md")
SOURCE_SUFFIXES = {
    "Sources": {".swift", ".cpp", ".h"},
    "tests": {".swift", ".mm", ".py"},
    "scripts": {".py", ".swift"},
}
SCRIPT_NAMES = {
    "build-app", "macos-sdk", "prepare-opencv-runtime", "swift-build", "test-ink",
    "test-library", "test-overlays", "test-regions", "test-tracking",
}
MAX_SOURCE_BYTES = 2 * 1024 * 1024
PATTERNS = {
    "private-key material": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "provider credential": re.compile(
        r"\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{25,}|"
        r"github_pat_[A-Za-z0-9_]{25,}|AKIA[A-Z0-9]{16})\b"),
    "credential literal": re.compile(
        r'''(?i)["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|authorization)["']?'''
        r'''\s*[:=]\s*["']([^"'\n]{6,})["']'''),
    "personal home path": re.compile(r"/Users/(?!example/|yourname/|username/)[A-Za-z0-9_. -]+/"),
}


class ExportError(Exception):
    pass


def source_paths(root):
    paths = []
    for name in ROOT_FILES:
        path = root / name
        if not path.is_file():
            raise ExportError("Missing project input: " + name)
        paths.append(path)
    for directory, suffixes in SOURCE_SUFFIXES.items():
        base = root / directory
        if base.is_symlink() or not base.is_dir():
            raise ExportError("Invalid source directory: " + directory)
        for current, directories, filenames in os.walk(base, followlinks=False):
            current = Path(current)
            kept = []
            for name in sorted(directories):
                if name.startswith(".") or name == "__pycache__":
                    continue
                path = current / name
                if path.is_symlink():
                    raise ExportError("Symlinked source directory: " + str(path.relative_to(root)))
                kept.append(name)
            directories[:] = kept
            for name in sorted(filenames):
                if name.startswith("."):
                    continue
                path = current / name
                if path.suffix in suffixes or (directory == "scripts" and path.parent == base and name in SCRIPT_NAMES):
                    paths.append(path)
    return sorted(paths, key=lambda path: str(path.relative_to(root)))


def checked_source(root, path):
    relative = path.relative_to(root).as_posix()
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_SOURCE_BYTES:
        raise ExportError("Unsupported source input: " + relative)
    # Open the inspected regular file without following a replacement symlink.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode) or opened.st_size > MAX_SOURCE_BYTES:
            raise ExportError("Unsupported source input: " + relative)
        data = stream.read(MAX_SOURCE_BYTES + 1)
    if len(data) > MAX_SOURCE_BYTES:
        raise ExportError("Source input exceeds size limit: " + relative)
    try:
        content = data.decode("utf-8")
    except UnicodeDecodeError:
        raise ExportError("Non-text source input: " + relative) from None
    for kind, pattern in PATTERNS.items():
        matches = list(pattern.finditer(content))
        if kind == "credential literal":
            # The anonymous public-registry token is held in memory and appended
            # at runtime; the constant header prefix contains no credential.
            matches = [match for match in matches if match.group(1).strip() != "Bearer"]
        if matches:
            raise ExportError("Review " + kind + " in " + relative + " before exporting.")
    return relative, data, 0o755 if opened.st_mode & 0o111 else 0o644


def export_source(root, output):
    root, output = Path(root).resolve(), Path(output).absolute()
    if output.suffix != ".zip" or output.is_symlink():
        raise ExportError("Choose a regular .zip output path.")
    files = [checked_source(root, path) for path in source_paths(root)]
    manifest = {"schemaVersion": 1, "files": {
        name: hashlib.sha256(data).hexdigest() for name, data, _ in files
    }}
    manifest_data = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    files.append(("SOURCE-MANIFEST.json", manifest_data, 0o644))
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".board-source-", suffix=".zip", dir=output.parent)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, data, mode in files:
                info = zipfile.ZipInfo("Board/" + name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return len(files) - 1


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=root / "dist/Board-source.zip")
    arguments = parser.parse_args()
    try:
        count = export_source(root, arguments.output)
    except (ExportError, OSError) as error:
        # ExportError only names the file/type. Never return matched values.
        message = str(error) if isinstance(error, ExportError) else "Could not read source inputs or write the archive."
        parser.exit(1, message + "\n")
    print("Exported " + str(count) + " source files to " + str(arguments.output))


if __name__ == "__main__":
    main()
