#!/usr/bin/env python3
"""Determine which packages to build and which deleted packages to remove.

In push/dispatch reconciliation mode, compares every package's PKGBUILD
version against the live pacman database stored in Cloudflare R2 so rapid
consecutive merges never lose updates if an intermediate workflow run is
superseded.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def parse_srcinfo(pkg_dir: Path) -> dict[str, Any]:
    """Run makepkg --printsrcinfo in pkg_dir and parse package metadata."""
    res = subprocess.run(
        ["makepkg", "--printsrcinfo"],
        cwd=pkg_dir,
        check=True,
        capture_output=True,
        text=True,
    )
    pkgbase = ""
    pkgver = ""
    pkgrel = ""
    epoch = ""
    pkgnames: list[str] = []

    for line in res.stdout.splitlines():
        if line.startswith("pkgbase = "):
            pkgbase = line.split(" = ", 1)[1].strip()
        elif line.startswith("\tpkgver = "):
            pkgver = line.split(" = ", 1)[1].strip()
        elif line.startswith("\tpkgrel = "):
            pkgrel = line.split(" = ", 1)[1].strip()
        elif line.startswith("\tepoch = "):
            epoch = line.split(" = ", 1)[1].strip()
        elif line.startswith("pkgname = "):
            pkgnames.append(line.split(" = ", 1)[1].strip())

    if not pkgbase or not pkgver or not pkgrel or not pkgnames:
        raise RuntimeError(f"Incomplete .SRCINFO for {pkg_dir.name}")

    fullver = f"{epoch}:{pkgver}-{pkgrel}" if epoch else f"{pkgver}-{pkgrel}"
    return {
        "dir": pkg_dir.name,
        "pkgbase": pkgbase,
        "fullver": fullver,
        "pkgnames": pkgnames,
    }


def discover_repo_packages(root: Path) -> dict[str, dict[str, Any]]:
    """Return metadata for every top-level directory containing a PKGBUILD."""
    packages: dict[str, dict[str, Any]] = {}
    for entry in sorted(root.iterdir()):
        if entry.is_dir() and not entry.name.startswith(".") and (entry / "PKGBUILD").is_file():
            packages[entry.name] = parse_srcinfo(entry)
    return packages


def parse_pacman_desc(text: str) -> dict[str, str]:
    """Parse key/first-value fields from a pacman repository desc file."""
    fields: dict[str, str] = {}
    current_key: str | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            current_key = None
            continue
        if line.startswith("%") and line.endswith("%"):
            current_key = line.strip("%")
        elif current_key and current_key not in fields:
            fields[current_key] = line
    return fields


def load_published_db(arch: str, repo_name: str) -> dict[str, dict[str, str]]:
    """Download <arch>/<repo_name>.db.tar.zst from R2 and parse all entries."""
    os.environ.setdefault("AWS_REQUEST_CHECKSUM_CALCULATION", "when_required")
    os.environ.setdefault("AWS_RESPONSE_CHECKSUM_VALIDATION", "when_required")

    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError

    endpoint = os.environ["R2_ENDPOINT"]
    bucket = os.environ["R2_BUCKET"]
    access_key = os.environ["R2_ACCESS_KEY_ID"]
    secret_key = os.environ["R2_SECRET_ACCESS_KEY"]

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
        config=Config(signature_version="s3v4"),
    )

    key = f"{arch}/{repo_name}.db.tar.zst"
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / f"{repo_name}.db.tar.zst"
        extract_dir = Path(tmp) / "db"
        extract_dir.mkdir()
        try:
            s3.download_file(bucket, key, str(db_path))
        except ClientError as exc:
            code = str(exc.response.get("Error", {}).get("Code", ""))
            status = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            if code in {"404", "NoSuchKey", "NotFound"} or status == 404:
                print(f"Remote database {key} does not exist yet; treating repo as empty.")
                return {}
            raise

        subprocess.run(
            ["tar", "-xf", str(db_path), "-C", str(extract_dir)],
            check=True,
        )

        published: dict[str, dict[str, str]] = {}
        for desc_path in sorted(extract_dir.glob("*/desc")):
            fields = parse_pacman_desc(desc_path.read_text(encoding="utf-8", errors="replace"))
            name = fields.get("NAME")
            if name:
                published[name] = {
                    "base": fields.get("BASE", name),
                    "version": fields.get("VERSION", ""),
                    "filename": fields.get("FILENAME", ""),
                }
        return published


def detect_pr_packages(root: Path, base_ref: str, head_ref: str, repo_pkgs: dict[str, dict[str, Any]]) -> list[str]:
    """Return package directories touched by the pull request diff."""
    res = subprocess.run(
        ["git", "diff", "--name-only", f"{base_ref}...{head_ref}"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    changed_dirs: set[str] = set()
    for rel in res.stdout.splitlines():
        rel = rel.strip()
        if not rel or "/" not in rel:
            continue
        top = rel.split("/", 1)[0]
        if top in repo_pkgs:
            changed_dirs.add(top)
    return sorted(changed_dirs)


def reconcile_against_r2(
    repo_pkgs: dict[str, dict[str, Any]],
    published: dict[str, dict[str, str]],
) -> tuple[list[str], list[str]]:
    """Return (packages_to_build, removed_pkgnames) by diffing repo vs R2 DB."""
    to_build: list[str] = []
    for pkg_dir, info in sorted(repo_pkgs.items()):
        needs_build = False
        for pkgname in info["pkgnames"]:
            pub = published.get(pkgname)
            if not pub or pub["version"] != info["fullver"]:
                cur_ver = pub["version"] if pub else "<missing>"
                print(f"Stale/missing {pkg_dir} ({pkgname}): published={cur_ver}, repo={info['fullver']}")
                needs_build = True
                break
        if needs_build:
            to_build.append(pkg_dir)

    repo_bases = {info["pkgbase"] for info in repo_pkgs.values()}
    removed = sorted(
        name
        for name, meta in published.items()
        if meta.get("base", name) not in repo_bases
    )
    if removed:
        print(f"Removed packages to drop from DB: {', '.join(removed)}")
    return to_build, removed


def write_github_outputs(packages: list[str], removed: list[str]) -> None:
    out_path = os.environ.get("GITHUB_OUTPUT")
    pairs = {
        "packages": json.dumps(packages),
        "has_packages": "true" if packages else "false",
        "removed_pkgnames": json.dumps(removed),
        "has_removed": "true" if removed else "false",
    }
    for k, v in pairs.items():
        print(f"{k}={v}")
    if out_path:
        with open(out_path, "a", encoding="utf-8") as fh:
            for k, v in pairs.items():
                fh.write(f"{k}={v}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["push", "pr", "dispatch"], required=True)
    parser.add_argument("--packages", default="", help="Comma/space-separated package names or 'all'")
    parser.add_argument("--force", action="store_true", help="Force rebuild for dispatch mode")
    parser.add_argument("--base-ref", default="origin/master")
    parser.add_argument("--head-ref", default="HEAD")
    parser.add_argument("--arch", default="x86_64")
    parser.add_argument("--repo-name", default="perennial")
    args = parser.parse_args()

    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    )
    repo_pkgs = discover_repo_packages(root)

    packages_to_build: list[str] = []
    removed_pkgnames: list[str] = []

    if args.mode == "pr":
        packages_to_build = detect_pr_packages(root, args.base_ref, args.head_ref, repo_pkgs)
    elif args.mode == "dispatch":
        raw = args.packages.strip()
        if raw.lower() == "all":
            packages_to_build = sorted(repo_pkgs.keys())
            published = load_published_db(args.arch, args.repo_name)
            _, removed_pkgnames = reconcile_against_r2(repo_pkgs, published)
        elif raw:
            requested = [p.strip("/") for p in re.split(r"[\s,]+", raw) if p.strip()]
            unknown = [p for p in requested if p not in repo_pkgs]
            if unknown:
                print(f"Unknown package(s): {', '.join(unknown)}", file=sys.stderr)
                return 1
            packages_to_build = sorted(dict.fromkeys(requested))
        else:
            published = load_published_db(args.arch, args.repo_name)
            if args.force:
                packages_to_build = sorted(repo_pkgs.keys())
                _, removed_pkgnames = reconcile_against_r2(repo_pkgs, published)
            else:
                packages_to_build, removed_pkgnames = reconcile_against_r2(repo_pkgs, published)
    else:
        published = load_published_db(args.arch, args.repo_name)
        packages_to_build, removed_pkgnames = reconcile_against_r2(repo_pkgs, published)

    write_github_outputs(packages_to_build, removed_pkgnames)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
