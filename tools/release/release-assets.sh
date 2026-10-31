#!/usr/bin/env bash
#
# release-assets.sh — release the version main's HEAD declares: tag HEAD and push the tags.
#
#     bash tools/release/release-assets.sh [X.Y.Z]        (make release-assets [VERSION=X.Y.Z])
#
# HEAD is the release commit that `make release-prep` (prepare.sh) made at the end of a branch,
# merged into main by its pull request. That push to main ran full-suite.yml, which built and
# checked exactly this commit, the release build included. Nothing is built or tested here,
# and no release is created here: the pushed tag triggers .github/workflows/release.yml, which
# builds the executables from the tag (build.yml, without its checks), attests them (GitHub
# artifact attestations can only be made inside GitHub Actions) and leaves a draft of the GitHub
# release. This script follows that run (follow-run.sh: a line per job started or finished);
# `make release-sign` then checks the draft, signs it here and publishes it. X.Y.Z, if given, must
# be the version HEAD declares.
#
# Guards (all must pass before the tag is made): the three versions agree (version-files.sh)
# and equal X.Y.Z, on `main`, clean working tree (untracked files and assume-unchanged /
# skip-worktree entries included), local == hub/main, neither the tag nor the GitHub release
# exists yet, the CHANGELOG has the version's section and an empty [Unreleased] one (a change
# merged after the release commit would ship without being in the notes), a successful
# full-suite.yml run for HEAD's push to main (a run in progress is waited for), and an audit that
# finds GitHub as this machine recorded it (audit.sh).
#
# Non-interactive use: set FSBPYR_RELEASE_ASSUME_YES=1 to skip the prompt.
# FSBPYR_RELEASE_WATCH_WAIT: how many seconds to wait for the tag's workflow run
# to show up (default 60); without one, the script says where to follow it and
# still succeeds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=version-files.sh
. tools/release/version-files.sh
# shellcheck source=confirm.sh
. tools/release/confirm.sh

BRANCH="main"
CHANGELOG="CHANGELOG.md"
WORKFLOW="release.yml"
SUITE_WORKFLOW="full-suite.yml"
WATCH_WAIT="${FSBPYR_RELEASE_WATCH_WAIT:-60}"
WATCH_POLL=3

[ $# -le 1 ] || { echo "usage: release-assets.sh [X.Y.Z]" >&2; exit 2; }

VERSION="$(current_version)"
if [ $# -eq 1 ] && [ "$1" != "$VERSION" ]; then
    echo "ERROR: HEAD declares version $VERSION, not $1: make the release commit first" \
         "(make release-prep VERSION=$1, on the branch that goes to $BRANCH)" >&2
    exit 1
fi
TAG="v$VERSION"
# The tag of the EL8 stubs' companion release, on the same commit: the EL8 workflow publishes
# that release on it, but GitHub refuses its token a tag on a commit that changes a workflow.
EL8_TAG="el8-$TAG"

# --- 0. Tooling --------------------------------------------------------------
command -v gh  >/dev/null || { echo "ERROR: gh CLI not installed" >&2; exit 1; }
command -v git >/dev/null || { echo "ERROR: git not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated (run: gh auth login)" >&2; exit 1; }

# --- 1. Guards ---------------------------------------------------------------
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] \
    || { echo "ERROR: not on '$BRANCH' (currently on '$CURRENT_BRANCH')" >&2; exit 1; }

# --untracked-files=all overrides a status.showUntrackedFiles=no config: what was
# tested must be exactly what the tag points at (CI builds from the tag).
[ -z "$(git status --porcelain --untracked-files=all)" ] \
    || { echo "ERROR: working tree is not clean; commit or stash first" >&2; exit 1; }
# git status cannot see edits to files marked assume-unchanged (lower-case tag in
# `git ls-files -v`) or skip-worktree (S).
HIDDEN="$(git ls-files -v | grep -E '^([a-z]|S) ' || true)"
[ -z "$HIDDEN" ] || {
    echo "ERROR: files hidden from git status (assume-unchanged / skip-worktree):" >&2
    printf '%s\n' "$HIDDEN" | cut -c3- | sed 's/^/  /' >&2
    echo "       clear with: git update-index --no-assume-unchanged --no-skip-worktree FILE" >&2
    exit 1
}

for tag in "$TAG" "$EL8_TAG"; do
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        echo "ERROR: tag $tag already exists locally" >&2; exit 1
    fi
    if git ls-remote --exit-code --tags hub "$tag" >/dev/null 2>&1; then
        echo "ERROR: tag $tag already exists on hub" >&2; exit 1
    fi
done
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "ERROR: a GitHub release for $TAG already exists" >&2; exit 1
fi

# A release is signed, and make release-sign refuses one that pins no keys: tagged, the version
# would be burned. docs/signing.md §5.2 says how the keys are made and pinned.
git ls-tree -r --name-only HEAD -- src/fsbpyr/release-keys/ | grep '\.pub$' >/dev/null || {
    echo "ERROR: src/fsbpyr/release-keys/ pins no release keys, and make release-sign would refuse" \
         "$TAG after its tag burned the version: make K and R and pin them first" \
         "(docs/signing.md, One-time setup)" >&2
    exit 1
}

# The release workflow publishes the version's section as the release notes; a change under
# [Unreleased] is in the tagged commit but would be in no release's notes.
bash tools/release/release-notes.sh "$VERSION" "$CHANGELOG" >/dev/null \
    || { echo "ERROR: no release notes for $VERSION: make release-prep makes them" >&2; exit 1; }
if bash tools/release/release-notes.sh Unreleased "$CHANGELOG" >/dev/null 2>&1; then
    echo "ERROR: $CHANGELOG has changes under [Unreleased], merged after the release commit" \
         "of $VERSION: they would ship in $TAG without being in its notes. End a branch with" \
         "make release-prep for the next version instead" >&2
    exit 1
fi

echo "==> Fetching hub/$BRANCH"
git fetch --quiet hub "$BRANCH"
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse FETCH_HEAD)"
[ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] \
    || { echo "ERROR: local $BRANCH differs from hub/$BRANCH; push or pull first" >&2; exit 1; }

