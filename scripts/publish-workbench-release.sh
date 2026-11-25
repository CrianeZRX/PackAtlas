#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 ]]; then
  printf 'Usage: %s <tag> <artifact-directory>\n' "$0" >&2
  exit 2
fi

tag=$1
artifacts=$2
version=$(python3 -c 'import json; print(json.load(open("Workbench/package.json"))["version"])')
if [[ "$tag" != "v$version" ]]; then
  printf 'Tag %s does not match Workbench/package.json version %s (expected v%s).\n' "$tag" "$version" "$version" >&2
  exit 1
fi

if draft=$(gh release view "$tag" --json isDraft --jq '.isDraft' 2>/dev/null); then
  if [[ "$draft" == false ]]; then
    printf 'Release %s is already published. Leaving it unchanged.\n' "$tag"
    exit 0
  fi
  printf 'Release %s already has a draft. Review it before publishing or retrying.\n' "$tag" >&2
  exit 1
fi

shopt -s nullglob
assets=()
require_asset() {
  local label=$1
  shift
  if [[ $# -ne 1 ]] || [[ ! -f "$1" || ! -s "$1" ]]; then
    printf 'Expected exactly one nonempty %s installer in %s.\n' "$label" "$artifacts" >&2
    exit 1
  fi
  assets+=("$1")
}
require_asset 'macOS arm64 .pkg' "$artifacts/PackAtlas-macOS-arm64/PackAtlas-${version}-macOS-arm64.pkg"
require_asset 'Windows x64 setup .exe' "$artifacts/PackAtlas-windows-x64/PackAtlas-${version}-windows-setup-x64.exe"
require_asset 'Windows x64 portable .exe' "$artifacts/PackAtlas-windows-x64/PackAtlas-${version}-windows-portable-x64.exe"
require_asset 'Ubuntu x64 .deb' "$artifacts/PackAtlas-ubuntu-x64/"*.deb
require_asset 'Ubuntu x64 .AppImage' "$artifacts/PackAtlas-ubuntu-x64/"*.AppImage

options=(--verify-tag --generate-notes --title "PackAtlas $version")
if [[ "${version%%+*}" == *-* ]]; then
  options+=(--prerelease)
fi
gh release create "$tag" "${options[@]}" "${assets[@]}"
