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
    # Presentational attributes from HTML 4. Current Chrome ignored `<body background>` in
    # testing, but other engines honour it and the cost of covering it is one line.
    "body": ("background",),
    "table": ("background",),
    "td": ("background",),
    "th": ("background",),
}

# rel values that DO fetch. A rel list is whitelisted only when it contains none of these:
# `rel="canonical stylesheet"` is one inert token plus one fetching token, and testing for
# the presence of an inert token let the whole element through.
FETCHING_REL = {"stylesheet", "preload", "prefetch", "preconnect", "dns-prefetch",
                "modulepreload", "prerender", "icon", "apple-touch-icon", "manifest",
                "mask-icon", "shortcut"}

OFF_ORIGIN = re.compile(r"^(?:https?:)?//", re.I)

# Tab, newline and other C0 controls are stripped by the URL parser before the scheme is
# read, so `h&#9;ttp://host` loads. Backslashes are folded to forward slashes, so
# `/\host/x.css` is protocol-relative. Normalise the same way before matching.
CONTROLS = re.compile(r"[\x00-\x20\x7f]")


def normalise(value: str) -> str:
    return CONTROLS.sub("", value).replace("\\", "/")


def offsite(value: str) -> bool:
    """True for absolute and protocol-relative URLs. Relative paths and data: are fine."""
    return bool(value) and bool(OFF_ORIGIN.match(normalise(value)))


def offsite_in_srcset(value: str) -> list[str]:
    # "a.png 1x, //cdn/b.png 2x" -> each candidate's URL is the first token.
    hits = []
    for candidate in value.split(","):
        parts = candidate.strip().split()
        if parts and offsite(parts[0]):
            hits.append(parts[0])
    return hits


META_REFRESH_URL = re.compile(r"url\s*=\s*(.+)$", re.I | re.S)


class Scanner(HTMLParser):
    def __init__(self, path: Path) -> None:
        super().__init__(convert_charrefs=True)
        self.path = path
        self.problems: list[str] = []
        self._in_style = False
        self._style_line = 0
        self._style_text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        # First occurrence wins, matching how a browser resolves a duplicated attribute.
        # Building the dict in order let a second `href` override the one Chrome actually
        # uses, so `<link href="ok.css" href="//cdn/evil.css">` scanned clean and fetched
        # the first while the check inspected the second.
        got: dict[str, str] = {}
        for key, value in attrs:
            got.setdefault(key.lower(), value or "")
        line = self.getpos()[0]

        if tag == "style":
            self._in_style = True
            self._style_line = line
            self._style_text = []

        # Inline CSS, in a <style> block or a style="" attribute, was not scanned at all —
        # and an @import or a url() there fetches exactly like one in a .css file. This was
        # the largest hole in the check: adding a webfont inline is the most natural way the
        # page's promise would have been broken.
        if "style" in got:
            self.problems += [f"{self.path}:{line}: style attribute: {problem}"
                              for problem in scan_css_text(got["style"])]

        if tag == "meta" and got.get("http-equiv", "").lower() == "refresh":
            match = META_REFRESH_URL.search(got.get("content", ""))
            if match and offsite(match.group(1).strip().strip("'\"")):
                self.problems.append(f"{self.path}:{line}: <meta refresh> to {match.group(1).strip()}")
            return

        for attr in FETCHING.get(tag, ()):
            value = got.get(attr, "")
            if not value:
                continue
            if tag == "link" and attr == "href":
                rels = set(got.get("rel", "").lower().split())
                if rels and rels.isdisjoint(FETCHING_REL):
                    continue
            if attr.endswith("srcset"):
                for hit in offsite_in_srcset(value):
                    self.problems.append(f"{self.path}:{line}: <{tag} {attr}> -> {hit}")
            elif offsite(value):
                self.problems.append(f"{self.path}:{line}: <{tag} {attr}> -> {value}")

    def handle_data(self, data: str) -> None:
        if self._in_style:
            self._style_text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "style" and self._in_style:
            self._in_style = False
            self.problems += [f"{self.path}:{self._style_line}: <style>: {problem}"
                              for problem in scan_css_text("".join(self._style_text))]


# DOTALL and \s* between the tokens: a declaration split across lines is still one
# declaration to a CSS parser, and the previous line-at-a-time scan could not see it.
CSS_URL = re.compile(r"url\(\s*['\"]?\s*([^)'\"]+)", re.I | re.S)
CSS_IMPORT = re.compile(r"@import\s+(?:url\(\s*)?['\"]?\s*([^)'\";\s]+)", re.I | re.S)
CSS_FONTFACE = re.compile(r"@font-face", re.I)


def scan_css_text(text: str) -> list[str]:
    """Problems in a stylesheet, a <style> block, or a style="" attribute."""
    problems = []
    for match in CSS_URL.finditer(text):
        if offsite(match.group(1)):
            problems.append(f"css url() -> {match.group(1).strip()}")
    for match in CSS_IMPORT.finditer(text):
        if offsite(match.group(1)):
            problems.append(f"@import -> {match.group(1).strip()}")
    if CSS_FONTFACE.search(text):
        problems.append("@font-face (the page ships no fonts)")
    return problems


def scan_css(path: Path) -> list[str]:
    return [f"{path}: {problem}" for problem in scan_css_text(path.read_text(encoding="utf-8"))]


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
