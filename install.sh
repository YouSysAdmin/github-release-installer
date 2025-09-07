#!/bin/sh
set -e

#
# GitHub Release Installer
# https://github.com/YouSysAdmin/github-release-installer
#
# A portable POSIX shell script to download, verify (SHA-256),
# install, or launch binaries from GitHub Releases.
#
# License: MIT (see LICENSE file)
#

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

###############################################################################
# Help
###############################################################################
usage() {
  this=$1
  cat <<EOF
$this: download binaries from GitHub Releases and install or launch.

Usage: $this [-b bindir] [-d] [-l] [tag] [-- tool-args...]
  -b    installation directory (default: ~/.bin)
  -d    debug logging
  -l    launch mode: download/cache & run binary directly (no install)

Env overrides:
  OWNER REPO PROJECT_NAME BINARY FORMAT NAME_TEMPLATE CHECKSUM_TEMPLATE CHECKSUM_FALLBACKS
  SUPPORTED_PLATFORMS CACHE_ROOT
EOF
  exit 2
}

###############################################################################
# Utils / logging
###############################################################################
is_command() { command -v "$1" >/dev/null 2>&1; }
echoerr() { echo "$@" 1>&2; }

_logp=6
log_set_priority() { _logp="$1"; }
log_ok() { [ -n "$1" ] && [ "$1" -le "$_logp" ]; }
log_tag() { case $1 in 0)echo emerg;;1)echo alert;;2)echo crit;;3)echo err;;4)echo warning;;5)echo notice;;6)echo info;;7)echo debug;;*)echo "$1";; esac; }
log_prefix() { echo "$OWNER/$REPO"; }
log_debug() { log_ok 7 || return 0; echoerr "$(log_prefix)" "$(log_tag 7)" "$@"; }
log_info()  { log_ok 6 || return 0; echoerr "$(log_prefix)" "$(log_tag 6)" "$@"; }
log_err()   { log_ok 3 || return 0; echoerr "$(log_prefix)" "$(log_tag 3)" "$@"; }
log_crit()  { log_ok 2 || return 0; echoerr "$(log_prefix)" "$(log_tag 2)" "$@"; }

uname_os()  { os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'); [ "$os" = "msys_nt" ] && os="windows"; echo "$os"; }
uname_arch(){
  arch=$(uname -m 2>/dev/null)
  case $arch in x86_64)arch=amd64;; x86|i686|i386)arch=386;; aarch64)arch=arm64;;
    armv5*)arch=armv5;; armv6*)arch=armv6;; armv7*)arch=armv7;; esac
  echo "$arch"
}

is_archive_format(){ case "$1" in tar.gz|tgz|zip|tar) return 0;; *) return 1;; esac; }

untar(){
  case "$1" in
    *.tar.gz|*.tgz) tar -xzf "$1" ;;
    *.tar)          tar -xf  "$1" ;;
    *.zip)          unzip -q "$1" ;;
    *) log_err "Unknown archive format: $1"; return 1 ;;
  esac
}

mktmpdir(){ if is_command mktemp; then d=$(mktemp -d) || true; fi; [ -z "$d" ] && d="${TMPDIR:-/tmp}/ghrel.$$.$RANDOM" && mkdir -p "$d"; echo "$d"; }

# HTTP helpers (fail on non-200)
http_download_curl() {
  out=$1; url=$2; hdr=$3

  # Silence curl's stderr so 404s don't spam the console.
  # We still capture the HTTP code and return non-zero on failure.
  if [ -z "$hdr" ]; then
    code=$(curl -w '%{http_code}' -fsSL -o "$out" "$url" 2>/dev/null || true)
  else
    code=$(curl -w '%{http_code}' -fsSL -H "$hdr" -o "$out" "$url" 2>/dev/null || true)
  fi
  [ "$code" = "200" ]
}
http_download_wget() {
  out=$1; url=$2; hdr=$3
  if [ -z "$hdr" ]; then wget -q -O "$out" "$url"
  else                   wget -q --header "$hdr" -O "$out" "$url"
  fi
}
http_download() {
  log_debug "GET $2"
  if is_command curl; then http_download_curl "$@" || return 1
  elif is_command wget; then http_download_wget "$@" || return 1
  else log_crit "Need curl or wget"; return 1
  fi
}

