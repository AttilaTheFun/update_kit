#!/bin/bash
# UpdateKit's proof of its tests, in format 2 (AttilaTheFun/reviews'
# docs/PROOF_FORMAT.md): a library's, tests only, `tests/linux` with its
# log, no screens. CI's `verify` job runs `swift test` on Linux (XCTest's
# tests and Swift Testing's), keeping its output and its exit status; the
# `proof` job writes this from them, and uploads the folder as the run's
# `proof` artifact, which Reviews shows and asks for before a release
# (README, "Releasing"). Every test runs on Linux (the owner's CI rule,
# 2026-11-13); Apple's builds of the library are the `ios-tests` job's. It
# fails as the tests did, after the proof is written either way.
#
#   tools/ci/proof.sh <proof folder> <linux log folder> [version]
#
# The log folder holds test.txt (the output) and status (its exit status).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
usage="usage: tools/ci/proof.sh <proof folder> <linux log folder> [version]"
proof="${1:?$usage}"
linux="${2:?$usage}"
version="${3:-}"
[ -n "$version" ] || version="unreleased"
mkdir -p "$proof/logs"
status() { cat "$1/status" 2> /dev/null || echo 1; }
cp "$linux/test.txt" "$proof/logs/linux.txt" 2> /dev/null || echo "No Linux test output came back." > "$proof/logs/linux.txt"
linux_status="$(status "$linux")"
python3 -I - "$proof" "$linux_status" "$version" "$(git -C "$ROOT" rev-parse HEAD)" << 'PY'
import datetime, json, os, re, sys
proof, linux, version, commit = sys.argv[1:5]
def tests(name, title, status):
    text = open(os.path.join(proof, "logs", name), errors="replace").read()
    # XCTest's summary of all its tests is its last: "Executed 41 tests,
    # with 0 failures (0 unexpected)"; Swift Testing's: "Test run with 8
    # tests in 2 suites passed" (or "… failed after … with 1 issue": a
    # failed run that names no issues counts one).
    counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", text)
    tests, failures = (int(counts[-1][0]), int(counts[-1][1])) if counts else (0, 0)
    swift_testing = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)(?:.*?with (\d+) issues?)?", text)
    if swift_testing:
        count, outcome, issues = swift_testing[-1]
        tests += int(count)
        failures += int(issues or 1) if outcome == "failed" else 0
    return {"id": "tests/" + name.split(".")[0], "kind": "tests", "title": title,
            "result": "passed" if status == "0" else "failed", "tests": tests, "failures": failures,
            "log": "logs/" + name}
document = {"format": 2, "app": "UpdateKit", "version": version,
            "repository": os.environ.get("GITHUB_REPOSITORY", "AttilaTheFun/update_kit"), "commit": commit,
            "run": int(os.environ["GITHUB_RUN_ID"]) if os.environ.get("GITHUB_RUN_ID") else None,
            "made": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "items": [tests("linux.txt", "Linux", linux)]}
json.dump(document, open(os.path.join(proof, "proof.json"), "w"), indent=1)
print("proof.json: Linux %s (%d tests)" % (document["items"][0]["result"], document["items"][0]["tests"]))
PY
[ "$linux_status" = 0 ]
