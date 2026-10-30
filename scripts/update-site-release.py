#!/usr/bin/env python3
"""Point the Pages site at the download assets of a published release.

The site keeps a static fallback of `releases/latest/download/Faster-Spaces.zip`
so it works before the first automated release. Once a release is published,
this script rewrites the marked download anchors to the exact tag and updates
the visible version label, so the page describes the artifact that was built
rather than whichever release happens to be latest.

Markup contract (see docs/index.html):
  - anchors with `data-release-download`
  - an anchor with `data-release-checksum`
  - an element with `data-release-version` whose text is the version
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

VERSION_RE = re.compile(
    r"(?P<open><(?P<tag>[a-zA-Z0-9]+)\b[^>]*\bdata-release-version\b[^>]*>)"
    r"[^<]*"
    r"(?P<close></(?P=tag)>)"
)
DOWNLOAD_ANCHOR_RE = re.compile(r"<a\b[^>]*\bdata-release-download\b[^>]*>", re.I)
CHECKSUM_ANCHOR_RE = re.compile(r"<a\b[^>]*\bdata-release-checksum\b[^>]*>", re.I)
HREF_RE = re.compile(r'href="[^"]*"')


def set_hrefs(html: str, anchor_re: re.Pattern[str], url: str) -> tuple[str, int]:
    """Replace the href on every anchor carrying the given marker."""

    def replace_anchor(match: re.Match[str]) -> str:
        anchor = match.group(0)
        replaced, count = HREF_RE.subn(f'href="{url}"', anchor, count=1)
        if count != 1:
            raise ValueError(f"anchor has no href: {anchor}")
        return replaced

    return anchor_re.subn(replace_anchor, html)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="release version, for example 2.1.2")
    parser.add_argument("--tag", required=True, help="release tag, for example v2.1.2")
    parser.add_argument(
        "--index",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "docs" / "index.html",
        help="path to docs/index.html",
    )
    parser.add_argument(
        "--feed",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "docs" / "latest.json",
        help="update feed read by the app",
    )
    args = parser.parse_args()

    version = args.version.strip()
    tag = args.tag.strip()
    if not version or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?", version):
        parser.error(f"invalid version: {version!r}")
    if tag != f"v{version}" and not tag.startswith(f"v{version}-"):
        parser.error(f"tag {tag!r} does not match version {version!r}")

    if not args.index.is_file():
        parser.error(f"site file not found: {args.index}")

    download_url = (
        "https://github.com/PeterHindes/faster-spaces/releases/download/"
        f"{tag}/Faster-Spaces.zip"
    )
    checksum_url = f"{download_url}.sha256"

    html = args.index.read_text(encoding="utf-8")

    html, version_count = VERSION_RE.subn(
        lambda match: f"{match.group('open')}{version}{match.group('close')}",
        html,
    )
    if version_count == 0:
        print(
            "error: docs/index.html has no element with data-release-version",
            file=sys.stderr,
        )
        return 1

    html, download_count = set_hrefs(html, DOWNLOAD_ANCHOR_RE, download_url)
    if download_count == 0:
        print(
            "error: docs/index.html has no anchor with data-release-download",
            file=sys.stderr,
        )
        return 1

    html, checksum_count = set_hrefs(html, CHECKSUM_ANCHOR_RE, checksum_url)
    if checksum_count == 0:
        print(
            "error: docs/index.html has no anchor with data-release-checksum",
            file=sys.stderr,
        )
        return 1

    if html != args.index.read_text(encoding="utf-8"):
        args.index.write_text(html, encoding="utf-8")

    feed = {
        "version": version,
        "tag": tag,
        "url": f"https://github.com/PeterHindes/faster-spaces/releases/tag/{tag}",
        "download": download_url,
        "published_at": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
    }
    args.feed.parent.mkdir(parents=True, exist_ok=True)
    args.feed.write_text(json.dumps(feed, indent=2) + "\n", encoding="utf-8")

    print(
        f"site points at {tag}: "
        f"{download_count} download link(s), {checksum_count} checksum link(s), "
        f"{version_count} version label(s); wrote {args.feed}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
