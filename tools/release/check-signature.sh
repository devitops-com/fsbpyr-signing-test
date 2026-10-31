#!/usr/bin/env bash
#
# check-signature.sh SOURCE FILE vX.Y.Z PREVIOUS — check FILE's signature, FILE.sig, as the clients
# will: against the keys the tag pins, for that release's own fsbpyr, and against those the previous
# release pins, for the fsbpyr that updates to it (docs/signing.md §5.3). SOURCE is a checkout that
# has both tags; PREVIOUS comes from previous-release.sh, and is empty if there is no such release.
#
# A tag's pins are the .pub files in src/fsbpyr/release-keys/ at that tag. Only the version named in
# tools/release/first-signed-release may have a previous release that pins nothing: for any other,
# that means the lookup went wrong, and a check that is skipped must stop the release. release-sign.sh,
# audit.sh and check-release.sh run this. Exit status: 0 VERIFIED, 1 NOT VERIFIED, 2 anything else,
# as release-signing.sh's.
set -Eeuo pipefail
trap 'exit 2' ERR

KEYS=src/fsbpyr/release-keys
FIRST=tools/release/first-signed-release

[[ $# == 4 ]] || { echo "usage: check-signature.sh SOURCE FILE vX.Y.Z PREVIOUS" >&2; exit 2; }
source=$1 file=$2 tag=$3 previous=$4
script=$(dirname -- "${BASH_SOURCE[0]}")/release-signing.sh

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# pins_of TAG DIR: DIR gets the .pub files TAG pins, as the names they have there. A tag missing
# from the checkout fails; a tag from before signing gives none.
pins_of() {
    mkdir -p "$2"
    local path listed
    listed=$(git -C "$source" ls-tree --name-only "$1" -- "$KEYS/") ||
        { echo "ERROR: $1 is not in $source" >&2; exit 2; }
    while IFS= read -r path; do
        [[ "$path" != *.pub ]] || git -C "$source" show "$1:$path" >"$2/${path##*/}"
    done <<<"$listed"
}

pubs_in() { find "$1" -maxdepth 1 -name '*.pub' -type f | LC_ALL=C sort; }

pins_of "$tag" "$work/own"
own=$(pubs_in "$work/own")
[[ -n "$own" ]] || { echo "ERROR: $tag pins no keys" >&2; exit 2; }
mapfile -t own_keys <<<"$own"
bash "$script" verify "$file" "${own_keys[@]}" || exit  # 1 stays 1: the ERR trap would make it 2

pinned=''
if [[ -n "$previous" ]]; then
    pins_of "$previous" "$work/previous"
    pinned=$(pubs_in "$work/previous")
fi
if [[ -z "$pinned" ]]; then
    first=$(git -C "$source" show "$tag:$FIRST") || { echo "ERROR: $tag has no $FIRST" >&2; exit 2; }
    [[ "v$first" == "$tag" ]] || {
        echo "ERROR: the release before $tag (${previous:-none found}) pins no keys, and only $FIRST ($first) may have none" >&2
        exit 2
    }
    echo "$tag is the first signed release: the release before it pins no keys"
    exit 0
fi
mapfile -t previous_keys <<<"$pinned"
bash "$script" verify "$file" "${previous_keys[@]}" || exit