http_copy() {
  tmp=$(mktmpdir)/body
  http_download "$tmp" "$1" "$2" || return 1
  cat "$tmp"; rm -f "$tmp"
}

# Try to fetch a checksum file with user-friendly logs
try_checksum_download() {
  url=$1      # full URL to checksum file
  name=$2     # the checksum filename we are trying (for logs)
  dst=$3      # destination path for the downloaded file

  log_info "looking for checksum file: ${name}"
  if http_download "$dst" "$url" ""; then
    # basic sanity: must be at least a sha256 length
    if [ "$(wc -c < "$dst")" -ge 32 ]; then
      log_info "found checksum file: ${name}"
      return 0
    else
      log_debug "checksum candidate too small: ${name} ($url)"
      return 1
    fi
  else
    log_debug "not found: ${url}"
    return 1
  fi
}

github_release(){
  owner_repo=$1; version=$2; [ -z "$version" ] && version="latest"
  if [ "$version" = "latest" ]; then
    url="https://github.com/${owner_repo}/releases/${version}"
    json=$(http_copy "$url" "Accept:application/json")
  else
    url_v="https://github.com/${owner_repo}/releases/v${version##v}"
    url_nv="https://github.com/${owner_repo}/releases/${version##v}"
    json=$(http_copy "$url_v" "Accept:application/json" || http_copy "$url_nv" "Accept:application/json")
  fi
  [ -z "$json" ] && return 1
  tag=$(echo "$json" | tr -d '\n' | sed 's/.*"tag_name":"//' | sed 's/".*//')
  [ -z "$tag" ] && return 1
  echo "$tag"
}

hash_sha256(){
  TARGET=${1:-/dev/stdin}
  if   is_command gsha256sum; then gsha256sum "$TARGET" | awk '{print $1}'
  elif is_command sha256sum;  then sha256sum  "$TARGET" | awk '{print $1}'
  elif is_command shasum;     then shasum -a 256 "$TARGET" 2>/dev/null | awk '{print $1}'
  elif is_command openssl;    then openssl dgst -sha256 "$TARGET" | awk '{print $2}'
  else log_crit "Need sha256sum/shasum/openssl"; return 1; fi
}

###############################################################################
# Templates
###############################################################################
render_name() {
  _tmpl=$1 _project=$2 _tag=$3 _os=$4 _arch=$5
  echo "$_tmpl" | sed \
    -e "s/{project}/$_project/g" -e "s/{tag}/$_tag/g" \
    -e "s/{os}/$_os/g" -e "s/{arch}/$_arch/g"
}
render_checksum_name() {
  _tmpl=$1 _asset=$2 _ext=$3 _project=$4 _tag=$5 _os=$6 _arch=$7
  echo "$_tmpl" | sed \
    -e "s/{asset}/$_asset/g" -e "s/{ext}/$_ext/g" \
    -e "s/{project}/$_project/g" -e "s/{tag}/$_tag/g" \
    -e "s/{os}/$_os/g" -e "s/{arch}/$_arch/g"
}

###############################################################################
# Args (preserve tool args exactly)
###############################################################################
BINDIR=${BINDIR:-"$HOME/.bin"}
MODE="install"; TAG=""; TOOL_ARGS_Q=""

quote_for_eval() { # outputs into global TOOL_ARGS_Q
  TOOL_ARGS_Q=""
  for a in "$@"; do
    b=$(printf "%s" "$a" | sed "s/'/'\\\\''/g")
    TOOL_ARGS_Q="$TOOL_ARGS_Q '$b'"
  done
}

parse_args() {
  while getopts "b:dlh?" arg; do
    case "$arg" in
      b) BINDIR="$OPTARG" ;;
      d) log_set_priority 10 ;;
      l) MODE="launch" ;;
      h|\?) usage "$0" ;;
    esac
  done
  shift $((OPTIND - 1))
  case "${1:-}" in ""|--|-*) : ;; * ) TAG="$1"; shift ;; esac
  [ "${1:-}" = "--" ] && shift
  # Store quoted copy of remaining args for faithful reconstruction later
  quote_for_eval "$@"
}
parse_args "$@"

###############################################################################
# Platform / tag
###############################################################################
OS=$(uname_os); ARCH=$(uname_arch); PLATFORM="${OS}/${ARCH}"
echo "$SUPPORTED_PLATFORMS" | tr ' ' '\n' | grep -qx "$PLATFORM" || { log_crit "unsupported platform: $PLATFORM"; exit 1; }

