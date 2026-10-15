# PHP extension parity

Grove's release builder adds the open-source PHP modules listed below directly
to PHP CLI and PHP-FPM. They are available immediately after installing a
prebuilt Grove package; users do not build or enable these modules separately.
The optional-module archive remains recipe 4: `intl`, `sodium`, `xdebug`, and
`spx`. No new archive schema or end-user compiler dependency is introduced.

The comparison uses [Herd's documented PHP extensions](https://herd.laravel.com/docs/macos/technology/php-extensions)
and the actual local Herd 8.4.25 and Grove 8.4.26 inventories. The documented
`lz4` module is included even though the inspected Herd binary did not load it.
Herd's proprietary `herd` module is not copied or distributed.

| Added modules | Implementation | License / notes |
| --- | --- | --- |
| `dba` | PHP's flat-file and INI-file handlers | PHP source license |
| `FFI` | PHP FFI and macOS system libffi | PHP source license; system library |
| `gettext` | PHP gettext + static GNU gettext 0.26 libintl | PHP source license; libintl LGPL 2.1-or-later |
| `imagick` | Imagick 3.8.1 + static ImageMagick 7.1.2-34 | PHP 3.01; ImageMagick License |
| `imap` | Bundled PHP source through 8.3; PECL IMAP 1.0.3 on 8.4/8.5; pinned c-client fork | PHP 3.01; c-client Apache 2.0 notices retained |
| `ldap` | PHP LDAP + static OpenLDAP 2.6.15 | PHP source license; OpenLDAP Public License |
| `lz4` | php-ext-lz4 0.7.1 + private static LZ4 | MIT; LZ4 BSD |
| `mongodb` | MongoDB PHP driver 2.5.4, bundled C libraries, private OpenSSL | Apache 2.0 and bundled dependency notices |
| `pdo_sqlsrv`, `sqlsrv` | Microsoft PHP drivers 5.13.3 + static unixODBC 2.3.14 | Drivers MIT; unixODBC libraries LGPL 2.1-or-later |
| `readline` | PHP readline with macOS libedit | PHP source license; system BSD library |
| `shmop`, `sysvmsg`, `sysvsem`, `sysvshm` | PHP's bundled Unix IPC modules | PHP source license |
| `xsl` | PHP XSL + macOS system libxslt/libxml2 | PHP source license; system libraries |
| `zstd` | php-ext-zstd 0.18.0 + private static Zstandard | MIT; Zstandard BSD |

Exact source URLs and SHA-256 digests live in
`ManagedPHPExtensionBundle.swift` and `ManagedPHPParityDependencies.swift`.
Each packaged release records these inputs in `licenses/grove-sources.json`
and preserves its exact Swift build recipes in `licenses/grove-build-recipe`.
No Herd runtime binaries are used.

## Capability boundaries

ImageMagick supports the built-in formats and private PNG/JPEG/WebP,
FreeType, bzip2, zlib, and Zstandard delegates. Optional external programs
such as Ghostscript and extra TIFF/HEIC/RAW delegates are not included.
MongoDB uses OpenSSL and compression; optional SASL and client-side encryption
libraries are not included.

The SQL Server PHP modules load without a separate driver. Connecting to SQL
Server additionally requires Microsoft's ODBC Driver for SQL Server and its
separate license terms. Grove does not bundle that proprietary driver or accept
its EULA for the user. This is also a
[documented Herd requirement](https://herd.laravel.com/docs/macos/troubleshooting/odbc-drivers).
The embedded unixODBC manager reads system driver configuration under `/etc`,
not a Homebrew build prefix.

Microsoft officially supports PHP 8.3+ in the 5.13 driver series. Grove tests
5.13.3 on PHP 8.2 as well because older 5.12 releases lack subsequent encoding
memory-safety and connection-pool fixes. This additional compatibility coverage
does not extend Microsoft's support policy. See
[Microsoft's release notes](https://github.com/microsoft/msphpsql/releases/tag/v5.13.1).

IMAP is legacy compatibility: the
[upstream PHP IMAP repository](https://github.com/php/pecl-mail-imap)
is archived. The pinned c-client fork provides OpenSSL compatibility. Grove
tests ordinary certificate-verified TLS 1.2 and TLS 1.3 locally.

## Source, notices, and relinking

The additional static LGPL libraries' complete, unmodified source archives
ship at `licenses/libraries/sources/gettext-0.26.tar.xz` and
`licenses/libraries/sources/unixODBC-2.3.14.tar.gz`, alongside their notices.
The build compiles only libintl and unixODBC's libraries into PHP; their
command-line tools are not included in the downloaded runtime.

Every release also publishes a separate `grove-php-<version>-<arch>-relink.tar.gz`
artifact at a content-addressed `releases/php-source/<version>/<arch>/<sha256>/`
URL. Its adjacent JSON descriptor records the archive hash, byte count, source
revision, and object key. This is a developer artifact, outside Grove's ordinary
runtime download. It contains the actual configured PHP and extension source,
link objects, complete private static library/header prefix, exact generated
Makefile, library source archives, license notices, input-file checksums, and
original payload-file checksums. It does not depend on retaining the original
release machine's build directory.

Extract the kit and follow its README to run `relink.py prepare` in a new path,
`relink.py rebuild-library gettext` or `unixodbc`, and `relink.py link`. The
prepare command relocates build metadata; library rebuilds retain local source
edits and install privately. Alternatively replace a compatible `.a` archive
under `libraries/lib` and relink. The resulting CLI/FPM engines remain separate
from installed Grove runtimes. The kit needs Apple's developer tools and Python
for custom rebuilds, with no Homebrew or network dependency. Ordinary Grove
users still download ready-to-run packages without developer tools.

The [public Grove runtime builder](https://github.com/ysrdevs/grove-runtime-builds)
preserves the full source recipe and mandatory per-variant kit-production step.
Use its verification checks before adopting modified binaries.

## Verification

The release gate requires all 17 module names and exercises actual FFI,
ImageMagick PNG resizing, IMAP MIME decoding, LDAP escaping, MongoDB BSON,
Zstandard/LZ4 compression round trips, XSL transformation, DBA file
read/write, SQL Server registration, and Unix API availability.
Existing gates still check all previous modules/network capabilities,
system-only Mach-O dependencies, native architecture, exact optional-module
versions, PHP-FPM startup, and actual Xdebug/SPX profile generation.

Independent dependency probes verified both SQL Server modules on PHP
8.2.33, 8.3.33, 8.4.26, and 8.5.11 on Apple Silicon and Intel/Rosetta.
All load in CLI and FPM and report the expected separate-driver requirement
on a connection attempt without Microsoft's driver. ARM and Intel IMAP probes
cover all four PHP versions, real TLS 1.2/1.3 login/logout, and ordinary certificate
verification. These isolated probes do not by themselves constitute a
published complete runtime or a real SQL Server integration test.

The complete ARM PHP 8.4.26 build passed the release recipe's existing
capability/CLI/FPM checks, all added native API probes, and real Xdebug/SPX
profile generation. Exact module versions were rechecked after applying
Imagick's upstream package-version substitution. Remaining release variants
must pass the same gates before publication.
