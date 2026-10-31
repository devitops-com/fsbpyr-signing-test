#!/usr/bin/env bash
#
# release-signing.sh — fsbpyr's release keys and the signature of a release's SHA256SUMS, made
# and checked with the openssl command alone (docs/signing.md). release-sign.sh signs with it on
# the admin's machine, so no fsbpyr is near the release key, and checks the new signature with it
# against the keys the previous release and this one pin; `make release-audit` and `make
# release-check` check with it; the admin makes the release keys with it.
#
#     bash tools/release/release-signing.sh new-key NAME         NAME.key and NAME.pub
#     bash tools/release/release-signing.sh sign KEY FILE        FILE.sig, signed as fsbpyr
#     bash tools/release/release-signing.sh verify FILE PUB...   FILE.sig against any PUB; a PUB
#                                                                that is not a .pub is skipped
#
# The files, as fsbpyr's `key new`, `sign` and `verify` write and read them (docs/signing.md §2):
#   NAME.key  two encrypted PKCS#8 PEM blocks under one passphrase, Ed25519 then ML-DSA-65;
#   NAME.pub  the two public keys as PEM, in the same order, and nothing else; its fingerprint
#             is SHA256: and the SHA-256 of the file;
#   FILE.sig  the Ed25519 signature (64 bytes), then the ML-DSA-65 one (3309 bytes), both over
#             the statement "fsbpyr-signature 1\nsubject fsbpyr\nsha256 <FILE's SHA-256>\n".
#
# The passphrase comes from FSBPYR_SIGNING_PASSPHRASE, or is asked for on the terminal, as typed
# (spaces too), 1 to 1024 bytes. Nothing that exists is replaced. Needs OpenSSL 3.5 or newer and
# sha256sum. Exit status: 0 done or VERIFIED, 1 NOT VERIFIED, 2 anything else (usage, setup, a
# failed step).
set -Eeuo pipefail
trap 'exit 2' ERR  # a failed step is never 1, which says NOT VERIFIED
umask 077
export LC_ALL=C
export OPENSSL_CONF=/dev/null  # a config can choose the ML-DSA key's format, and shrink the .key

SUBJECT=fsbpyr
ALGORITHMS=(ED25519 ML-DSA-65)
SIG_SIZES=(64 3309)
MAX_PASSPHRASE=1024

die() { printf '%s\n' "$2" >&2; exit "$1"; }
warn() { printf '%s\n' "$1" >&2; }

usage() {
    cat >&2 <<'EOF'
usage: release-signing.sh new-key NAME
       release-signing.sh sign KEY FILE
       release-signing.sh verify FILE PUB...
EOF
    exit 2
}

need_tools() {
    command -v sha256sum >/dev/null || die 2 'sha256sum is missing: install coreutils'
    command -v openssl >/dev/null || die 2 'openssl is missing: OpenSSL 3.5 or newer is needed'
    local listed algorithm
    listed=$(openssl list -signature-algorithms 2>/dev/null) || die 2 'openssl cannot list its signature algorithms'
    for algorithm in "${ALGORITHMS[@]}"; do
        grep -qw -- "$algorithm" <<<"$listed" ||
            die 2 "$(openssl version) has no $algorithm: OpenSSL 3.5 or newer is needed"
    done
}

