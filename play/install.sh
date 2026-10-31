#!/bin/sh
# The fsbpyr installer, modelled on uv's:
#
#     curl -LsSf https://github.com/devitops-com/fsbpyr/releases/latest/download/install.sh | sh
#     curl -LsSf .../install.sh | sh -s -- --python 3.13    # the fsbpyr that runs on 3.13
#
# This is the template. tools/release/make-install.sh fills in the release's version, the
# targets and Pythons it has and the SHA-256 and recorded glibc of every asset when the release
# is made (release.yml's publish job), so a download is checked against what the release built
# before anything of it runs. Plain POSIX sh (dash, busybox); nothing runs until the last line,
# so a truncated download does nothing.

set -u

APP_VERSION='0.8.2'
TARGETS='x86_64-linux-gnu'
# The Pythons it has a build for, oldest first, and the one it installs when not told one.
PYTHONS='3.14'
DEFAULT_PYTHON='3.14'
# One asset per line: its name, its SHA-256 and, for an executable, the glibc it needs
# (`fsbpyr inspect`: "glibc >= X.Y"; - where there is none).
RELEASE_ASSETS='
fsbpyr-3.14-x86_64-linux-gnu daf1536b38907bd31d9a4e1a13861c5cc445df13a1eeaa68a48c8c3ec08336fb 2.34
fsbpyr-3.14-x86_64-linux-gnu.xz 5c1dbe89120f04bdec9e86c0034ddad956388c63e426efb3471c2ac69eac30a6 -
'

REPO='devitops-com/fsbpyr-signing-test'
SIGNER_WORKFLOW="$REPO/.github/workflows/release.yml"
# Tests only: they serve the release from a local HTTPS server.
BASE_URL="${FSBPYR_INSTALLER_BASE_URL:-https://github.com/$REPO/releases/download/v$APP_VERSION}"

QUIET=0
VERBOSE=0
NO_MODIFY_PATH=0
PYTHON=
ASSET=
WORK_DIR=
STAGE=

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
say_verbose() { [ "$VERBOSE" = 1 ] && say "$*"; return 0; }
warn() { printf 'warning: %s\n' "$*" >&2; }
err() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

have() { command -v "$1" > /dev/null 2>&1; }

cleanup() {
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
    [ -z "$STAGE" ] || rm -f "$STAGE"
}

