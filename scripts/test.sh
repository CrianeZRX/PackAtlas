#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test -j 2 --scratch-path .build --cache-path .build/spm-cache \
  --config-path .build/spm-config --security-path .build/spm-security --disable-sandbox "$@"
