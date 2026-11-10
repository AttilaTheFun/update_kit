#!/bin/bash
# UpdateKit proposed for release: a draft of this commit on main, titled
# "UpdateKit <version>", its notes the pull requests since the last
# release and the run that verified it, with that run's proof attached as
# proof.zip. The owner releases it in Reviews, which publishes the draft and
# makes its v<version> tag; this never publishes or tags (README,
# "Releasing"). One release a minor line: <version> is MAJOR.MINOR.PATCH,
# and none published may be on its line already.
#
#   GH_TOKEN=… tools/ci/propose.sh <version> <proof.zip>
set -euo pipefail
version="${1:?usage: tools/ci/propose.sh <version> <proof.zip>}"
zip="${2:?usage: tools/ci/propose.sh <version> <proof.zip>}"
repository="${GITHUB_REPOSITORY:-AttilaTheFun/update_kit}"
commit="$(git rev-parse HEAD)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "propose: \"$version\" is not MAJOR.MINOR.PATCH" >&2; exit 2; }
[ -f "$zip" ] || { echo "propose: no proof at $zip" >&2; exit 1; }
line="${version%.*}"

# The releases there are, drafts too: none of this version, and none
# published on its line.
releases="$(gh api --paginate "repos/$repository/releases" --jq '.[] | [.tag_name, (.draft|tostring)] | @tsv')"
if printf '%s\n' "$releases" | awk -F'\t' -v tag="v$version" '$1 == tag { found = 1 } END { exit !found }'; then
    echo "propose: v$version is a release or a draft already" >&2; exit 1
fi
if printf '%s\n' "$releases" | awk -F'\t' -v line="v$line" '$2 == "false" && ($1 == line || index($1, line ".") == 1) { found = 1 } END { exit !found }'; then
    echo "propose: the $line line has its release already: propose the next minor version" >&2; exit 1
fi

last="$(git describe --tags --abbrev=0 --match 'v*' 2> /dev/null || true)"
notes="$(mktemp)"
{
    echo "UpdateKit $version, proposed for release: verified (tests and proof) by ${GITHUB_SERVER_URL:-https://github.com}/$repository/actions/runs/${GITHUB_RUN_ID:-?}."
    echo
    if [ -n "$last" ]; then
        echo "Since $last:"
        git log --format='- %s' "$last..HEAD"
    fi
} > "$notes"
gh release create "v$version" --repo "$repository" --draft --target "$commit" --title "UpdateKit $version" \
    --notes-file "$notes" "$zip"
echo "propose: draft v$version made, a release of $commit"
