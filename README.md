# arch-packages

Personal Arch Linux `PKGBUILD` recipes, automatically built, GPG-signed, and
published to the `[perennial]` pacman repository at
`https://arch.perennialte.ch/$arch`.

## Setup

Import and locally sign the repository signing key:

```bash
curl -fsSL https://arch.perennialte.ch/perennial.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key B7603BC4859FE9D2F4290E26CFF6600621D1EF60
```

Add `[perennial]` to `/etc/pacman.conf`:

```ini
[perennial]
SigLevel = Required DatabaseRequired
Server = https://arch.perennialte.ch/$arch
```

Sync and upgrade as usual:

```bash
yay
```

(Or `sudo pacman -Syu`.)

## Automated updates and publishing

Two GitHub Actions workflows keep `[perennial]` up to date:

1. **Update packages (`.github/workflows/update-packages.yml`)** runs every 6
   hours (and on manual `workflow_dispatch`, optionally scoped to a single
   package). It checks every package with a `.nvchecker.toml`, runs `./pkg bump`
   for outdated packages, and opens or refreshes one pull request per package on
   `update/<package>` without auto-merging.

   To guard against newly published or quickly yanked releases, the workflow
   enforces a 72-hour minimum release age before bumping a package or
   opening/updating its pull request. First-seen timestamps per `(package,
   version)` are persisted in `release-age.json` on the orphan `ci/release-age`
   branch; if upstream publishes a newer version before 72 hours elapse, the
   timer resets for the new version. Manual `workflow_dispatch` runs can set
   `ignore_release_age` to bypass the wait for urgent updates.
2. **Build and publish packages (`.github/workflows/build-and-publish.yml`)**
   runs on every push to `master` (and on manual `workflow_dispatch`). It
   compares every package's `PKGBUILD` version against the live database on
   Cloudflare R2, builds stale or missing packages in parallel inside
   `archlinux:base-devel`, GPG-signs each package and the repository database,
   uploads them to `arch.perennialte.ch`, and prunes superseded package files.
   Pull requests run a build-only check for modified packages.

Once any update PR is merged and the publish workflow finishes, running `yay`
pulls the updated package directly from `[perennial]`.

### Repository secrets

`Build and publish packages` expects these GitHub Actions repository secrets:

- `R2_ENDPOINT` — Cloudflare R2 S3 API endpoint (`https://<account-id>.r2.cloudflarestorage.com`)
- `R2_BUCKET` — R2 bucket name (`arch-packages`)
- `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` — bucket-scoped R2 API token credentials
- `REPO_GPG_PRIVATE_KEY` — armored private key matching [`keys/perennial.asc`](keys/perennial.asc)

## Local development

`./pkg` remains available for checking versions, bumping recipes, and building
or testing locally before opening a PR:

```bash
sudo pacman -S --needed base-devel devtools nvchecker pacman-contrib
./pkg help
./pkg outdated
./pkg bump <package>
./pkg build <package>
```

For packaging-only changes, increment `pkgrel` by hand instead of running
`bump`.

`claude-desktop` takes its version and `.deb` checksum from Anthropic's apt
index, which `claude-desktop/update` verifies against the signing key pinned
in `claude-desktop/anthropic.asc` (fingerprint
`31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`).
