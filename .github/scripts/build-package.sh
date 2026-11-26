#!/bin/bash
# Build a single package in an isolated build directory and place the built
# .pkg.tar.zst artifact(s) into the requested output directory.
set -euo pipefail

if (( $# != 2 )); then
    printf 'Usage: %s <package> <output-dir>\n' "$0" >&2
    exit 1
fi

pkg=${1%/}
out_dir=$2

root=$(git rev-parse --show-toplevel)
pkg_dir="$root/$pkg"
[[ -f $pkg_dir/PKGBUILD ]] || {
    printf 'No PKGBUILD found in %s\n' "$pkg_dir" >&2
    exit 1
}

mkdir -p "$out_dir"
out_dir=$(cd -- "$out_dir" && pwd)

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export SRCDEST="$work/sources"
export BUILDDIR="$work/build"
export PKGDEST="$out_dir"
export MAKEFLAGS="${MAKEFLAGS:---jobs=$(nproc)}"
export PACKAGER="perennial Arch Repository <packages@perennialte.ch>"

mkdir -p "$SRCDEST" "$BUILDDIR"

# Import any vendored upstream PGP keys in <pkg>/keys/pgp/*.asc.
shopt -s nullglob
for keyfile in "$pkg_dir"/keys/pgp/*.asc; do
    printf '==> Importing vendored PGP key %s\n' "${keyfile##*/}"
    gpg --batch --import "$keyfile"
done
shopt -u nullglob

# Fetch any remaining validpgpkeys referenced in PKGBUILD if not already present.
mapfile -t pgpkeys < <(
    cd "$pkg_dir" &&
        makepkg --printsrcinfo |
        sed -nE 's/^\tvalidpgpkeys = //p'
)
for key in "${pgpkeys[@]}"; do
    [[ -n $key ]] || continue
    if ! gpg --batch --list-keys "$key" >/dev/null 2>&1; then
        printf '==> Fetching upstream PGP key %s\n' "$key"
        gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key" ||
            gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$key"
    fi
done

printf '==> Building %s\n' "$pkg"
(
    cd "$pkg_dir"
    makepkg --syncdeps --rmdeps --cleanbuild --noconfirm
)

mapfile -t expected < <(cd "$pkg_dir" && makepkg --packagelist)
if (( ${#expected[@]} == 0 )); then
    printf 'makepkg --packagelist returned no packages for %s\n' "$pkg" >&2
    exit 1
fi

shopt -s nullglob
built=("$out_dir"/*.pkg.tar.zst)
shopt -u nullglob
if (( ${#built[@]} == 0 )); then
    printf 'No .pkg.tar.zst artifacts produced for %s\n' "$pkg" >&2
    exit 1
fi

# Verify every non-debug package listed by makepkg exists; -debug packages are
# omitted by makepkg when a package contains no unstripped ELF binaries.
for f in "${expected[@]}"; do
    base=${f##*/}
    if [[ $base == *-debug-[0-9]* ]]; then
        continue
    fi
    [[ -f $f ]] || {
        printf 'Expected package artifact missing: %s\n' "$f" >&2
        exit 1
    }
done

printf '==> Built packages for %s:\n' "$pkg"
ls -lh "${built[@]}"
