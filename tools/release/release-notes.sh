#!/usr/bin/env bash
#
# release-notes.sh — print one version's section of the CHANGELOG.
#
#     bash tools/release/release-notes.sh VERSION [CHANGELOG]
#
# VERSION is what stands in the section header: `0.1.0` for `## [0.1.0] - 2026-09-24`, or
# `Unreleased`. CHANGELOG defaults to the project's CHANGELOG.md. The section runs up to the next
# `## [` header; leading and trailing blank lines are dropped.
#
# Used by prepare.sh (the [Unreleased] section must not be empty), release.sh (the version's
# section must be there, [Unreleased] empty) and by the release workflow
# (.github/workflows/release.yml: the notes of the GitHub release for the pushed tag).
# Exit status: 0 with the notes on stdout, 1 if the section is missing or empty, 2 on bad usage.
set -euo pipefail

usage() { echo "usage: release-notes.sh VERSION [CHANGELOG]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] && [ -n "$1" ] || usage

VERSION="$1"
CHANGELOG="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/CHANGELOG.md}"
[ -f "$CHANGELOG" ] || { echo "ERROR: $CHANGELOG not found" >&2; exit 1; }

# A fixed-string header match (a version's dots are not regex wildcards): "## [VERSION]", then
# the end of the line or a space (" - DATE"). awk exits 3 when there is no such header.
header="## [$VERSION]"
status=0
notes="$(awk -v h="$header" '
    function is_header() {
        return index($0, h) == 1 && (length($0) == length(h) || substr($0, length(h) + 1, 1) == " ")
    }
    grab && /^## \[/ { exit }
    grab             { buf = buf $0 ORS }
    !grab && is_header() { grab = 1 }
    END {
        if (!grab) exit 3
        sub(/^\n+/, "", buf); sub(/\n+$/, "", buf); printf "%s", buf
    }
' "$CHANGELOG")" || status=$?
case "$status" in
    0) ;;
    3) echo "ERROR: no '$header' section in $CHANGELOG" >&2; exit 1 ;;
    *) echo "ERROR: cannot read $CHANGELOG" >&2; exit 1 ;;
esac
[ -n "${notes//[[:space:]]/}" ] \
    || { echo "ERROR: the '$header' section in $CHANGELOG is empty" >&2; exit 1; }
printf '%s\n' "$notes"
