#!/usr/bin/env python3
"""Copy top-level forms of FILE at REV in REPO into OUT.

usage: extract-forms.py REPO REV FILE (--only|--except) LINES OUT

LINES is a comma-separated list of 1-based form start lines, or "-".
--only keeps just those forms; --except keeps all forms but those.  A
form's start is its #+/#- line when it has one.  A ;-comment block
directly above a form travels with it, and the file's header (the
comments before its first form) is always kept; "--except -" copies
the whole file, free-standing comments included.  (in-package ...)
forms are dropped; OUT starts with a provenance line and (in-package
#:vivace-cabinet).  It is an error when a LINE is not a form start,
two forms share a line, a form is still open at the end of the file,
or the mode is neither --only nor --except (#5).
"""
import subprocess
import sys

MODES = ("--only", "--except")
WHITESPACE = " \t\r\f\v\n"
TOKEN_END = WHITESPACE + "()\";'`,"


class FormError(ValueError):
    """The file's forms cannot be delimited, or the arguments are bad."""


def form_spans(text):
    """[(start, end)] 1-based line spans of the top-level forms.

    A top-level form is a parenthesised form, a string or an atom, with
    any reader-macro prefixes (quote, #', #+expr ...) before it.
    Raises FormError when a form is unterminated, a ) is unmatched or
    two forms share a line.
    """
    spans, i, n, line = [], 0, len(text), 1
    depth, start, need = 0, None, 0

    def fail(what):
        raise FormError(f"line {line}: {what}")

    def skip_block_comment(i, line):
        level = 1
        i += 2
        while level:
            if i >= n:
                fail("#| without |#")
            if text.startswith("|#", i):
                level, i = level - 1, i + 2
            elif text.startswith("#|", i):
                level, i = level + 1, i + 2
            else:
                line += text[i] == "\n"
                i += 1
        return i, line

    def skip_delimited(i, line, close):
        """Past the "..." or |...| opened at I, honouring \\ escapes."""
        i += 1
        while i < n and text[i] != close:
            if text[i] == "\\":
                i += 1
            if i < n:
                line += text[i] == "\n"
            i += 1
        if i >= n:
            fail(f"{close} without a closing {close}")
        return i + 1, line

    def skip_character(i):
        """Past the #\\x or #\\Name at I."""
        i += 3
        if i <= n and text[i - 1].isalnum():
            while i < n and (text[i].isalnum() or text[i] in "-_"):
                i += 1
        return i

    def skip_token(i, line):
        """Past the atom at I, whose |...| and \\ parts may hold anything."""
        while i < n and text[i] not in TOKEN_END:
            if text[i] == "\\":
                i += 2
            elif text[i] == "|":
                i, line = skip_delimited(i, line, "|")
            else:
                i += 1
        return i, line

    def close_item():
        """One top-level item read; the form ends when none is owed."""
        nonlocal start, need
        need -= 1
        if need == 0:
            if spans and spans[-1][1] == start:
                fail("two forms on one line")
            spans.append((start, line))
            start = None

    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif c in WHITESPACE:
            i += 1
        elif c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("#|", i):
            i, line = skip_block_comment(i, line)
        elif depth > 0:
            # Inside a form only the delimiters matter.
            if c == "(":
                depth += 1
                i += 1
            elif c == ")":
                depth -= 1
                i += 1
                if depth == 0:
                    close_item()
            elif c in "\"|":
                i, line = skip_delimited(i, line, c)
            elif text.startswith("#\\", i):
                i = skip_character(i)
            elif c == "\\":
                i += 2
            else:
                i += 1
        else:
            # At top level every item is a form or a prefix of one.
            if start is None:
                start, need = line, 1
            if c == "(":
                depth = 1
                i += 1
            elif c == ")":
                fail("unmatched )")
            elif c == '"':
                i, line = skip_delimited(i, line, c)
                close_item()
            elif c in "'`":
                i += 1
            elif c == ",":
                i += 2 if text[i + 1:i + 2] in ("@", ".") else 1
            elif c == "#":
                i += 1
                while i < n and text[i].isdigit():
                    i += 1
                d = text[i:i + 1]
                i += 1
                if d == "\\":
                    i = skip_character(i - 2)
                    close_item()
                elif d == "#":
                    close_item()
                elif d in "+-":
                    need += 1
                elif d in ("", "\n"):
                    fail("# at the end of a line")
                # Any other dispatch (#', #., #(, #x, #: ...) prefixes
                # the item that follows.
            else:
                i, line = skip_token(i, line)
                close_item()
    if start is not None:
        line = start
        fail("form still open at the end of the file")
    return spans


def with_comments(lines, start):
    """START moved up over a ;-comment block directly above it."""
    while start > 1 and lines[start - 2].lstrip().startswith(";"):
        start -= 1
    return start


def extract(text, path, rev, mode, wanted):
    """The copy of TEXT (FILE at REV) under MODE and WANTED, as (output,
    kept spans, dropped spans).  Raises FormError on bad input."""
    if mode not in MODES:
        raise FormError(f"mode {mode!r} is not one of {' '.join(MODES)}")
    lines = text.split("\n")
    spans = form_spans(text)
    starts = {s for s, _ in spans}
    want = set() if wanted == "-" else {int(x) for x in wanted.split(",")}
    bad = sorted(want - starts)
    if bad:
        raise FormError(f"not form starts: {bad}")
    pkg = [(s, e) for s, e in spans
           if lines[s - 1].lstrip().lower().startswith("(in-package")]
    forms = [span for span in spans if span not in pkg]
    keep = [(s, e) for s, e in forms if (s in want) == (mode == "--only")]
    dropped = [span for span in forms if span not in keep]
    pkg_lines = {l for s, e in pkg for l in range(s, e + 1)}
    head = [f";;;; Copied from vivace-graph {path} at {rev} ({mode}"
            f" {wanted}).", ";;;; See docs/provenance.md.", "",
            "(in-package #:vivace-cabinet)", ""]
    if forms and not dropped:
        # The whole file: every comment stays where it was.
        body = [lines[l - 1] for l in range(1, forms[-1][1] + 1)
                if l not in pkg_lines]
        while body and not body[0].strip():
            body.pop(0)
        parts = ["\n".join(body)]
    else:
        first = min([with_comments(lines, s) for s, _ in forms],
                    default=len(lines) + 1)
        header = [lines[l - 1] for l in range(1, first)
                  if l not in pkg_lines]
        while header and not header[-1].strip():
            header.pop()
        while header and not header[0].strip():
            header.pop(0)
        parts = ["\n".join(header)] if header else []
        for s, e in keep:
            parts.append("\n".join(lines[with_comments(lines, s) - 1:e]))
    return ("\n".join(head) + "\n" + "\n\n".join(parts) + "\n",
            keep, dropped)


def main():
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    repo, rev, path, mode, wanted, out = sys.argv[1:7]
    text = subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"],
                          check=True, capture_output=True,
                          text=True).stdout
    lines = text.split("\n")
    try:
        output, keep, dropped = extract(text, path, rev, mode, wanted)
    except FormError as e:
        sys.exit(f"{path}: {e}")
    for s, e in keep:
        print(f"  kept {s}-{e}: {lines[s - 1][:60]}")
    for s, e in dropped:
        print(f"  DROPPED {s}-{e}: {lines[s - 1][:60]}")
    with open(out, "w") as f:
        f.write(output)


if __name__ == "__main__":
    main()
