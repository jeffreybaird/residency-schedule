#!/usr/bin/env python3
"""Package and validate the retained, credential-free part of a Mix release."""

import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile


def allowed(name):
    parts = PurePosixPath(name).parts
    return bool(parts) and (
        parts[0] in ("bin", "lib", "releases") or parts[0].startswith("erts-")
    )


def private(name):
    parts = PurePosixPath(name).parts
    return any(part.startswith(".env") for part in parts) or name == "releases/COOKIE"


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def checked_members(archive, identity):
    members = archive.getmembers()
    seen = set()
    for member in members:
        name = member.name
        parts = PurePosixPath(name).parts
        if (
            not name or name.startswith("/") or ".." in parts
            or str(PurePosixPath(name)) != name or name in seen
            or private(name) or not (allowed(name) or name == "RELEASE_ID")
            or not (member.isdir() or member.isfile())
        ):
            raise ValueError("unsafe archive")
        seen.add(name)
    for member in members:
        for parent in PurePosixPath(member.name).parents:
            if str(parent) in seen and not archive.getmember(str(parent)).isdir():
                raise ValueError("invalid archive parent")
    marker = archive.getmember("RELEASE_ID")
    binary = archive.getmember("bin/residency_schedule")
    if not marker.isfile() or marker.size != len(identity) + 1:
        raise ValueError("invalid identity")
    if archive.extractfile(marker).read() != (identity + "\n").encode():
        raise ValueError("wrong identity")
    if not binary.isfile() or not binary.mode & 0o111:
        raise ValueError("missing executable")
    return members


def verified_tar(path, manifest, identity):
    if path.is_symlink() or manifest.is_symlink():
        raise ValueError("linked artifact")
    checksum = digest(path)
    address = re.search(r"-([0-9a-f]{64})\.tar\.gz$", path.name)
    fields = manifest.read_text().strip().split()
    if fields != [checksum, path.name] or (address and address.group(1) != checksum):
        raise ValueError("checksum mismatch")
    archive = tarfile.open(path, "r:gz")
    checked_members(archive, identity)
    return archive


def write_package(root, output, identity, snapshot=False):
    root = root.resolve(strict=True)
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if snapshot and (root / "ARTIFACT_ID").exists():
        marker = root / "ARTIFACT_ID"
        artifact_id = marker.read_text().strip()
        if marker.is_symlink() or not re.fullmatch(re.escape(identity) + r"-[0-9a-f]{64}", artifact_id):
            raise ValueError("invalid previous artifact identity")
        with verified_tar(output / (artifact_id + ".tar.gz"), output / (artifact_id + ".sha256"), identity):
            return
    name = identity if snapshot else "release-" + identity
    final = output / (name + ".tar.gz")
    manifest = output / (name + ".sha256")
    if final.exists() or manifest.exists():
        with verified_tar(final, manifest, identity):
            return
    if not snapshot and any(p.name.startswith(".env") for p in root.rglob("*")):
        raise ValueError("configuration in build")
    entries = []

    def collect(path, relative, ancestors):
        if private(relative):
            return
        target = path.resolve(strict=True)
        resolved_name = target.relative_to(root).as_posix()
        if not allowed(resolved_name) or private(resolved_name):
            raise ValueError("external or private link")
        if target.is_dir():
            if target in ancestors:
                raise ValueError("cyclic link")
            entries.append((relative, target, True))
            for child in sorted(target.iterdir()):
                collect(child, relative + "/" + child.name, ancestors | {target})
        elif target.is_file():
            entries.append((relative, target, False))
        else:
            raise ValueError("special file")

    for child in sorted(root.iterdir()):
        if allowed(child.name):
            collect(child, child.name, set())
    if not any(name == "bin/residency_schedule" and not directory for name, _, directory in entries):
        raise ValueError("missing release")
    descriptor, temporary = tempfile.mkstemp(dir=output, prefix=".pack-")
    os.close(descriptor)
    try:
        with tarfile.open(temporary, "w:gz") as archive:
            for relative, target, directory in entries:
                member = tarfile.TarInfo(relative)
                member.mode = target.stat().st_mode & 0o777
                member.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
                if directory:
                    archive.addfile(member)
                else:
                    member.size = target.stat().st_size
                    with target.open("rb") as stream:
                        archive.addfile(member, stream)
            marker = tarfile.TarInfo("RELEASE_ID")
            marker.mode = 0o644
            marker.size = len(identity) + 1
            archive.addfile(marker, io.BytesIO((identity + "\n").encode()))
        with tarfile.open(temporary) as archive:
            checked_members(archive, identity)
        if snapshot:
            artifact_id = identity + "-" + digest(Path(temporary))
            final = output / (artifact_id + ".tar.gz")
            manifest = output / (artifact_id + ".sha256")
            if final.exists() or manifest.exists():
                with verified_tar(final, manifest, identity):
                    return
        os.replace(temporary, final)
        manifest.write_text(digest(final) + "  " + final.name + "\n")
    finally:
        Path(temporary).unlink(missing_ok=True)


def stage(source, identity, destination, retained):
    path = source / ("release-" + identity + ".tar.gz")
    manifest = source / ("release-" + identity + ".sha256")
    with verified_tar(path, manifest, identity) as archive:
        # Only regular files and directories survive validation. Never extract links.
        destination.mkdir(mode=0o700)
        for member in archive.getmembers():
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as incoming, target.open("xb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
                target.chmod(member.mode & 0o777)
    retained.mkdir(parents=True, exist_ok=True, mode=0o700)
    artifact_id = identity + "-" + digest(path)
    saved = retained / (artifact_id + ".tar.gz")
    saved_manifest = retained / (artifact_id + ".sha256")
    if saved.exists() or saved_manifest.exists():
        with verified_tar(saved, saved_manifest, identity):
            if digest(saved) != digest(path):
                raise ValueError("artifact identity collision")
    else:
        shutil.copyfile(path, saved)
        saved_manifest.write_text(digest(saved) + "  " + saved.name + "\n")
    (destination / "ARTIFACT_ID").write_text(artifact_id + "\n")


def main():
    command, *arguments = sys.argv[1:]
    if command == "package":
        root, output, identity = arguments
        if not re.fullmatch(r"[0-9a-f]{40}", identity):
            raise ValueError("invalid release id")
        write_package(Path(root), Path(output), identity)
    elif command == "snapshot":
        root, output, identity = arguments
        write_package(Path(root), Path(output), identity, snapshot=True)
    elif command == "stage":
        source, identity, destination, retained = arguments
        stage(Path(source), identity, Path(destination), Path(retained))
    else:
        raise ValueError("invalid operation")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Release artifact validation or packaging failed", file=sys.stderr)
        sys.exit(1)
