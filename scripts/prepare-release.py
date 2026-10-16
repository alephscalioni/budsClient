#!/usr/bin/env python3
"""Prepare an Ed25519-signed macOS update without exporting its Keychain key."""
from pathlib import Path
import datetime
import email.utils
import importlib.util
import hashlib
import json
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = "alephscalioni.BudsClient.updates"
SPARKLE = ROOT / ".build/workspace/tools/sparkle-2.10.0/bin"


def assembled_source():
    spec = importlib.util.spec_from_file_location("assembly", ROOT / "scripts/assemble-source.py")
    assembly = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(assembly)
    return assembly.validate_workspace(ROOT)


def run(*args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def validate_build(info, metadata, root=None):
    root = assembled_source() if root is None else Path(root)
    if (info.get("BudsBuildConfiguration") != "Release" or metadata.get("configuration") != "Release"
            or metadata.get("native_library_configuration") != "Release"
            or "DEBUG" in metadata.get("native_library_defines", [])
            or "BUDS_EMBEDDED" not in metadata.get("native_library_defines", [])
            or info.get("BudsBuildIdentifier") != metadata.get("build_id")):
        raise ValueError("Only matching native/managed Release builds may be published.")
    records = {}
    all_records = [(item["path"], item["sha256"]) for item in metadata["sources"]]
    all_records += list(metadata["managed_build_inputs"].items())
    all_records += [("macOSAutoSwitch/" + item["path"], item["sha256"])
                    for item in metadata["native_library_compiled_inputs"]]
    for relative, expected in all_records:
        if relative in records and records[relative] != expected:
            raise ValueError("Conflicting compiled source hashes: " + relative)
        records[relative] = expected
    for relative, expected in records.items():
        path = root / relative
        if not path.resolve().is_relative_to(root.resolve()) or not path.is_file():
            raise ValueError("Missing or invalid build source: " + relative)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("Source changed after compilation: " + relative)


def prepare():
    spec = importlib.util.spec_from_file_location("updates", ROOT / "scripts/configure-updates.py")
    updates = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(updates)
    version, build, feed, key = updates.read_configuration(ROOT / "config/updates.json")
    if not feed or not key:
        raise SystemExit("Configure the fork's update feed before preparing a release.")
    app = ROOT / "dist/Buds.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    metadata = json.loads((app / "Contents/Resources/BuildInfo.json").read_text())
    validate_build(info, metadata)
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"), info.get("SUFeedURL"), info.get("SUPublicEDKey")) != (version, build, feed, key):
        raise SystemExit("The packaged build and release configuration differ. Rebuild first.")
    run("codesign", "--verify", "--deep", "--strict", app)
    if run(SPARKLE / "generate_keys", "--account", ACCOUNT, "-p") != key:
        raise SystemExit("The release signing key does not match this app's public key.")
    directory = ROOT / "dist/releases" / (version + "-" + build)
    directory.mkdir(parents=True, exist_ok=False)
    archive = directory / ("BudsClient-" + version + "-" + build + ".zip")
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    signature = run(SPARKLE / "sign_update", "--account", ACCOUNT, "-p", archive)
    run(SPARKLE / "sign_update", "--account", ACCOUNT, "--verify", archive, signature)
    namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", namespace)
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "BudsClient para macOS"
    ET.SubElement(channel, "link").text = "https://github.com/alephscalioni/BudsClient"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "BudsClient " + version
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, "{" + namespace + "}version").text = build
    ET.SubElement(item, "{" + namespace + "}shortVersionString").text = version
    ET.SubElement(item, "{" + namespace + "}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "enclosure", {
        "url": "https://github.com/alephscalioni/BudsClient/releases/download/v" + version + "/" + archive.name,
        "length": str(archive.stat().st_size), "type": "application/octet-stream",
        "{" + namespace + "}edSignature": signature,
    })
    appcast = directory / "appcast.xml"
    ET.ElementTree(rss).write(appcast, encoding="utf-8", xml_declaration=True)
    run(SPARKLE / "sign_update", "--account", ACCOUNT, appcast)
    run(SPARKLE / "sign_update", "--account", ACCOUNT, "--verify", appcast)
    metadata = {"version": version, "build": build, "archive": archive.name, "length": archive.stat().st_size,
                "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                "feed": feed, "keychain_account": ACCOUNT, "signature_verified": True}
    (directory / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(directory)


if __name__ == "__main__":
    prepare()
