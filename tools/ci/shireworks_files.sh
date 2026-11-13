# Sourced by tools/ci/container_build.sh (copied from Applications'): where
# Bazel takes Xcode 27.2's SDK archive and rules_applecross's ported tools
# from, Shireworks' files (by SHA-256, with its cache's read token in
# .netrc), through a downloader config for MODULE.bazel's placeholders. No
# host is named in the repository.

# Xcode 27.2's SDK archive.
SDK_SHA256="b1583e60f9fd35881b5a948ce71627079877f1ced7ea231e14d3c342dd389668"

# The Shireworks server whose files and cache a build reads:
# SHIREWORKS_FILES_HOST, else the first of SHIREWORKS_SERVERS (a CI job's
# environment has it).
shireworks_files_host() {
    local host="${SHIREWORKS_FILES_HOST:-}"
    if [ -z "$host" ]; then
        host="${SHIREWORKS_SERVERS:-}"
        host="${host%%[ ,]*}"
        host="${host#*://}"
        host="${host%%[:/]*}"
    fi
    [ -n "$host" ] || { echo "$(basename "$0"): no host for Shireworks' files: set SHIREWORKS_FILES_HOST (or SHIREWORKS_SERVERS)" >&2; return 1; }
    printf '%s\n' "$host"
}

# write_downloader_config <file> <host>
#
# GitHub's release downloads keep their own URL and gain Bazel's mirror as a
# fallback: a rewrite that matches drops the URL it matched, so the first
# rule gives it back. (github.com answered 504 for hours on 2026-11-09 while
# mirror.bazel.build served most of the same archives; it lacks some, so it's
# a partial net. Shireworks' container_build has the same.)
write_downloader_config() {
    cat > "$1" << EOF
rewrite apple-sdks\.invalid/.* http://$2:7490/files/sha256/$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) http://$2:7490/files/sha256/\$1
rewrite (github\.com/[^/]+/[^/]+/releases/download/.*) \$1
rewrite (github\.com/[^/]+/[^/]+/releases/download/.*) mirror.bazel.build/\$1
EOF
}
