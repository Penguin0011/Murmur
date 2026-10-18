#!/usr/bin/env python3
"""Apply build-time update configuration; never put private signing keys in the app."""
import base64
import os
import plistlib
import re
import sys
from urllib.parse import urlsplit


def configure(info, env):
    feed = env.get("MURMUR_UPDATE_FEED_URL", "")
    key = env.get("MURMUR_UPDATE_PUBLIC_KEY", "")
    if bool(feed) != bool(key):
        raise ValueError("Set both MURMUR_UPDATE_FEED_URL and MURMUR_UPDATE_PUBLIC_KEY")
    if feed:
        url = urlsplit(feed)
        if (url.scheme != "https" or url.hostname != "github.com" or url.port is not None
                or url.username or url.password or url.query or url.fragment
                or any(part in (".", "..") for part in url.path.split("/"))
                or not re.fullmatch(r"/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+/releases/latest/download/appcast\.xml", url.path)):
            raise ValueError("Feed must be an HTTPS GitHub latest-release appcast.xml asset URL")
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError("Sparkle public key must be a base64 Ed25519 public key (32 bytes)")
        info.update(SUFeedURL=feed, SUPublicEDKey=key, SUEnableAutomaticChecks=True,
                    SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=True,
                    SUSendProfileInfo=False, SUScheduledCheckInterval=86400,
                    SUVerifyUpdateBeforeExtraction=True)
    elif env.get("MURMUR_RELEASE") == "1":
        raise ValueError("Release builds require update feed and public key configuration")
    for variable, field in [("MURMUR_BUILD_VERSION", "CFBundleVersion"),
                            ("MURMUR_VERSION", "CFBundleShortVersionString")]:
        if variable in env:
            value = env[variable]
            if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
                raise ValueError(f"{variable} must contain one to three numeric components")
            info[field] = value
    return info


if __name__ == "__main__":
    path = sys.argv[1]
    with open(path, "rb") as source:
        info = configure(plistlib.load(source), os.environ)
    with open(path, "wb") as output:
        plistlib.dump(info, output)
