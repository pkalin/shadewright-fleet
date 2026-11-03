#!/usr/bin/env python3
"""Path guard: fail unless every changed path matches the allow list.

Usage: path_guard.py ALLOW_LIST_FILE < changed-paths.json

stdin is a JSON array of strings: every path a pull request touches, with both the old and the new path of a
rename. The allow list is read from the file named on the command line; the workflow gives it the copy from the
pull request's BASE commit, so the pull request cannot change the rules it is judged by. This script only reads
those two inputs. It never reads the working tree of the pull request, runs nothing from it and needs no network.

Fails closed: a missing, unreadable or empty allow list, a malformed pattern, an input that is not a JSON array
of plain paths, and any path outside the list are all errors (exit 1). Exit 2 is a usage error.

Allow list format: one glob per line, "#" starts a comment line, blank lines are ignored.
  *   matches any characters except "/"
  **  matches any characters including "/"  (a trailing "/**" also matches everything below the directory)
  ?   matches one character except "/"
Anything else is literal. Matching is case sensitive and anchored to the whole path.

Whatever the allow list says, ALWAYS_DENIED paths never pass: they are the pipeline, the GitOps entry points and
the rules themselves, which only a human may change.
"""
import json
import re
import sys

ALWAYS_DENIED = (".github/", "clusters/", "infrastructure/")


def glob_to_regex(pattern):
    out = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**", i):
            if pattern.startswith("**/", i):
                out.append("(?:.*/)?")  # "**/" also matches zero directories
                i += 3
            else:
                out.append(".*")
                i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("".join(out) + r"\Z")


def parse_allow_list(text):
    patterns = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("/") or ".." in line.split("/") or "\\" in line or line.startswith("!"):
            raise ValueError("allow list line %d: unsupported pattern %r" % (n, line))
        patterns.append(glob_to_regex(line))
    if not patterns:
        raise ValueError("allow list has no patterns")
    return patterns


def check_path(path, patterns):
    """Return None when allowed, else the reason."""
    if not isinstance(path, str) or not path:
        return "not a path"
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in path):
        return "control character in path"
    if path.startswith("/") or ".." in path.split("/"):
        return "unexpected path form"
    if path.startswith(ALWAYS_DENIED):
        return "never allowed (protected path)"
    if not any(p.match(path) for p in patterns):
        return "not on the allow list"
    return None


def main(argv):
    if len(argv) != 2:
        print("usage: path_guard.py ALLOW_LIST_FILE < paths.json", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as f:
            patterns = parse_allow_list(f.read())
    except (OSError, UnicodeDecodeError, ValueError) as e:
        print("path guard: cannot use the allow list from the base commit: %s" % e, file=sys.stderr)
        return 1
    try:
        paths = json.load(sys.stdin)
    except ValueError as e:
        print("path guard: input is not JSON: %s" % e, file=sys.stderr)
        return 1
    if not isinstance(paths, list):
        print("path guard: input is not a JSON array", file=sys.stderr)
        return 1
    bad = []
    for p in paths:
        reason = check_path(p, patterns)
        if reason:
            bad.append((p, reason))
    for p, reason in bad:
        print("path guard: %s: %s" % (json.dumps(p), reason))
    if bad:
        print("path guard: %d of %d changed paths need a human; see .github/shadewright-paths.txt on the base branch"
              % (len(bad), len(paths)))
        return 1
    print("path guard: all %d changed paths are on the allow list" % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
