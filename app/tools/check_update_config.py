#!/usr/bin/env python3
import base64
import sys
sys.dont_write_bytecode = True
from configure_updates import configure

feed = "https://github.com/Penguin0011/Murmur/releases/latest/download/appcast.xml"
key = base64.b64encode(bytes(range(32))).decode()
valid = dict(MURMUR_UPDATE_FEED_URL=feed, MURMUR_UPDATE_PUBLIC_KEY=key,
             MURMUR_BUILD_VERSION="42", MURMUR_VERSION="0.2.0")
info = configure({}, valid)
assert info["SUFeedURL"] == feed and info["SUPublicEDKey"] == key
assert info["CFBundleVersion"] == "42" and info["CFBundleShortVersionString"] == "0.2.0"
assert info["SUVerifyUpdateBeforeExtraction"] and not info["SUAutomaticallyUpdate"]
assert configure({}, {}) == {}
for changes in [dict(MURMUR_UPDATE_PUBLIC_KEY=""), dict(MURMUR_UPDATE_FEED_URL=""),
                dict(MURMUR_UPDATE_PUBLIC_KEY="bad"), dict(MURMUR_BUILD_VERSION="../1"),
                dict(MURMUR_VERSION="1-beta")]:
    try:
        configure({}, valid | changes)
        raise AssertionError(changes)
    except ValueError:
        pass
for bad_feed in [feed.replace("https:", "http:"), feed + "?token=secret", feed + "#fragment",
                 feed.replace("github.com", "github.com.evil.example"),
                 feed.replace("github.com", "user@github.com"),
                 feed.replace("github.com", "github.com:443"),
                 feed.replace("/Murmur/", "/../"), feed.replace("appcast.xml", "other.xml")]:
    try:
        configure({}, valid | dict(MURMUR_UPDATE_FEED_URL=bad_feed))
        raise AssertionError(bad_feed)
    except ValueError:
        pass
try:
    configure({}, dict(MURMUR_RELEASE="1"))
    raise AssertionError("release missing signing key")
except ValueError:
    pass
print("Update build configuration checks passed")
