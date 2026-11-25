#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo "Requires Apple Silicon macOS."; exit 1; }
stage=$(mktemp -d /tmp/quickunzip-mac-deps.XXXXXX)
trap 'rm -rf "$stage"' EXIT
fetch() {
  curl -fL --retry 3 "$1" -o "$stage/$2"
  printf '%s  %s\n' "$3" "$stage/$2" | shasum -a 256 -c -
}
if [[ ! -x Vendor/7zip/7zz ]]; then
  fetch https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac.tar.xz 7zip.tar.xz b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd
  tar -xf "$stage/7zip.tar.xz" -C "$stage" 7zz
  install -m 755 "$stage/7zz" Vendor/7zip/7zz
fi
if [[ ! -x Vendor/rare/runtime/bin/python ]]; then
  fetch https://github.com/astral-sh/python-build-standalone/releases/download/20261124/cpython-3.12.16%2B20261124-aarch64-apple-darwin-install_only_stripped.tar.gz python.tar.gz 9d6d9d0d85feda3f9cb4eb3e048f0fed21ed280feda087927eaa4fbc7124826f
  tar -xf "$stage/python.tar.gz" -C "$stage"
  mkdir -p Vendor/rare/runtime
  ditto --norsrc --noextattr "$stage/python" Vendor/rare/runtime
fi
python3 scripts/build_rare.py
