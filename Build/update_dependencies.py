#!/usr/bin/env python3
"""Prepare reviewable native dependency updates using Python 3.10+ and Git."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
APPLE_LOCK = Path("Build/Inputs.lock.json")
ANDROID_LOCK = Path("Build/Android/Native.lock.json")


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()


def version(tag):
    # mpvkit also publishes stable packaging fixes, e.g. 2.1.0-fix and 4.15.13-2512.
    match = re.fullmatch(r"[nv]?(\d+(?:\.\d+){1,3})(?:-(fix|\d+))?", tag)
    if not match:
        return None
    numbers = tuple(map(int, match[1].split(".")))
    suffix = match[2]
    return numbers + (0,) * (4 - len(numbers)) + (1 if suffix == "fix" else int(suffix or 0),)


def release_url(url):
    match = re.fullmatch(r"https://github.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)", url)
    if not match:
        raise ValueError(f"Unsupported SDK asset URL: {url}")
    return match.groups()


def sdk_groups(lock):
    groups = {}
    for dependency in lock["dependencies"]:
        repository, _, _ = release_url(dependency["url"])
        groups.setdefault("sdk-" + repository.replace("/", "-"), []).append(dependency)
    return groups


def components(lock):
    return [source["id"] for source in lock["sources"]] + list(sdk_groups(lock))


class Upstream:
    def releases(self, repository):
        result = []
        page = 1
        while True:
            headers = {"Accept": "application/vnd.github+json", "User-Agent": "MPVUI-dependency-updater"}
            token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
            if token:
                headers["Authorization"] = "Bearer " + token
            request = Request(f"https://api.github.com/repos/{repository}/releases?per_page=100&page={page}", headers=headers)
            with urlopen(request, timeout=60) as response:
                batch = json.load(response)
            result.extend(batch)
            if len(batch) < 100:
                return result
            page += 1

    def source_release(self, source):
        prefix = {"ffmpeg": "n", "mpv": "v"}[source["id"]]
        refs = {}
        for line in run("git", "ls-remote", "--tags", source["url"]).splitlines():
            commit, ref = line.split()
            refs[ref.removeprefix("refs/tags/")] = commit
        candidates = [tag for tag in refs if re.fullmatch(prefix + r"\d+(?:\.\d+){1,3}", tag)]
        if not candidates:
            raise ValueError(f"No stable tags for {source['id']}")
        tag = max(candidates, key=version)
        commit = refs.get(tag + "^{}", refs[tag])
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError(f"Invalid upstream commit for {tag}")
        return tag, commit

    def asset_digest(self, asset):
        # Never pass the repository token to a download URL or its CDN redirects.
        digest = hashlib.sha256()
        size = 0
        with urlopen(asset["browser_download_url"], timeout=120) as response:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
        result = digest.hexdigest()
        if size != asset["size"]:
            raise ValueError(f"Incomplete asset: {asset['name']}")
        if asset.get("digest") and asset["digest"] != "sha256:" + result:
            raise ValueError(f"Upstream checksum mismatch: {asset['name']}")
        return result


def verify_patches(root, source, patch_sets):
    """Apply each platform's ordered patches independently in a disposable checkout."""
    with tempfile.TemporaryDirectory(prefix="mpvui-update-") as temporary:
        checkout = Path(temporary)
        run("git", "init", "--quiet", str(checkout))
        run("git", "fetch", "--quiet", "--no-tags", "--depth=1", source["url"], source["commit"], cwd=checkout)
        run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=checkout)
        for platform, patches in patch_sets.items():
            run("git", "reset", "--hard", "--quiet", "HEAD", cwd=checkout)
            run("git", "clean", "-fdx", "--quiet", cwd=checkout)
            for patch in patches:
                path = (root / patch["path"]).resolve()
                if not path.is_relative_to(root.resolve()):
                    raise ValueError(f"Patch outside repository: {patch['path']}")
                if hashlib.sha256(path.read_bytes()).hexdigest() != patch["sha256"]:
                    raise ValueError(f"Patch checksum drift: {patch['path']}")
                try:
                    run("git", "apply", "--check", str(path), cwd=checkout)
                    run("git", "apply", str(path), cwd=checkout)
                except subprocess.CalledProcessError as error:
                    raise ValueError(f"{source['id']} {platform} patch failed: {patch['path']}\n{error.stderr}") from error


def shared_source(source, android):
    if android is None:
        return None
    other = android["git"][source["id"]]
    if other["url"].removesuffix(".git") != source["url"].removesuffix(".git") or other["commit"] != source["commit"]:
        raise ValueError(f"Apple/Android source pins differ for {source['id']}; reconcile them before updating")
    return other


def patch_sets(source, android):
    result = {"Apple": source["patches"]}
    if android is not None:
        result["Android"] = android[source["id"] + "Patches"]
    return result


def update_source(root, source, android, upstream):
    other = shared_source(source, android)
    tag, commit = upstream.source_release(source)
    current = version(source["ref"])
    if current is None:
        raise ValueError(f"Expected a stable release ref for {source['id']}: {source['ref']}")
    if version(tag) <= current:
        if tag == source["ref"] and commit != source["commit"]:
            raise ValueError(f"Upstream tag moved: {tag}; inspect the change manually")
        return []
    previous = source["ref"]
    old_commit = source["commit"]
    source.update(ref=tag, commit=commit, version=tag[1:])
    verify_patches(root, source, patch_sets(source, android))
    if other is not None:
        other["commit"] = commit
    return [f"- {source['id']}: `{previous}` → `{tag}` ([upstream diff]({source['url']}/compare/{old_commit}...{commit})).",
            ("- Apple and Android commits updated together; both ordered patch sets applied successfully."
             if other is not None else "- The ordered Apple patch set applied successfully.")]