REALTAG=$(github_release "$OWNER/$REPO" "${TAG:-latest}") || { log_crit "cannot resolve tag '${TAG:-latest}'"; exit 1; }
log_info "resolved version: $REALTAG for $PLATFORM"

###############################################################################
# Asset naming & URLs
###############################################################################
ASSET_BASE=$(render_name "$NAME_TEMPLATE" "$PROJECT_NAME" "$REALTAG" "$OS" "$ARCH")
if is_archive_format "$FORMAT"; then ASSET_FILE="${ASSET_BASE}.${FORMAT}"; ASSET_EXT="$FORMAT"; else ASSET_FILE="${ASSET_BASE}"; ASSET_EXT="bin"; fi

BASE_DL="https://github.com/${OWNER}/${REPO}/releases/download/${REALTAG}"
TARBALL_URL="${BASE_DL}/${ASSET_FILE}"

# Build checksum candidates (primary + fallbacks)
CS_PRIMARY=$(render_checksum_name "$CHECKSUM_TEMPLATE" "$ASSET_FILE" "$ASSET_EXT" "$PROJECT_NAME" "$REALTAG" "$OS" "$ARCH")
CS_CANDIDATES="$CS_PRIMARY"
if [ "$CHECKSUM_TEMPLATE" != "{asset}.sha256" ]; then
  CS_ALT=$(render_checksum_name '{asset}.sha256' "$ASSET_FILE" "$ASSET_EXT" "$PROJECT_NAME" "$REALTAG" "$OS" "$ARCH")
  CS_CANDIDATES="$CS_CANDIDATES $CS_ALT"
fi
if [ "$CHECKSUM_TEMPLATE" != "{asset}.{ext}.sha256" ]; then
  CS_LEGACY=$(render_checksum_name '{asset}.{ext}.sha256' "$ASSET_FILE" "$ASSET_EXT" "$PROJECT_NAME" "$REALTAG" "$OS" "$ARCH")
  CS_CANDIDATES="$CS_CANDIDATES $CS_LEGACY"
fi
CS_CANDIDATES="$CS_CANDIDATES $CHECKSUM_FALLBACKS"

###############################################################################
# Cache
###############################################################################
CACHE_DIR="${CACHE_ROOT}/${OWNER}/${REPO}/${REALTAG}/${OS}-${ARCH}"
CACHED_TARBALL="${CACHE_DIR}/${ASSET_FILE}"
CACHED_BIN="${CACHE_DIR}/${BINARY}"
ensure_cache(){ mkdir -p "$CACHE_DIR"; }
ensure_cache

###############################################################################
# Binary discovery
###############################################################################
find_binary_in_dir() {
  base=$1
  if [ -x "${base}/${BINARY}" ]; then echo "${base}/${BINARY}"; return 0; fi
  for p in $(find "$base" -type f 2>/dev/null); do
    [ -x "$p" ] || continue
    bn=$(basename "$p")
    [ "$bn" = "$BINARY" ] && { echo "$p"; return 0; }
    [ -n "$PROJECT_NAME" ] && [ "$bn" = "$PROJECT_NAME" ] && { echo "$p"; return 0; }
    case "$bn" in "$PROJECT_NAME"-*|"$BINARY"-*) echo "$p"; return 0;; esac
  done
  p=$(find "$base" -type f -perm -111 2>/dev/null | head -n1)
  [ -n "$p" ] && { echo "$p"; return 0; }
  return 1
}

###############################################################################
# Download + checksums
###############################################################################
download_with_checksums() {
  out_asset=$1
  out_sum=$2

  log_info "downloading asset: ${ASSET_FILE}"
  if ! http_download "$out_asset" "$TARBALL_URL" ""; then
    log_crit "failed to download asset: ${TARBALL_URL}"
    log_info "tip: ensure NAME_TEMPLATE/FORMAT match the release asset naming"
    log_info "     tried platform: ${PLATFORM}, tag: ${REALTAG}"
    return 1
  fi

  # Try per-asset checksum first (primary + alternates), then fall back to manifests.
  # We'll log every candidate we try so the user sees what's happening.
  for cs in $CS_CANDIDATES; do
    url="${BASE_DL}/${cs}"
    if try_checksum_download "$url" "$cs" "$out_sum"; then
      CHECKSUM_FILE_USED="$cs"
      return 0
    fi
  done

  log_crit "no usable checksum found"
  log_info "tried: $CS_CANDIDATES"
  log_info "tip: add the correct manifest name to CHECKSUM_FALLBACKS if your project uses a custom filename"
  return 1
}

