# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
"""dnf plugin for changetrack-ng pre/post transaction snapshots.

Installed by `make install-hooks` to /etc/dnf/plugins/changetrack_ng.py.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys

import dnf

_DEFAULTS_FILE = "@DEFAULTSDIR@/changetrack-ng"


def _load_defaults() -> dict[str, str]:
    """Parse the defaults file (KEY=VALUE, shell-sourceable subset)."""
    result: dict[str, str] = {}
    try:
        with open(_DEFAULTS_FILE) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                if not key.isidentifier():
                    continue
                val = val.strip()
                if (val.startswith('"') and val.endswith('"')) or (
                    val.startswith("'") and val.endswith("'")
                ):
                    val = val[1:-1]
                result[key] = val
    except OSError:
        pass
    return result


class ChangeTrackNg(dnf.Plugin):
    name = "changetrack_ng"

    def _run(self, stage: str, required: bool = False) -> None:
        defaults = _load_defaults()
        env = {**os.environ, **defaults}

        extra_args = shlex.split(defaults.get("CHANGETRACK_EXTRA_ARGS", ""))
        cmd = ["@BINDIR@/changetrack-ng", "run", "--system"] + extra_args + ["-m", f"{stage}: dnf"]

        try:
            result = subprocess.run(
                cmd,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
        except Exception as exc:
            sys.stderr.write(f"[changetrack-ng] WARNING: {stage} hook failed: {exc}\n")
            return

        if result.returncode != 0:
            sys.stderr.write(
                f"[changetrack-ng] WARNING: {stage} hook exited with status {result.returncode}\n"
            )

    def resolved(self) -> None:
        self._run("pre-install", required=False)

    def transaction(self) -> None:
        self._run("post-install", required=False)
