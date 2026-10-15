#!/usr/bin/env python3
"""Offline relocation, LGPL library rebuilding, and PHP CLI/FPM relinking."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile


def run(command, directory, environment):
    print("Running " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=directory, env=environment, check=True)


def environment(root):
    configuration = json.loads((root / "kit.json").read_text())
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
    flags = "-O2 -fPIC -arch " + configuration["architecture"] + " -mmacosx-version-min=14.0"
    prefix = root / "libraries"
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SDKROOT": sdk, "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++", "CFLAGS": flags, "CXXFLAGS": flags,
            # PHP 8.2 consumes these flags from make's environment rather than
            # retaining them in its generated Makefile. Match the engine build.
            "CPPFLAGS": "-I" + str(prefix / "include"),
            "LDFLAGS": "-L" + str(prefix / "lib") + " -Wl,-export_dynamic -framework CoreFoundation",
            "PKG_CONFIG": "/usr/bin/false", "PKG_CONFIG_PATH": "", "PKG_CONFIG_LIBDIR": "/var/empty",
            "CONFIG_SITE": "/dev/null", "PHPRC": "", "PHP_INI_SCAN_DIR": "", "XDEBUG_MODE": "off"}


def prepare(root, destination):
    destination = destination.absolute()
    if destination.exists() or any(c.isspace() for c in str(destination)):
        raise ValueError("Choose a new workspace path without spaces")
    shutil.copytree(root, destination, symlinks=True)
    config = json.loads((destination / "kit.json").read_text())
    replacements = {}
    for original, replacement in [(config["originalPHPDirectory"], destination / "php"),
                                  (config["originalLibraryPrefix"], destination / "libraries")]:
        replacements[original] = str(replacement)
        if original.startswith("/private/tmp/"):
            replacements[original[len("/private"):]] = str(replacement)
    sdk = environment(destination)["SDKROOT"]
    # Only generated textual build metadata is relocated. Source/object bytes
    # and archives retain their original contents.
    for parent in [destination / "php", destination / "libraries"]:
        for file in parent.rglob("*"):
            if file.is_symlink() or not file.is_file():
                continue
            if not (file.name.startswith("Makefile") or file.name in ["libtool", "config.nice", "config.status"]
                    or file.suffix in [".dep", ".la", ".lo", ".pc", ".mk"]):
                continue
            text = file.read_text()
            for original, replacement in sorted(replacements.items(), key=lambda item: -len(item[0])):
                text = text.replace(original, replacement)
            text = re.sub(r"/Applications/[^ \n'\"]+?/SDKs/MacOSX[^ /'\"]*\.sdk", sdk, text)
            times = file.stat()
            file.write_text(text)
            os.utime(file, ns=(times.st_atime_ns, times.st_mtime_ns))
    # Archive mode normalization deliberately removes executable bits; only
    # the generated scripts called by make need them restored.
    for name in ["libtool", "configure", "config.status"]:
        (destination / "php" / name).chmod(0o755)
    # The deterministic archive uses epoch timestamps, while SDK headers keep
    # their installation dates. Mark retained objects current so relinking does
    # not needlessly recompile every source because of those SDK dependencies.
    for file in (destination / "php").rglob("*"):
        if file.is_file() and file.suffix in [".o", ".lo"]:
            os.utime(file, None)
    config["prepared"] = True
    (destination / "kit.json").write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
    print("Prepared " + str(destination))


def extract_library(archive, destination, expected_directory):
    """Extract only the regular files/directories in the pinned source tarballs.

    Validate the entire archive before writing. Reject links rather than relying
    on tarfile's default filter, which differs across supported Python versions.
    """
    destination = destination.resolve()
    expected = destination / expected_directory
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        for member in members:
            name = PurePosixPath(member.name)
            if (not name.parts or name.is_absolute() or ".." in name.parts
                    or name.parts[0] != expected_directory
                    or not (member.isfile() or member.isdir())
                    or not (destination / member.name).resolve().is_relative_to(expected)):
                raise ValueError("Unsafe library archive path: " + member.name)
            member.mode &= 0o777
        tar.extractall(destination, members=members)


def rebuild_library(root, name):
    env = environment(root)
    prefix = root / "libraries"
    spec = {"gettext": ("gettext-0.26.tar.xz", "gettext-0.26"),
            "unixodbc": ("unixODBC-2.3.14.tar.gz", "unixODBC-2.3.14")}[name]
    source = root / "library-sources" / spec[1]
    if not source.exists():
        source.parent.mkdir(exist_ok=True)
        archive = root / "licenses/libraries/sources" / spec[0]
        extract_library(archive, source.parent, spec[1])
    build = root / "library-builds" / name
    build.mkdir(parents=True, exist_ok=True)
    basic = ["--prefix=" + str(prefix), "--enable-static", "--disable-shared"]
    if name == "gettext":
        arguments = basic + ["--disable-java", "--disable-c++", "--disable-d", "--disable-modula2",
                             "--disable-rpath", "--disable-libasprintf", "--disable-openmp",
                             "--with-included-libintl", "--with-libiconv-prefix=" + str(prefix)]
        run([source / "configure"] + arguments, build, env)
        target = build / "gettext-runtime/intl"
        run(["/usr/bin/make", "-j", "4"], target, env)
        run(["/usr/bin/make", "install"], target, env)
    else:
        arguments = basic + ["--sysconfdir=/etc", "--disable-gui", "--disable-drivers", "--disable-driver-config",
                             "--disable-readline", "--disable-editline", "--with-included-ltdl",
                             "--with-libiconv-prefix=" + str(prefix)]
        run([source / "configure"] + arguments, build, env)
        run(["/usr/bin/make", "-j", "4"], build, env)
        run(["/usr/bin/make", "install", "sysconfdir=" + str(prefix / "etc")], build, env)
    print("Rebuilt private " + name + ". Run link to use it in PHP.")


def link(root):
    config = json.loads((root / "kit.json").read_text())
    if not config.get("prepared"):
        raise ValueError("Run prepare into a separate workspace first")
    php = root / "php"
    for binary in ["sapi/cli/php", "sapi/fpm/php-fpm"]:
        (php / binary).unlink(missing_ok=True)
    arch = config["architecture"]
    run(["/usr/bin/make", "-j", "4", "sapi/cli/php", "sapi/fpm/php-fpm",
         "CC=/usr/bin/clang -arch " + arch, "CXX=/usr/bin/clang++ -arch " + arch], php, environment(root))
    run([php / "sapi/cli/php", "-n", "-v"], php, environment(root))
    run([php / "sapi/fpm/php-fpm", "-n", "-v"], php, environment(root))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    initialize = sub.add_parser("prepare")
    initialize.add_argument("--workspace", type=Path, required=True)
    rebuild = sub.add_parser("rebuild-library")
    rebuild.add_argument("library", choices=["gettext", "unixodbc"])
    sub.add_parser("link")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    if args.command == "prepare":
        prepare(root, args.workspace)
    elif args.command == "rebuild-library":
        rebuild_library(root, args.library)
    else:
        link(root)
