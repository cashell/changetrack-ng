# SPDX-FileCopyrightText: 2026 Christopher Cashell <topher@zyp.org>
# SPDX-License-Identifier: GPL-3.0-or-later
"""dnf plugin for changetrack-ng pre/post transaction snapshots.

Installed by `make install-hooks` to /etc/dnf/plugins/changetrack_ng.py.
"""

from __future__ import annotations

import subprocess

import dnf


class ChangeTrackNg(dnf.Plugin):
    name = "changetrack_ng"

    def _run(self, stage: str, required: bool) -> None:
        cmd = ["@BINDIR@/changetrack-ng", "run", "-m", f"{stage}: dnf"]
        try:
            result = subprocess.run(
                cmd,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as exc:
            if required:
                raise dnf.exceptions.Error(f"changetrack-ng hook failed: {exc}")
            return

        if result.returncode != 0 and required:
            raise dnf.exceptions.Error(
                f"changetrack-ng hook exited with status {result.returncode}"
            )

    def resolved(self) -> None:
        self._run("pre-install", required=True)

    def transaction(self) -> None:
        self._run("post-install", required=False)
