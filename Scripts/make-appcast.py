#!/usr/bin/env python3
"""Writes appcast.json, the manifest Better Claude 0.1.x reads to find a newer release.

    make-appcast.py <version> <zip> <dmg> <notes.md>

0.1.x fetches releases/latest/download/appcast.json and checks the zip against zipSHA256.
Newer versions ignore this file and verify the zip's signature instead; it stays in each
release so older copies can still update to one that does.
"""
import datetime
import hashlib
import json
import os
import sys

version, zip_path, dmg_path, notes_path = sys.argv[1:5]
base = f"https://github.com/mandipadk/BetterClaude/releases/download/v{version}"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


notes = open(notes_path, encoding="utf-8").read().strip() if os.path.exists(notes_path) else ""
manifest = {
    "version": version,
    "build": os.popen("git rev-list --count HEAD").read().strip() or "1",
    "minimumSystemVersion": "26.0",
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        .isoformat().replace("+00:00", "Z"),
    "zipURL": f"{base}/{os.path.basename(zip_path)}",
    "zipSHA256": sha256(zip_path),
    "dmgURL": f"{base}/{os.path.basename(dmg_path)}",
    "dmgSHA256": sha256(dmg_path),
    "notes": notes,
}
json.dump(manifest, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
