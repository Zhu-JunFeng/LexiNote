#!/usr/bin/env python3
"""Build LexiNote's read-only ECDICT lookup resource.

The source is pinned to skywind3000/ECDICT commit bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b.
Run `python3 Scripts/build_ecdict.py` to download and regenerate the bundled SQLite file,
or pass `--csv /path/to/ecdict.csv` to use an already downloaded copy.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
from pathlib import Path
import sqlite3
import tempfile
from urllib.request import urlopen


SOURCE_COMMIT = "bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b"
SOURCE_URL = f"https://raw.githubusercontent.com/skywind3000/ECDICT/{SOURCE_COMMIT}/ecdict.csv"
SOURCE_SHA256 = "1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf"
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "LexiNote" / "Resources" / "ecdict.sqlite"
REQUIRED_COLUMNS = {"word", "phonetic", "definition", "translation"}


def download(destination: Path) -> None:
    with urlopen(SOURCE_URL, timeout=60) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def build(source_csv: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    source_hash = sha256(source_csv)
    if source_hash != SOURCE_SHA256:
        raise ValueError(f"ECDICT CSV SHA-256 mismatch: expected {SOURCE_SHA256}, got {source_hash}")
    with tempfile.NamedTemporaryFile(prefix="ecdict-", suffix=".sqlite", dir=output.parent, delete=False) as temp:
        temporary_output = Path(temp.name)

    try:
        connection = sqlite3.connect(temporary_output)
        try:
            connection.executescript(
                """
                PRAGMA page_size=4096;
                PRAGMA journal_mode=OFF;
                PRAGMA synchronous=OFF;
                CREATE TABLE entries (
                    key TEXT PRIMARY KEY,
                    word TEXT NOT NULL,
                    phonetic TEXT,
                    definition TEXT,
                    translation TEXT
                ) WITHOUT ROWID;
                CREATE TABLE source_info (commit_hash TEXT NOT NULL, csv_sha256 TEXT NOT NULL);
                """
            )
            connection.execute("INSERT INTO source_info VALUES (?, ?)", (SOURCE_COMMIT, source_hash))
            with source_csv.open("r", encoding="utf-8-sig", newline="") as source:
                reader = csv.DictReader(source)
                if not REQUIRED_COLUMNS.issubset(reader.fieldnames or []):
                    raise ValueError("ECDICT CSV is missing required columns")

                batch: list[tuple[str, str, str | None, str | None, str | None]] = []
                for row in reader:
                    word = " ".join((row["word"] or "").split())
                    if not word:
                        continue
                    definition = (row["definition"] or "").strip() or None
                    translation = (row["translation"] or "").strip() or None
                    if not definition and not translation:
                        continue
                    batch.append((word.casefold(), word, (row["phonetic"] or "").strip() or None,
                                  definition, translation))
                    if len(batch) >= 10_000:
                        connection.executemany("INSERT OR IGNORE INTO entries VALUES (?, ?, ?, ?, ?)", batch)
                        batch.clear()
                if batch:
                    connection.executemany("INSERT OR IGNORE INTO entries VALUES (?, ?, ?, ?, ?)", batch)
            connection.commit()
            result = connection.execute("PRAGMA integrity_check").fetchone()
            if result != ("ok",):
                raise RuntimeError(f"SQLite integrity check failed: {result}")
            count = connection.execute("SELECT count(*) FROM entries").fetchone()[0]
        finally:
            connection.close()

        os.replace(temporary_output, output)
        print(f"Built {output}: {count:,} entries, {output.stat().st_size:,} bytes")
        print(f"ECDICT source: {SOURCE_URL}")
        print(f"Source SHA-256: {source_hash}")
    finally:
        temporary_output.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, help="Use a local ECDICT CSV instead of downloading")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    if args.csv:
        build(args.csv, args.output)
    else:
        with tempfile.TemporaryDirectory(prefix="lexinote-ecdict-") as directory:
            source_csv = Path(directory) / "ecdict.csv"
            download(source_csv)
            build(source_csv, args.output)


if __name__ == "__main__":
    main()