usage() {
    cat <<EOF
fsbpyr-installer.sh

The installer for fsbpyr $APP_VERSION

This script detects the platform it runs on, downloads the matching fsbpyr executable of the
release (https://github.com/$REPO/releases) for Python $DEFAULT_PYTHON or the one --python names,
checks it against the SHA-256 recorded in this script and with \`fsbpyr inspect --verify\`, and
installs it, with its man page and shell completions, into the first of
\$FSBPYR_INSTALL_DIR, \$XDG_BIN_HOME, \$XDG_DATA_HOME/../bin and \$HOME/.local/bin.

Usage: install.sh [OPTIONS]

Options:
      --python X.Y
          Install the fsbpyr that runs on Python X.Y (this release has: $PYTHONS); by
          default $DEFAULT_PYTHON. \`fsbpyr self update\` keeps to the Python installed.
  -v, --verbose
          Print more while installing
  -q, --quiet
          Print only errors
      --no-modify-path
          Do not change shell files or \$GITHUB_PATH to put the install directory on PATH
  -h, --help
          Print this help

Environment:
  FSBPYR_VERIFY=1
          Also check the download's GitHub attestation with \`gh attestation verify\`; stop
          when it fails or gh is missing
  FSBPYR_NO_MODIFY_PATH=1
          As --no-modify-path
EOF
}

# --- Target ---

# The target of this host, named as the release's assets name it.
detect_target() {
    os="$(uname -s)" || err "cannot run uname"
    machine="$(uname -m)" || err "cannot run uname"
    case "$os" in
        Linux) kernel=linux ;;
        Darwin) kernel=macos ;;
        *) kernel="$(printf '%s' "$os" | tr '[:upper:]' '[:lower:]')" ;;
    esac
    case "$machine" in
        x86_64 | amd64) cpu=x86_64 ;;
        aarch64 | arm64 | armv8l) cpu=aarch64 ;;
        *) cpu="$machine" ;;
    esac
    if [ "$kernel" = macos ] && [ "$cpu" = x86_64 ] \
        && [ "$(sysctl -n hw.optional.arm64 2> /dev/null)" = 1 ]; then
        cpu=aarch64  # a shell under Rosetta on Apple Silicon
    fi
    case "$kernel" in
        linux)
            if ldd --version 2>&1 | grep -qi musl; then libc=musl; else libc=gnu; fi
            TARGET="$cpu-linux-$libc"
            ;;
        *) TARGET="$cpu-$kernel" ;;
    esac
}

in_list() {
    for item in $2; do
        [ "$item" != "$1" ] || return 0
    done
    return 1
}

# Stop, naming the targets the release has, when it has none for this host.
check_target() {
    if ! in_list "$TARGET" "$TARGETS"; then
        err "fsbpyr $APP_VERSION has no executable for this host ($TARGET); its targets are: ${TARGETS:-none}"
    fi
}

# The asset of this host for the Python asked for, DEFAULT_PYTHON when none was.
choose_asset() {
    [ -n "$PYTHON" ] || PYTHON="$DEFAULT_PYTHON"
    in_list "$PYTHON" "$PYTHONS" \
        || err "fsbpyr $APP_VERSION has no build for Python $PYTHON; its Pythons are: ${PYTHONS:-none}"
    ASSET="fsbpyr-$PYTHON-$TARGET"
    [ -n "$(asset_field "$ASSET" 2)" ] \
        || err "fsbpyr $APP_VERSION has no Python $PYTHON build for this host ($TARGET)"
}

asset_field() { # asset, field (2: SHA-256, 3: glibc)
    printf '%s\n' "$RELEASE_ASSETS" | awk -v a="$1" -v f="$2" '$1 == a { print $f; exit }'
}

# True when the host's glibc is at least X.Y: the release records the newest glibc symbol its
# executable uses, and a host with an older one cannot start it.
check_glibc() {
    needed="$(asset_field "$ASSET" 3)"
    case "$needed" in "" | -) return 0 ;; esac
    host="$(ldd --version 2>&1 | sed -n '1s/.* \([0-9][0-9]*\.[0-9][0-9]*\)[^ ]*$/\1/p')"
    if [ -z "$host" ]; then
        warn "cannot tell this host's glibc version; fsbpyr needs glibc >= $needed"
        return 0
    fi
    need_major="${needed%%.*}"
    need_minor="${needed#*.}"
    host_major="${host%%.*}"
    host_minor="${host#*.}"
    if [ "$host_major" -lt "$need_major" ] \
        || { [ "$host_major" -eq "$need_major" ] && [ "$host_minor" -lt "$need_minor" ]; }; then
        err "this host's glibc is $host, but fsbpyr $APP_VERSION needs glibc >= $needed"
    fi
    say_verbose "glibc $host (needs >= $needed)"
}

# --- Download and checks ---

download() { # url, file
    case "$1" in
        https://*) ;;
        *) err "refusing to download $1: only https:// URLs are used" ;;
    esac
    if have curl; then
        curl --proto '=https' --tlsv1.2 -fsSL -o "$2" "$1" \
            || err "could not download $1"
    elif have wget; then
        wget --https-only --secure-protocol=TLSv1_2 -q -O "$2" "$1" \
            || err "could not download $1"
    else
        err "need curl or wget to download fsbpyr"
    fi
}

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | cut -d ' ' -f 1
    elif have shasum; then
        shasum -a 256 "$1" | cut -d ' ' -f 1
    else
        err "need sha256sum or shasum to check the download"
    fi
}

check_sha256() { # file, asset
    expected="$(asset_field "$2" 2)"
    [ -n "$expected" ] || err "this script has no checksum for $2"
    actual="$(sha256_of "$1")" || exit 1
    if [ "$actual" != "$expected" ]; then
        err "checksum mismatch for $2: expected $expected, got $actual"
    fi
    say_verbose "sha256 of $2 matches"
}

check_attestation() { # file
    say_verbose "checking the attestation of $1"
    gh attestation verify "$1" --repo "$REPO" --signer-workflow "$SIGNER_WORKFLOW" \
        --source-ref "refs/tags/v$APP_VERSION" > /dev/null \
        || err "the attestation of the download does not verify; nothing was installed"
}

# Downloads the executable into $STAGE (in the install directory, so that the rename is atomic
# and no mount option of /tmp matters) and checks it three ways before it is installed.
fetch_executable() {
    asset="$ASSET"
    WORK_DIR="$(mktemp -d)" || err "cannot make a temporary directory"
    STAGE="$INSTALL_DIR/.fsbpyr.$$.tmp"
    if have xz && [ -n "$(asset_field "$asset.xz" 2)" ]; then
        download "$BASE_URL/$asset.xz" "$WORK_DIR/download"
        check_sha256 "$WORK_DIR/download" "$asset.xz"
        [ "${FSBPYR_VERIFY:-}" != 1 ] || check_attestation "$WORK_DIR/download"
        xz -dc "$WORK_DIR/download" > "$STAGE" || err "cannot unpack $asset.xz"
    else
        download "$BASE_URL/$asset" "$WORK_DIR/download"
        check_sha256 "$WORK_DIR/download" "$asset"
        [ "${FSBPYR_VERIFY:-}" != 1 ] || check_attestation "$WORK_DIR/download"
        cp "$WORK_DIR/download" "$STAGE" || err "cannot write $STAGE"
    fi
    check_sha256 "$STAGE" "$asset"
    chmod 755 "$STAGE" || err "cannot make $STAGE executable"
    "$STAGE" inspect --verify "$STAGE" > "$WORK_DIR/verify.out" 2>&1 \
        || { cat "$WORK_DIR/verify.out" >&2; err "the download fails \`fsbpyr inspect --verify\`"; }
}

# --- Install ---

choose_install_dir() {
    if [ -n "${FSBPYR_INSTALL_DIR:-}" ]; then
        INSTALL_DIR="$FSBPYR_INSTALL_DIR"
    elif [ -n "${XDG_BIN_HOME:-}" ]; then
        INSTALL_DIR="$XDG_BIN_HOME"
    elif [ -n "${XDG_DATA_HOME:-}" ]; then
        INSTALL_DIR="$XDG_DATA_HOME/../bin"
    elif [ -n "${HOME:-}" ]; then
        INSTALL_DIR="$HOME/.local/bin"
    else
        err "cannot tell where to install: HOME is not set; set FSBPYR_INSTALL_DIR"
    fi
    mkdir -p "$INSTALL_DIR" || err "cannot create $INSTALL_DIR"
    INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)" || err "cannot enter $INSTALL_DIR"
}

# Writes what `make install` does under the prefix of the install directory, with the new
# executable as the source: a failure here does not undo the install.
install_extras() {
    [ "$(basename "$INSTALL_DIR")" = bin ] || {
        say_verbose "not installing the man page and completions: $INSTALL_DIR is not a bin directory"
        return 0
    }
    share="$(dirname "$INSTALL_DIR")/share"
    put_extra "$share/man/man1/fsbpyr.1" man
    put_extra "$share/bash-completion/completions/fsbpyr" completion bash
    put_extra "$share/zsh/site-functions/_fsbpyr" completion zsh
    put_extra "$share/fish/vendor_completions.d/fsbpyr.fish" completion fish
}

put_extra() { # file, then the arguments of fsbpyr that print it
    file="$1"
    shift
    mkdir -p "$(dirname "$file")" \
        && "$INSTALL_DIR/fsbpyr" "$@" > "$file.$$.tmp" 2> /dev/null \
        && mv -f "$file.$$.tmp" "$file" \
        || { rm -f "$file.$$.tmp"; warn "could not write $file"; return 0; }
    say_verbose "  $file"
}

# --- PATH ---

# The directory as a shell file writes it: under $HOME as "$HOME/...".
dir_expression() {
    case "$INSTALL_DIR" in
        "$HOME"/*) printf '$HOME/%s' "${INSTALL_DIR#"$HOME"/}" ;;
        *) printf '%s' "$INSTALL_DIR" ;;
    esac
}

# Appends a line to a shell file unless it has it already.
add_line() { # file, line
    if [ -f "$1" ] && grep -qxF -- "$2" "$1"; then
        say_verbose "$1 has it already"
        return 0
    fi
    mkdir -p "$(dirname "$1")" || return 1
    if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then echo >> "$1"; fi
    printf '%s\n' "$2" >> "$1" || return 1
    say_verbose "added to $1"
}

write_env_files() {
    expr="$(dir_expression)"
    if [ -e "$INSTALL_DIR/env" ]; then
        say_verbose "reusing $INSTALL_DIR/env"
    else
        printf '%s\n' '#!/bin/sh' \
            '# add binaries to PATH if they are not added yet' \
            '# affix colons on either side of $PATH to simplify matching' \
            'case ":${PATH}:" in' \
            "    *:\"$expr\":*)" \
            '        ;;' \
            '    *)' \
            '        # prepended, in case a system-installed binary needs to be overridden' \
            "        export PATH=\"$expr:\$PATH\"" \
            '        ;;' \
            'esac' > "$INSTALL_DIR/env" || return 1
    fi
    if [ -e "$INSTALL_DIR/env.fish" ]; then
        say_verbose "reusing $INSTALL_DIR/env.fish"
    else
        printf '%s\n' "if not contains \"$expr\" \$PATH" \
            "    set -x PATH \"$expr\" \$PATH" \
            'end' > "$INSTALL_DIR/env.fish" || return 1
    fi
}

# Puts the install directory on PATH for new shells: an env script next to the executable,
# sourced from the shell files (the scheme uv shares with rustup). Returns 0 when it did.
modify_path() {
    case "$INSTALL_DIR" in
        *'"'* | *'$'* | *'`'* | *'\'* | *"
"*) err "cannot write shell files for $INSTALL_DIR, which has a quote, \$, backtick or backslash in it; install elsewhere or use --no-modify-path" ;;
    esac
    [ -n "${HOME:-}" ] || err "HOME is not set; use --no-modify-path"
    write_env_files || err "cannot write the env scripts in $INSTALL_DIR"
    expr="$(dir_expression)"
    line=". \"$expr/env\""
    add_line "$HOME/.profile" "$line"
    [ ! -f "$HOME/.bashrc" ] || add_line "$HOME/.bashrc" "$line"
    zshrc="${ZDOTDIR:-$HOME}/.zshrc"
    [ ! -f "$zshrc" ] || add_line "$zshrc" "$line"
    fish_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
    if [ -d "$fish_dir" ] || have fish; then
        add_line "$fish_dir/conf.d/fsbpyr.env.fish" "source \"$expr/env.fish\""
    fi
}

# In GitHub Actions the next steps of the job get the directory through $GITHUB_PATH.
add_to_path() {
    case ":${PATH}:" in
        *":$INSTALL_DIR:"*) return 0 ;;
    esac
    if [ "$NO_MODIFY_PATH" = 1 ]; then
        say "$INSTALL_DIR is not on your PATH"
        return 0
    fi
    if [ -n "${GITHUB_PATH:-}" ]; then
        printf '%s\n' "$INSTALL_DIR" >> "$GITHUB_PATH" || err "cannot write to \$GITHUB_PATH"
        say_verbose "added $INSTALL_DIR to \$GITHUB_PATH"
        return 0
    fi
    modify_path
    say ""
    say "To add $INSTALL_DIR to your PATH, either restart your shell or run:"
    say ""
    say "    source $(dir_expression)/env (sh, bash, zsh)"
    say "    source $(dir_expression)/env.fish (fish)"
}