verify_checksum_file() {
  target=$1; sums=$2
  if grep -Eq "[[:space:]]\*?${ASSET_FILE}\$" "$sums" 2>/dev/null; then
    want=$(grep -E "[[:space:]]\*?${ASSET_FILE}\$" "$sums" | awk '{print $1; exit}')
  else
    want=$(awk '{print $1; exit}' "$sums")
  fi
  [ -n "$want" ] || { log_err "checksum file lacks entry for ${ASSET_FILE}"; return 1; }

  got=$(hash_sha256 "$target") || return 1
  [ "$want" = "$got" ] || { log_err "checksum mismatch: want=$want got=$got"; return 1; }
}

###############################################################################
# Actions
###############################################################################
execute_install() {
  tmp=$(mktmpdir)
  dst_asset="${tmp}/${ASSET_FILE}"
  dst_sum="${tmp}/checksums.txt"

  download_with_checksums "$dst_asset" "$dst_sum" || exit 1
  verify_checksum_file "$dst_asset" "$dst_sum" || exit 1

  install -d "$BINDIR"
  if is_archive_format "$FORMAT"; then
    ( cd "$tmp" && untar "$ASSET_FILE" )
    binpath=$(find_binary_in_dir "$tmp") || true
    [ -n "$binpath" ] || { log_crit "binary '${BINARY}' not found in archive"; exit 1; }
    install "$binpath" "$BINDIR/"
  else
    chmod +x "$dst_asset" 2>/dev/null || true
    install "$dst_asset" "$BINDIR/$BINARY"
  fi
  log_info "installed $BINDIR/$BINARY"
}

unpack_to_cache() {
  if is_archive_format "$FORMAT"; then
    ( cd "$CACHE_DIR" && untar "$CACHED_TARBALL" )
    binpath=$(find_binary_in_dir "$CACHE_DIR") || true
    [ -n "$binpath" ] || { log_crit "cannot locate an executable in archive"; exit 1; }
    chmod +x "$binpath" 2>/dev/null || true
    [ "$binpath" = "$CACHED_BIN" ] || cp -f "$binpath" "$CACHED_BIN"
  else
    cp -f "$CACHED_TARBALL" "$CACHED_BIN"
    chmod +x "$CACHED_BIN" 2>/dev/null || true
  fi
}

execute_launch() {
  if [ -x "$CACHED_BIN" ]; then
    log_info "using cached binary: $CACHED_BIN"
  else
    dst_asset="$CACHED_TARBALL"
    dst_sum="${CACHE_DIR}/checksums.txt"

    if [ ! -f "$dst_asset" ] || [ ! -f "$dst_sum" ]; then
      download_with_checksums "$dst_asset" "$dst_sum" || exit 1
    fi
    if ! verify_checksum_file "$dst_asset" "$dst_sum"; then
      log_info "cached asset checksum failed; re-downloading"
      download_with_checksums "$dst_asset" "$dst_sum" || exit 1
      verify_checksum_file "$dst_asset" "$dst_sum" || exit 1
    fi

    unpack_to_cache
    [ -x "$CACHED_BIN" ] || { log_crit "extracted binary not executable"; exit 1; }
  fi

  log_info "launching: $CACHED_BIN (args preserved)"
  # Reconstruct argv faithfully
  if [ -n "$TOOL_ARGS_Q" ]; then
    eval "set -- $TOOL_ARGS_Q"
  else
    set --
  fi

  # If our stdin isn't a TTY (e.g., piped), reattach to the terminal so '-i' works
  if [ ! -t 0 ] && [ -r /dev/tty ]; then
    exec "$CACHED_BIN" "$@" < /dev/tty > /dev/tty 2>&1
  else
    exec "$CACHED_BIN" "$@"
  fi
}

###############################################################################
# Run
###############################################################################
if [ "$MODE" = "launch" ]; then
  execute_launch
else
  execute_install
fi
