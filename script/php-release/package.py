#!/usr/bin/env python3
"""Deterministic PHP release packaging; no signing keys or cloud credentials here."""
import argparse
import datetime as dt
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request

MODULES = ("intl", "sodium", "xdebug", "spx")
RECIPE = 4
MAX_EXPANDED = 400_000_000
VERSION = re.compile(r"8\.[2-5]\.[0-9]+\Z")
SHA = re.compile(r"[a-f0-9]{64}\Z")


def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(part)
    return result.hexdigest()


def inventory(directory):
    result, expanded = {}, 0
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError(f"Release payload must contain only ordinary files and directories: {relative}")
        if len(path.relative_to(directory).parts) > 11 or "\n" in relative or "\r" in relative:
            raise ValueError(f"Invalid archive path: {relative!r}")
        if path.is_file():
            expanded += path.stat().st_size
            if expanded > MAX_EXPANDED or len(result) >= 4096:
                raise ValueError("Release payload exceeds its published limits")
            result[relative] = digest(path)
    required = {"bin/php", "bin/php-fpm", *[f"modules/{name}.so" for name in MODULES]}
    if not required <= result.keys() or not any(p.startswith("web-ui/") for p in result) or not any(p.startswith("licenses/") for p in result):
        raise ValueError("Release payload is incomplete")
    if not all(p.startswith(("bin/", "modules/", "web-ui/", "licenses/")) for p in result):
        raise ValueError("Unexpected release payload directory")
    return result


def archive(directory, output):
    """Stable tar metadata, bytewise order, fixed gzip header, no Apple metadata."""
    with open(output, "wb") as stream:
        with gzip.GzipFile(filename="", fileobj=stream, mode="wb", compresslevel=9, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as bundle:
                for path in sorted(directory.rglob("*")):
                    relative = path.relative_to(directory).as_posix()
                    info = tarfile.TarInfo(relative)
                    info.uid = info.gid = 0
                    info.uname = info.gname = "root"
                    info.mtime = 0
                    if path.is_dir():
                        info.type, info.mode = tarfile.DIRTYPE, 0o755
                        bundle.addfile(info)
                    else:
                        info.mode = 0o755 if relative in ("bin/php", "bin/php-fpm") else 0o644
                        info.size = path.stat().st_size
                        with open(path, "rb") as source:
                            bundle.addfile(info, source)


def source_provenance(repo, version, architecture):
    core = repo / "Grove/Grove/Core"
    deps = (core / "ManagedPHPDependencyBuilder.swift").read_text()
    bundle = (core / "ManagedPHPExtensionBundle.swift").read_text()
    def inspector(name):
        path = core / (name + ".swift")
        if path.exists(): return path.read_text()
        shared = (core / "RuntimeBuildSupport.swift").read_text()
        return shared.split("enum " + name + " {", 1)[1].split("\n}", 1)[0]
    xdebug = inspector("InspectorXdebug")
    spx = inspector("InspectorSPX")
    def pin(source, name):
        return re.search(rf'static let {name} = "([^"]+)"', source).group(1)
    sources = []
    for name, arm, intel in re.findall(r'\("([^"]+)", "([a-f0-9]{64})", "([a-f0-9]{64})"\)', deps):
        arch = "aarch64" if architecture == "arm64" else "x86_64"
        sources.append({"name": name, "kind": "static-library", "url": f"https://github.com/static-php/hosted/releases/download/2026.2.17/{name}-{arch}-darwin.txz", "sha256": arm if architecture == "arm64" else intel, "buildRecipe": "https://github.com/static-php/hosted/tree/2026.2.17"})
    for name, url, sha in re.findall(r'\.init\(name: "([^"]+)", url: "([^"]+)", digest: "([a-f0-9]{64})"', deps):
        sources.append({"name": name, "kind": "source-or-build-tool", "url": url, "sha256": sha})
    for name, release, sha in re.findall(r'\.init\(name: "([^"]+)", version: "([^"]+)", sha256: "([a-f0-9]{64})"', bundle):
        sources.append({"name": name, "kind": "source", "version": release, "url": f"https://pecl.php.net/get/{name}-{release}.tgz", "sha256": sha})
    for name, release, sha in re.findall(r'\("(m4|autoconf)", "([^"]+)", "([a-f0-9]{64})"\)', bundle):
        sources.append({"name": name, "kind": "build-tool-source", "version": release, "url": f"https://ftp.gnu.org/gnu/{name}/{name}-{release}.tar.gz", "sha256": sha})
    sources += [{"name": "xdebug", "kind": "source", "version": pin(xdebug, "version"), "url": f'https://xdebug.org/files/xdebug-{pin(xdebug, "version")}.tgz', "sha256": pin(xdebug, "archiveSHA256")},
                {"name": "spx", "kind": "source", "version": pin(spx, "version"), "url": f'https://codeload.github.com/NoiseByNorthwest/php-spx/tar.gz/{pin(spx, "sourceCommit")}', "sha256": pin(spx, "archiveSHA256")}]
    with urllib.request.urlopen(f"https://www.php.net/releases/?json&version={version}", timeout=30) as response:
        metadata = json.load(response)
    if metadata["version"] != version:
        raise ValueError("Official PHP source version changed")
    php = next(item for item in metadata["source"] if item["filename"] == f"php-{version}.tar.xz")
    sources.append({"name": "php", "kind": "source", "version": version, "url": f'https://www.php.net/distributions/{php["filename"]}', "sha256": php["sha256"]})
    revision = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[a-f0-9]{40,64}", revision):
        try:
            revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True).strip()
        except subprocess.CalledProcessError:
            revision = "uncommitted"
    repository = os.environ.get("GITHUB_REPOSITORY", "local-build")
    return {"schemaVersion": 1, "recipe": RECIPE, "phpVersion": version, "architecture": architecture,
            "sourceRevision": revision, "sourceRepository": repository,
            "sources": sorted(sources, key=lambda s: s["name"]),
            "recipeFiles": {p: digest(repo / p) for p in ["Grove/Grove/Core/" + name for name in ["ManagedPHPExtensionBundle.swift", "ManagedPHPDependencyBuilder.swift", "PHPBuildSupport.swift", "ManagedPHPRelease.swift"]]},
            "notes": "Sources and checksums identify the exact inputs. The adjacent grove-build-recipe directory preserves the build recipe. No signing key is included."}


