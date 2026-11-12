# arch-packages

Personal Arch Linux `PKGBUILD` recipes and local binary packages.

## Build a package

```bash
cd qdirstat
makepkg --syncdeps --cleanbuild
```

## Publish to the local repository

```sh
publish() {
    local repo=/srv/pacman/perennial/x86_64
    local package destination
    local -a packages installed

    packages=("${(@f)$(makepkg --packagelist)}")

    if (( ${#packages[@]} == 0 )); then
        print -u2 "No package files reported by makepkg"
        return 1
    fi

    for package in "${packages[@]}"; do
        if [[ ! -f "$package" ]]; then
            print -u2 "Package file does not exist: $package"
            return 1
        fi

        destination="$repo/${package:t}"
        sudo install -Dm644 -- "$package" "$destination" || return 1
        installed+=("$destination")
    done

    sudo repo-add -R "$repo/perennial.db.tar.zst" "${installed[@]}"
}

publish
```

Configure `/etc/pacman.conf` once:

```ini
[perennial]
SigLevel = Optional TrustAll
Server = file:///srv/pacman/perennial/$arch
```

Refresh and install through `yay`:

```bash
yay -Syu perennial/qdirstat
```

## Update a package

Change `pkgver` and reset `pkgrel=1`, or increment `pkgrel` for packaging-only changes. Update checksums and republish:

```bash
cd qdirstat
updpkgsums
makepkg --syncdeps --cleanbuild
```

For `claude-desktop`, check the new `.deb` checksum against Anthropic's signed apt index before republishing. `anthropic.asc` is the pinned signing key (fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`). The commands print the expected SHA-256 of the `.deb` for `pkgver` only if the signature and index checks pass, and it must match what `updpkgsums` wrote:

```bash
cd claude-desktop
base=https://downloads.claude.ai/claude-desktop/apt/stable
pkgver=$(source PKGBUILD && echo "$pkgver")
curl -fsSO "$base/dists/stable/InRelease"
curl -fsSO "$base/dists/stable/main/binary-amd64/Packages"
gpg --dearmor < anthropic.asc > anthropic.gpg
gpgv --keyring ./anthropic.gpg InRelease &&
grep -q " $(sha256sum < Packages | cut -d' ' -f1) .*main/binary-amd64/Packages$" InRelease &&
awk -v v="$pkgver" '$1 == "Version:" { m = $2 == v } m && $1 == "SHA256:" { print $2 }' Packages
```

Only recipes belong in Git. Build artifacts, downloaded sources, `src/`, and `pkg/` should remain ignored.
