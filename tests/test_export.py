"""Offline checks; never invoke a packager, signer, app or hardware API."""
from pathlib import Path
import copy
import hashlib
import importlib.util
import io
import json
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


assembly = module("assembly", "scripts/assemble-source.py")
release = module("release", "scripts/prepare-release.py")


class AssemblyTests(unittest.TestCase):
    def test_host_patch_is_applied_inside_new_git_repository(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["/usr/bin/git", "init", "-q", str(root)], check=True)
            source = root / ".build/workspace/staging"
            source.mkdir(parents=True)
            (source / "host.txt").write_text("original\n")
            patch_file = root / "host.patch"
            patch_file.write_text("diff --git a/host.txt b/host.txt\n"
                                  "--- a/host.txt\n+++ b/host.txt\n"
                                  "@@ -1 +1 @@\n-original\n+ours\n")
            assembly.apply_host_patch(patch_file, source)
            self.assertEqual((source / "host.txt").read_text(), "ours\n")

    def test_corrupt_cached_dependency_fails_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "archive.tar.gz"
            path.write_bytes(b"untrusted archive")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                assembly.verify_archive(path, assembly.dependency())

    def test_archive_rejects_traversal_and_source_symlinks(self):
        prefix = "GalaxyBudsClient-" + assembly.dependency()["commit"]
        for relative, link in [("../escape", False), ("GalaxyBudsClient/escape.cs", True)]:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "archive.tar.gz"
                with tarfile.open(archive, "w:gz") as bundle:
                    entry = tarfile.TarInfo(prefix + "/" + relative)
                    if link:
                        entry.type = tarfile.SYMTYPE
                        entry.linkname = "/outside"
                        bundle.addfile(entry)
                    else:
                        entry.size = 1
                        bundle.addfile(entry, io.BytesIO(b"x"))
                with self.assertRaises(ValueError):
                    assembly.extract(archive, root / "source", assembly.dependency()["commit"])
                self.assertFalse((root / "escape").exists())

    def fixture(self, root):
        (root / "dependency.json").write_bytes((ROOT / "dependency.json").read_bytes())
        (root / "source.swift").write_text("original\n")
        source = root / ".build/workspace/GalaxyBudsClient"
        source.mkdir(parents=True)
        (source / "compiled.swift").write_text("compiled\n")
        record = {"dependency": assembly.dependency(root), "inputs": assembly.inventory(root),
                  "sources": assembly.inventory(source)}
        (source / assembly.STAMP).write_text(json.dumps(record))
        return source

    def test_validation_rejects_export_drift_generated_drift_and_injected_source(self):
        for kind in ["export", "generated", "injected"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = self.fixture(root)
                self.assertEqual(assembly.validate_workspace(root), source.resolve())
                # Compilers may write ignored outputs without changing source provenance.
                (source / "obj").mkdir()
                (source / "obj/generated.cs").write_text("generated")
                (source / "GalaxyBudsClient").mkdir()
                (source / "GalaxyBudsClient/FodyWeavers.xsd").write_text("generated editor schema")
                self.assertEqual(assembly.validate_workspace(root), source.resolve())
                if kind == "export":
                    (root / "source.swift").write_text("edited")
                elif kind == "generated":
                    (source / "compiled.swift").write_text("edited")
                else:
                    (source / "injected.cs").write_text("injected")
                with self.assertRaisesRegex(ValueError, "changed"):
                    assembly.validate_workspace(root)

    def test_cannot_replace_unowned_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "dependency.json").write_bytes((ROOT / "dependency.json").read_bytes())
            source = root / ".build/workspace/GalaxyBudsClient"
            source.mkdir(parents=True)
            protected = source / "keep.txt"
            protected.write_text("keep")
            with self.assertRaisesRegex(ValueError, "unowned"):
                assembly.assemble(root)
            self.assertEqual(protected.read_text(), "keep")


class ReleaseValidationTests(unittest.TestCase):
    def fixture(self, root):
        path = root / "compiled.swift"
        path.write_text("compiled input\n")
        fingerprint = hashlib.sha256(path.read_bytes()).hexdigest()
        info = {"BudsBuildConfiguration": "Release", "BudsBuildIdentifier": "build"}
        metadata = {"configuration": "Release", "native_library_configuration": "Release",
                    "native_library_defines": ["BUDS_EMBEDDED"], "build_id": "build",
                    "sources": [{"path": "compiled.swift", "sha256": fingerprint}],
                    "managed_build_inputs": {}, "native_library_compiled_inputs": []}
        return info, metadata

    def test_rejects_debug_stale_hash_conflicting_hash_and_path_escape(self):
        for kind in ["debug", "stale", "conflict", "escape"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                info, metadata = self.fixture(root)
                release.validate_build(info, metadata, root)
                bad = copy.deepcopy(metadata)
                if kind == "debug":
                    bad["native_library_defines"].append("DEBUG")
                elif kind == "stale":
                    (root / "compiled.swift").write_text("new source")
                elif kind == "conflict":
                    bad["managed_build_inputs"]["compiled.swift"] = "bad"
                else:
                    bad["sources"][0]["path"] = "../outside.swift"
                with self.assertRaises(ValueError):
                    release.validate_build(info, bad, root)

    def test_default_release_validation_uses_assembled_source_before_any_tool(self):
        with patch.object(release, "assembled_source", side_effect=ValueError("stale workspace")) as source:
            with patch.object(release, "run") as run:
                with self.assertRaisesRegex(ValueError, "stale workspace"):
                    release.validate_build({}, {})
                source.assert_called_once()
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
