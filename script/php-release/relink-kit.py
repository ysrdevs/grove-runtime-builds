#!/usr/bin/env python3
"""Archive the actual configured PHP source, objects, libraries and relink tools."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def create(args):
    recipe = args.recipe.resolve(strict=True)
    build = args.build.resolve(strict=True)
    libraries = (args.libraries or build / "libraries/prefix").resolve(strict=True)
    payload = args.payload.resolve(strict=True)
    php = build / ("source/php-" + args.version)
    if not re.fullmatch(r"8\.[2-5]\.\d+", args.version) or args.architecture not in ("arm64", "x86_64"):
        raise ValueError("Invalid version or architecture")
    for required in [php / "Makefile", php / "main/php_version.h", libraries / "lib/libintl.a",
                     libraries / "lib/libodbc.a", payload / "licenses/libraries/sources/gettext-0.26.tar.xz",
                     payload / "licenses/libraries/sources/unixODBC-2.3.14.tar.gz"]:
        if not required.is_file():
            raise ValueError("Missing complete relink input: " + str(required))
    if not list(php.glob("main/*.lo")):
        raise ValueError("Build objects must be retained before creating the relink kit")
    args.output.mkdir(parents=True, exist_ok=True)
    stem = "grove-php-" + args.version + "-" + args.architecture + "-relink"
    with tempfile.TemporaryDirectory(prefix="grove-relink-kit-") as temporary:
        kit = Path(temporary).resolve() / stem
        kit.mkdir()
        def ignore(directory, names):
            # Generated logs can contain host environment diagnostics. Source,
            # headers, exact Makefiles and all link objects remain available.
            return [name for name in names if name == ".git" or name == "config.log"
                    or name.startswith("grove-") or name.endswith((".so", ".dylib", ".log"))]
        shutil.copytree(php, kit / "php", symlinks=True, ignore=ignore)
        for relative in ["sapi/cli/php", "sapi/fpm/php-fpm", "sapi/phpdbg/phpdbg"]:
            (kit / "php" / relative).unlink(missing_ok=True)
        for directory in ["include", "lib"]:
            shutil.copytree(libraries / directory, kit / "libraries" / directory, symlinks=False)
        shutil.copytree(payload / "licenses", kit / "licenses", symlinks=True)
        shutil.copyfile(recipe / "script/php-release/relink.py", kit / "relink.py")
        shutil.copytree(recipe / "Grove/Grove/Core", kit / "build-recipe", ignore=shutil.ignore_patterns("*.log"))
        spec = importlib.util.spec_from_file_location("grove_package", recipe / "script/php-release/package.py")
        package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(package)
        provenance = package.source_provenance(recipe, args.version, args.architecture)
        (kit / "provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
        configuration = {
            "schemaVersion": 1, "phpVersion": args.version, "architecture": args.architecture,
            "originalPHPDirectory": str(php), "originalLibraryPrefix": str(libraries),
            "payloadFiles": {str(p.relative_to(payload)): digest(p) for p in payload.rglob("*") if p.is_file()},
        }
        (kit / "kit.json").write_text(json.dumps(configuration, indent=2, sort_keys=True) + "\n")
        (kit / "README.md").write_text("""# Grove PHP relink kit

This is a developer source/object artifact, separate from Grove's one-click
runtime download. It contains the complete configured PHP and extension source,
their link objects, the private static libraries and headers, original source
provenance, license notices, and GNU gettext/unixODBC source archives.

Extract anywhere into a path without spaces. Apple's developer tools and Python
3 are required for a custom rebuild; no Homebrew, original build directory,
network download, signing key, or Microsoft ODBC driver is needed.

    python3 relink.py prepare --workspace /private/tmp/grove-custom-php
    python3 /private/tmp/grove-custom-php/relink.py rebuild-library gettext
    python3 /private/tmp/grove-custom-php/relink.py rebuild-library unixodbc
    python3 /private/tmp/grove-custom-php/relink.py link

Prepare preserves the exact source and Makefile and relocates their private
paths. The unpacked library source is under library-sources/. Edit it before
rebuild-library; subsequent builds retain those edits. To relink against your
own compatible static library instead, replace its .a file under libraries/lib
and run link. Neither command writes system configuration.

The custom CLI and FPM executables are written to php/sapi/cli/php and
php/sapi/fpm/php-fpm. They are ordinary unsigned developer binaries and do not
replace installed Grove runtimes. The original intl/sodium/Xdebug/SPX modules
remain ABI compatible when library edits preserve the original PHP build ABI.
Use the preserved release recipe's verification before adopting custom builds.

input-files.json records hashes of the original kit files. Modifying source or
libraries intentionally changes those hashes. provenance.json records exact
upstream input URLs/checksums; kit.json binds this kit to the runtime payload.
All third-party source and object files retain their licenses in licenses/.
""")
        inventory = {}
        for path in sorted(kit.rglob("*")):
            if path.is_symlink():
                target = path.resolve()
                if not target.is_relative_to(kit):
                    raise ValueError("Relink kit has an escaping symlink: " + str(path))
            elif path.is_file():
                inventory[str(path.relative_to(kit))] = digest(path)
        (kit / "input-files.json").write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
        archive = args.output / (stem + ".tar.gz")
        if archive.exists():
            raise ValueError("Refusing to overwrite an existing relink archive")
        with archive.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w") as tar:
                for path in [kit] + sorted(kit.rglob("*")):
                    info = tar.gettarinfo(str(path), arcname=str(path.relative_to(kit.parent)))
                    info.uid = info.gid = 0
                    info.uname = info.gname = "root"
                    info.mtime = 0
                    info.mode = 0o755 if path.is_dir() else 0o644
                    if info.isfile():
                        with path.open("rb") as stream:
                            tar.addfile(info, stream)
                    else:
                        tar.addfile(info)
        if args.verify:
            # Exercise the archive itself after timestamps/modes were normalized.
            # This must work from a different path using retained objects only.
            extracted = Path(temporary) / "extracted"
            extracted.mkdir()
            with tarfile.open(archive) as tar:
                tar.extractall(extracted)
            source = extracted / stem
            relocated = Path(temporary) / "relocated"
            log = args.output / (stem + ".verify.log")
            with log.open("w") as stream:
                for command in [[sys.executable, str(source / "relink.py"), "prepare", "--workspace", str(relocated)],
                                [sys.executable, str(relocated / "relink.py"), "link"]]:
                    subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)
        result = {"schemaVersion": 1, "phpVersion": args.version, "architecture": args.architecture,
                  "filename": archive.name, "sha256": digest(archive), "size": archive.stat().st_size,
                  "sourceRevision": provenance["sourceRevision"], "fileCount": len(inventory),
                  "relocationVerified": args.verify}
        result["key"] = "releases/php-source/" + args.version + "/" + args.architecture + "/" + result["sha256"] + "/" + archive.name
        (args.output / (stem + ".json")).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(json.dumps(result))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--build", required=True, type=Path)
    parser.add_argument("--libraries", type=Path)
    parser.add_argument("--payload", required=True, type=Path)
    parser.add_argument("--recipe", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--verify", action="store_true", help="Extract and relink CLI/FPM before accepting this kit")
    create(parser.parse_args())