# passphrase new|old: FSBPYR_SIGNING_PASSPHRASE, or asked for on the terminal (twice for a new key).
passphrase() {
    if [[ -z "${FSBPYR_SIGNING_PASSPHRASE-}" ]]; then
        { : </dev/tty; } 2>/dev/null || die 2 'no passphrase: set FSBPYR_SIGNING_PASSPHRASE or run this on a terminal'
        local again
        IFS= read -rsp 'Passphrase: ' FSBPYR_SIGNING_PASSPHRASE </dev/tty; echo >&2
        if [[ "$1" == new ]]; then
            IFS= read -rsp 'Passphrase again: ' again </dev/tty; echo >&2
            [[ "$again" == "$FSBPYR_SIGNING_PASSPHRASE" ]] || die 2 'the passphrases differ'
        fi
    fi
    [[ -n "$FSBPYR_SIGNING_PASSPHRASE" ]] || die 2 'the passphrase is empty'
    # OpenSSL's PEM reader takes no longer one, and says so only as a failure to read the key
    ((${#FSBPYR_SIGNING_PASSPHRASE} <= MAX_PASSPHRASE)) || die 2 "the passphrase is longer than $MAX_PASSPHRASE bytes"
    export FSBPYR_SIGNING_PASSPHRASE
}

fingerprint() { local digest; digest=$(sha256sum <"$1"); printf 'SHA256:%s\n' "${digest%% *}"; }

# split_pem FILE FIRST REST: FILE's first PEM block, and what follows it.
split_pem() {
    sed -n '1,/^-----END /p' "$1" >"$2"
    sed '1,/^-----END /d' "$1" >"$3"
}

# check_key KEY: exactly two encrypted blocks, each ending in an LF, with nothing before or between
# them and only LFs after them; the last LF may be missing, as a key copied through a secret may
# lose it. openssl's reader would take text around a block, and a block that is not encrypted.
check_key() {
    [[ "$(tr -d '\000\r' <"$1" | wc -c)" == "$(wc -c <"$1")" ]] || return 1
    awk -v begin='-----BEGIN ENCRYPTED PRIVATE KEY-----' -v end='-----END ENCRYPTED PRIVATE KEY-----' '
        state == 4 { if ($0 != "") bad = 1; next }
        state == 0 || state == 2 { if ($0 != begin) bad = 1; state++; next }
        $0 == end { state++; next }
        !/^[A-Za-z0-9+\/=]+$/ { bad = 1 }
        END { exit bad || state != 4 }
    ' "$1"
}

# check_public PUB DIR: PUB holds exactly the two public keys, Ed25519 then ML-DSA-65, as openssl
# writes them; otherwise it says why and fails. DIR is scratch space.
check_public() {
    local pub=$1 dir=$2 i
    [[ -f "$pub" && -r "$pub" ]] || { warn "cannot read the public key $pub"; return 1; }
    split_pem "$pub" "$dir/p.0" "$dir/p.1" || return 1
    : >"$dir/canonical"
    for i in 0 1; do
        [[ "$(openssl pkey -pubin -in "$dir/p.$i" -text_pub -noout 2>/dev/null | sed -n 1p)" == "${ALGORITHMS[i]} Public-Key:" ]] ||
            { warn "$pub: key $((i + 1)) is not an ${ALGORITHMS[i]} public key"; return 1; }
        openssl pkey -pubin -in "$dir/p.$i" -pubout >>"$dir/canonical" || return 1
    done
    [[ "$(sha256sum <"$dir/canonical")" == "$(sha256sum <"$pub")" ]] ||
        { warn "$pub holds more than the two public keys"; return 1; }
}

# statement FILE OUT: the statement that both signatures sign.
statement() {
    local digest
    digest=$(sha256sum <"$1") || die 2 "cannot read $1"
    printf 'fsbpyr-signature 1\nsubject %s\nsha256 %s\n' "$SUBJECT" "${digest%% *}" >"$2"
}

# verify_with STATEMENT SIG PUB DIR: both signatures in SIG are good for the two keys in PUB.
verify_with() {
    local i
    split_pem "$3" "$4/v.0" "$4/v.1"
    head -c "${SIG_SIZES[0]}" "$2" >"$4/vs.0"
    tail -c "${SIG_SIZES[1]}" "$2" >"$4/vs.1"
    for i in 0 1; do
        openssl pkeyutl -verify -rawin -pubin -inkey "$4/v.$i" -in "$1" -sigfile "$4/vs.$i" >/dev/null 2>&1 ||
            return 1
    done
}

# place TMP FINAL MODE: TMP gets the name FINAL, which must not exist. -T: a directory that appears
# there is refused, and the file does not go inside it.
place() {
    [[ ! -e "$2" && ! -L "$2" ]] || { warn "$2 exists; nothing replaced"; return 1; }
    chmod "$3" "$1"
    ln -T -- "$1" "$2" || { warn "cannot write $2"; return 1; }
}

new_key() {
    local name=$1 file i
    for file in "$name.key" "$name.pub"; do
        [[ ! -e "$file" && ! -L "$file" ]] || die 2 "$file exists; nothing replaced"
    done
    passphrase new
    tmp=$(mktemp -d "$(dirname -- "$name")/.release-signing.XXXXXXXX") || die 2 "cannot write beside $name"
    : >"$tmp/key"
    : >"$tmp/pub"
    for i in 0 1; do
        # Generated into a pipe, so the unencrypted key is never written to disk.
        openssl genpkey -algorithm "${ALGORITHMS[i]}" |
            openssl pkcs8 -topk8 -v2 aes-256-cbc -v2prf hmacWithSHA256 -iter 600000 \
                -passout env:FSBPYR_SIGNING_PASSPHRASE -out "$tmp/k.$i"
        openssl pkey -in "$tmp/k.$i" -passin env:FSBPYR_SIGNING_PASSPHRASE -pubout >>"$tmp/pub"
        cat "$tmp/k.$i" >>"$tmp/key"
    done
    check_public "$tmp/pub" "$tmp" || exit 2
    place "$tmp/key" "$name.key" 600 || exit 2
    place "$tmp/pub" "$name.pub" 644 || { rm -f -- "$name.key"; exit 2; }
    printf 'wrote %s (keep it secret) and %s\nfingerprint %s\n' "$name.key" "$name.pub" "$(fingerprint "$name.pub")"
}

sign() {
    local key=$1 file=$2 sig=$2.sig i
    [[ -f "$key" && -r "$key" ]] || die 2 "cannot read the key $key"
    [[ -f "$file" && -r "$file" ]] || die 2 "cannot read $file"
    [[ ! -e "$sig" && ! -L "$sig" ]] || die 2 "$sig exists; nothing replaced"
    check_key "$key" || die 2 "$key does not hold two encrypted keys and nothing else"
    passphrase old
    tmp=$(mktemp -d "$(dirname -- "$sig")/.release-signing.XXXXXXXX") || die 2 "cannot write beside $file"
    statement "$file" "$tmp/statement"
    split_pem "$key" "$tmp/k.0" "$tmp/k.1"
    : >"$tmp/pub"
    for i in 0 1; do
        # the label says encrypted, and only this can tell: a plain key ignores any passphrase
        openssl asn1parse -in "$tmp/k.$i" 2>/dev/null | grep ':PBES2' >/dev/null ||
            die 2 "$key does not hold two encrypted keys and nothing else"
        openssl pkey -in "$tmp/k.$i" -passin env:FSBPYR_SIGNING_PASSPHRASE -pubout >>"$tmp/pub" 2>/dev/null ||
            die 2 "cannot open $key: wrong passphrase?"
        openssl pkeyutl -sign -rawin -inkey "$tmp/k.$i" -passin env:FSBPYR_SIGNING_PASSPHRASE \
            -in "$tmp/statement" -out "$tmp/s.$i"
    done
    check_public "$tmp/pub" "$tmp" || exit 2
    cat "$tmp/s.0" "$tmp/s.1" >"$tmp/sig"
    verify_with "$tmp/statement" "$tmp/sig" "$tmp/pub" "$tmp" ||
        die 2 'the new signature does not verify; nothing written'
    place "$tmp/sig" "$sig" 644 || exit 2
    printf 'signed %s as %s with key %s\nwrote %s\n' "$file" "$SUBJECT" "$(fingerprint "$tmp/pub")" "$sig"
}

verify() {
    local file=$1 sig=$1.sig pub size usable=0
    shift
    [[ -f "$file" && -r "$file" ]] || die 2 "cannot read $file"
    [[ -f "$sig" && -r "$sig" ]] || die 1 "NOT VERIFIED: $file: no $sig"
    size=$(wc -c <"$sig")
    ((size == SIG_SIZES[0] + SIG_SIZES[1])) ||
        die 1 "NOT VERIFIED: $file: $sig has $((size)) bytes, not the $((SIG_SIZES[0] + SIG_SIZES[1])) of a signature"
    tmp=$(mktemp -d) || die 2 'cannot make a temporary directory'
    statement "$file" "$tmp/statement"
    for pub in "$@"; do
        check_public "$pub" "$tmp" || continue  # said why; the others may still match
        usable=1
        if verify_with "$tmp/statement" "$sig" "$pub" "$tmp"; then
            printf 'VERIFIED  %s  (project %s, Ed25519 + ML-DSA-65, key %s %s)\n' "$file" "$SUBJECT" "$pub" "$(fingerprint "$pub")"
            return 0
        fi
    done
    ((usable)) || die 2 "no usable public key among $*"
    die 1 "NOT VERIFIED: $file: $sig does not match $*"
}

tmp=
trap '[[ -z "$tmp" ]] || rm -rf -- "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Paths, none of which may read as an option of the tools below.
command=${1-}
arguments=()
for argument in "${@:2}"; do
    [[ "$argument" != -* ]] || argument=./$argument
    arguments+=("$argument")
done
set -- "${arguments[@]}"

case "$command:$#" in
    new-key:1) need_tools; new_key "$1" ;;
    sign:2) need_tools; sign "$1" "$2" ;;
    verify:*) (($# >= 2)) || usage; need_tools; verify "$@" ;;
    *) usage ;;
esac
