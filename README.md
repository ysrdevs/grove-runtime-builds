# Grove runtime builds

The reproducible build recipes for Grove's downloadable native macOS PHP runtimes. Grove users download a complete verified package; they do not need Xcode, Homebrew, or a compiler.

Each package contains exact-version PHP CLI and PHP-FPM, optional intl and sodium, Xdebug 3.5.3, SPX 0.4.22 and its explorer, source provenance, and third-party notices. Apple Silicon and Intel are built and executed on separate native macOS runners. PHP 8.2–8.5 are supported by the recipe; an artifact is available only after its native job passes.

## Build locally

Maintainers need Apple's developer tools and Python 3. No Homebrew is used.

```sh
swift build --product grove-php-release
.build/debug/grove-php-release build --version 8.4.26 --workspace /private/tmp/grove-php-build --output /private/tmp/grove-php-payload
python3 script/php-release/package.py package --version 8.4.26 --architecture arm64 --input /private/tmp/grove-php-payload --output /private/tmp/grove-php-artifacts
```

Use x86_64 on a native Intel Mac. The builder downloads a standalone baseline into its isolated workspace, verifies the original module/network capabilities are retained, builds private pinned dependencies, and tests CLI/FPM, Unicode normalization, sodium encryption/signatures, actual Xdebug/SPX captures, and a real FPM pool startup. Nothing modifies the user's installed runtimes.

The build recipe's dependency URLs and checksums are pinned in source. PHP release sources use official PHP release checksums. Artifact packaging fixes ordering, ownership, timestamps, modes, and gzip metadata. This makes repackaging identical payload bytes deterministic; the compiler output itself is not claimed to be bit-for-bit reproducible across SDK/toolchain versions.

## CI and publication

Run the **Build PHP runtimes** workflow manually with exact patch versions. Its default matrix covers PHP 8.2.33, 8.3.33, 8.4.26, and 8.5.11 on `macos-15` (Apple Silicon) and `macos-15-intel`. Build outputs are unsigned GitHub Actions artifacts. No private signing key or Cloudflare credentials belong in this repository.

The `architectures` input accepts `arm64`, `x86_64`, or both separated by a comma. Retry only the failed version/architecture after a recipe repair, so successful native builds do not need to run again. For example:

```sh
gh workflow run php-runtimes.yml --repo ysrdevs/grove-runtime-builds \
  -f versions=8.2.33,8.3.33 -f architectures=x86_64
```

The release maintainer downloads and reviews successful outputs, signs the package catalog with a separately held Ed25519 key, and publishes immutable SHA-addressed archives to Cloudflare R2 before the catalog. The desktop app pins that public key and checks the catalog, archive, every extracted file, architecture, system-only linkage, exact PHP/module versions, and CLI/FPM startup before activation. CI success alone does not publish an update.

Third-party components retain their own licenses in each package. Grove's build code is MIT licensed.
