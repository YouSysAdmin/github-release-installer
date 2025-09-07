# GitHub Release Installer Script

A portable POSIX shell script to download, verify, and install (or launch) prebuilt binaries from a GitHub project’s Releases.

## Features

- Works with any GitHub repository that ships binaries in releases.
- Supports installation into a directory (~/.bin by default).
- Supports launch mode: download/cache & run directly without permanent install.
- Validates downloads with SHA-256 checksums (per-asset or manifest files).
- Works on Linux and macOS (amd64/arm64).
- Requires only a POSIX shell and either curl or wget.

## Usage

```sh
install.sh [-b bindir] [-d] [-l] [tag] [-- tool-args...]

  -b    installation directory (default: ~/.bin)
  -d    enable debug logging
  -l    launch mode (run tool directly from cache, no install)

[tag]  release tag (e.g. v1.2.3). If omitted, "latest" is used.

--     everything after `--` is passed directly to the tool
```

## Config
You can fully customize the script for your project and save it in your repository.

```sh
###############################################################################
# Config (override via env)
###############################################################################

# GitHub repository owner/organization
: "${OWNER:=example}"

# GitHub repository name
: "${REPO:=example-repo}"

# Project name used in asset filenames
# Example: "example" → "example-v1.2.3-linux-amd64"
: "${PROJECT_NAME:=example}"

# Executable name inside archive or raw release
# Example: "example" → binary is called "example"
: "${BINARY:=example}"

# Archive format (controls how assets are unpacked)
# Supported: tar.gz | tgz | zip | tar | bin (for raw binaries without archive)
: "${FORMAT:=tar.gz}"

# Template for asset base filename
# Placeholders:
#   {project} → project name (e.g. "mytool")
#   {tag}     → release tag (e.g. "v1.2.3")
#   {os}      → OS name (e.g. "linux", "darwin", "windows")
#   {arch}    → architecture (e.g. "amd64", "arm64")
# Example result: "mytool-v1.2.3-linux-amd64"
[ -z "${NAME_TEMPLATE+x}" ] && NAME_TEMPLATE='{project}-{tag}-{os}-{arch}'

# Template for checksum filename
# Placeholders:
#   {asset}   → full asset filename (e.g. "mytool-v1.2.3-linux-amd64.tar.gz")
#   {ext}     → asset extension (e.g. "tar.gz", "zip", "bin")
#   {project}, {tag}, {os}, {arch} → same as above
# Example result: "mytool-v1.2.3-linux-amd64.tar.gz.sha256"
[ -z "${CHECKSUM_TEMPLATE+x}" ] && CHECKSUM_TEMPLATE='{asset}.sha256'

# Space-separated list of fallback manifest checksum files
# Used if a per-asset checksum file is not found in the release.
# Common names:
#   SHA256SUMS
#   SHA256SUMS.txt
#   checksums.txt
#   checksums.sha256
: "${CHECKSUM_FALLBACKS:=SHA256SUMS SHA256SUMS.txt checksums.txt checksums.sha256}"

# List of supported platform combinations (GOOS/GOARCH).
# The script checks the current system against this list and errors if not found.
#
# Minimal defaults (most common targets):
#   darwin/amd64   → macOS Intel
#   darwin/arm64   → macOS Apple Silicon
#   linux/amd64    → Linux x86_64
#   linux/arm64    → Linux ARM64 (e.g. AWS Graviton, Raspberry Pi 64-bit)
#
# Example extended list:
#   linux/386 linux/ppc64 linux/ppc64le linux/s390x
#   freebsd/386 freebsd/amd64 freebsd/arm freebsd/arm64
#   openbsd/386 openbsd/amd64 openbsd/arm openbsd/arm64
#   netbsd/386 netbsd/amd64 netbsd/arm netbsd/arm64
#   dragonfly/amd64
#   windows/386 windows/amd64 windows/arm windows/arm64
#   solaris/amd64 plan9/386 plan9/amd64
#
# Extend this list if your project provides more builds.
: "${SUPPORTED_PLATFORMS:=darwin/amd64 darwin/arm64 linux/amd64 linux/arm64}"

# Directory where cached files are stored in launch mode.
# Defaults to $TMPDIR/ghrel-cache or /tmp/ghrel-cache.
: "${CACHE_ROOT:=${TMPDIR:-/tmp}/gh-rel-installer-cache}"
```

