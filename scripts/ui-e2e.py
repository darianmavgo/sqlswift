#!/usr/bin/env python3
"""Replay Tests/SQLDocAppTests/banquet-ui-cases.json against the *running dev app*.

Drives the real window through bin/ui-command.txt and checks bin/ui-state.json
(see CLAUDE.md "UI feedback loop"). Unlike `swift test`, this exercises the real
SwiftUI Banquet bar field, so it also runs the `ui: true` cases (`type`, `blur`).

    make hot            # in another terminal: dev app + hot reload
    make ui-e2e         # or: python3 scripts/ui-e2e.py [-k substring] [--db path]
"""
import argparse, json, os, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "bin")
CMD = os.path.join(BIN, "ui-command.txt")
STATE = os.path.join(BIN, "ui-state.json")
CASES = os.path.join(ROOT, "Tests", "SQLDocAppTests", "banquet-ui-cases.json")

# Per-table view state survives between cases in the live app (the tests use a
# fresh AppViewModel each time), so put the table back to neutral first.
RESET = ["blur", "showall", "clearfilters", "sort -", "display raw"]


def read_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def send(line):
    with open(CMD, "w") as f:
        f.write(line + "\n")
    deadline = time.time() + 5
    while os.path.exists(CMD):
        if time.time() > deadline:
            sys.exit("dev app is not consuming bin/ui-command.txt — is `make hot` running?")
        time.sleep(0.05)


def settle(min_wait=0.8):
    """Wait for the command to take effect and the snapshot to stop changing."""
    time.sleep(min_wait)
    prev, stable = None, 0
    for _ in range(40):
        s = read_state()
        busy = bool(s and s.get("grid", {}).get("isLoading"))
        if s == prev and not busy:
            stable += 1
            if stable >= 2:
                return s
        else:
            stable = 0
        prev = s
        time.sleep(0.3)
    return prev


def check(case, state, db):
    sub = lambda v: v.replace("{DB}", db)
    g = state.get("grid", {})
    e = case["expect"]
    pairs = [
        ("table", state.get("table"), e.get("table")),
        ("bar URL", state.get("banquetURL"), sub(e["url"]) if "url" in e else None),
        ("bar text", state.get("banquetBarText"), sub(e["bar"]) if "bar" in e else None),
        ("sort", g.get("sort"), e.get("sort")),
        ("filters", g.get("filters"), e.get("filters")),
        ("offset", g.get("offset"), e.get("offset")),
        ("page limit", g.get("pageLimit"), e.get("pageLimit")),
        ("rows loaded", g.get("rowsLoaded"), e.get("rowsLoaded")),
        ("visible columns", g.get("visibleColumns"), e.get("visibleColumns")),
    ]
    return [f"{what}: got {got!r}, want {want!r}" for what, got, want in pairs
            if want is not None and got != want]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", default="", help="only cases whose name contains this")
    ap.add_argument("--db", default=os.path.join(ROOT, "testdata", "sample.db"))
    ap.add_argument("--headless-only", action="store_true", help="skip ui:true cases")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f"{args.db} missing — run: sh scripts/make_testdata.sh")
    if not os.path.isdir(BIN) or read_state() is None:
        sys.exit("no bin/ui-state.json — start the dev app with `make hot` first")

    with open(CASES) as f:
        cases = json.load(f)["cases"]
    cases = [c for c in cases if args.k in c["name"] and not (args.headless_only and c.get("ui"))]

    failed = 0
    for c in cases:
        for line in RESET:
            send(line)
        for step in c["steps"]:
            send(step.replace("{DB}", args.db))
            settle(1.0 if step.startswith("type") else 0.6)
        state = settle(0.2)
        errs = check(c, state, args.db)
        if state.get("bannerError"):
            errs.append(f"banner error: {state['bannerError']}")
        tag = "ui " if c.get("ui") else "   "
        if errs:
            failed += 1
            print(f"✘ {tag}{c['name']}")
            for e in errs:
                print(f"      {e}")
        else:
            print(f"✔ {tag}{c['name']}")
    print(f"\n{len(cases) - failed}/{len(cases)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
