#!/usr/bin/env bash
#
# previous-release.sh vX.Y.Z — the published release vX.Y.Z with the highest version below the
# given one, or nothing if there is none. Published: GitHub lists it, every page of it, and it is
# neither a draft nor a prerelease. Only names vX.Y.Z count, so a companion el8-vX.Y.Z never does,
# and versions compare as numbers: as text, v0.9.0 sorts above v0.30.0.
#
# Not from git, which does not say which tags were published: a release that failed keeps its tag
# and the version is burned, and only a published release has users, whose pins a new release must
# pass. release-sign.sh, audit.sh and check-release.sh use this. GH_TOKEN, a read-only token, is
# optional. FSBPYR_RELEASE_REPO and FSBPYR_RELEASES_API replace GitHub in tests and rehearsals.
# Needs curl and jq. Exit 0, or 2 if the list cannot be read: a lookup that goes wrong must stop a
# release, not skip a check.
set -Eeuo pipefail
trap 'exit 2' ERR

REPOSITORY=${FSBPYR_RELEASE_REPO:-devitops-com/fsbpyr}
API="${FSBPYR_RELEASES_API:-https://api.github.com/repos/$REPOSITORY/releases}"
PER_PAGE=100
XYZ='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

[[ $# == 1 && "$1" =~ $XYZ ]] || { echo "usage: previous-release.sh vX.Y.Z" >&2; exit 2; }
tag=$1

headers=(-H 'Accept: application/vnd.github+json')
[[ -z "${GH_TOKEN-}" ]] || headers+=(-H "Authorization: Bearer $GH_TOKEN")

names=''
page=1
while :; do
    body=$(curl -fsSL "${headers[@]}" "$API?per_page=$PER_PAGE&page=$page") ||
        { echo "ERROR: cannot read page $page of the release list" >&2; exit 2; }
    listed=$(jq -er 'if type == "array" then length else error end' <<<"$body" 2>/dev/null) &&
        [[ "$listed" =~ ^[0-9]+$ ]] ||
        { echo "ERROR: page $page of the release list is no JSON list" >&2; exit 2; }
    names+=$(jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' <<<"$body")$'\n'
    ((listed == PER_PAGE)) || break
    page=$((page + 1))
done

printf '%s\n%s\n' "$names" "$tag" | { grep -E "$XYZ" || true; } | LC_ALL=C sort -uV |
    awk -v tag="$tag" '$0 == tag { if (last != "") print last; exit } { last = $0 }'
