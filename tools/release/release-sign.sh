#!/usr/bin/env bash
#
# release-sign.sh — on the admin's machine, sign the drafts CI left for a release and publish them
# (docs/signing.md §5.3). K never leaves this machine: only the .sig goes to GitHub.
#
#     bash tools/release/release-sign.sh KEY [X.Y.Z]     (make release-sign KEY=PATH [VERSION=X.Y.Z])
#
# X.Y.Z defaults to the version HEAD declares. KEY is K, or R in a recovery: both pass or fail the
# same checks, against the keys this tag and the previous release pin. It runs again for the
# companion el8-vX.Y.Z when el8.yml has finished later than release.yml.
#
# Nothing is signed unless your HEAD, GitHub's main, GitHub's tag and the attestation of the sums
# file all name one commit. That rests on GitHub itself being sound, and an account on it being
# what may be lost: an account cannot get GitHub to attest a file for a commit that did not build
# it. The attested sums then vouch for every other file. What that commit holds is the admin's to
# know, so this is only as good as what they pulled into main.
#
# The audit runs first, and again after publishing, when the record has the new release. Exit
# status: 0 done, 1 refused, 2 usage.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=version-files.sh
. tools/release/version-files.sh
# shellcheck source=confirm.sh
. tools/release/confirm.sh