# --- Main ---

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help) usage; exit 0 ;;
            -q | --quiet) QUIET=1 ;;
            -v | --verbose) VERBOSE=1 ;;
            --no-modify-path) NO_MODIFY_PATH=1 ;;
            --python=*) PYTHON="${1#--python=}" ;;
            --python)
                [ $# -ge 2 ] || { printf 'error: --python needs a version, such as 3.13\n\n' >&2; usage >&2; exit 1; }
                PYTHON="$2"
                shift
                ;;
            *) printf 'error: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
        esac
        shift
    done
    [ "${FSBPYR_NO_MODIFY_PATH:-}" != 1 ] || NO_MODIFY_PATH=1
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM

    detect_target
    check_target
    choose_asset
    case "$TARGET" in *-gnu) check_glibc ;; esac
    if [ "${FSBPYR_VERIFY:-}" = 1 ] && ! have gh; then
        err "FSBPYR_VERIFY=1 needs the GitHub CLI (gh) to check the attestation, and it is not installed"
    fi

    choose_install_dir
    say "downloading fsbpyr $APP_VERSION for Python $PYTHON ($TARGET)"
    fetch_executable
    say "installing to $INSTALL_DIR"
    mv -f "$STAGE" "$INSTALL_DIR/fsbpyr" || err "cannot install $INSTALL_DIR/fsbpyr"
    STAGE=
    say "  fsbpyr"
    install_extras
    add_to_path
    say "everything's installed!"
}

main "$@"
