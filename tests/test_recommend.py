#!/usr/bin/env python3
"""Unit tests for the pure logic in browser-picker-recommend (no GUI, no network)."""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "bin", "browser-picker-recommend")

# The script has no .py extension, so give the loader an explicit source loader.
loader = importlib.machinery.SourceFileLoader("bprec", SRC)
spec = importlib.util.spec_from_loader("bprec", loader)
bprec = importlib.util.module_from_spec(spec)
loader.exec_module(bprec)  # safe: CLI is under `if __name__ == "__main__"`

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


# --- url_parts: http(s) only, www/userinfo/port stripped ---
check(bprec.url_parts("https://github.com/orgA/repo1/issues/3") == ("github.com", ["orgA", "repo1", "issues", "3"]),
      "url_parts host+segs")
check(bprec.url_parts("https://www.linkedin.com/feed/") == ("linkedin.com", ["feed"]), "url_parts strips www")
check(bprec.url_parts("https://github.com:443/x") == ("github.com:443", ["x"]), "url_parts keeps port")
check(bprec.url_parts("http://localhost:5088/studio/swipe") == ("localhost:5088", ["studio", "swipe"]),
      "url_parts keeps localhost port")
check(bprec.url_parts("mailto:a@b.com") == (None, []), "url_parts ignores non-http")

# --- common_prefix ---
check(bprec.common_prefix([["a", "b", "c"], ["a", "b", "d"]]) == ["a", "b"], "common_prefix shared")
check(bprec.common_prefix([["a", "b"], ["x", "y"]]) == [], "common_prefix none")


def store_from(urls_labels):
    """Replay (url, label) regular picks into a fresh store."""
    store = {"events": []}
    for ts, (url, label) in enumerate(urls_labels):
        bprec.record_event(store, url, label, ts)
    return store


def peek_after(urls_labels, url, threshold_n=3):
    """What the picker would offer for `url` after the given prior picks."""
    store = store_from(urls_labels)
    host, segs = bprec.url_parts(url)
    return bprec.peek(store["events"], host, segs, threshold_n)


W = "Chromium — Work"
P = "Chromium — Personal"

# Below threshold: only 1 prior pick -> no offer on the 2nd open.
check(peek_after([("https://github.com/orgA/repo1", W)], "https://github.com/orgA/repo1") is None,
      "one prior -> no offer (threshold 3)")

# Same repo: 2 priors -> on the 3rd open, offer the repo-level rule.
check(peek_after([("https://github.com/orgA/repo1/a", W), ("https://github.com/orgA/repo1/b", W)],
                 "https://github.com/orgA/repo1/c") == ("github.com/orgA/repo1", W),
      "same repo -> repo offer")

# Two different repos in one org -> generalize to the org (and only if the new link is under it).
check(peek_after([("https://github.com/orgA/repo1", W), ("https://github.com/orgA/repo2", W)],
                 "https://github.com/orgA/repo3") == ("github.com/orgA", W),
      "org generalization")
check(peek_after([("https://github.com/orgA/repo1", W), ("https://github.com/orgA/repo2", W)],
                 "https://github.com/orgB/repo9") is None,
      "offer only when the new link is under the pattern")

# Different orgs, one profile -> generalize to the whole host.
check(peek_after([("https://github.com/orgA/r", W), ("https://github.com/orgB/r", W)],
                 "https://github.com/orgC/r") == ("github.com", W),
      "host generalization")

# Contested host: another profile also uses the org -> don't offer the org rule.
check(peek_after([("https://github.com/orgA/repo1", W),
                  ("https://github.com/orgA/repo2", W),
                  ("https://github.com/orgA/repo9", P)],
                 "https://github.com/orgA/repo3") is None,
      "contested org -> no offer")

# Private/non-http picks are never recorded (caller passes only regular picks; mailto is ignored).
store = store_from([("mailto:me@example.com", W)])
check(store["events"] == [], "non-http not recorded")

# Tunable threshold via settings.conf is honoured by threshold() (here just check the floor of 2).
check(bprec.threshold() >= 2, "threshold floor")

# --- add_rule: idempotent, inserted before a catch-all ---
tmp = tempfile.mkdtemp()
bprec.CONF = tmp
bprec.RULES_FILE = os.path.join(tmp, "rules.conf")
with open(bprec.RULES_FILE, "w") as f:
    f.write("1|||github.com/org|||A\n1|||*|||A\n")
check(bprec.add_rule("github.com/orgA", W) is True, "add_rule writes new")
check(bprec.add_rule("github.com/orgA", W) is False, "add_rule idempotent")
with open(bprec.RULES_FILE) as f:
    body = f.read()
check(body.index("github.com/orgA") < body.index("1|||*|||A"), "add_rule inserts before catch-all")

if fails:
    print("FAILED:")
    for m in fails:
        print("  -", m)
    sys.exit(1)
print("test_recommend.py: all passed")
