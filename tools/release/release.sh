#!/usr/bin/env bash
#
# release.sh — the whole release in one command, on the admin's machine (make release).
#
#     bash tools/release/release.sh [X.Y.Z]        (make release [KEY=PATH] [VERSION=X.Y.Z])
#
# Run it on main, at the release commit that `make release-prep` made on a branch and its pull
# request merged. Pull that yourself first, after looking at it: this never pulls, since what main
# holds is the admin's to know, and a pull here would sign whatever GitHub's main says.
#
# It tags and builds (release-assets.sh: the audit, the tag, release.yml), waits for el8.yml, signs
# and publishes (release-sign.sh, which shows what it will sign, asks once and takes the passphrase
# once), checks the release as its users get it (make release-check) and publishes the wiki (make
# wiki-publish). Run it again after any stop: what is done is left out. The EL8 stubs are outside
# the release gate, so a failed el8.yml leaves the release to go out without them.
#
# The release key's file comes from KEY, or FSBPYR_RELEASE_KEY_FILE, or is asked for when it is
# needed. FSBPYR_RELEASE_WATCH_WAIT: how many seconds to wait for a workflow run to show up
# (default 60). Exit status: 0 done, 1 stopped, 2 usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=version-files.sh
. tools/release/version-files.sh

REPOSITORY=${FSBPYR_RELEASE_REPO:-devitops-com/fsbpyr}
REMOTE=hub
WATCH_WAIT=${FSBPYR_RELEASE_WATCH_WAIT:-60}
WATCH_POLL=3

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s\n' "$*"; }

[ $# -le 1 ] || { echo "usage: release.sh [X.Y.Z]" >&2; exit 2; }
VERSION=${1:-$(current_version)}
[[ "$VERSION" =~ $XYZ ]] || die "$VERSION is no version X.Y.Z"
TAG=v$VERSION
EL8_TAG=el8-$TAG

# The commit a tag has on GitHub, by its whole name; nothing if there is no such tag.
tag_on_github() { git ls-remote "$REMOTE" | awk -v ref="refs/tags/$1" '$2 == ref { print $1 }'; }

# The latest run of a workflow for this tag. GitHub shows a run a moment after the push.
run_of() { # workflow file
    local run waited=0
    while :; do
        run=$(gh run list --repo "$REPOSITORY" --workflow "$1" --branch "$TAG" --limit 1 \
            --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
        case "$run" in
            ''|*[!0-9]*) ;;
            *) echo "$run"; return 0 ;;
        esac
        [ "$waited" -lt "$WATCH_WAIT" ] || return 1
        sleep "$WATCH_POLL"
        waited=$((waited + WATCH_POLL))
    done
}

# Whether a draft of this release is left to sign.
draft_left() {
    local release
    for release in "$TAG" "$EL8_TAG"; do
        [ "$(gh release view "$release" --repo "$REPOSITORY" --json isDraft --jq .isDraft 2>/dev/null)" != true ] \
            || return 0
    done
    return 1
}

step "1/5 Tag and build $TAG"
if [ -n "$(tag_on_github "$TAG")" ]; then
    echo "$TAG is on GitHub: going on from there"
    run=$(run_of release.yml) || die "$TAG has no release.yml run"
    bash tools/release/follow-run.sh "$run" \
        || die "release.yml failed for $TAG: see gh run view $run --log-failed"
else
    bash tools/release/release-assets.sh "$VERSION"
fi

step "2/5 Wait for the EL8 stubs"
if run=$(run_of el8.yml) && bash tools/release/follow-run.sh "$run"; then
    echo "el8.yml passed"
else
    echo "warning: el8.yml did not pass for $TAG: the release goes out without EL8 stubs for now." >&2
    echo "         Once a run has passed: make release-sign KEY=PATH" >&2
fi

step "3/5 Sign and publish"
if draft_left; then
    key=${FSBPYR_RELEASE_KEY_FILE:-}
    if [ -z "$key" ]; then
        { : </dev/tty; } 2>/dev/null || die "no release key: give KEY=PATH or set FSBPYR_RELEASE_KEY_FILE"
        IFS= read -rp 'Release key file: ' key </dev/tty
    fi
    bash tools/release/release-sign.sh "${key/#\~/$HOME}" "$VERSION"
else
    echo "nothing is left to sign"
fi

step "4/5 Check it as users get it"
make --no-print-directory release-check VERSION="$VERSION"

step "5/5 Publish the wiki"
make --no-print-directory wiki-publish

printf '\nReleased fsbpyr %s\n' "$TAG"
gh release view "$TAG" --repo "$REPOSITORY" --json url --jq .url 2>/dev/null || true
