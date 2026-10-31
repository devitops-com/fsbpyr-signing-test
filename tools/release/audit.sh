#!/usr/bin/env bash
#
# audit.sh — compare what GitHub holds with what this machine recorded, so that the admin is the
# first to see a tampered account or repository, not a user (docs/signing.md §5.7).
#
#     bash tools/release/audit.sh                 (make release-audit)
#     bash tools/release/audit.sh --accept        take today's state as the reference
#     bash tools/release/audit.sh --record TAG    add a release this machine has just published
#
# Checked: every tag against this clone; GitHub's main is known here; every published release is on
# record, with the same commit and the same files, immutable, and signed by the keys its tag pins;
# nothing recorded is gone; no draft for a tag this clone lacks; the latest release is the newest
# one; and the settings an attacker changes to stay: members, apps, webhooks, keys, rulesets,
# secrets, variables, environments, runners, Actions, immutable releases, the wiki's head.
#
# `make release` and `make release-sign` run it, and it can run from cron on any machine with this
# clone: it needs no release key, only a gh login that can read those settings. It never runs in
# GitHub Actions, which an attacker could turn off. The reference is outside GitHub, in
# FSBPYR_RELEASE_STATE (default $XDG_STATE_HOME/fsbpyr-release): `releases`, one line per release
# (tag, commit, the SHA-256 of its files' names and digests), and `settings`. A signature that
# passes on a release that is not on record is a stolen key. --accept takes whatever it finds, so
# read what differs first. FSBPYR_RELEASE_REPO and FSBPYR_RELEASE_WIKI replace GitHub in tests and
# rehearsals. Needs gh, git, jq and sha256sum, and OpenSSL 3.5 for the signatures.
#
# Exit status: 0 as recorded, 1 something differs, 2 it could not be checked: a lookup that goes
# wrong must stop a release, not pass a check.
set -Eeuo pipefail
trap 'exit 2' ERR  # with -E in every $(...) too; a <(...) is not waited for, so none may fail
export LC_ALL=C

REPOSITORY=${FSBPYR_RELEASE_REPO:-devitops-com/fsbpyr}
WIKI=${FSBPYR_RELEASE_WIKI:-https://github.com/$REPOSITORY.wiki.git}
REMOTE=hub
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE=${FSBPYR_RELEASE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/fsbpyr-release}
XYZ='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
API=repos/$REPOSITORY

failures=0
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

usage() {
    echo "usage: audit.sh [--accept | --record TAG]" >&2
    exit 2
}

# tag commit, sorted, for the tags of a remote or of this clone, annotated tags as their commits.
remote_tags() {
    git -C "$ROOT" ls-remote "$REMOTE" 'refs/tags/*' | awk '{
        name = $2; sub("^refs/tags/", "", name)
        if (sub(/\^\{\}$/, "", name)) { peeled[name] = $1 } else { object[name] = $1 }
    } END { for (name in object) print name, (name in peeled ? peeled[name] : object[name]) }' | sort
}

local_tags() {
    git -C "$ROOT" for-each-ref refs/tags \
        --format='%(refname:short) %(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)' | sort
}

# Every release, drafts too, a JSON object per line.
all_releases() { gh api --paginate "$API/releases?per_page=100" --jq '.[]'; }

# The SHA-256 of what a release is, as GitHub lists it: its id, so that one deleted and made again
# differs, what it says, and its files' names and digests.
fingerprint() {
    jq -r '.tag_name, .id, .prerelease, .target_commitish, .name, .body,
           ([.assets[] | "\(.name) \(.digest)"] | sort | .[])' <<<"$1" | sha256sum | cut -d' ' -f1
}

