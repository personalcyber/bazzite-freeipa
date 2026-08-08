#!/usr/bin/env python3
"""Rebuild a SQLite-backed flatpak_packages table for osquery ATC.

osquery has no native flatpak_packages table (unlike deb_packages /
rpm_packages), so Fleet's Software inventory can't see installed Flatpak
apps out of the box -- a real gap on an image where Flatpak/Flathub is a
first-class app delivery mechanism.

This script runs `flatpak list` and writes the results into a plain
SQLite database that osquery's Automatic Table Construction (ATC) feature
can expose as a normal queryable table. The database is inert on its own;
it needs a Fleet-side agent_options entry to actually become queryable --
see the auto_table_construction snippet in README.md.

Only the system-wide Flatpak installation (/var/lib/flatpak) is covered,
since this runs as root via a systemd timer; per-user installs under
~/.local/share/flatpak are not enumerated.
"""

import os
import sqlite3
import subprocess
import sys

DB_DIR = "/var/lib/flatpak-inventory"
DB_PATH = os.path.join(DB_DIR, "flatpak.db")
COLUMNS = ["application", "version", "branch", "origin", "ref", "installation"]


def list_flatpaks():
    """Return one tuple per installed app, in COLUMNS order.

    --columns gives stable, script-friendly tab-separated output with no
    header, unlike the default human-oriented table.
    """
    result = subprocess.run(
        ["flatpak", "list", "--app", "--columns=" + ",".join(COLUMNS)],
        capture_output=True,
        text=True,
        check=True,
    )
    rows = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != len(COLUMNS):
            print(f"skipping malformed flatpak list line: {line!r}", file=sys.stderr)
            continue
        rows.append(tuple(fields))
    return rows


def main():
    try:
        rows = list_flatpaks()
    except FileNotFoundError:
        # flatpak isn't installed on this system; nothing to inventory.
        return 0
    except subprocess.CalledProcessError as exc:
        print(f"flatpak list failed: {exc}", file=sys.stderr)
        return 1

    # Created here rather than at build time: unlike orbit's /opt payload
    # (see the tmpfiles.d seeding in build.sh), this directory and its
    # contents only ever exist at runtime, so there's no build-time /var
    # content that needs seeding onto a deployed system.
    os.makedirs(DB_DIR, exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    try:
        # DROP+CREATE on every run so apps that were removed since the
        # last run disappear from the table instead of lingering as stale
        # rows.
        conn.execute("DROP TABLE IF EXISTS flatpak_packages")
        conn.execute(
            "CREATE TABLE flatpak_packages ({})".format(
                ", ".join(f"{col} TEXT" for col in COLUMNS)
            )
        )
        conn.executemany(
            "INSERT INTO flatpak_packages ({}) VALUES ({})".format(
                ", ".join(COLUMNS), ", ".join("?" for _ in COLUMNS)
            ),
            rows,
        )
        conn.commit()
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
