#!/bin/bash
# Check packages with .nvchecker.toml against upstream and open (or refresh)
# one pull request per outdated package without auto-merging.
#
# Enforces a minimum release age (default 72h) measured from when CI first
# observes each (package, upstream_version) pair. State is stored in
# release-age.json on an orphan git branch (default: ci/release-age) using git
# plumbing so it never touches the working tree or master history.
set -euo pipefail

dry_run=0
base_branch=${BASE_BRANCH:-master}
target_package=${TARGET_PACKAGE:-}
min_release_age=${MIN_RELEASE_AGE:-72h}
ignore_release_age=${IGNORE_RELEASE_AGE:-0}
state_branch=${STATE_BRANCH:-ci/release-age}
state_file=release-age.json
now_epoch=${NOW_EPOCH:-}

usage() {
    printf 'Usage: %s [--dry-run] [--package NAME] [--base BRANCH] [--min-release-age DURATION] [--ignore-release-age] [--state-branch BRANCH] [--now EPOCH]\n' "$0" >&2
}

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
        --min-release-age)
            min_release_age=${2:?missing duration}
            shift 2
            ;;
        --ignore-release-age)
            ignore_release_age=1
            shift
            ;;
        --state-branch)
            state_branch=${2:?missing state branch}
            shift 2
            ;;
        --now)
            now_epoch=${2:?missing epoch timestamp}
            shift 2
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

case ${ignore_release_age,,} in
    "" | 0 | false) ignore_release_age=0 ;;
    1 | true) ignore_release_age=1 ;;
    *)
        printf 'Invalid IGNORE_RELEASE_AGE value: %s (expected 0/1 or false/true)\n' "$ignore_release_age" >&2
        exit 1
        ;;
esac

parse_duration_seconds() {
    local spec=$1 num unit
    if [[ $spec == 0 ]]; then
        printf '0\n'
        return 0
    fi
    if [[ $spec =~ ^([0-9]+)([smhd])$ ]]; then
        num=$((10#${BASH_REMATCH[1]}))
        unit=${BASH_REMATCH[2]}
        case $unit in
            s) printf '%s\n' "$num" ;;
            m) printf '%s\n' "$((num * 60))" ;;
            h) printf '%s\n' "$((num * 3600))" ;;
            d) printf '%s\n' "$((num * 86400))" ;;
        esac
        return 0
    fi
    printf 'Invalid duration %q (expected 0 or <N><s|m|h|d>, e.g. 72h)\n' "$spec" >&2
    return 1
}

format_duration() {
    local secs=$1 hours mins
    if (( secs < 0 )); then
        secs=0
    fi
    if (( secs < 60 )); then
        printf '%ss\n' "$secs"
        return 0
    fi
    if (( secs < 3600 )); then
        printf '%sm\n' "$((secs / 60))"
        return 0
    fi
    hours=$((secs / 3600))
    mins=$(((secs % 3600) / 60))
    if (( mins == 0 )); then
        printf '%sh\n' "$hours"
    else
        printf '%sh %sm\n' "$hours" "$mins"
    fi
}