def package(args):
    if not VERSION.fullmatch(args.version) or args.architecture not in ("arm64", "x86_64"):
        raise ValueError("Invalid PHP version or architecture")
    source = args.input.resolve(strict=True)
    inventory(source)
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="grove-package-") as temporary:
        stage = Path(temporary) / "payload"
        shutil.copytree(source, stage)
        provenance = source_provenance(args.repo.resolve(), args.version, args.architecture)
        recipe = stage / "licenses/grove-build-recipe"
        recipe.mkdir()
        for relative in provenance["recipeFiles"]:
            shutil.copyfile(args.repo / relative, recipe / Path(relative).name)
        (stage / "licenses/grove-sources.json").write_text(json.dumps(provenance, sort_keys=True, indent=2) + "\n")
        files = inventory(stage)
        temporary_archive = Path(temporary) / "artifact.tar.gz"
        archive(stage, temporary_archive)
        checksum = digest(temporary_archive)
        path = f"releases/php/{args.version}/{args.architecture}/{checksum}/grove-php-{args.version}-{args.architecture}.tar.gz"
        destination = args.output / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() and digest(destination) != checksum:
            raise ValueError("Immutable artifact path is already occupied")
        shutil.copyfile(temporary_archive, destination)
        entry = {"id": f"grove-php-{args.version}-{args.architecture}-{RECIPE}-{checksum[:12]}", "recipe": RECIPE,
                 "phpVersion": args.version, "architecture": args.architecture, "minimumMacOS": "14.0",
                 "archive": {"path": path, "sha256": checksum, "size": destination.stat().st_size},
                 "modules": {"intl": args.version, "sodium": args.version,
                             "xdebug": next(s["version"] for s in provenance["sources"] if s["name"] == "xdebug"),
                             "spx": next(s["version"] for s in provenance["sources"] if s["name"] == "spx")},
                 "files": files}
        descriptor = args.output / f"php-{args.version}-{args.architecture}.package.json"
        descriptor.write_text(json.dumps(entry, sort_keys=True, indent=2) + "\n")
        print(json.dumps({"descriptor": str(descriptor), "archive": str(destination), "sha256": checksum, "size": destination.stat().st_size}))


def manifest(args):
    entries = [json.loads(path.read_text()) for path in args.packages]
    keys = [(p["phpVersion"], p["architecture"]) for p in entries]
    if len(set(keys)) != len(keys) or not entries:
        raise ValueError("Each PHP version and architecture must have exactly one package")
    if not 1 <= args.valid_days <= 90:
        raise ValueError("Manifest lifetime must be 1–90 days")
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    iso = lambda date: date.isoformat().replace("+00:00", "Z")
    payload = {"schemaVersion": 1, "generatedAt": iso(now), "expiresAt": iso(now + dt.timedelta(days=args.valid_days)),
               "packages": sorted(entries, key=lambda p: (tuple(map(int, p["phpVersion"].split("."))), p["architecture"]), reverse=True)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode())
    print(f"Unsigned payload: {args.output} ({len(entries)} packages)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("package")
    pack.add_argument("--version", required=True)
    pack.add_argument("--architecture", required=True, choices=("arm64", "x86_64"))
    pack.add_argument("--input", required=True, type=Path)
    pack.add_argument("--output", required=True, type=Path)
    pack.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    pack.set_defaults(run=package)
    manifest_parser = commands.add_parser("manifest")
    manifest_parser.add_argument("--output", required=True, type=Path)
    manifest_parser.add_argument("--valid-days", type=int, default=30)
    manifest_parser.add_argument("packages", nargs="+", type=Path)
    manifest_parser.set_defaults(run=manifest)
    args = parser.parse_args()
    try:
        args.run(args)
    except (ValueError, OSError, KeyError, StopIteration) as error:
        parser.exit(1, f"Release packaging failed: {error}\n")

if __name__ == "__main__":
    main()
