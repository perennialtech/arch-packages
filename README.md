# arch-packages

Personal Arch Linux `PKGBUILD` recipes, published to a local pacman
repository named `[perennial]`.

## Setup

Clone the repository and change into it, since `./pkg` runs from the
checkout:

```bash
git clone https://github.com/perennialtech/arch-packages.git
cd arch-packages
```

Install the tools `./pkg` uses:

```bash
sudo pacman -S --needed base-devel devtools nvchecker pacman-contrib
```

Create the repository directory, owned by you so publishing needs no sudo:

```bash
sudo install -d -o "$USER" -g "$USER" /srv/pacman/perennial/x86_64
```

Add the repository to `/etc/pacman.conf`:

```ini
[perennial]
SigLevel = Optional TrustAll
Server = file:///srv/pacman/perennial/$arch
```

## Usage

Run `./pkg help` for all commands. Updating a package and installing it:

```bash
./pkg outdated
./pkg bump claude-desktop
./pkg build claude-desktop
./pkg publish claude-desktop
sudo pacman -Syu
```

For packaging-only changes, increment `pkgrel` by hand instead of running
`bump`.

`claude-desktop` takes its version and `.deb` checksum from Anthropic's apt
index, which `claude-desktop/update` verifies against the signing key pinned
in `claude-desktop/anthropic.asc` (fingerprint
`31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`).
