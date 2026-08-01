#!/usr/bin/env python3
"""Fail if the site references anything it would fetch from another origin.

The page tells its readers it loads no fonts, no scripts and no third-party assets. This
enforces that claim instead of trusting it, and runs in the Pages deploy before publishing.

Why a parser and not a grep. The first version of this check was an extended regular
expression, and a review defeated it fifteen times out of fifteen: protocol-relative
`//fonts.googleapis.com`, single-quoted and unquoted attribute values, a `<link>` split
across lines, `<base href>` (which silently re-hosts every relative URL on the page,
including styles.css), `srcset`, `imagesrcset`, `<video poster>`, `<svg><use href>`,
`<meta http-equiv=refresh>`, `<object data>`, and a violation sharing a line with the
canonical link, which the line-oriented exclusion then dropped whole. Attribute syntax has
too many shapes to match with a pattern; a parser sees them all as the same attribute.

An `<a href>` is deliberately allowed. A link is fetched when a person clicks it, which is
not the page loading an asset. `rel="canonical"` and `rel="alternate"` name a URL without
fetching it, so they are allowed too — as attributes, not as lines.
"""

from __future__ import annotations

import sys
import re
from html.parser import HTMLParser
from pathlib import Path

# tag -> attributes that cause a fetch.
FETCHING = {
    "link": ("href", "imagesrcset"),
    "script": ("src",),
    "iframe": ("src",),
    "img": ("src", "srcset"),
    "source": ("src", "srcset"),
    "video": ("src", "poster"),
    "audio": ("src",),
    "embed": ("src",),
    "object": ("data",),
    "track": ("src",),
    "input": ("src",),
    "use": ("href", "xlink:href"),
    "image": ("href", "xlink:href"),
    # <base> does not fetch anything itself; it re-points every relative URL on the page,
    # which is a more complete compromise than any single asset.
    "base": ("href",),
}

# rel values that name a URL rather than fetching one.
INERT_REL = {"canonical", "alternate", "license", "author", "help", "search", "me"}

OFF_ORIGIN = re.compile(r"^\s*(?:https?:)?//", re.I)


def offsite(value: str) -> bool:
    """True for absolute and protocol-relative URLs. Relative paths and data: are fine."""
    return bool(value) and bool(OFF_ORIGIN.match(value))


def offsite_in_srcset(value: str) -> list[str]:
    # "a.png 1x, //cdn/b.png 2x" -> each candidate's URL is the first token.
    hits = []
    for candidate in value.split(","):
        parts = candidate.strip().split()
        if parts and offsite(parts[0]):
            hits.append(parts[0])
    return hits


class Scanner(HTMLParser):
    def __init__(self, path: Path) -> None:
        super().__init__(convert_charrefs=True)
        self.path = path
        self.problems: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        got = {k.lower(): (v or "") for k, v in attrs}
        line = self.getpos()[0]

        if tag == "meta" and got.get("http-equiv", "").lower() == "refresh":
            # content="0; url=https://elsewhere"
            target = got.get("content", "")
            url = target.partition("url=")[2].strip().strip("'\"")
            if offsite(url):
                self.problems.append(f"{self.path}:{line}: <meta refresh> to {url}")
            return

        for attr in FETCHING.get(tag, ()):
            value = got.get(attr, "")
            if not value:
                continue
            if tag == "link" and attr == "href":
                rels = set(got.get("rel", "").lower().split())
                if rels & INERT_REL:
                    continue
            if attr.endswith("srcset"):
                for hit in offsite_in_srcset(value):
                    self.problems.append(f"{self.path}:{line}: <{tag} {attr}> -> {hit}")
            elif offsite(value):
                self.problems.append(f"{self.path}:{line}: <{tag} {attr}> -> {value}")


CSS_URL = re.compile(r"url\(\s*['\"]?\s*((?:https?:)?//[^)'\"\s]+)", re.I)
CSS_IMPORT = re.compile(r"@import\s+(?:url\()?\s*['\"]?\s*((?:https?:)?//[^)'\";\s]+)", re.I)
CSS_FONTFACE = re.compile(r"@font-face", re.I)


def scan_css(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    problems = []
    for number, line in enumerate(text.splitlines(), 1):
        for match in CSS_URL.finditer(line):
            problems.append(f"{path}:{number}: css url() -> {match.group(1)}")
        for match in CSS_IMPORT.finditer(line):
            problems.append(f"{path}:{number}: @import -> {match.group(1)}")
        if CSS_FONTFACE.search(line):
            problems.append(f"{path}:{number}: @font-face (the page ships no fonts)")
    return problems


def main(root: str) -> int:
    base = Path(root)
    problems: list[str] = []
    checked = 0

    for path in sorted(base.rglob("*")):
        if path.suffix.lower() in {".html", ".htm"}:
            checked += 1
            scanner = Scanner(path)
            scanner.feed(path.read_text(encoding="utf-8"))
            scanner.close()
            problems += scanner.problems
        elif path.suffix.lower() == ".css":
            checked += 1
            problems += scan_css(path)

    if not checked:
        print(f"error: no HTML or CSS found under {base}", file=sys.stderr)
        return 1

    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        print(f"\n{len(problems)} external reference(s); the page claims it loads none.",
              file=sys.stderr)
        return 1

    print(f"{checked} file(s) checked, no external references.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1 else "site"))