def update_sdk(dependencies, upstream):
    repository, _, _ = release_url(dependencies[0]["url"])
    releases = [release for release in upstream.releases(repository)
                if not release["draft"] and not release["prerelease"] and version(release["tag_name"]) is not None]
    if not releases:
        raise ValueError(f"No stable releases for {repository}")
    release = max(releases, key=lambda item: version(item["tag_name"]))
    tag = release["tag_name"]
    current_tags = {release_url(dependency["url"])[1] for dependency in dependencies}
    if len(current_tags) != 1 or any(dependency["version"] not in current_tags for dependency in dependencies):
        raise ValueError(f"SDK bundle versions differ for {repository}")
    previous = current_tags.pop()
    if version(previous) is None:
        raise ValueError(f"Unsupported locked release: {previous}")
    if version(tag) <= version(previous):
        return []
    assets = {asset["name"]: asset for asset in release["assets"]}
    pending = []
    # Resolve the complete SDK/runtime set before downloading or changing any pins.
    for dependency in dependencies:
        for item in [dependency] + dependency["runtime"]:
            repo, locked_tag, name = release_url(item["url"])
            if repo != repository or locked_tag != previous:
                raise ValueError(f"SDK/runtime release mismatch: {item['url']}")
            expected = f"https://github.com/{repository}/releases/download/{quote(tag, safe='')}/{name}"
            asset = assets.get(name)
            if asset is None or asset["browser_download_url"] != expected:
                raise ValueError(f"Missing or unexpected asset in {repository} {tag}: {name}")
            pending.append((item, asset))
    hashes = [(item, asset, upstream.asset_digest(asset)) for item, asset in pending]
    for item, asset, checksum in hashes:
        item.update(url=asset["browser_download_url"], sha256=checksum)
    for dependency in dependencies:
        dependency["version"] = tag
    names = ", ".join(dependency["id"] for dependency in dependencies)
    return [f"- {names}: `{previous}` → `{tag}` ([release notes](https://github.com/{repository}/releases/tag/{quote(tag, safe='')})).",
            f"- Downloaded and SHA-256 hashed all {len(hashes)} SDK/runtime assets; checked upstream digests when available."]


def prepare_update(root, component, upstream):
    original = {APPLE_LOCK: json.loads((root / APPLE_LOCK).read_text())}
    if (root / ANDROID_LOCK).exists():
        original[ANDROID_LOCK] = json.loads((root / ANDROID_LOCK).read_text())
    updated = copy.deepcopy(original)
    apple, android = updated[APPLE_LOCK], updated.get(ANDROID_LOCK)
    if component in sdk_groups(apple):
        changes = update_sdk(sdk_groups(apple)[component], upstream)
    else:
        source = next(source for source in apple["sources"] if source["id"] == component)
        changes = update_source(root, source, android, upstream)
    outputs = {path: json.dumps(value, indent=2) + "\n" for path, value in updated.items() if value != original[path]}
    return outputs, changes


def report(changes):
    if not changes:
        return "No newer stable release found.\n"
    return ("Updates pinned native build inputs.\n\n" + "\n".join(changes) +
            "\n\nThese checks do not compile the native libraries or test playback. "
            "Before merging, build a complete Apple release candidate (and Android native libraries when present), "
            "then run their consumer/playback tests. See "
            "[Build/BUILD.md](https://github.com/LePips/MPVUI/blob/main/Build/BUILD.md).\n\n"
            "Published binaries and `Build/Artifacts.lock.json` are unchanged. "
            "Publish and adopt a new native artifact separately to deliver the update to consumers.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true", help="Print the workflow component matrix")
    mode.add_argument("--component", help="Update one source or SDK release bundle")
    mode.add_argument("--validate", action="store_true", help="Check committed source pins and both platforms' patches")
    parser.add_argument("--dry-run", action="store_true", help="Resolve and verify an update without writing locks")
    parser.add_argument("--report", type=Path, help="Write Markdown suitable for the update PR body")
    args = parser.parse_args()
    apple = json.loads((ROOT / APPLE_LOCK).read_text())
    if args.list:
        print(json.dumps(components(apple)))
        return
    if args.validate:
        android = json.loads((ROOT / ANDROID_LOCK).read_text()) if (ROOT / ANDROID_LOCK).exists() else None
        for source in apple["sources"]:
            shared_source(source, android)
            verify_patches(ROOT, source, patch_sets(source, android))
        print("Source pins and ordered patches verified for all available platforms.")
        return
    if args.component not in components(apple):
        parser.error("Unknown component; use --list to see supported components")
    outputs, changes = prepare_update(ROOT, args.component, Upstream())
    if not args.dry_run:
        for path, content in outputs.items():
            (ROOT / path).write_text(content)
    body = report(changes)
    print(body)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(body)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Command failed: {error.cmd}\n{error.stderr}") from error
