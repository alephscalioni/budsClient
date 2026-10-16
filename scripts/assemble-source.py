#!/usr/bin/env python3
"""Assemble the pinned macOS host. No app, signing or device operations."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".build/workspace/GalaxyBudsClient"
STAMP = ".buds-assembly.json"
PROJECTS = {"GalaxyBudsClient", "GalaxyBudsClient.Platform", "GalaxyBudsClient.Platform.OSX",
            "GalaxyBudsClient.Generators", "GalaxyBudsClient.Tests"}
GENERATED = {".git", ".build", ".swiftpm", "dist", "bin", "obj", "Build", "xcuserdata", "__pycache__"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    records = {}
    for directory, folders, files in os.walk(root):
        folders[:] = sorted(name for name in folders if name not in GENERATED)
        for name in folders + sorted(files):
            path = Path(directory) / name
            relative = path.relative_to(root)
            if name in {STAMP, ".DS_Store"} or path.suffix == ".pyc":
                continue
            # Fody creates an editor schema beside the project during publish;
            # it is not a compiled input or an export source file.
            if relative.as_posix() == "GalaxyBudsClient/FodyWeavers.xsd":
                continue
            if path.is_symlink():
                raise ValueError("Unexpected source symlink: " + str(relative))
            if path.is_file():
                records[relative.as_posix()] = digest(path)
    return records


def dependency(root=ROOT):
    value = json.loads((root / "dependency.json").read_text())
    pin = "754b6fdfb1c151b022cece775c8aaad4eb185afa"
    if (value.get("commit") != pin
            or value.get("repository") != "https://github.com/timschneeb/GalaxyBudsClient"
            or value.get("archiveURL") != "https://codeload.github.com/timschneeb/GalaxyBudsClient/tar.gz/" + pin
            or value.get("sha256") != "c9e303467c804c42f01c5fb492180ed7d895df751c789f78f780ac3967e44ceb"):
        raise ValueError("Unexpected upstream dependency; review and pin it explicitly.")
    return value


def verify_archive(path, lock):
    if digest(path) != lock["sha256"]:
        raise ValueError("Pinned upstream archive checksum mismatch.")


def fetch(root, lock):
    path = root / ".build" / ("GalaxyBudsClient-" + lock["commit"] + ".tar.gz")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        fd, temporary = tempfile.mkstemp(prefix=".upstream-", dir=path.parent)
        os.close(fd)
        temporary = Path(temporary)
        try:
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--retry", "2",
                            "--proto", "=https", "--proto-redir", "=https",
                            "--silent", "--show-error", lock["archiveURL"], "--output", str(temporary)], check=True)
            verify_archive(temporary, lock)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    verify_archive(path, lock)
    return path


def extract(archive, destination, commit):
    prefix = "GalaxyBudsClient-" + commit
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            parts = PurePosixPath(member.name).parts
            if not parts or parts[0] != prefix or ".." in parts or member.name.startswith("/"):
                raise ValueError("Unsafe upstream archive path: " + member.name)
            relative = PurePosixPath(*parts[1:])
            if not relative.parts:
                continue
            if relative.parts[0] not in PROJECTS and str(relative) not in {"LICENSE", "global.json"}:
                continue
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError("Unexpected upstream link or special file: " + member.name)
            path = destination / str(relative)
            path.parent.mkdir(parents=True, exist_ok=True)
            with bundle.extractfile(member) as source, path.open("wb") as output:
                shutil.copyfileobj(source, output)
            path.chmod(member.mode & 0o777)


def copy_tree(source, destination):
    for relative in inventory(source):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, target)


def apply_host_patch(patch, destination):
    # A fetched workspace is nested below this export's Git repository. Without
    # this boundary, git apply silently skips its paths as outside the prefix.
    environment = {key: value for key, value in os.environ.items()
                   if key not in {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"}}
    environment["GIT_CEILING_DIRECTORIES"] = str(destination.parent.resolve())
    for arguments in (["--check"], []):
        subprocess.run(["/usr/bin/git", "apply", *arguments, "--whitespace=nowarn", str(patch)],
                       cwd=destination, env=environment, check=True)


def validate_workspace(root=ROOT, source=None):
    root = root.resolve()
    expected_source = root / ".build/workspace/GalaxyBudsClient"
    source = expected_source if source is None else Path(source)
    if source.is_symlink() or source.resolve() != expected_source or not source.is_dir():
        raise ValueError("Expected the clean export's generated source workspace.")
    record = json.loads((source / STAMP).read_text())
    if record.get("dependency") != dependency(root) or record.get("inputs") != inventory(root):
        raise ValueError("Export inputs changed; reassemble and rebuild before publishing.")
    if record.get("sources") != inventory(source):
        raise ValueError("Generated source changed; reassemble and rebuild before publishing.")
    return source


def assemble(root=ROOT):
    root = root.resolve()
    lock = dependency(root)
    inputs = inventory(root)
    source = root / ".build/workspace/GalaxyBudsClient"
    if source.exists() or source.is_symlink():
        if source.is_symlink() or not source.is_dir() or not (source / STAMP).is_file():
            raise ValueError("Refusing to replace an unowned source workspace.")
        try:
            return validate_workspace(root, source)
        except ValueError:
            pass
    archive = fetch(root, lock)
    source.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".assembly-", dir=source.parent) as temporary:
        staged = Path(temporary) / "source"
        staged.mkdir()
        extract(archive, staged, lock["commit"])
        patch = root / "patches/managed-host.patch"
        apply_host_patch(patch, staged)
        for relative in inventory(root / "overlays"):
            if (staged / relative).exists():
                raise ValueError("Added overlay would replace upstream source: " + relative)
        copy_tree(root / "overlays", staged)
        copy_tree(root / "macOSAutoSwitch", staged / "macOSAutoSwitch")
        copy_tree(root / "config", staged / "config")
        for name in ("build-buds-macos.sh", "fetch-sparkle.sh"):
            target = staged / "scripts" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / "scripts/internal" / name, target)
        shutil.copy2(root / "scripts/configure-updates.py", staged / "scripts/configure-updates.py")
        shutil.copy2(root / "global.json", staged / "global.json")
        record = {"dependency": lock, "inputs": inputs, "sources": inventory(staged)}
        (staged / STAMP).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        if inventory(root) != inputs:
            raise ValueError("Export inputs changed during assembly; retry after edits settle.")
        if source.exists():
            shutil.rmtree(source)
        staged.rename(source)
    return validate_workspace(root, source)


if __name__ == "__main__":
    print(assemble())