## Examples

Install the latest release into ~/.bin:

```sh
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/master/scripts/install.sh | bash
```

Install a specific version:

```sh
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/master/scripts/install.sh | sudo bash -s -- v1.2.3

# install to /usr/local/bin
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/master/scripts/install.sh | sudo bash -s -- -b /usr/local/bin v1.2.3
```

Launch the latest release without installing:

```sh
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/master/scripts/install.sh | bash -s -- -l
```

Launch a specific version and pass flags to the tool:

```sh
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/master/scripts/install.sh | bash -s -- -l v2.0.0 -- --help
```

Real examples:

JC2AWS (https://github.com/YouSysAdmin/jc2aws)

```sh
curl -fsSL https://raw.githubusercontent.com/YouSysAdmin/github-release-installer/main/install.sh \
  | OWNER=YouSysAdmin REPO=jc2aws PROJECT_NAME=jc2aws BINARY=jc2aws bash -s -- -l -- -h
```

Headscale-PF (https://github.com/YouSysAdmin/headscale-pf)

```sh
curl -fsSL https://raw.githubusercontent.com/YouSysAdmin/github-release-installer/main/install.sh \
  | OWNER=YouSysAdmin REPO=headscale-pf PROJECT_NAME=headscale-pf NAME_TEMPLATE='{project}_{tag}_{os}_{arch}' BINARY=headscale-pf bash -s -- -l -- -h
```

## Environment Variables

These can be overridden to adapt the script for any project:

| Variable              | Description                                                                                              | Default                                             |
| --------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `OWNER`               | GitHub repository owner/organization                                                                     | _required_                                          |
| `REPO`                | GitHub repository name                                                                                   | _required_                                          |
| `PROJECT_NAME`        | Project name used in asset filenames                                                                     | same as `REPO`                                      |
| `BINARY`              | Executable name inside archive or raw release                                                            | same as `PROJECT_NAME`                              |
| `FORMAT`              | Archive format (`tar.gz`, `tgz`, `zip`, `tar`, or `bin` for raw binaries)                                | `tar.gz`                                            |
| `NAME_TEMPLATE`       | Template for asset base name, placeholders: `{project}`, `{tag}`, `{os}`, `{arch}`                       | `{project}-{tag}-{os}-{arch}`                       |
| `CHECKSUM_TEMPLATE`   | Template for checksum filename; placeholders: `{asset}`, `{ext}`, `{project}`, `{tag}`, `{os}`, `{arch}` | `{asset}.sha256`                                    |
| `CHECKSUM_FALLBACKS`  | Space-separated list of manifest filenames to try if per-asset checksum missing                          | `SHA256SUMS SHA256SUMS.txt checksums.txt`           |
| `SUPPORTED_PLATFORMS` | Space-separated list of supported GOOS/GOARCH combos                                                     | `darwin/amd64 darwin/arm64 linux/amd64 linux/arm64` |
| `CACHE_ROOT`          | Directory where cached files are stored in launch mode                                                   | `${TMPDIR:-/tmp}/ghrel-cache`                       |
| `BINDIR`              | Installation directory when using install mode (`-b` flag overrides too).                                | `$HOME/.bin`                                        |

## Notes

- Supports both per-asset checksum files (e.g. tool-v1.2.3-linux-amd64.tar.gz.sha256) and manifest checksum files (e.g. SHA256SUMS).
- In launch mode, binaries are cached and reused until the checksum fails, at which point they are re-downloaded.
- Interactive tools (that read from stdin) work even when piping the installer, thanks to automatic TTY reattachment.
