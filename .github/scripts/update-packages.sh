#!/bin/bash
# Check packages with .nvchecker.toml against upstream and open (or refresh)
# one pull request per outdated package without auto-merging.
set -euo pipefail

dry_run=0
base_branch=${BASE_BRANCH:-master}
target_package=${TARGET_PACKAGE:-}

while (( $# )); do
    case $1 in
        --dry-run)
            dry_run=1
            shift
            ;;
        --package)
            target_package=${2:?missing package name}
            shift 2
            ;;
        --base)
            base_branch=${2:?missing base branch}
            shift 2
            ;;
        *)
            printf 'Usage: %s [--dry-run] [--package NAME] [--base BRANCH]\n' "$0" >&2
            exit 1
            ;;
    esac
done

# pkgctl's terminal spinner uses tput; ensure TERM supports cursor control in
# non-interactive CI environments.
export TERM=${TERM:-xterm-256color}
if [[ $TERM == dumb ]]; then
    export TERM=xterm-256color
fi

root=$(git rev-parse --show-toplevel)
cd "$root"

packages=()
if [[ -n $target_package ]]; then
    target_package=${target_package%/}
    if [[ ! -f $target_package/PKGBUILD || ! -f $target_package/.nvchecker.toml ]]; then
        printf 'Package %s must contain both PKGBUILD and .nvchecker.toml\n' "$target_package" >&2
        exit 1
    fi
    packages=("$target_package")
else
    shopt -s nullglob
    for cfg in */.nvchecker.toml; do
        pkg=${cfg%/.nvchecker.toml}
        [[ -f $pkg/PKGBUILD ]] && packages+=("$pkg")
    done
    shopt -u nullglob
fi

