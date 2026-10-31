# version-files.sh — sourced by prepare.sh and release.sh: fsbpyr's version, which lives in three
# files that must agree: pyproject.toml's [project] version, src/fsbpyr/__init__.py's
# __version__ and fsbpyr's own entry in uv.lock.

VERSION_FILES=(pyproject.toml src/fsbpyr/__init__.py uv.lock)
XYZ='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# version_selector FILE: an awk fragment that sets `hit` on FILE's version line.
# pyproject.toml: [project]'s (tomllib's ["project"]["version"], what the tag check in
# build.yml compares the tag with), not another table's `version` key. uv.lock: the
# line in fsbpyr's own [[package]] block. prepare.sh bumps the same lines.
version_selector() {
    case "$1" in
        pyproject.toml)
            echo '/^\[/ { s = ($0 ~ /^\[project\][[:space:]]*$/) } { hit = s && /^version[[:space:]]*=/ }' ;;
        src/fsbpyr/__init__.py)
            echo '{ hit = /^__version__[[:space:]]*=/ }' ;;
        uv.lock)
            echo '/^\[\[package\]\]/ { s = 0 } /^name = "fsbpyr"$/ { s = 1 } { hit = s && /^version[[:space:]]*=/ }' ;;
    esac
}

# `|| true` keeps a failed read from tripping `set -e`/pipefail before the explicit
# emptiness check below can emit a friendly diagnostic.
read_version() {
    awk "$(version_selector "$1")"' hit { print; exit }' "$1" 2>/dev/null | cut -d'"' -f2 || true
}

# current_version: prints the version the three files agree on; fails, saying why, if they
# do not or one cannot be read.
current_version() {
    local f v version=""
    for f in "${VERSION_FILES[@]}"; do
        v="$(read_version "$f")"
        [ -n "$v" ] || { echo "ERROR: cannot read version from $f" >&2; return 1; }
        if [ -z "$version" ]; then
            version="$v"
        elif [ "$v" != "$version" ]; then
            echo "ERROR: $f has version $v, ${VERSION_FILES[0]} has $version; make them agree" >&2
            return 1
        fi
    done
    echo "$version"
}
