#!/usr/bin/env python3
"""Copy top-level forms of FILE at REV in REPO into OUT.

usage: extract-forms.py REPO REV FILE (--only|--except) LINES OUT

LINES is a comma-separated list of 1-based form start lines, or "-".
--only keeps just those forms; --except keeps all forms but those.  A
form's start is its #+/#- line when it has one.  A ;-comment block
directly above a form travels with it.  (in-package ...) forms are
dropped; OUT starts with a provenance line and (in-package
#:vivace-cabinet).  Any LINE that is not a form start is an error.
"""
import subprocess
import sys


def form_spans(text):
    """[(start, end)] 1-based line spans of the top-level forms."""
    spans, i, n, line = [], 0, len(text), 1
    depth, start = 0, None

    def skip_block_comment(i, line):
        level = 1
        i += 2
        while level:
            if text.startswith("|#", i):
                level, i = level - 1, i + 2
            elif text.startswith("#|", i):
                level, i = level + 1, i + 2
            else:
                line += text[i] == "\n"
                i += 1
        return i, line

    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("#|", i):
            i, line = skip_block_comment(i, line)
        elif c == '"':
            i += 1
            while text[i] != '"':
                if text[i] == "\\":
                    i += 1
                line += text[i] == "\n"
                i += 1
            i += 1
        elif text.startswith("#\\", i):
            i += 3
            if text[i - 1].isalnum():
                while i < n and (text[i].isalnum() or text[i] in "-_"):
                    i += 1
        elif c == "|":
            i += 1
            while text[i] != "|":
                line += text[i] == "\n"
                i += 1
            i += 1
        elif depth == 0 and text.startswith(("#+", "#-"), i):
            if start is None:
                start = line
            i += 2
            if text[i] == "(":
                d = 0
                while True:
                    d += text[i] == "("
                    d -= text[i] == ")"
                    i += 1
                    if d == 0:
                        break
            else:
                while i < n and not text[i].isspace() and text[i] != "(":
                    i += 1
        elif c == "(":
            if depth == 0 and start is None:
                start = line
            depth += 1
            i += 1
        elif c == ")":
            depth -= 1
            i += 1
            if depth == 0:
                spans.append((start, line))
                start = None
        else:
            i += 1
    return spans


def with_comments(lines, start):
    """START moved up over a ;-comment block directly above it."""
    while start > 1 and lines[start - 2].lstrip().startswith(";"):
        start -= 1
    return start


def main():
    repo, rev, path, mode, wanted, out = sys.argv[1:7]
    text = subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"],
                          check=True, capture_output=True,
                          text=True).stdout
    lines = text.split("\n")
    spans = form_spans(text)
    starts = {s for s, _ in spans}
    want = set() if wanted == "-" else {int(x) for x in wanted.split(",")}
    bad = sorted(want - starts)
    if bad:
        sys.exit(f"{path}: not form starts: {bad}")
    pkg = [(s, e) for s, e in spans
           if lines[s - 1].lstrip().lower().startswith("(in-package")]
    keep = [(s, e) for s, e in spans if (s, e) not in pkg
            and ((s in want) == (mode == "--only"))]
    head = [f";;;; Copied from vivace-graph {path} at {rev} ({mode}"
            f" {wanted}).", ";;;; See docs/provenance.md.", "",
            "(in-package #:vivace-cabinet)", ""]
    body = []
    for s, e in keep:
        body.append("\n".join(lines[with_comments(lines, s) - 1:e]))
        print(f"  kept {s}-{e}: {lines[s - 1][:60]}")
    for s, e in spans:
        if (s, e) not in keep and (s, e) not in pkg:
            print(f"  DROPPED {s}-{e}: {lines[s - 1][:60]}")
    with open(out, "w") as f:
        f.write("\n".join(head) + "\n\n".join(body) + "\n")


main()