# The settings an attacker changes to stay, a line each, sorted.
settings() {
    local org=${REPOSITORY%%/*} rulesets id
    rulesets=$(gh api --paginate "$API/rulesets?per_page=100" --jq '.[].id')
    {
        gh api "$API" --jq '"repository \(.visibility) default=\(.default_branch) archived=\(.archived) wiki=\(.has_wiki)"'
        gh api --paginate "$API/collaborators?affiliation=all&per_page=100" --jq '.[] | "collaborator \(.login) \(.role_name)"'
        gh api --paginate "orgs/$org/members?role=admin&per_page=100" --jq '.[] | "owner \(.login)"'
        gh api --paginate "orgs/$org/members?per_page=100" --jq '.[] | "member \(.login)"'
        gh api --paginate "orgs/$org/installations?per_page=100" --jq '.installations[] | "app \(.app_slug) \(.repository_selection) \(.permissions | tojson)"'
        gh api --paginate "$API/hooks?per_page=100" --jq '.[] | "webhook \(.id) \(.config.url) active=\(.active)"'
        gh api --paginate "$API/keys?per_page=100" --jq '.[] | "deploy-key \(.id) \(.title) read_only=\(.read_only)"'
        for id in $rulesets; do
            gh api "$API/rulesets/$id" --jq '"ruleset \(.name) \(.target) \(.enforcement) \(.bypass_actors | tojson) \(.conditions | tojson) \(.rules | tojson)"'
        done
        gh api --paginate "$API/actions/secrets?per_page=100" --jq '.secrets[] | "secret \(.name) \(.updated_at)"'
        gh api --paginate "orgs/$org/actions/secrets?per_page=100" --jq '.secrets[] | "org-secret \(.name) \(.updated_at)"'
        gh api --paginate "$API/actions/variables?per_page=100" --jq '.variables[] | "variable \(.name) \(.value)"'
        gh api --paginate "orgs/$org/actions/variables?per_page=100" --jq '.variables[] | "org-variable \(.name) \(.value)"'
        gh api "$API/environments" --jq '.environments[]? | "environment \(.name)"'
        gh api --paginate "$API/actions/runners?per_page=100" --jq '.runners[] | "runner \(.name) \([.labels[].name] | join(","))"'
        gh api --paginate "orgs/$org/actions/runners?per_page=100" --jq '.runners[] | "org-runner \(.name) \([.labels[].name] | join(","))"'
        gh api "$API/actions/permissions" --jq '"actions enabled=\(.enabled) allowed=\(.allowed_actions)"'
        gh api "$API/actions/permissions/workflow" --jq '"workflows token=\(.default_workflow_permissions) approve-prs=\(.can_approve_pull_request_reviews)"'
        gh api "$API/immutable-releases" --jq '"immutable-releases \(.enabled)"'
        git -C "$ROOT" ls-remote "$WIKI" HEAD | awk '{ print "wiki", $1 }'
    } | sort
}

# A release's commit, from the remote's tags in $tags.
commit_of() { awk -v tag="$1" '$1 == tag { print $2 }' <<<"$tags"; }

record_line() { # release JSON
    local tag commit
    tag=$(jq -r .tag_name <<<"$1")
    commit=$(commit_of "$tag")
    [[ -n "$commit" ]] || { echo "ERROR: GitHub has no tag $tag" >&2; exit 2; }
    printf '%s %s %s\n' "$tag" "$commit" "$(fingerprint "$1")"
}

accept() {
    local releases release now
    umask 077
    mkdir -p "$STATE"
    tags=$(remote_tags)
    releases=$(all_releases)
    now=$(settings)
    : >"$STATE/releases.new"
    while IFS= read -r release; do
        [[ -n "$release" && "$(jq -r .draft <<<"$release")" == false ]] || continue
        record_line "$release" >>"$STATE/releases.new"
    done <<<"$releases"
    printf '%s\n' "$now" >"$STATE/settings.new"
    mv -f "$STATE/releases.new" "$STATE/releases"
    mv -f "$STATE/settings.new" "$STATE/settings"
    echo "recorded $(wc -l <"$STATE/releases") releases and the settings of $REPOSITORY in $STATE"
}

record() { # TAG
    local release
    [[ -f "$STATE/releases" ]] || { echo "ERROR: no reference in $STATE: run audit.sh --accept first" >&2; exit 2; }
    tags=$(remote_tags)
    release=$(gh api "$API/releases/tags/$1")
    [[ "$(jq -r .draft <<<"$release")" == false ]] || { echo "ERROR: $1 is a draft" >&2; exit 2; }
    ! awk -v tag="$1" '$1 == tag { found = 1 } END { exit !found }' "$STATE/releases" ||
        { echo "ERROR: $1 is on record already" >&2; exit 2; }
    record_line "$release" >>"$STATE/releases"
    echo "recorded $1"
}

check_tags_and_main() {
    local here differs main
    here=$(local_tags)
    differs=$(diff <(printf '%s\n' "$here") <(printf '%s\n' "$tags") || true)
    [[ -z "$differs" ]] || fail "the tags here (<) and on GitHub (>) differ:"$'\n'"$differs"
    main=$(git -C "$ROOT" ls-remote "$REMOTE" | awk '$2 == "refs/heads/main" { print $1 }')
    [[ -n "$main" ]] || { echo "ERROR: GitHub has no main" >&2; exit 2; }
    git -C "$ROOT" merge-base --is-ancestor "$main" refs/heads/main 2>/dev/null ||
        fail "GitHub's main is at $main, which this clone's main does not hold"
}

# Whether a release's version must be signed: the version in first-signed-release and later ones.
must_be_signed() { # vX.Y.Z
    local first
    first=v$(cat "$ROOT/tools/release/first-signed-release")
    [[ "$(printf '%s\n%s\n' "$first" "$1" | sort -V | head -1)" == "$first" ]]
}

# The sums of a release against the keys its tag pins, and its files against those sums.
check_signed() { # release JSON, tag
    local version sums listed files previous status=0
    version=${2#el8-}
    sums=SHA256SUMS
    [[ "$2" == "$version" ]] || sums=SHA256SUMS-glibc2.28
    files=$(jq -r '.assets[] | "\(.name) \(.digest)"' <<<"$1" | sort)
    if ! awk -v name="$sums.sig" '$1 == name { found = 1 } END { exit !found }' <<<"$files"; then
        must_be_signed "$version" || return 0
        fail "$2 has no $sums.sig"
        return 0
    fi
    gh release download "$2" --repo "$REPOSITORY" --dir "$work/$2" --pattern "$sums" --pattern "$sums.sig"
    previous=$(bash "$ROOT/tools/release/previous-release.sh" "$version")
    bash "$ROOT/tools/release/check-signature.sh" "$ROOT" "$work/$2/$sums" "$version" "$previous" \
        >/dev/null 2>"$work/signature.err" || status=$?
    case $status in
        0) ;;
        1) fail "the signature of $2's $sums is not valid"; return 0 ;;
        *) cat "$work/signature.err" >&2; exit 2 ;;
    esac
    listed=$(awk '{ print $2, "sha256:" $1 }' "$work/$2/$sums" | sort)
    files=$(awk -v sums="$sums" '$1 != sums && $1 != sums ".sig"' <<<"$files")
    [[ -z "$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$files"))" ]] ||
        fail "$2 has files its signed $sums does not list"
    # A companion publishes each stub's .xz only, and its sums list the stub too.
    [[ "$2" != "$version" || -z "$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$files"))" ]] ||
        fail "$2 lacks files its signed $sums lists"
}

check_releases() {
    local releases release tag expected recorded seen=''
    releases=$(all_releases)
    while IFS= read -r release; do
        [[ -n "$release" ]] || continue
        tag=$(jq -r .tag_name <<<"$release")
        if [[ "$(jq -r .draft <<<"$release")" == true ]]; then
            git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null ||
                fail "a draft release $tag, for a tag this clone lacks"
            continue
        fi
        seen+="$tag"$'\n'
        recorded=$(awk -v tag="$tag" '$1 == tag' "$STATE/releases")
        if [[ -z "$recorded" ]]; then
            fail "release $tag is on GitHub and not on record: if its signature passes, a release key is stolen"
        else
            expected=$(record_line "$release")
            [[ "$expected" == "$recorded" ]] || fail "release $tag changed: recorded $recorded, now $expected"
        fi
        [[ "$(jq -r .immutable <<<"$release")" == true ]] || fail "release $tag is not immutable"
        check_signed "$release" "$tag"
    done <<<"$releases"
    while IFS=' ' read -r tag _; do
        grep -qxF -- "$tag" <<<"$seen" || fail "release $tag is on record and gone from GitHub"
    done <"$STATE/releases"
}

check_latest() {
    local newest latest
    newest=$(cut -d' ' -f1 "$STATE/releases" | { grep -E "$XYZ" || true; } | sort -V | tail -1)
    [[ -n "$newest" ]] || return 0
    latest=$(gh api "$API/releases/latest" --jq .tag_name)
    [[ "$latest" == "$newest" ]] || fail "the latest release is $latest, not $newest: updates are held back"
}

check_settings() {
    local now differs
    now=$(settings)
    differs=$(diff "$STATE/settings" <(printf '%s\n' "$now") || true)
    [[ -z "$differs" ]] || fail "the settings differ from the record (<), now (>):"$'\n'"$differs"
}

case "${1-}:$#" in
    :0) ;;
    --accept:1) accept; exit 0 ;;
    --record:2) record "$2"; exit 0 ;;
    *) usage ;;
esac

[[ -f "$STATE/releases" && -f "$STATE/settings" ]] ||
    { echo "ERROR: no reference in $STATE: read GitHub's state, then run audit.sh --accept" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
tags=$(remote_tags)
check_tags_and_main
check_releases
check_latest
check_settings
if ((failures)); then
    echo "audit: $failures finding(s): treat GitHub as tampered with until each is explained"
    exit 1
fi
echo "audit: $(wc -l <"$STATE/releases") releases, the tags, main and the settings are as recorded"
