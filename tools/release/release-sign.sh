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
# file all name one commit, and every job of the run the attestation names ran on GitHub's own
# machines: the attestation is made after the build, and says nothing of where the build ran. That
# rests on GitHub itself being sound, and an account on it being what may be lost: an account cannot
# get GitHub to attest a file for a commit that did not build it. The attested sums then vouch for
# every other file. What that commit holds is the admin's to know, so this is only as good as what
# they pulled into main.
#
# The draft is read again before the signature is uploaded and before it is published: whoever
# holds the account has as long as the prompts take.
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

# The commit a name has on GitHub, by the whole name: ls-remote's patterns match the tail of a ref,
# so that a tag refs/tags/x/refs/tags/vX.Y.Z would answer for vX.Y.Z.
remote_commit() { # full ref name
    git ls-remote "$REMOTE" | awk -v ref="$1" '$2 == ref { print $1 }'
}

# Your HEAD, the tag here, GitHub's main and GitHub's tag are one commit.
one_commit() {
    local main remote_tag
    [ "$(git rev-parse "refs/tags/$TAG^{commit}")" = "$COMMIT" ] || die "$TAG is not this clone's HEAD ($COMMIT)"
    main=$(remote_commit "refs/heads/$BRANCH")
    [ "$main" = "$COMMIT" ] || die "GitHub's $BRANCH is at ${main:-nothing}, not at your commit $COMMIT: refusing to sign"
    remote_tag=$(remote_commit "refs/tags/$TAG^{}")
    [ -n "$remote_tag" ] || remote_tag=$(remote_commit "refs/tags/$TAG")
    [ "$remote_tag" = "$COMMIT" ] || die "GitHub's $TAG is at ${remote_tag:-nothing}, not at your commit $COMMIT: refusing to sign"
}

