#!/usr/bin/env python3
"""Patch ChatGPT's Linux primary window to use KWin decorations."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
import shutil
import sys
import tempfile
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parent
ARCHIVE = APP_ROOT / "usr/lib/chatgpt/resources/app.asar"
EXECUTABLE = APP_ROOT / "usr/lib/chatgpt/ChatGPT"
VERSION_FILE = APP_ROOT / "usr/lib/chatgpt/version"
LOCK_FILE = APP_ROOT / "patch-native-decoration.lock"


def same_size(source: bytes, replacement: bytes) -> bytes:
    if len(replacement) > len(source):
        raise ValueError("replacement is longer than source")
    return replacement + b" " * (len(source) - len(replacement))


WINDOW_SOURCE = b"n===`win32`||n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:A9(r),...e===`quickChat`?{resizable:!0}:{}}:{titleBarStyle:`default`,...e===`quickChat`?{resizable:!0}:{}}"
WINDOW_PATCH = same_size(
    WINDOW_SOURCE,
    b"n===`win32`?{titleBarStyle:`hidden`,titleBarOverlay:A9(r),...e===`quickChat`?{resizable:!0}:{}}:{...e===`quickChat`?{resizable:!0}:{}}",
)

ZOOM_SOURCE = b"(process.platform===`win32`||process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(A9(t)))"
ZOOM_PATCH = same_size(
    ZOOM_SOURCE,
    b"(process.platform===`win32`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(A9(t)))",
)

SYNC_SOURCE = b"if(process.platform!==`win32`&&process.platform!==`linux`||t!==`primary`&&t!==`quickChat`)return;let n=()=>{e.isDestroyed()||e.setTitleBarOverlay(A9(this.windowZooms.get(e.id)))};return l.nativeTheme.on(`updated`,n),n(),()=>{l.nativeTheme.off(`updated`,n)}}"
SYNC_PATCH = SYNC_SOURCE.replace(
    b"&&process.platform!==`linux`",
    b" " * len(b"&&process.platform!==`linux`"),
    1,
)

RULES = (
    ("BrowserWindow title-bar options", WINDOW_SOURCE, WINDOW_PATCH),
    ("zoom overlay update", ZOOM_SOURCE, ZOOM_PATCH),
    ("theme overlay update", SYNC_SOURCE, SYNC_PATCH),
)


def archive_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def app_version() -> str:
    try:
        return VERSION_FILE.read_text(encoding="ascii").strip() or "unknown"
    except OSError:
        return "unknown"


def executable_is_running() -> bool:
    executable = str(EXECUTABLE.resolve())
    for process in Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            command = (process / "cmdline").read_bytes().split(b"\0", 1)[0]
            if command and os.path.realpath(os.fsdecode(command)) == executable:
                return True
        except (OSError, UnicodeError):
            continue
    return False


def replace_exact(data: bytes, source: bytes, replacement: bytes) -> bytes:
    count = data.count(source)
    if count != 1:
        raise RuntimeError(f"expected one match, found {count}")
    if len(source) != len(replacement):
        raise RuntimeError("patch strings must have identical lengths")
    return data.replace(source, replacement, 1)


def atomic_write(data: bytes) -> None:
    mode = ARCHIVE.stat().st_mode & 0o7777
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{ARCHIVE.name}.", suffix=".tmp", dir=ARCHIVE.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, ARCHIVE)
        directory = os.open(ARCHIVE.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def backup_path(before_hash: str) -> Path:
    version = "".join(
        character if character.isalnum() or character in ".-_" else "_"
        for character in app_version()
    )
    return ARCHIVE.with_name(
        f"{ARCHIVE.name}.native-decoration.{version}.{before_hash[:12]}.bak"
    )


def state(data: bytes, source: bytes, patch: bytes) -> str:
    source_count = data.count(source)
    patch_count = data.count(patch)
    if source_count == 1 and patch_count == 0:
        return "original"
    if source_count == 0 and patch_count == 1:
        return "patched"
    return f"unknown (original={source_count}, patched={patch_count})"


def status(data: bytes) -> int:
    print(f"ChatGPT version: {app_version()}")
    print(f"ASAR SHA-256: {archive_hash(data)}")
    states = []
    for name, source, patch in RULES:
        current = state(data, source, patch)
        states.append(current)
        print(f"{name}: {current}")
    if all(current == "patched" for current in states):
        print("Native decoration patch: applied")
    elif all(current == "original" for current in states):
        print("Native decoration patch: not applied")
    else:
        print("Native decoration patch: partial/unknown")
    return 0


def apply_patch(data: bytes, quiet: bool) -> int:
    current_states = [state(data, source, patch) for _, source, patch in RULES]
    if all(current == "patched" for current in current_states):
        if not quiet:
            print("Native decoration patch is already applied.")
        return 0
    if not all(current == "original" for current in current_states):
        raise RuntimeError("bundle does not match the expected unpatched ChatGPT version")

    before_hash = archive_hash(data)
    patched_data = data
    for _, source, patch in RULES:
        patched_data = replace_exact(patched_data, source, patch)

    backup = backup_path(before_hash)
    if not backup.exists():
        shutil.copy2(ARCHIVE, backup)
    atomic_write(patched_data)
    print(f"Applied native decoration patch to ChatGPT {app_version()}.")
    print(f"Backup: {backup}")
    print(f"New ASAR SHA-256: {archive_hash(patched_data)}")
    return 0


def restore_patch(data: bytes) -> int:
    current_states = [state(data, source, patch) for _, source, patch in RULES]
    if all(current == "original" for current in current_states):
        print("Native decoration patch is not applied.")
        return 0
    if not all(current == "patched" for current in current_states):
        raise RuntimeError("bundle is partially patched; refusing automatic restore")

    restored_data = data
    for _, source, patch in RULES:
        restored_data = replace_exact(restored_data, patch, source)
    atomic_write(restored_data)
    print(f"Restored original ChatGPT window decoration behavior for {app_version()}.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--apply", action="store_true", help="apply the patch")
    action.add_argument("--restore", action="store_true", help="remove the patch")
    action.add_argument("--status", action="store_true", help="show patch status")
    parser.add_argument("--quiet", action="store_true", help="suppress already-applied output")
    args = parser.parse_args()

    if not ARCHIVE.is_file():
        print(f"ChatGPT ASAR archive not found: {ARCHIVE}", file=sys.stderr)
        return 1
    try:
        data = ARCHIVE.read_bytes()
    except OSError as error:
        print(f"Unable to read {ARCHIVE}: {error}", file=sys.stderr)
        return 1

    if args.status:
        return status(data)
    if executable_is_running():
        print("ChatGPT is running; close it before changing app.asar.", file=sys.stderr)
        return 1

    try:
        with LOCK_FILE.open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            data = ARCHIVE.read_bytes()
            if args.restore:
                return restore_patch(data)
            return apply_patch(data, args.quiet)
    except (OSError, RuntimeError) as error:
        print(f"Native decoration patch failed: {error}", file=sys.stderr)
        print("The installed bundle was not changed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
