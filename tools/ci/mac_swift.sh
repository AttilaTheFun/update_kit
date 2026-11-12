#!/bin/bash
# UpdateKit on a Mac, from a Linux CI job: the package goes to a slot of
# Shireworks' primary Mac (tools/ci/mac_slot.sh), which builds or tests it
# with SwiftPM, so every job runs in Shireworks' Linux containers (the
# owner's CI rule, 2026-11-12) and only what needs Apple's SDKs runs on the
# Mac. Resolved in the job's container first: the sources and SwiftPM's
# resolution (.build's repositories and checkouts) go up, and the slot
# builds without resolving again.
#
#   tools/ci/mac_swift.sh build          the package and its tests for macOS, and
#                                        the package for the iOS simulator
#   tools/ci/mac_swift.sh test <dir>     the tests on macOS: <dir>/test.txt (their
#                                        output) and <dir>/status (their exit status)
#
# Needs the runner's SHIREWORKS_GRANT (tools/ci/shireworks.sh). Fails as the
# build or the tests do; the slot is released however it ends.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
usage() { echo "usage: tools/ci/mac_swift.sh build | test <dir>" >&2; exit 2; }
mode="${1:-}"
case "$mode" in
    build) ;;
    test) out="${2:-}"; [ -n "$out" ] || usage; mkdir -p "$out" ;;
    *) usage ;;
esac
# Shireworks' REST API (tools/ci/shireworks.sh), each call asked again when
# its server didn't answer.
SW="$ROOT/tools/ci/shireworks_retry.sh"
work="$(mktemp -d)"
# shellcheck source=tools/ci/mac_slot.sh
. "$ROOT/tools/ci/mac_slot.sh"
finished=""
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    mac_slot_release
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "::group::The package, resolved here"
cd "$ROOT"
swift package resolve
tar -czf "$work/package.tgz" Package.swift Package.resolved Sources Tests \
    .build/repositories .build/checkouts .build/workspace-state.json
ls -l "$work/package.tgz"
echo "::endgroup::"

mac_slot_lease
mac_slot_upload "$work/package.tgz" update_kit.tgz
unpack='rm -rf update_kit && mkdir update_kit && cd update_kit && tar -xzf ../update_kit.tgz && echo "SwiftPM $(swift --version 2>&1 | head -1)"'
clean='cd .. && rm -rf update_kit update_kit.tgz'
case "$mode" in
    build)
        echo "::group::Built on a Mac slot: macOS (with the tests), then the iOS simulator"
        mac_slot_exec bash -c "set -euo pipefail; $unpack
            swift build --disable-automatic-resolution --build-tests
            swift build --disable-automatic-resolution \
                --triple arm64-apple-ios17.0-simulator --sdk \"\$(xcrun --sdk iphonesimulator --show-sdk-path)\"
            $clean"
        echo "::endgroup::"
        echo "$me: UpdateKit builds for macOS (its tests too) and the iOS simulator"
        ;;
    test)
        echo "::group::The tests on a Mac slot"
        set +e
        mac_slot_exec bash -c "set -uo pipefail; $unpack || exit 1
            swift test --disable-automatic-resolution 2>&1
            status=\$?
            $clean
            exit \$status" 2>&1 | tee "$out/test.txt"
        status=${PIPESTATUS[0]}
        set -e
        echo "$status" > "$out/status"
        echo "::endgroup::"
        [ "$status" -eq 0 ] || { echo "$me: the tests failed on macOS ($status)" >&2; exit "$status"; }
        echo "$me: the tests pass on macOS"
        ;;
esac
finished=1