# --- 2. One commit -----------------------------------------------------------
for tool in gh git jq sha256sum; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
[ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || die "not on $BRANCH"
[ -z "$(git status --porcelain --untracked-files=all)" ] || die "the working tree is not clean"
COMMIT=$(git rev-parse HEAD)
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "this clone has no tag $TAG"
one_commit

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

# Before anything reads the sums: it is GitHub's word that this commit's own workflow made them.
# --deny-self-hosted-runners speaks for the job that attested, which only hashed what the jobs
# before it left, so every job of the run must have run on GitHub's machines too: runner group 0,
# which an organization's groups, from 1 up, are not.
check_attestation() { # file, workflow, release
    local attestation uris uri foreign
    attestation=$(gh attestation verify "$1" --repo "$REPOSITORY" \
        --signer-workflow "$REPOSITORY/.github/workflows/$2" --source-ref "refs/tags/$TAG" \
        --source-digest "$COMMIT" --deny-self-hosted-runners --format json) \
        || die "the attestation of $3's ${1##*/} does not name your commit $COMMIT: refusing to sign"
    uris=$(jq -r '.[].verificationResult.signature.certificate.runInvocationURI' <<<"$attestation")
    while IFS= read -r uri; do
        [[ "$uri" =~ ^https://github\.com/$REPOSITORY/actions/runs/([0-9]+)/attempts/([0-9]+)$ ]] \
            || die "the attestation of $3 names the run '$uri': refusing to sign"
        foreign=$(gh api --paginate "repos/$REPOSITORY/actions/runs/${BASH_REMATCH[1]}/attempts/${BASH_REMATCH[2]}/jobs?per_page=100" \
            --jq '.jobs[] | select(.conclusion != "skipped" and .runner_group_id != 0) | .name')
        [ -z "$foreign" ] || die "run ${BASH_REMATCH[1]} of $3 has jobs on machines of someone else: $foreign: refusing to sign"
    done <<<"$uris"
}

# The files of a release's one draft on GitHub now, as `name sha256:digest`, sorted.
draft_files() { # release, or the draft's id on stdout with `id` as second argument
    local listed
    listed=$(gh api --paginate "repos/$REPOSITORY/releases?per_page=100" \
        --jq ".[] | select(.tag_name == \"$1\" and .draft)")
    [ "$(grep -c '^{' <<<"$listed" || true)" = 1 ] || die "$1 is not exactly one draft: refusing to sign"
    [ "$(jq -r .prerelease <<<"$listed")" = false ] || die "the draft $1 was made a prerelease: refusing to sign"
    if [ "${2-}" = id ]; then
        jq -r .id <<<"$listed"
    else
        jq -r '.assets[] | "\(.name) \(.digest)"' <<<"$listed" | LC_ALL=C sort
    fi
}

# The files of the directory that was checked, as draft_files lists them.
checked_files() { # directory
    (cd "$1" && find . -mindepth 1 -maxdepth 1 -printf '%P\0' | xargs -0 sha256sum) |
        awk '{ print $2, "sha256:" $1 }' | LC_ALL=C sort
}

# What was checked is still what is there, and the commit still the commit.
unchanged() { # directory, release
    one_commit
    [ "$(draft_files "$2")" = "$(checked_files "$1")" ] \
        || die "the draft $2 changed while it was being signed: nothing was published, see what changed before anything else"
}

check_release() { # release, sums file, workflow
    local release=$1 sums=$2 workflow=$3 dir=$WORK/$1
    echo "==> Checking the draft $release"
    gh release download "$release" --repo "$REPOSITORY" --dir "$dir"
    [ -f "$dir/$sums" ] || die "the draft $release has no $sums"
    [ ! -e "$dir/$sums.sig" ] || die "the draft $release already has a signature. If a run of this command stopped after uploading it, remove it (gh release delete-asset $release $sums.sig); if not, someone else put it there"
    check_attestation "$dir/$sums" "$workflow" "$release"
    check_files "$dir" "$sums" "$release"
}

summary_of() { # release, sums file
    local dir=$WORK/$1
    printf '  release : %s  (%s files)\n' "$1" "$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l)"
    printf '  sums    : %s  %s\n' "$2" "$(sha256sum "$dir/$2" | cut -d' ' -f1)"
}

# Once, for all the signing of this run. From no environment: it goes to the signing alone.
passphrase() {
    typed=${FSBPYR_SIGNING_PASSPHRASE-}
    [ -z "$typed" ] || return 0
    { : </dev/tty; } 2>/dev/null || die "no passphrase: set FSBPYR_SIGNING_PASSPHRASE or run this on a terminal"
    IFS= read -rsp "Passphrase of $KEY: " typed </dev/tty
    echo >&2
}

sign_sums() { # release, sums file
    local file=$WORK/$1/$2 previous
    FSBPYR_SIGNING_PASSPHRASE=$typed bash tools/release/release-signing.sh sign "$KEY" "$file"
    previous=$(bash tools/release/previous-release.sh "$TAG")
    bash tools/release/check-signature.sh . "$file" "$TAG" "$previous"
}

publish_release() { # release, sums file, make_latest value
    local release=$1 sums=$2 latest=$3 dir=$WORK/$1
    mv "$dir/$sums.sig" "$WORK/$release.sig"
    unchanged "$dir" "$release"
    mv "$WORK/$release.sig" "$dir/$sums.sig"
    gh release upload "$release" "$dir/$sums.sig" --repo "$REPOSITORY"
    unchanged "$dir" "$release"
    # By id: a tag can have more than one draft by now, and only this one was checked.
    gh api -X PATCH "repos/$REPOSITORY/releases/$(draft_files "$release" id)" \
        -F draft=false -f "make_latest=$latest" >/dev/null
    bash tools/release/audit.sh --record "$release"
    echo "==> Published $release"
}

main_state=$(state_of "$TAG")
el8_state=$(state_of "$EL8_TAG")
case "$main_state" in
    none) die "$TAG has no draft: release.yml has not finished" ;;
    published) echo "$TAG is published" ;;
esac
case "$el8_state" in
    none) echo "$EL8_TAG has no draft yet: run this again when el8.yml has finished, or leave it, as a release may have no EL8 stubs" ;;
    published) echo "$EL8_TAG is published" ;;
esac
[ "$main_state" = draft ] || [ "$el8_state" = draft ] || exit 0

# Both drafts are checked, and both signed, before either is published: a wrong passphrase, or a
# companion that does not pass, leaves nothing half done.
[ "$main_state" != draft ] || check_release "$TAG" SHA256SUMS release.yml
[ "$el8_state" != draft ] || check_release "$EL8_TAG" SHA256SUMS-glibc2.28 el8.yml
printf '\nAbout to sign and publish, on %s:\n' "$REPOSITORY"
[ "$main_state" != draft ] || summary_of "$TAG" SHA256SUMS
[ "$el8_state" != draft ] || summary_of "$EL8_TAG" SHA256SUMS-glibc2.28
cat <<SUMMARY
  commit  : $COMMIT
            your HEAD, GitHub's $BRANCH, GitHub's $TAG and the attestation all name it,
            and every job of its run ran on GitHub's machines
  key     : $KEY

This signs with the key on this machine and uploads only the signature. Publishing is final:
a published release cannot be changed.
SUMMARY
confirm_or_abort
passphrase
[ "$main_state" != draft ] || sign_sums "$TAG" SHA256SUMS
[ "$el8_state" != draft ] || sign_sums "$EL8_TAG" SHA256SUMS-glibc2.28
[ "$main_state" != draft ] || publish_release "$TAG" SHA256SUMS true
[ "$el8_state" != draft ] || publish_release "$EL8_TAG" SHA256SUMS-glibc2.28 false

# --- 5. As GitHub now serves it ----------------------------------------------
bash tools/release/audit.sh || die "the audit fails after publishing: see above"
