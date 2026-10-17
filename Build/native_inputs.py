"""Resolve platform build inputs from the shared native dependency lock."""

import copy
import hashlib
import json
from pathlib import Path

LOCK_PATH = Path("Build/Inputs.lock.json")
PLATFORMS = ("apple", "android")


def load(root):
    lock = json.loads((root / LOCK_PATH).read_text())
    if lock["schemaVersion"] != 1:
        raise ValueError("Unsupported native input schema")
    sources = lock["sources"]
    if len(sources) != 2 or {source["id"] for source in sources} != {"mpv", "ffmpeg"}:
        raise ValueError("Exactly one shared mpv and FFmpeg source is required")
    if {source["id"] for source in sources} & lock["android"]["git"].keys():
        raise ValueError("Android dependencies must not override shared source pins")
    patched_sources = sources + [{"id": name, "patches": source.get("patches", [])} for name, source in lock["android"]["git"].items()]
    for source in patched_sources:
        paths = [patch["path"] for patch in source["patches"]]
        ids = [patch["id"] for patch in source["patches"]]
        if len(set(paths)) != len(paths) or len(set(ids)) != len(ids):
            raise ValueError(f"Duplicate patches for {source['id']}")
        for patch in source["patches"]:
            platforms = patch.get("platforms", ["android"] if source["id"] in lock["android"]["git"] else [])
            if not platforms or len(set(platforms)) != len(platforms) or not set(platforms) <= set(PLATFORMS):
                raise ValueError(f"Invalid patch platforms: {patch['path']}")
    return lock


def sources_for(lock, platform):
    if platform not in PLATFORMS:
        raise ValueError(f"Unknown native platform: {platform}")
    sources = copy.deepcopy(lock["sources"])
    for source in sources:
        source["patches"] = [
            {key: value for key, value in patch.items() if key != "platforms"}
            for patch in source["patches"]
            if platform in patch["platforms"]
        ]
    return sources


def inputs_for(lock, platform):
    return {**copy.deepcopy(lock[platform]), "sources": sources_for(lock, platform)}


def fingerprint(inputs):
    return hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
