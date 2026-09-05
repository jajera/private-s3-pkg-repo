"""S3 package-repo index rebuild Lambda.

Triggered by EventBridge on Object Created for package blobs only:
  repos/rpm/al2023/x86_64/**/*.rpm
  repos/deb/ubuntu/noble/pool/**/*.deb

Builds indexes (createrepo_c / apt-ftparchive), signs repo metadata with the
lab GPG key from Secrets Manager, writes indexes back, and refreshes
catalog.json plus the public key.

Env:
  PACKAGE_BUCKET   private package bucket (primary)
  UI_BUCKET        public catalog UI bucket
  GPG_SECRET_ARN   Secrets Manager ARN holding the armored private key
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import boto3

RPM_TREE = "repos/rpm/al2023/x86_64"
DEB_TREE = "repos/deb/ubuntu/noble"
PUBKEY_PKG_KEY = "repos/gpg/lab-signing.asc"
PUBKEY_UI_KEY = "gpg/lab-signing.asc"


def _env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise RuntimeError(f"missing required env {name}")
    return v


def _run(cmd: list[str], cwd: str | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.check_call(cmd, cwd=cwd)


def _sync_prefix(s3, bucket: str, prefix: str, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents") or []:
            key = obj["Key"]
            if key.endswith("/"):
                continue
            rel = key[len(prefix) :] if key.startswith(prefix) else Path(key).name
            local = dest / rel
            local.parent.mkdir(parents=True, exist_ok=True)
            s3.download_file(bucket, key, str(local))


def _upload_tree(s3, bucket: str, local_root: Path, key_prefix: str) -> None:
    for path in local_root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(local_root).as_posix()
        key = f"{key_prefix.rstrip('/')}/{rel}"
        extra: dict[str, str] = {}
        if path.suffix == ".gz" or path.name.endswith(".gz"):
            extra["ContentType"] = "application/gzip"
        elif path.suffix == ".xml" or path.name == "repomd.xml":
            extra["ContentType"] = "application/xml"
        elif path.suffix == ".asc" or path.name.endswith(".gpg"):
            extra["ContentType"] = "application/pgp-signature"
        elif path.name in {"Packages", "Release", "InRelease"}:
            extra["ContentType"] = "text/plain"
        kwargs: dict[str, Any] = {}
        if extra:
            kwargs["ExtraArgs"] = extra
        s3.upload_file(str(path), bucket, key, **kwargs)


def _build_catalog(stage: Path) -> dict[str, Any]:
    packages: list[dict[str, Any]] = []
    repos = stage / "repos"
    if repos.is_dir():
        for path in repos.rglob("*"):
            if not path.is_file():
                continue
            if path.suffix not in {".rpm", ".deb"}:
                continue
            rel = path.relative_to(stage).as_posix()
            fmt = "rpm" if path.suffix == ".rpm" else "deb"
            name = path.name
            if fmt == "deb":
                pkg_name = name.split("_", 1)[0]
                arch = "amd64"
            else:
                pkg_name = name.rsplit("-", 2)[0] if name.count("-") >= 2 else name
                arch = "x86_64"
            packages.append(
                {
                    "name": pkg_name,
                    "file": path.name,
                    "format": fmt,
                    "arch": arch,
                    "key": rel,
                    "size": path.stat().st_size,
                }
            )
    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "packages": sorted(packages, key=lambda p: (p["format"], p["name"], p["file"])),
    }


def _import_signing_key(secret_arn: str) -> str:
    """Import private key into a fresh GNUPGHOME; return the home path."""
    sm = boto3.client("secretsmanager")
    priv = sm.get_secret_value(SecretId=secret_arn)["SecretString"]
    gnupg = tempfile.mkdtemp(prefix="gnupg-")
    os.chmod(gnupg, 0o700)
    os.environ["GNUPGHOME"] = gnupg
    subprocess.run(
        ["gpg", "--batch", "--import"],
        input=priv.encode("utf-8"),
        check=True,
        capture_output=True,
    )
    # Prefer the first secret key for signing.
    subprocess.check_call(
        ["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", "--list-secret-keys"],
    )
    return gnupg


def _export_public_key() -> bytes:
    return subprocess.check_output(["gpg", "--batch", "--armor", "--export"])


def _publish_pubkey(s3, package_bucket: str, ui_bucket: str, pubkey: bytes) -> None:
    for bucket, key in (
        (package_bucket, PUBKEY_PKG_KEY),
        (ui_bucket, PUBKEY_UI_KEY),
    ):
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=pubkey,
            ContentType="application/pgp-keys",
        )
        print(f"published pubkey s3://{bucket}/{key}", flush=True)


def _sign_file_detach(path: Path) -> Path:
    asc = path.with_suffix(path.suffix + ".asc")
    if path.name == "repomd.xml":
        asc = path.parent / "repomd.xml.asc"
    if asc.exists():
        asc.unlink()
    _run(
        [
            "gpg",
            "--batch",
            "--yes",
            "--pinentry-mode",
            "loopback",
            "--detach-sign",
            "--armor",
            "-o",
            str(asc),
            str(path),
        ]
    )
    return asc


def _sign_release(release: Path) -> None:
    inrelease = release.parent / "InRelease"
    release_gpg = release.parent / "Release.gpg"
    for p in (inrelease, release_gpg):
        if p.exists():
            p.unlink()
    _run(
        [
            "gpg",
            "--batch",
            "--yes",
            "--pinentry-mode",
            "loopback",
            "--clearsign",
            "-o",
            str(inrelease),
            str(release),
        ]
    )
    _run(
        [
            "gpg",
            "--batch",
            "--yes",
            "--pinentry-mode",
            "loopback",
            "--detach-sign",
            "--armor",
            "-o",
            str(release_gpg),
            str(release),
        ]
    )


def rebuild() -> dict[str, Any]:
    package_bucket = _env("PACKAGE_BUCKET")
    ui_bucket = _env("UI_BUCKET")
    secret_arn = _env("GPG_SECRET_ARN")
    s3 = boto3.client("s3")
    catalog: dict[str, Any] = {"generated_at": None, "packages": []}
    signed = False
    gnupg: str | None = None

    try:
        gnupg = _import_signing_key(secret_arn)
        pubkey = _export_public_key()
        if not pubkey.strip():
            raise RuntimeError("gpg export produced empty public key")
        _publish_pubkey(s3, package_bucket, ui_bucket, pubkey)

        with tempfile.TemporaryDirectory(prefix="rebuild-") as tmp:
            stage = Path(tmp)
            rpm_local = stage / RPM_TREE
            deb_local = stage / DEB_TREE
            rpm_local.mkdir(parents=True, exist_ok=True)
            deb_local.mkdir(parents=True, exist_ok=True)

            _sync_prefix(s3, package_bucket, f"{RPM_TREE}/", rpm_local)
            _sync_prefix(s3, package_bucket, f"{DEB_TREE}/", deb_local)

            pkgs_dir = rpm_local / "Packages"
            pkgs_dir.mkdir(parents=True, exist_ok=True)
            if any(pkgs_dir.glob("*.rpm")):
                try:
                    _run(["createrepo_c", "--update", str(rpm_local)])
                except subprocess.CalledProcessError:
                    _run(["createrepo_c", str(rpm_local)])
                repodata = rpm_local / "repodata"
                repomd = repodata / "repomd.xml"
                if repomd.is_file():
                    _sign_file_detach(repomd)
                    signed = True
                if repodata.is_dir():
                    _upload_tree(s3, package_bucket, repodata, f"{RPM_TREE}/repodata")

            pool = deb_local / "pool"
            dist_bin = deb_local / "dists" / "noble" / "main" / "binary-amd64"
            dist_bin.mkdir(parents=True, exist_ok=True)
            if pool.is_dir() and any(pool.rglob("*.deb")):
                packages_file = dist_bin / "Packages"
                with packages_file.open("w", encoding="utf-8") as out:
                    subprocess.check_call(
                        ["apt-ftparchive", "packages", "pool"],
                        cwd=str(deb_local),
                        stdout=out,
                    )
                gz_path = dist_bin / "Packages.gz"
                with gz_path.open("wb") as gz_out:
                    subprocess.check_call(["gzip", "-9c", str(packages_file)], stdout=gz_out)
                release = deb_local / "dists" / "noble" / "Release"
                with release.open("w", encoding="utf-8") as out:
                    subprocess.check_call(
                        [
                            "apt-ftparchive",
                            "-o",
                            "APT::FTPArchive::Release::Origin=private-s3-pkg-repo",
                            "-o",
                            "APT::FTPArchive::Release::Label=lab",
                            "-o",
                            "APT::FTPArchive::Release::Suite=noble",
                            "-o",
                            "APT::FTPArchive::Release::Codename=noble",
                            "-o",
                            "APT::FTPArchive::Release::Architectures=amd64",
                            "-o",
                            "APT::FTPArchive::Release::Components=main",
                            "release",
                            "dists/noble",
                        ],
                        cwd=str(deb_local),
                        stdout=out,
                    )
                _sign_release(release)
                signed = True
                _upload_tree(s3, package_bucket, deb_local / "dists", f"{DEB_TREE}/dists")

            catalog = _build_catalog(stage)
            s3.put_object(
                Bucket=ui_bucket,
                Key="catalog.json",
                Body=json.dumps(catalog, indent=2).encode("utf-8"),
                ContentType="application/json",
            )
    finally:
        if gnupg and os.path.isdir(gnupg):
            shutil.rmtree(gnupg, ignore_errors=True)
            os.environ.pop("GNUPGHOME", None)

    return {
        "ok": True,
        "packages": len(catalog["packages"]),
        "signed": signed,
    }


def _is_package_key(key: str) -> bool:
    if "/Packages/" in key and key.endswith(".rpm"):
        return True
    if "/pool/" in key and key.endswith(".deb"):
        return True
    return False


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    print("event:", json.dumps(event)[:2000], flush=True)
    detail = event.get("detail") or {}
    obj = (detail.get("object") or {}) if isinstance(detail, dict) else {}
    key = obj.get("key") or ""
    # Empty key = manual/ops invoke → always rebuild.
    if key and not _is_package_key(key):
        print("skip non-package key", key, flush=True)
        return {"ok": True, "skipped": True}
    result = rebuild()
    print("result:", result, flush=True)
    return result
