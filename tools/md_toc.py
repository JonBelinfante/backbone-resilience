#!/usr/bin/env python3
"""Add a table of contents to a Markdown file.

Usage:
    python3 tools/md_toc.py FILE.md            print the contents list
    python3 tools/md_toc.py FILE.md --write    put it in the file

With --write the list goes between <!-- toc --> and <!-- tocstop -->, or under the first
heading if the file has no markers. Running it again replaces the old list.
"""

from __future__ import annotations

import argparse
import re
import sys

START = "<!-- toc -->"
END = "<!-- tocstop -->"
HEADING = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


def headings(lines):
    """Return (level, text) for each hash heading outside a code fence."""
    found, fence = [], ""
    for line in lines:
        opening = FENCE.match(line)
        if opening:
            fence = "" if fence == opening.group(1)[0] else (fence or opening.group(1)[0])
        elif not fence and HEADING.match(line):
            match = HEADING.match(line)
            found.append((len(match.group(1)), match.group(2)))
    return found


def plain(text):
    """Reduce links to their labels and drop code marks."""
    return re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text).replace("`", "")


def slug(text):
    """Make the GitHub anchor for a heading."""
    return re.sub(r"[^\w\- ]", "", plain(text).lower()).replace(" ", "-")


def build(lines, low, high):
    """Build the nested contents list as a list of lines."""
    seen, parents, out = {}, [], []
    for level, text in headings(lines):
        base = slug(text)
        count = seen.get(base, 0)
        seen[base] = count + 1
        anchor = base if count == 0 else "%s-%d" % (base, count)
        if not low <= level <= high:
            continue
        while parents and parents[-1] >= level:
            parents.pop()
        out.append("%s- [%s](#%s)" % ("  " * len(parents), plain(text), anchor))
        parents.append(level)
    return out


def place(lines, toc):
    """Put the list between the markers, or under the first heading."""
    block = [START, ""] + toc + ["", END]
    starts = [i for i, line in enumerate(lines) if line.strip() == START]
    ends = [i for i, line in enumerate(lines) if line.strip() == END]
    if starts and ends and starts[0] < ends[0]:
        return lines[: starts[0]] + block + lines[ends[0] + 1 :]
    if starts or ends:
        sys.exit("md_toc: one marker without the other, or the markers are out of order")
    first = next((i for i, line in enumerate(lines) if HEADING.match(line)), -1)
    return lines[: first + 1] + [""] + block + lines[first + 1 :]


def main():
    """Read the command line and print or write the list."""
    parser = argparse.ArgumentParser(description="Add a table of contents to a Markdown file.")
    parser.add_argument("file")
    parser.add_argument("--write", action="store_true", help="write the list into the file")
    parser.add_argument("--min-level", type=int, default=2, help="shallowest heading (default 2)")
    parser.add_argument("--max-level", type=int, default=4, help="deepest heading (default 4)")
    args = parser.parse_args()
    try:
        with open(args.file, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        sys.exit("md_toc: %s" % error)
    toc = build(lines, args.min_level, args.max_level)
    if not args.write:
        print("\n".join(toc))
        return
    with open(args.file, "w", encoding="utf-8") as handle:
        handle.write("\n".join(place(lines, toc)) + "\n")


if __name__ == "__main__":
    main()