if (( ${#packages[@]} == 0 )); then
    echo "No packages with .nvchecker.toml found."
    exit 0
fi

# Extract pkgver from a PKGBUILD directory using makepkg --printsrcinfo so
# computed pkgver expressions work as well as plain assignments.
read_pkgver() {
    local dir=$1
    (cd "$dir" && makepkg --printsrcinfo) |
        awk -F' = ' '!seen && $1 == "\tpkgver" { print $2; seen = 1 }'
}

# Read pkgver from a git ref without leaving changes in the working tree.
read_ref_pkgver() {
    local ref=$1 pkg=$2 tmp ver rc=0
    tmp=$(mktemp -d)
    if git archive "$ref" -- "$pkg" | tar -x -C "$tmp"; then
        ver=$(read_pkgver "$tmp/$pkg") || rc=$?
    else
        rc=$?
    fi
    rm -rf -- "$tmp"
    (( rc == 0 )) && printf '%s\n' "$ver"
    return "$rc"
}

check_json=$(pkgctl version check --json --verbose "${packages[@]}")

summary_rows=()
failures=0

while IFS=$'\t' read -r pkg status local_ver upstream_ver out_of_date message; do
    if [[ $status == warning ]]; then
        printf '::warning title=Version check warning for %s::%s\n' "$pkg" "$message"
        summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | Warning: ${message} |")
        continue
    fi

    if [[ $status != success ]]; then
        printf '::error title=Version check failed for %s::%s\n' "$pkg" "$message"
        summary_rows+=("| \`$pkg\` | \`$local_ver\` | — | Check failed: ${message} |")
        failures=1
        continue
    fi

    if [[ $out_of_date != true ]]; then
        printf '%s: up to date (%s)\n' "$pkg" "$local_ver"
        summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | Up to date |")
        continue
    fi

    printf '==> %s: %s -> %s\n' "$pkg" "$local_ver" "$upstream_ver"
    branch="update/$pkg"

    pr_number=$(gh pr list \
        --base "$base_branch" \
        --head "$branch" \
        --state open \
        --json number \
        --jq '.[0].number // empty')

    if [[ -n $pr_number ]] && git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
        pr_ver=$(read_ref_pkgver "origin/$branch" "$pkg" || true)
        if [[ $pr_ver == "$upstream_ver" ]]; then
            printf '%s: PR #%s already tracks %s; skipping\n' "$pkg" "$pr_number" "$upstream_ver"
            summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | PR #${pr_number} already open |")
            continue
        fi
    fi

    if (( dry_run )); then
        tmp_wt=$(mktemp -d)
        git worktree add --detach "$tmp_wt" "origin/$base_branch" >/dev/null
        if (cd "$tmp_wt" && ./pkg bump "$pkg") && (cd "$tmp_wt/$pkg" && makepkg --printsrcinfo >/dev/null); then
            bumped_ver=$(read_pkgver "$tmp_wt/$pkg")
            printf '[dry-run] %s: bumped %s -> %s cleanly (would push %s)\n' \
                "$pkg" "$local_ver" "$bumped_ver" "$branch"
            summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$bumped_ver\` | Dry run: ready for PR |")
        else
            printf '[dry-run] %s: bump failed (%s -> %s)\n' "$pkg" "$local_ver" "$upstream_ver" >&2
            summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | Dry run: bump failed |")
            failures=1
        fi
        git worktree remove --force "$tmp_wt" >/dev/null
        continue
    fi

    git checkout -B "$branch" "origin/$base_branch"
    git reset --hard "origin/$base_branch"
    git clean -fd -- "$pkg"

    if ! ./pkg bump "$pkg"; then
        printf '::error title=Bump failed for %s::Failed to bump %s from %s to %s\n' \
            "$pkg" "$pkg" "$local_ver" "$upstream_ver"
        git reset --hard "origin/$base_branch"
        git clean -fd -- "$pkg"
        summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | Bump failed |")
        failures=1
        continue
    fi

    if ! (cd "$pkg" && makepkg --printsrcinfo >/dev/null); then
        printf '::error title=Invalid PKGBUILD for %s::makepkg --printsrcinfo failed after bump\n' "$pkg"
        git reset --hard "origin/$base_branch"
        git clean -fd -- "$pkg"
        summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | Invalid PKGBUILD after bump |")
        failures=1
        continue
    fi

    if [[ -z $(git status --porcelain -- "$pkg") ]]; then
        printf '%s: ./pkg bump produced no changes; skipping\n' "$pkg"
        summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | No changes after bump |")
        continue
    fi

    new_ver=$(read_pkgver "$pkg")
    if [[ -n $pr_number ]] && git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
        pr_ver=$(read_ref_pkgver "origin/$branch" "$pkg" || true)
        if [[ $pr_ver == "$new_ver" ]]; then
            printf '%s: PR #%s already tracks %s; skipping\n' "$pkg" "$pr_number" "$new_ver"
            git reset --hard "origin/$base_branch"
            summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$new_ver\` | PR #${pr_number} already open |")
            continue
        fi
    fi

    git add -- "$pkg"
    git commit -m "bump $pkg to $new_ver"
    git push --force origin "HEAD:refs/heads/$branch"

    pr_title="$pkg: Update to $new_ver"
    pr_body=$(cat <<EOF
Automated package update from \`${local_ver}\` to \`${new_ver}\`.

After merging, build and install locally:

\`\`\`bash
git pull
./pkg build ${pkg}
./pkg publish ${pkg}
sudo pacman -Syu
\`\`\`
EOF
)

    if [[ -n $pr_number ]]; then
        gh pr edit "$pr_number" --title "$pr_title" --body "$pr_body"
        printf '%s: updated PR #%s to %s\n' "$pkg" "$pr_number" "$new_ver"
        summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$new_ver\` | Updated PR #${pr_number} |")
    else
        pr_url=$(gh pr create \
            --base "$base_branch" \
            --head "$branch" \
            --title "$pr_title" \
            --body "$pr_body")
        printf '%s: opened %s\n' "$pkg" "$pr_url"
        summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$new_ver\` | Opened ${pr_url} |")
    fi
done < <(
    jq -r '.[] | [
        .pkgbase,
        .status,
        (.local_version // ""),
        (.upstream_version // ""),
        (.out_of_date // false | tostring),
        (.message // "" | gsub("[\r\n\t]+"; " "))
    ] | @tsv' <<<"$check_json"
)

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo "## Package update check"
        echo ""
        echo "| Package | Local | Upstream | Result |"
        echo "| --- | --- | --- | --- |"
        printf '%s\n' "${summary_rows[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
fi

exit "$failures"
