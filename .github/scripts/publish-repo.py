#!/usr/bin/env python3
"""GPG-sign built Arch packages, update the pacman repo DB, and publish to R2.

Upload order prevents broken client syncs during publishing:
  1. Upload new .pkg.tar.zst and .pkg.tar.zst.sig files.
  2. Upload updated .db/.files tarballs, copies, and signatures (no-cache).
  3. Upload the repository public key (<repo>.asc).
  4. Prune old .pkg.tar.zst/.sig files no longer referenced by the database.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run(cmd: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


def get_secret_key_fingerprint() -> str:
    res = run(["gpg", "--batch", "--list-secret-keys", "--with-colons"])
    for line in res.stdout.splitlines():
        parts = line.split(":")
        if parts[0] == "fpr" and len(parts) > 9 and parts[9]:
            return parts[9]
    raise RuntimeError("No GPG secret key found in GNUPGHOME")


def get_pubkey_file_fingerprint(pubkey_path: Path) -> str:
    res = run(["gpg", "--batch", "--show-keys", "--with-colons", str(pubkey_path)])
    for line in res.stdout.splitlines():
        parts = line.split(":")
        if parts[0] == "fpr" and len(parts) > 9 and parts[9]:
            return parts[9]
    raise RuntimeError(f"No GPG public key found in {pubkey_path}")


def read_pkginfo(pkg_path: Path) -> tuple[str, str, str]:
    """Return (pkgname, pkgbase, pkgver) from a built .pkg.tar.zst archive."""
    res = run(["tar", "-xOf", str(pkg_path), ".PKGINFO"])
    pkgname = ""
    pkgbase = ""
    pkgver = ""
    for line in res.stdout.splitlines():
        if line.startswith("pkgname = "):
            pkgname = line.split(" = ", 1)[1].strip()
        elif line.startswith("pkgbase = "):
            pkgbase = line.split(" = ", 1)[1].strip()
        elif line.startswith("pkgver = "):
            pkgver = line.split(" = ", 1)[1].strip()
    if not pkgname:
        raise RuntimeError(f"Could not read pkgname from {pkg_path.name}")
    return pkgname, (pkgbase or pkgname), pkgver


def parse_pacman_desc(text: str) -> dict[str, str]:
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


def read_db_entries(db_path: Path) -> dict[str, dict[str, str]]:
    if not db_path.is_file():
        return {}
    with tempfile.TemporaryDirectory() as tmp:
        extract_dir = Path(tmp)
        run(["tar", "-xf", str(db_path), "-C", str(extract_dir)])
        entries: dict[str, dict[str, str]] = {}
        for desc_path in sorted(extract_dir.glob("*/desc")):
            fields = parse_pacman_desc(desc_path.read_text(encoding="utf-8", errors="replace"))
            name = fields.get("NAME")
            if name:
                entries[name] = {
                    "base": fields.get("BASE", name),
                    "version": fields.get("VERSION", ""),
                    "filename": fields.get("FILENAME", ""),
                }
        return entries


def sign_and_verify(target: Path, fpr: str) -> Path:
    sig_path = Path(f"{target}.sig")
    run(
        [
            "gpg",
            "--batch",
            "--yes",
            "--detach-sign",
            "--no-armor",
            "--local-user",
            fpr,
            "--output",
            str(sig_path),
            str(target),
        ]
    )
    run(["gpg", "--batch", "--verify", str(sig_path), str(target)])
    return sig_path


def make_s3_client():
    os.environ.setdefault("AWS_REQUEST_CHECKSUM_CALCULATION", "when_required")
    os.environ.setdefault("AWS_RESPONSE_CHECKSUM_VALIDATION", "when_required")

    import boto3
    from botocore.config import Config

    return boto3.client(
        "s3",
        endpoint_url=os.environ["R2_ENDPOINT"],
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto",
        config=Config(signature_version="s3v4"),
    )


def download_if_exists(s3, bucket: str, key: str, dest: Path) -> bool:
    from botocore.exceptions import ClientError

    try:
        s3.download_file(bucket, key, str(dest))
        return True
    except ClientError as exc:
        code = str(exc.response.get("Error", {}).get("Code", ""))
        status = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if code in {"404", "NoSuchKey", "NotFound"} or status == 404:
            return False
        raise


def list_r2_keys(s3, bucket: str, prefix: str) -> list[str]:
    keys: list[str] = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            keys.append(obj["Key"])
    return keys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages-dir", type=Path, help="Directory containing built .pkg.tar.zst files")
    parser.add_argument("--remove", nargs="*", default=[], help="Package names to remove from the repo DB")
    parser.add_argument("--pubkey", type=Path, required=True, help="Path to repository public GPG key")
    parser.add_argument("--arch", default="x86_64")
    parser.add_argument("--repo-name", default="perennial")
    args = parser.parse_args()

    fpr = get_secret_key_fingerprint()
    pubkey_fpr = get_pubkey_file_fingerprint(args.pubkey)
    if fpr != pubkey_fpr:
        raise RuntimeError(
            f"Secret key fingerprint ({fpr}) does not match {args.pubkey} ({pubkey_fpr})"
        )
    print(f"Using GPG signing key {fpr}")

    new_pkgs: list[Path] = []
    if args.packages_dir and args.packages_dir.is_dir():
        new_pkgs = sorted(
            p for p in args.packages_dir.rglob("*.pkg.tar.zst") if p.is_file()
        )

    explicit_removals = [name for name in args.remove if name]
    if not new_pkgs and not explicit_removals:
        print("Nothing to publish or remove.")
        return 0

    bucket = os.environ["R2_BUCKET"]
    s3 = make_s3_client()
    prefix = f"{args.arch}/"

    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        db_tar = stage / f"{args.repo_name}.db.tar.zst"
        files_tar = stage / f"{args.repo_name}.files.tar.zst"

        has_db = download_if_exists(s3, bucket, f"{prefix}{db_tar.name}", db_tar)
        download_if_exists(s3, bucket, f"{prefix}{files_tar.name}", files_tar)
        if not has_db:
            print("No existing remote database found; initializing a new repository.")

        staged_pkgs: list[Path] = []
        built_by_base: dict[str, set[str]] = {}
        published_summary: list[tuple[str, str, str]] = []

        for src_pkg in new_pkgs:
            dest_pkg = stage / src_pkg.name
            shutil.copy2(src_pkg, dest_pkg)
            sign_and_verify(dest_pkg, fpr)
            pkgname, pkgbase, pkgver = read_pkginfo(dest_pkg)
            built_by_base.setdefault(pkgbase, set()).add(pkgname)
            staged_pkgs.append(dest_pkg)
            published_summary.append((pkgname, pkgver, dest_pkg.name))
            print(f"Signed {dest_pkg.name}")

        if staged_pkgs:
            cmd = [
                "repo-add",
                "--sign",
                "--include-sigs",
                "--key",
                fpr,
                "--remove",
                str(db_tar),
                *(str(p) for p in staged_pkgs),
            ]
            res = subprocess.run(cmd, cwd=stage, check=True, text=True)
            _ = res

        # Also remove any orphaned split/debug packages left over from rebuilt pkgbases
        # (for example, if a PKGBUILD enabled !debug in a new release).
        current_entries = read_db_entries(db_tar)
        orphaned = [
            name
            for name, meta in current_entries.items()
            if meta["base"] in built_by_base and name not in built_by_base[meta["base"]]
        ]
        all_removals = sorted(
            name for name in set(explicit_removals) | set(orphaned) if name in current_entries
        )

        if all_removals and db_tar.is_file():
            print(f"Removing from database: {', '.join(all_removals)}")
            subprocess.run(
                [
                    "repo-remove",
                    "--sign",
                    "--key",
                    fpr,
                    str(db_tar),
                    *all_removals,
                ],
                cwd=stage,
                check=True,
                text=True,
            )

        if not db_tar.is_file() or not files_tar.is_file():
            raise RuntimeError("Repository database files were not created")

        # Verify database signatures produced by repo-add/repo-remove.
        db_sig = Path(f"{db_tar}.sig")
        files_sig = Path(f"{files_tar}.sig")
        run(["gpg", "--batch", "--verify", str(db_sig), str(db_tar)])
        run(["gpg", "--batch", "--verify", str(files_sig), str(files_tar)])

        # Pacman fetches <repo>.db/.files (no .tar.zst suffix); R2 has no symlinks,
        # so materialize plain copies alongside the .tar.zst archives.
        db_copies = [
            (db_tar, f"{args.repo_name}.db.tar.zst", "application/zstd"),
            (db_sig, f"{args.repo_name}.db.tar.zst.sig", "application/pgp-signature"),
            (db_tar, f"{args.repo_name}.db", "application/zstd"),
            (db_sig, f"{args.repo_name}.db.sig", "application/pgp-signature"),
            (files_tar, f"{args.repo_name}.files.tar.zst", "application/zstd"),
            (files_sig, f"{args.repo_name}.files.tar.zst.sig", "application/pgp-signature"),
            (files_tar, f"{args.repo_name}.files", "application/zstd"),
            (files_sig, f"{args.repo_name}.files.sig", "application/pgp-signature"),
        ]

        # Step 1: Upload new packages and their signatures first.
        for pkg in staged_pkgs:
            pkg_sig = Path(f"{pkg}.sig")
            print(f"Uploading {prefix}{pkg.name}")
            s3.upload_file(
                str(pkg),
                bucket,
                f"{prefix}{pkg.name}",
                ExtraArgs={
                    "CacheControl": "public, max-age=3600",
                    "ContentType": "application/zstd",
                },
            )
            s3.upload_file(
                str(pkg_sig),
                bucket,
                f"{prefix}{pkg_sig.name}",
                ExtraArgs={
                    "CacheControl": "public, max-age=3600",
                    "ContentType": "application/pgp-signature",
                },
            )

        # Step 2: Upload database and files indexes with no-cache headers.
        for src, remote_name, content_type in db_copies:
            print(f"Uploading {prefix}{remote_name}")
            s3.upload_file(
                str(src),
                bucket,
                f"{prefix}{remote_name}",
                ExtraArgs={
                    "CacheControl": "no-cache, no-store, max-age=0",
                    "ContentType": content_type,
                },
            )

        # Step 3: Upload the repository public signing key at bucket root.
        pub_key_name = f"{args.repo_name}.asc"
        print(f"Uploading {pub_key_name}")
        s3.upload_file(
            str(args.pubkey),
            bucket,
            pub_key_name,
            ExtraArgs={
                "CacheControl": "public, max-age=3600",
                "ContentType": "application/pgp-keys",
            },
        )

        # Step 4: Prune package files in R2 no longer referenced by the DB.
        final_entries = read_db_entries(db_tar)
        live_names = {remote_name for _, remote_name, _ in db_copies}
        for meta in final_entries.values():
            fname = meta.get("filename")
            if fname:
                live_names.add(fname)
                live_names.add(f"{fname}.sig")

        stale_keys = [
            key
            for key in list_r2_keys(s3, bucket, prefix)
            if (key.endswith(".pkg.tar.zst") or key.endswith(".pkg.tar.zst.sig"))
            and key[len(prefix) :] not in live_names
        ]
        for key in stale_keys:
            print(f"Pruning stale object {key}")
            s3.delete_object(Bucket=bucket, Key=key)

        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            lines = [
                f"## Published `[{args.repo_name}]` ({args.arch})",
                "",
            ]
            if published_summary:
                lines.extend(
                    [
                        "| Package | Version | File |",
                        "| --- | --- | --- |",
                        *(f"| `{n}` | `{v}` | `{f}` |" for n, v, f in published_summary),
                        "",
                    ]
                )
            if all_removals:
                lines.append(f"Removed from database: {', '.join(f'`{n}`' for n in all_removals)}")
                lines.append("")
            if stale_keys:
                lines.append(f"Pruned {len(stale_keys)} superseded file(s) from R2.")
                lines.append("")
            lines.append(f"Active packages in `[{args.repo_name}]`: **{len(final_entries)}**")
            with open(summary_path, "a", encoding="utf-8") as fh:
                fh.write("\n".join(lines) + "\n")

        print(f"Publish complete. Active packages in [{args.repo_name}]: {len(final_entries)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
