#!/usr/bin/env bash
#
# follow-run.sh — follows a workflow run until it completes: one plain line when a job starts
# and one when it ends (`gh run watch` redraws the terminal instead), then the run's result.
#
#     bash tools/release/follow-run.sh RUN_ID
#
# Exit 0: the run succeeded; 1: it did not, or gh could not read it 5 times in a row. The
# run's own status ends the wait: GitHub has left jobs of a finished run "in_progress".
# FSBPYR_RELEASE_FOLLOW_POLL: seconds between two looks at the run (default 30).
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: follow-run.sh RUN_ID" >&2; exit 2; }
run="$1"
poll="${FSBPYR_RELEASE_FOLLOW_POLL:-30}"
MAX_FAILURES=5

# The run's state, then one "STATE<TAB>JOB" line per job; a state is the conclusion once
# completed, else the status.
STATES='def state: if .status == "completed" then .conclusion else .status end;'
STATES+=' state, (.jobs[] | "\(state)\t\(.name)")'

declare -A shown=()
failures=0
while :; do
    if ! states="$(gh run view "$run" --json status,conclusion,jobs --jq "$STATES")"; then
        failures=$((failures + 1))
        [ "$failures" -lt "$MAX_FAILURES" ] \
            || { echo "ERROR: cannot read run $run" >&2; exit 1; }
        sleep "$poll"
        continue
    fi
    failures=0
    while IFS=$'\t' read -r state job; do
        case "$state" in queued|waiting|pending|requested) continue ;; esac
        [ "${shown[$job]:-}" != "$state" ] || continue
        shown[$job]="$state"
        echo "$(date +%T)  $state  $job"
    done < <(tail -n +2 <<<"$states")
    case "$(head -n 1 <<<"$states")" in
        success) echo "$(date +%T)  run $run succeeded"; exit 0 ;;
        queued|waiting|pending|requested|in_progress) ;;
        *) echo "$(date +%T)  run $run: $(head -n 1 <<<"$states")"; exit 1 ;;
    esac
    sleep "$poll"
done