epoch_to_iso() {
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

epoch_to_display() {
    date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'
}

iso_to_epoch() {
    local ts=$1
    [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    date -u -d "$ts" +%s 2>/dev/null
}

min_release_age_seconds=$(parse_duration_seconds "$min_release_age")
min_release_age_display=$(format_duration "$min_release_age_seconds")

if [[ -n $now_epoch ]]; then
    if [[ ! $now_epoch =~ ^[0-9]+$ ]]; then
        printf 'Invalid --now / NOW_EPOCH value: %s (expected Unix epoch seconds)\n' "$now_epoch" >&2
        exit 1
    fi
else
    now_epoch=$(date -u +%s)
fi
now_iso=$(epoch_to_iso "$now_epoch")

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

empty_state=$(jq -S -n '{packages: {}}')
state_parent=""
state_corrupted=0
initial_state=$empty_state
state_json=$empty_state

load_release_age_state() {
    local ls_rc=0 raw_state=""
    set +e
    git ls-remote --exit-code --heads origin "$state_branch" >/dev/null 2>&1
    ls_rc=$?
    set -e

    if (( ls_rc == 0 )); then
        git fetch --no-tags --quiet origin "+refs/heads/$state_branch:refs/remotes/origin/$state_branch"
        state_parent=$(git rev-parse "refs/remotes/origin/$state_branch")
        raw_state=$(git show "$state_parent:$state_file" 2>/dev/null || true)
        if [[ -n $raw_state ]] && jq -e 'type == "object" and (.packages | type == "object")' <<<"$raw_state" >/dev/null 2>&1; then
            initial_state=$(jq -S '{packages: .packages}' <<<"$raw_state")
            state_json=$initial_state
        else
            printf '::warning title=Invalid release-age state::Resetting unreadable %s on %s\n' "$state_file" "$state_branch"
            state_corrupted=1
        fi
    elif (( ls_rc != 2 )); then
        printf '::error title=Failed to query state branch::git ls-remote failed for %s (exit %s)\n' "$state_branch" "$ls_rc"
        exit 1
    fi
}

state_get_version() {
    jq -r --arg pkg "$1" '.packages[$pkg].version // empty' <<<"$state_json"
}

state_get_first_seen() {
    jq -r --arg pkg "$1" '.packages[$pkg].first_seen // empty' <<<"$state_json"
}

state_set() {
    state_json=$(jq -S \
        --arg pkg "$1" \
        --arg ver "$2" \
        --arg seen "$3" \
        '.packages[$pkg] = {version: $ver, first_seen: $seen}' <<<"$state_json")
}

state_delete() {
    state_json=$(jq -S --arg pkg "$1" 'del(.packages[$pkg])' <<<"$state_json")
}

state_prune_missing_packages() {
    local known_json
    known_json=$(printf '%s\n' "${packages[@]}" | jq -R . | jq -s .)
    state_json=$(jq -S --argjson known "$known_json" \
        '.packages |= with_entries(select(.key as $k | $known | index($k) != null))' <<<"$state_json")
}

save_release_age_state() {
    local blob tree commit
    if (( state_corrupted == 0 )) && [[ $state_json == "$initial_state" ]]; then
        return 0
    fi
    if [[ -z $state_parent && $state_json == "$empty_state" ]]; then
        return 0
    fi
    if (( dry_run )); then
        printf '[dry-run] Would update %s on %s\n' "$state_file" "$state_branch"
        return 0
    fi

    blob=$(printf '%s\n' "$state_json" | git hash-object -w --stdin)
    tree=$(printf '100644 blob %s\t%s\n' "$blob" "$state_file" | git mktree)
    if [[ -n $state_parent ]]; then
        commit=$(git commit-tree "$tree" -p "$state_parent" -m "Update release-age state")
    else
        commit=$(git commit-tree "$tree" -m "Initialize release-age state")
    fi
    git push origin "$commit:refs/heads/$state_branch"
}

if (( min_release_age_seconds > 0 )); then
    load_release_age_state
fi

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
        if (( min_release_age_seconds > 0 )); then
            state_delete "$pkg"
        fi
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
    pr_ver=""

    if [[ -n $pr_number ]] && git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
        pr_ver=$(read_ref_pkgver "origin/$branch" "$pkg" || true)
        if [[ $pr_ver == "$upstream_ver" ]]; then
            printf '%s: PR #%s already tracks %s; skipping\n' "$pkg" "$pr_number" "$upstream_ver"
            if (( min_release_age_seconds > 0 )); then
                tracked_ver=$(state_get_version "$pkg")
                if [[ -n $tracked_ver && $tracked_ver != "$upstream_ver" ]]; then
                    state_delete "$pkg"
                fi
            fi
            summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | PR #${pr_number} already open |")
            continue
        fi
    fi

    age_note=""
    if (( min_release_age_seconds > 0 )); then
        tracked_ver=$(state_get_version "$pkg")
        first_seen=$(state_get_first_seen "$pkg")
        first_seen_epoch=""
        if [[ $tracked_ver == "$upstream_ver" && -n $first_seen ]]; then
            first_seen_epoch=$(iso_to_epoch "$first_seen" || true)
        fi
        if [[ -z $first_seen_epoch ]]; then
            first_seen=$now_iso
            first_seen_epoch=$now_epoch
            state_set "$pkg" "$upstream_ver" "$first_seen"
        fi

        age_seconds=$((now_epoch - first_seen_epoch))
        ready_epoch=$((first_seen_epoch + min_release_age_seconds))
        age_display=$(format_duration "$age_seconds")
        first_seen_display=$(epoch_to_display "$first_seen_epoch")
        ready_display=$(epoch_to_display "$ready_epoch")

        if (( age_seconds < min_release_age_seconds )); then
            if (( ignore_release_age == 0 )); then
                printf '%s: deferring %s (first seen %s; age %s / %s; ready after %s)\n' \
                    "$pkg" "$upstream_ver" "$first_seen" "$age_display" "$min_release_age_display" "$ready_display"
                if [[ -n $pr_number && -n $pr_ver ]]; then
                    summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | Deferred (${age_display} / ${min_release_age_display}; ready ${ready_display}; PR #${pr_number} stays on \`${pr_ver}\`) |")
                else
                    summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$upstream_ver\` | Deferred (${age_display} / ${min_release_age_display}; ready ${ready_display}) |")
                fi
                continue
            fi
            age_note="Minimum release age (\`${min_release_age_display}\`) was bypassed via manual trigger (first observed ${first_seen_display}, age ${age_display})."
        else
            age_note="First observed by CI on ${first_seen_display} (met \`${min_release_age_display}\` minimum release age)."
        fi
    fi

    if (( dry_run )); then
        tmp_wt=$(mktemp -d)
        git worktree add --detach "$tmp_wt" "origin/$base_branch" >/dev/null
        if (cd "$tmp_wt" && ./pkg bump "$pkg") && (cd "$tmp_wt/$pkg" && makepkg --printsrcinfo >/dev/null); then
            bumped_ver=$(read_pkgver "$tmp_wt/$pkg")
            if (( min_release_age_seconds > 0 && ignore_release_age == 0 )) && [[ $bumped_ver != "$upstream_ver" ]]; then
                state_set "$pkg" "$bumped_ver" "$now_iso"
                ready_display=$(epoch_to_display "$((now_epoch + min_release_age_seconds))")
                printf '[dry-run] %s: upstream changed to %s during bump; would defer until %s\n' \
                    "$pkg" "$bumped_ver" "$ready_display"
                summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$bumped_ver\` | Dry run: deferred (0s / ${min_release_age_display}; ready ${ready_display}) |")
            else
                printf '[dry-run] %s: bumped %s -> %s cleanly (would push %s)\n' \
                    "$pkg" "$local_ver" "$bumped_ver" "$branch"
                summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$bumped_ver\` | Dry run: ready for PR |")
            fi
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
    if (( min_release_age_seconds > 0 && ignore_release_age == 0 )) && [[ $new_ver != "$upstream_ver" ]]; then
        printf '%s: upstream moved from %s to %s during bump; deferring %s\n' \
            "$pkg" "$upstream_ver" "$new_ver" "$new_ver"
        git reset --hard "origin/$base_branch"
        git clean -fd -- "$pkg"
        state_set "$pkg" "$new_ver" "$now_iso"
        ready_display=$(epoch_to_display "$((now_epoch + min_release_age_seconds))")
        if [[ -n $pr_number && -n $pr_ver ]]; then
            summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$new_ver\` | Deferred (0s / ${min_release_age_display}; ready ${ready_display}; PR #${pr_number} stays on \`${pr_ver}\`) |")
        else
            summary_rows+=("| \`$pkg\` | \`$local_ver\` | \`$new_ver\` | Deferred (0s / ${min_release_age_display}; ready ${ready_display}) |")
        fi
        continue
    fi

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
    pr_body="Automated package update from \`${local_ver}\` to \`${new_ver}\`."
    if [[ -n $age_note ]]; then
        pr_body+=$'\n\n'"${age_note}"
    fi
    pr_body+=$(cat <<EOF


Merging this PR automatically builds, signs, and publishes \`${pkg}\` to \`[perennial]\`. Once the publish workflow finishes, update with:

\`\`\`bash
yay
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

if (( min_release_age_seconds > 0 )); then
    if [[ -z $target_package ]]; then
        state_prune_missing_packages
    fi
    if ! save_release_age_state; then
        printf '::error title=Failed to persist release-age state::Could not push %s to %s\n' "$state_file" "$state_branch"
        failures=1
    fi
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo "## Package update check"
        echo ""
        if (( min_release_age_seconds == 0 )); then
            echo "Minimum release age: disabled"
        elif (( ignore_release_age )); then
            echo "Minimum release age: \`${min_release_age_display}\` (bypassed)"
        else
            echo "Minimum release age: \`${min_release_age_display}\`"
        fi
        echo ""
        echo "| Package | Local | Upstream | Result |"
        echo "| --- | --- | --- | --- |"
        printf '%s\n' "${summary_rows[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
fi

exit "$failures"
