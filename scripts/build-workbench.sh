#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
for dependency in Vendor/7zip/7zz Vendor/rare/runtime/bin/python Vendor/rare/bin/zpaq; do
  if [[ ! -x $dependency ]]; then
    echo "Missing ${dependency}. Run bash scripts/prepare-workbench-mac.sh first." >&2
    exit 1
  fi
done
swift build -c release -j 2 --product QuickUnzipWorkbench --scratch-path .build --cache-path .build/spm-cache \
  --config-path .build/spm-config --security-path .build/spm-security --disable-sandbox
swift build -c release -j 2 --product qunzip --scratch-path .build --cache-path .build/spm-cache \
  --config-path .build/spm-config --security-path .build/spm-security --disable-sandbox
stage=$(mktemp -d /tmp/quickunzip-workbench.XXXXXX)
trap 'rm -rf "$stage"' EXIT
bundle='PackAtlas.app'
app="$stage/payload/$bundle"
contents="$app/Contents"
mkdir -p "$contents"/{MacOS,Resources/{Licenses,Tools,Workbench}}
cp .build/release/QuickUnzipWorkbench "$contents/MacOS/PackAtlas"
cp .build/release/qunzip "$contents/MacOS/qunzip"
ditto --norsrc --noextattr Workbench/ui "$contents/Resources/Workbench"
ditto --norsrc --noextattr Vendor/rare "$contents/Resources/Rare"
install -m 755 Vendor/7zip/7zz "$contents/Resources/Tools/7zz"
cp Vendor/7zip/{7zz-License.txt,7zz-readme.txt,copying.txt,SOURCE.txt} "$contents/Resources/Licenses/"
cp Vendor/zpaq/COPYING "$contents/Resources/Licenses/ZPAQ.txt"
cp Vendor/lhasa/COPYING "$contents/Resources/Licenses/Lhasa.txt"
cp Vendor/alzbzip/LICENSE "$contents/Resources/Licenses/UnALZ.txt"
python3 scripts/make_plist.py "$contents/Info.plist" --workbench
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/make_packatlas_icon.swift -o "$stage/make-icon"
"$stage/make-icon" "$stage/AppIcon.iconset"
python3 scripts/pack_icon.py "$stage/AppIcon.iconset" "$contents/Resources/AppIcon.icns"
xattr -cr "$app"
find "$contents/Resources/Rare" -type f -print0 | while IFS= read -r -d '' file; do
  case "$(file -b "$file")" in
    *Mach-O*) codesign --force --sign - --timestamp=none "$file" ;;
  esac
done
codesign --force --sign - --timestamp=none "$contents/Resources/Tools/7zz"
codesign --force --sign - --timestamp=none "$contents/MacOS/qunzip"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
mkdir -p dist/Workbench
out="dist/Workbench/PackAtlas-3.0.0-preview.1-macOS-arm64.pkg"
pkgbuild --analyze --root "$stage/payload" "$stage/components.plist"
python3 - "$stage/components.plist" <<'PY2'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1])
components = plistlib.loads(p.read_bytes())
for item in components:
    item["BundleIsRelocatable"] = False
p.write_bytes(plistlib.dumps(components))
PY2
pkgbuild --root "$stage/payload" --component-plist "$stage/components.plist" --identifier app.packatlas.desktop.installer \
    --version 3.0.0 --install-location /Applications "$stage/workbench.pkg"
cp "$stage/workbench.pkg" "$out"
printf '%s\n' "$out"
