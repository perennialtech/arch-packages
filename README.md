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

Only recipes belong in Git. Build artifacts, downloaded sources, `src/`, and `pkg/` should remain ignored.
