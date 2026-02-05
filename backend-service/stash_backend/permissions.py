from __future__ import annotations

import os
import stat
from pathlib import Path

from .types import PermissionReport


def inspect_permissions(path: Path) -> PermissionReport:
    exists = path.exists()
    readable = os.access(path, os.R_OK)
    writable = os.access(path, os.W_OK)
    executable = os.access(path, os.X_OK)

    owner_uid = None
    owner_gid = None
    mode_octal = "0000"
    detail: str | None = None

    if exists:
        st = path.stat()
        owner_uid = st.st_uid
        owner_gid = st.st_gid
        mode_octal = oct(stat.S_IMODE(st.st_mode))

    stash_writable = False
    if exists and readable and executable:
        stash_path = path / ".stash"
        try:
            stash_path.mkdir(parents=True, exist_ok=True)
            probe = stash_path / ".perm_probe"
            with probe.open("w", encoding="utf-8") as f:
                f.write("ok")
            probe.unlink(missing_ok=True)
            stash_writable = True
        except PermissionError:
            detail = "Permission denied writing to project .stash directory"
        except OSError as exc:
            detail = f"Filesystem error when probing .stash: {exc}"

    needs_sudo = not (readable and executable and stash_writable)

    return PermissionReport(
        path=str(path),
        exists=exists,
        readable=readable,
        writable=writable,
        executable=executable,
        stash_writable=stash_writable,
        needs_sudo=needs_sudo,
        mode_octal=mode_octal,
        owner_uid=owner_uid,
        owner_gid=owner_gid,
        detail=detail,
    )