# GitHub starts no workflow for a push whose commit's message has a skip instruction, and that
# includes the tag's push: release.yml would never run for $TAG.
SKIP_INSTRUCTION='\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|^skip-checks: ?true'
if git log -1 --format=%B HEAD | grep -qiE "$SKIP_INSTRUCTION"; then
    echo "ERROR: HEAD's commit message has a CI skip instruction: GitHub would start no" \
         "release.yml run for $TAG on it. Merge without it; full-suite.yml leaves out" \
         "documentation-only pushes by itself" >&2
    exit 1
fi

# full-suite.yml runs on every push to $BRANCH that changes more than documentation, the
# release build and its checks included: tag only a commit whose run passed, or one with only
# documentation changed since such a commit (green-run.sh). A run in progress is waited for.
bash tools/release/green-run.sh "$SUITE_WORKFLOW" "$LOCAL_HEAD" >/dev/null

# Before a version is burned on a repository that may have been tampered with.
bash tools/release/audit.sh \
    || { echo "ERROR: the audit did not pass; nothing was tagged" >&2; exit 1; }

# --- 2. Confirm --------------------------------------------------------------
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '?')"
cat <<EOF

About to release:
  repo    : $REPO
  version : $VERSION
  tag     : $TAG
  branch  : $BRANCH  ($(git rev-parse --short HEAD))

This tags $BRANCH's HEAD and pushes the tag, which starts the $WORKFLOW workflow: it
builds, attests and leaves a draft for make release-sign. It is outward-facing and hard to undo.
EOF
confirm_or_abort

# --- 3. Tag and push the tag ---------------------------------------------------
if ! git tag -a "$TAG" -m "fsbpyr $TAG" || ! git tag -a "$EL8_TAG" -m "fsbpyr $TAG: EL8 stubs"; then
    echo "ERROR: creating the tags $TAG and $EL8_TAG failed; nothing was pushed" >&2
    exit 1
fi
echo "==> Tagged $TAG and $EL8_TAG; pushing them to hub"
if ! git push --atomic hub "$TAG" "$EL8_TAG"; then
    cat >&2 <<EOF
ERROR: push failed. The tags $TAG and $EL8_TAG exist locally, but nothing was pushed. Choose one:
       (a) Abort: git tag -d $TAG $EL8_TAG
       (b) Fix the remote state and push again; $TAG starts the release workflow:
             git push --atomic hub $TAG $EL8_TAG
EOF
    exit 1
fi

# --- 4. Follow the release workflow the tag started --------------------------
# Past this point $TAG is pushed and the build is in CI's hands: `make release` goes on from
# here, and this script's tag guard blocks a second run. GitHub creates the run a few seconds
# after the push.
echo "==> $TAG pushed; the $WORKFLOW workflow builds and attests it and leaves a draft"
run_id=""
waited=0
while :; do
    run_id="$(gh run list --workflow "$WORKFLOW" --branch "$TAG" --commit "$LOCAL_HEAD" \
        --event push --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null \
        || true)"
    case "$run_id" in
        ''|*[!0-9]*) run_id="" ;;
        *) break ;;
    esac
    [ "$waited" -lt "$WATCH_WAIT" ] 2>/dev/null || break
    sleep "$WATCH_POLL"
    waited=$((waited + WATCH_POLL))
done

if [ -z "$run_id" ]; then
    echo "==> No $WORKFLOW run for $TAG showed up yet. Follow it at"
    echo "      https://github.com/$REPO/actions/workflows/$WORKFLOW"
    echo "    When it succeeds, check, sign and publish the draft: make release-sign KEY=PATH"
    exit 0
fi

echo "==> Following run $run_id (Ctrl-C stops following, not the release)"
if ! bash tools/release/follow-run.sh "$run_id"; then
    # The full suite built and checked this very commit, so a failure here is most likely
    # transient. A pushed tag is never moved or pushed again: if it needs a code fix, the
    # version is burned, and the fix is released under the next patch version, whose notes
    # must also carry the burned one's changes.
    next="X.Y.Z+1"
    [[ "$VERSION" =~ $XYZ ]] && next="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
    cat >&2 <<EOF
ERROR: the release workflow (run $run_id) failed: $TAG is pushed and has no draft.
       See why:           gh run view $run_id --log-failed
       Transient failure: gh run rerun $run_id --failed
       Needs a code fix:  this version is burned: $TAG stays as it is. Fix it on a branch,
                          merge the [$VERSION] section of $CHANGELOG into [Unreleased] with
                          the fix's entry, so $next's notes carry its changes, note at the
                          top of $CHANGELOG that $TAG has no release, and end the branch
                          with make release-prep VERSION=$next
EOF
    exit 1
fi

echo ""
echo "Built fsbpyr $TAG: nothing is published yet. Check, sign and publish the draft:"
echo "    make release-sign KEY=PATH"
