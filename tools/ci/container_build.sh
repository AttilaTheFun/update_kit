#!/bin/bash
# UpdateKit built for iOS and macOS in a Linux container, with
# rules_applecross (MODULE.bazel): CI's `ios-tests` job, in its own
# container (Shireworks' single-use update_kit-jit runners), leasing
# nothing. Shireworks has written its ~/.bazelrc (its cache, read-only) and
# ~/.netrc (the cache's read token). Xcode 27.2's SDK archive and
# rules_applecross's ported tools come from Shireworks' files through the
# downloader config written here (tools/ci/shireworks_files.sh): no host is
# named in the repository. Copied from Applications' (its tools/ci).
#
#   tools/ci/container_build.sh                  # the library for iOS and macOS
#   tools/ci/container_build.sh build <args…>    # bazel build <args…> there
#
#   SHIREWORKS_FILES_HOST   the name Shireworks' files and cache are reached by
#                           (default: the first of SHIREWORKS_SERVERS, as a job has it)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tools/ci/shireworks_files.sh
. "$ROOT/tools/ci/shireworks_files.sh"
host="$(shireworks_files_host)"

# MODULE.bazel's placeholders, to that Shireworks server (.ci is not checked in; a
# builder's .bazelrc.user may name the same file).
mkdir -p "$ROOT/.ci"
write_downloader_config "$ROOT/.ci/downloader.cfg" "$host"

flags=("--downloader_config=$ROOT/.ci/downloader.cfg")
# A builder's .bazelrc.user may turn apple_on_linux on already (README):
# given twice, Bazel warns of it.
grep -qsx 'build:linux --config=apple_on_linux' "$ROOT/.bazelrc.user" || flags+=(--config=apple_on_linux)
if [ $# -gt 0 ]; then
    command=(bazel "$1" --keep_going "${flags[@]}" "${@:2}")
else
    command=(bazel build --keep_going "${flags[@]}" //:ios_build //:macos_build)
fi

if [ "$(uname -s)" = Linux ]; then
    # In this container, in place.
    echo "This container: $(nproc) CPUs, $(awk '/MemTotal/ { printf "%.1f GB", $2 / 1048576 }' /proc/meminfo 2> /dev/null) memory"
    cd "$ROOT"
    exec "${command[@]}"
fi

echo "container_build.sh: builds run in a Linux container: CI's own, or one leased from Shireworks with this checkout there" >&2
exit 1
