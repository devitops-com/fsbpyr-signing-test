# confirm.sh — sourced by release.sh and release-sign.sh: ask before something outward-facing.

# confirm_or_abort: Continue? on the terminal. FSBPYR_RELEASE_ASSUME_YES=1 skips the prompt.
confirm_or_abort() {
    [ "${FSBPYR_RELEASE_ASSUME_YES:-0}" != "1" ] || return 0
    local reply
    if [ -t 0 ]; then
        printf 'Continue? [y/N] '; read -r reply
    # The /dev/tty node always exists; without a controlling terminal opening it
    # fails (and set -e would abort without a word), so probe it instead.
    elif { : > /dev/tty; } 2>/dev/null; then
        printf 'Continue? [y/N] ' > /dev/tty; read -r reply < /dev/tty
    else
        echo "ERROR: not a TTY; set FSBPYR_RELEASE_ASSUME_YES=1 to proceed non-interactively" >&2
        exit 1
    fi
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
}