REPOSITORY=${FSBPYR_RELEASE_REPO:-devitops-com/fsbpyr}
BRANCH=main
REMOTE=hub

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] && [ $# -le 2 ] && [ -n "$1" ] || { echo "usage: release-sign.sh KEY [X.Y.Z]" >&2; exit 2; }
KEY=$1
VERSION=${2:-$(current_version)}
[[ "$VERSION" =~ $XYZ ]] || die "$VERSION is no version X.Y.Z"
TAG=v$VERSION
EL8_TAG=el8-$TAG

# --- 1. The key --------------------------------------------------------------
[ -f "$KEY" ] || die "no key file $KEY"
case "$(realpath -- "$KEY")" in
    "$ROOT"/*) die "$KEY is inside this checkout: a release key is never kept in the repository" ;;
esac

# --- 2. One commit -----------------------------------------------------------
for tool in gh git jq sha256sum; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
[ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || die "not on $BRANCH"
[ -z "$(git status --porcelain --untracked-files=all)" ] || die "the working tree is not clean"
COMMIT=$(git rev-parse HEAD)
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "this clone has no tag $TAG"
[ "$(git rev-parse "refs/tags/$TAG^{commit}")" = "$COMMIT" ] || die "$TAG is not this clone's HEAD ($COMMIT)"
main=$(git ls-remote "$REMOTE" "refs/heads/$BRANCH" | cut -f1)
[ "$main" = "$COMMIT" ] || die "GitHub's $BRANCH is at ${main:-nothing}, not at your commit $COMMIT: refusing to sign"
remote_tag=$(git ls-remote "$REMOTE" "refs/tags/$TAG" "refs/tags/$TAG^{}" | tail -1 | cut -f1)
[ "$remote_tag" = "$COMMIT" ] || die "GitHub's $TAG is at ${remote_tag:-nothing}, not at your commit $COMMIT: refusing to sign"

# --- 3. The audit ------------------------------------------------------------
bash tools/release/audit.sh || die "the audit did not pass: nothing was signed"

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK:?}"' EXIT

# --- 4. The drafts -----------------------------------------------------------
# State of a release: draft, published or none.
state_of() { # release
    local draft
    if ! draft=$(gh release view "$1" --repo "$REPOSITORY" --json isDraft --jq .isDraft 2>"$WORK/view.err"); then
        grep -q 'release not found' "$WORK/view.err" || { cat "$WORK/view.err" >&2; exit 1; }
        echo none
    else
        case "$draft" in
            true) echo draft ;;
            false) echo published ;;
            *) echo "ERROR: GitHub says isDraft is '$draft' for $1" >&2; exit 1 ;;
        esac
    fi
}

# Every file of the draft is listed in its sums with the digest it has, and a main release has
# every listed file. A companion publishes each stub's .xz only, and its sums list the stub too.
check_files() { # directory, sums, release
    local listed files
    listed=$(awk '{ print $2 }' "$1/$2" | LC_ALL=C sort)
    files=$(cd "$1" && find . -mindepth 1 -maxdepth 1 -printf '%P\n' | grep -vxF "$2" | LC_ALL=C sort)
    [ -z "$(LC_ALL=C comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$files"))" ] \
        || die "$3 has files its attested $2 does not list: refusing to sign"
    if [ "$3" = "$TAG" ]; then
        [ -z "$(LC_ALL=C comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$files"))" ] \
            || die "$3 lacks files its attested $2 lists: refusing to sign"
    fi
    (cd "$1" && sha256sum --quiet --strict --ignore-missing -c "$2") >/dev/null \
        || die "a file of $3 is not what its attested $2 lists: refusing to sign"
}

sign_release() { # release, sums file, workflow, --latest value
    local release=$1 sums=$2 workflow=$3 latest=$4 dir=$WORK/$1 previous
    echo "==> Checking the draft $release"
    gh release download "$release" --repo "$REPOSITORY" --dir "$dir"
    [ -f "$dir/$sums" ] || die "the draft $release has no $sums"
    [ ! -e "$dir/$sums.sig" ] || die "the draft $release already has a signature that this machine did not make"
    # Before anything reads the file: it is GitHub's word that this commit's own workflow made it.
    gh attestation verify "$dir/$sums" --repo "$REPOSITORY" \
        --signer-workflow "$REPOSITORY/.github/workflows/$workflow" \
        --source-ref "refs/tags/$TAG" --source-digest "$COMMIT" --deny-self-hosted-runners >/dev/null \
        || die "the attestation of $release's $sums does not name your commit $COMMIT: refusing to sign"
    check_files "$dir" "$sums" "$release"
    cat <<SUMMARY

About to sign and publish:
  repo    : $REPOSITORY
  release : $release  ($(find "$dir" -mindepth 1 -maxdepth 1 | wc -l) files)
  commit  : $COMMIT
            your HEAD, GitHub's $BRANCH, GitHub's $TAG and the attestation all name it
  sums    : $sums  $(sha256sum "$dir/$sums" | cut -d' ' -f1)
  key     : $KEY

This signs with the key on this machine and uploads only the signature. Publishing is final:
a published release cannot be changed.
SUMMARY
    confirm_or_abort
    bash tools/release/release-signing.sh sign "$KEY" "$dir/$sums"
    previous=$(bash tools/release/previous-release.sh "$TAG")
    bash tools/release/check-signature.sh . "$dir/$sums" "$TAG" "$previous"
    gh release upload "$release" "$dir/$sums.sig" --repo "$REPOSITORY"
    gh release edit "$release" --repo "$REPOSITORY" --draft=false "--latest=$latest"
    bash tools/release/audit.sh --record "$release"
    echo "==> Published $release"
}

main_state=$(state_of "$TAG")
el8_state=$(state_of "$EL8_TAG")
case "$main_state" in
    none) die "$TAG has no draft: release.yml has not finished" ;;
    draft) sign_release "$TAG" SHA256SUMS release.yml true ;;
    published) echo "$TAG is published" ;;
esac
case "$el8_state" in
    none) echo "$EL8_TAG has no draft yet: run this again when el8.yml has finished, or leave it, as a release may have no EL8 stubs" ;;
    draft) sign_release "$EL8_TAG" SHA256SUMS-glibc2.28 el8.yml false ;;
    published) echo "$EL8_TAG is published" ;;
esac

# --- 5. As GitHub now serves it ----------------------------------------------
[ "$main_state" != draft ] && [ "$el8_state" != draft ] \
    || bash tools/release/audit.sh || die "the audit fails after publishing: see above"
