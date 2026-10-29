#!/usr/bin/env python3
"""Prepare reviewable native dependency updates using Python 3.10+ and Git."""

import argparse
import copy
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import quote
from urllib.request import Request, urlopen


from native_inputs import LOCK_PATH, PLATFORMS, load

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Update:
    dependency: str
    previous: str
    version: str
    link: str


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


def source_version(ref):
    """Drop the release prefix from tags such as v0.40.0 and n7.1, keeping other refs intact."""
    return re.sub(r"^[nv](?=\d)", "", ref)


def release_url(url):
    match = re.fullmatch(r"https://github.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)", url)
    if not match:
        raise ValueError(f"Unsupported SDK asset URL: {url}")
    return match.groups()


def sdk_groups(lock):
    groups = {}
    for dependency in lock["apple"]["dependencies"]:
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

    def resolve(self, url, ref):
        """Resolve one tag or branch to its commit, preferring a tag's peeled commit."""
        if not ref or ref.startswith("-") or "\n" in ref:
            raise ValueError(f"Invalid upstream ref: {ref!r}")
        rows = [
            line.split("\t")
            for line in run("git", "ls-remote", url, f"refs/tags/{ref}", f"refs/tags/{ref}^{{}}", f"refs/heads/{ref}").splitlines()
        ]
        peeled = [commit for commit, name in rows if name.endswith("^{}")]
        matches = peeled or [commit for commit, _ in rows]
        if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{40}", matches[0]):
            raise ValueError(f"Missing or ambiguous upstream ref: {ref}")
        return matches[0]

    def fetch(self, url, commit, checkout):
        fetch(url, commit, checkout)

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


def fetch(url, commit, checkout):
    run("git", "init", "--quiet", str(checkout))
    run("git", "fetch", "--quiet", "--no-tags", "--depth=1", url, commit, cwd=checkout)
    run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=checkout)


def verify_patches(root, source, patch_sets):
    """Apply each platform's ordered patches independently in a disposable checkout."""
    with tempfile.TemporaryDirectory(prefix="mpvui-update-") as temporary:
        checkout = Path(temporary)
        fetch(source["url"], source["commit"], checkout)
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


def patch_sets(source):
    return {platform: [patch for patch in source["patches"] if platform in patch["platforms"]] for platform in PLATFORMS}


def update_source(root, source, upstream, ref=None):
    if ref:
        tag, commit = ref, upstream.resolve(source["url"], ref)
        if commit == source["commit"]:
            return []
    else:
        tag, commit = upstream.source_release(source)
        current = version(source["ref"])
        if current is None:
            raise ValueError(f"Expected a stable release ref for {source['id']}: {source['ref']}")
        if version(tag) <= current:
            if tag == source["ref"] and commit != source["commit"]:
                raise ValueError(f"Upstream tag moved: {tag}; inspect the change manually")
            return []
    previous = source["version"]
    old_commit = source["commit"]
    source.update(ref=tag, commit=commit, version=source_version(tag))
    verify_patches(root, source, patch_sets(source))
    return [Update(source["id"], previous, source["version"], f"{source['url']}/compare/{old_commit}...{commit}")]


def update_sdk(dependencies, upstream):
    repository, _, _ = release_url(dependencies[0]["url"])
    releases = [
        release
        for release in upstream.releases(repository)
        if not release["draft"] and not release["prerelease"] and version(release["tag_name"]) is not None
    ]
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
    link = f"https://github.com/{repository}/releases/tag/{quote(tag, safe='')}"
    return [Update(dependency["id"], previous, tag, link) for dependency in dependencies]


def prepare_update(root, component, upstream, ref=None):
    original = load(root)
    updated = copy.deepcopy(original)
    groups = sdk_groups(updated)
    if ref and (component == "all" or component in groups):
        raise ValueError("--ref applies to a single source component")
    changes = []
    for selected in components(updated) if component == "all" else [component]:
        if selected in groups:
            changes.extend(update_sdk(groups[selected], upstream))
        else:
            source = next(source for source in updated["sources"] if source["id"] == selected)
            changes.extend(update_source(root, source, upstream, ref))
    outputs = {LOCK_PATH: json.dumps(updated, indent=2, sort_keys=True) + "\n"} if updated != original else {}
    return outputs, changes


def stage_recipe_review(root, upstream, ref=None):
    """Copy upstream Apple recipe sources for a manual port. The input lock is not changed."""
    recipes = load(root)["apple"]["recipeSource"]
    ref = ref or recipes["ref"]
    commit = upstream.resolve(recipes["url"], ref)
    directory = root / ".build/updates" / f"recipes-{commit}"
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mpvui-recipes-") as temporary:
        checkout = Path(temporary)
        upstream.fetch(recipes["url"], commit, checkout)
        for name in ("base.swift", "main.swift"):
            shutil.copy2(checkout / "Sources/BuildScripts/XCFrameworkBuild" / name, directory / f"upstream-{name}")
    (directory / "REVIEW.md").write_text(
        f"Upstream recipe resolution\n\nPrevious: {recipes['commit']}\nCandidate: {commit}\nRef: {ref}\n\n"
        "Review the upstream recipe diff and port relevant changes into Build/Sources/MPVBuildCore/Recipes. "
        "Inputs.lock.json is not updated automatically.\n"
    )
    return directory


def report(changes):
    return "".join(f"- {change.dependency}: {change.previous} -> {change.version} ([changes]({change.link}))\n" for change in changes)


def title(changes):
    return "Update " + ", ".join(f"{change.dependency} {change.version}" for change in changes) if changes else "Update dependencies"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true", help="List native dependency components")
    mode.add_argument("--all", action="store_true", help="Update all native dependencies together")
    mode.add_argument("--component", help="Update one source or SDK release bundle, or stage a recipes review")
    mode.add_argument("--validate", action="store_true", help="Check committed source pins and both platforms' patches")
    parser.add_argument("--ref", help="Use this upstream tag or branch instead of the latest stable release (sources and recipes)")
    parser.add_argument("--dry-run", action="store_true", help="Resolve and verify an update without writing the input lock")
    parser.add_argument("--report", type=Path, help="Write Markdown suitable for the update PR body")
    args = parser.parse_args()
    lock = load(ROOT)
    if args.list:
        print(json.dumps(components(lock) + ["recipes"]))
        return
    if args.ref and not args.component:
        parser.error("--ref requires --component")
    if args.component == "recipes":
        print(f"Review recipe update: {stage_recipe_review(ROOT, Upstream(), args.ref)}")
        return
    if args.validate:
        for source in lock["sources"]:
            verify_patches(ROOT, source, patch_sets(source))
        print("Source pins and ordered patches verified for Apple and Android.")
        return
    if not args.all and args.component not in components(lock):
        parser.error("Unknown component; use --list to see supported components")
    if args.ref and args.component in sdk_groups(lock):
        parser.error("--ref applies to source components and recipes")
    outputs, changes = prepare_update(ROOT, "all" if args.all else args.component, Upstream(), args.ref)
    if not args.dry_run:
        for path, content in outputs.items():
            (ROOT / path).write_text(content)
    body = report(changes)
    print(title(changes))
    print(body)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(body)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as file:
            file.write(f"title={title(changes)}\n")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Command failed: {error.cmd}\n{error.stderr}") from error
