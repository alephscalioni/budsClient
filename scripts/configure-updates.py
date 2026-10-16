#!/usr/bin/env python3
"""Apply the fork's public update configuration. Private keys stay in Keychain."""
import base64
import json
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import urlsplit


def read_configuration(path):
    value = json.loads(Path(path).read_text())
    version, build = value.get("version"), value.get("build")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("The app version must contain three numeric components.")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]{0,17}", build):
        raise ValueError("The app build must be a positive, increasing integer.")
    feed, key = value.get("feedURL"), value.get("publicEDKey")
    if not feed and not key:
        return version, build, None, None
    if not isinstance(feed, str) or not isinstance(key, str):
        raise ValueError("The update feed and its public verification key are required together.")
    url = urlsplit(feed)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError("The update feed must use HTTPS without credentials or a fragment.")
    if url.hostname.lower() in {"timschneeberger.me", "www.timschneeberger.me"} or "timschneeb/galaxybudsclient" in url.path.lower():
        raise ValueError("The upstream app feed cannot update this fork.")
    try:
        decoded = base64.b64decode(key, validate=True)
    except ValueError as error:
        raise ValueError("Invalid public update verification key.") from error
    if len(decoded) != 32:
        raise ValueError("The update verification key must be 32 bytes.")
    return version, build, feed, key


def configure(config_path, info_path):
    version, build, feed, key = read_configuration(config_path)
    path = Path(info_path)
    info = plistlib.loads(path.read_bytes())
    info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
    for name in ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUSendProfileInfo"):
        info.pop(name, None)
    if feed:
        info.update(SUFeedURL=feed, SUPublicEDKey=key, SUEnableAutomaticChecks=True,
                    SUAutomaticallyUpdate=True, SUSendProfileInfo=False)
    path.write_bytes(plistlib.dumps(info))
    evidence = path.parent / "Resources/BuildInfo.json"
    if evidence.is_file():
        metadata = json.loads(evidence.read_text())
        metadata.update(app_version=version, app_build=build, update_feed=feed)
        evidence.write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    configure(*sys.argv[1:])
