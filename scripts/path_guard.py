#!/usr/bin/env python3
"""Path guard: fail unless every changed path matches the allow list.

Usage: path_guard.py ALLOW_LIST_FILE [TREE_FILE] < changed-paths.json

stdin is a JSON array of strings: every path a pull request touches, with both the old and the new path of a
rename. The allow list is read from the file named on the command line; the workflow gives it the copy from the
pull request's BASE commit, so the pull request cannot change the rules it is judged by. This script only reads
those inputs.

TREE_FILE (optional but always given by the workflow) is the raw response of the GitHub API for the head commit's
Git tree (git/trees/<sha>?recursive=1), read as data only. A changed path that is a symlink (mode 120000) or a
submodule (160000) there fails, and so does a truncated tree, because then it cannot be checked. A path missing from
the tree was deleted, which is fine. It never reads the working tree of the pull request, runs nothing from it and needs no network.

Fails closed: a missing, unreadable or empty allow list, a malformed pattern, an input that is not a JSON array
of plain paths, and any path outside the list are all errors (exit 1). Exit 2 is a usage error.

Allow list format: one glob per line, "#" starts a comment line, blank lines are ignored.
  *   matches any characters except "/"
  **  matches any characters including "/"  (a trailing "/**" also matches everything below the directory)
  ?   matches one character except "/"
Anything else is literal. Matching is case sensitive and anchored to the whole path.

Whatever the allow list says, ALWAYS_DENIED paths never pass: the pipeline, the GitOps entry points, the matcher
and its tests, the Makefile and every file in the repository root, which only a human may change.
"""
import json
import re
import sys

ALWAYS_DENIED = (".github/", "clusters/", "infrastructure/", "scripts/", "tests/")
ALWAYS_DENIED_FILES = ("Makefile",)
UNSAFE_MODES = {"120000": "symlink", "160000": "submodule"}


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
    if path.startswith(ALWAYS_DENIED) or path in ALWAYS_DENIED_FILES or "/" not in path:
        return "never allowed (protected path)"
    if not any(p.match(path) for p in patterns):
        return "not on the allow list"
    return None


def load_modes(tree_file):
    """Map path -> Git mode from a git/trees API response. Raises ValueError when it cannot be trusted."""
    try:
        with open(tree_file, encoding="utf-8") as f:
            tree = json.load(f)
    except (OSError, UnicodeDecodeError, ValueError) as e:
        raise ValueError("cannot read the tree: %s" % e)
    if not isinstance(tree, dict) or not isinstance(tree.get("tree"), list):
        raise ValueError("the tree response has no tree list")
    if tree.get("truncated") is not False:
        raise ValueError("the tree is truncated or incomplete, symlinks cannot be ruled out")
    modes = {}
    for entry in tree["tree"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str) or not isinstance(entry.get("mode"), str):
            raise ValueError("malformed tree entry")
        modes[entry["path"]] = entry["mode"]
    return modes


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: path_guard.py ALLOW_LIST_FILE [TREE_FILE] < paths.json", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as f:
            patterns = parse_allow_list(f.read())
    except (OSError, UnicodeDecodeError, ValueError) as e:
        print("path guard: cannot use the allow list from the base commit: %s" % e, file=sys.stderr)
        return 1
    modes = {}
    if len(argv) == 3:
        try:
            modes = load_modes(argv[2])
        except ValueError as e:
            print("path guard: %s" % e, file=sys.stderr)
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
        if not reason and modes.get(p) in UNSAFE_MODES:
            reason = "a %s is not allowed" % UNSAFE_MODES[modes[p]]
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
