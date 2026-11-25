#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release -j 2 --scratch-path .build --cache-path .build/spm-cache \
  --config-path .build/spm-config --security-path .build/spm-security --disable-sandbox
BUILD_STAGE=$(mktemp -d /tmp/quickunzip-build.XXXXXX)
trap 'rm -rf "$BUILD_STAGE"' EXIT
APP="$BUILD_STAGE/QuickUnzip.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QuickUnzip "$APP/Contents/MacOS/QuickUnzip"
cp .build/release/qunzip "$APP/Contents/MacOS/qunzip"
mkdir -p "$APP/Contents/Resources/Tools" "$APP/Contents/Resources/Licenses"
install -m 755 Vendor/7zip/7zz "$APP/Contents/Resources/Tools/7zz"
cp Vendor/7zip/7zz-License.txt Vendor/7zip/7zz-readme.txt Vendor/7zip/copying.txt Vendor/7zip/SOURCE.txt "$APP/Contents/Resources/Licenses/"
ditto --norsrc --noextattr Vendor/rare "$APP/Contents/Resources/Rare"
cp Vendor/zpaq/COPYING "$APP/Contents/Resources/Licenses/ZPAQ.txt"
cp Vendor/alzbzip/LICENSE "$APP/Contents/Resources/Licenses/UnALZ.txt"
cp Vendor/rare/BZIP2-LICENSE.txt "$APP/Contents/Resources/Licenses/Bzip2.txt"
cp Vendor/lhasa/COPYING "$APP/Contents/Resources/Licenses/Lhasa.txt"
python3 scripts/make_plist.py "$APP/Contents/Info.plist"
swiftc scripts/make_icon.swift -o .build/make-icon
.build/make-icon "$PWD/.build/AppIcon.iconset"
python3 scripts/pack_icon.py .build/AppIcon.iconset "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
for tool in "$APP"/Contents/Resources/Rare/bin/* "$APP"/Contents/Resources/Rare/runtime/bin/python "$APP"/Contents/Resources/Rare/runtime/lib/python3.12/lib-dynload/*; do
  codesign --force --sign - --timestamp=none "$tool"
done
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/Tools/7zz"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/qunzip"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$PWD/dist"
# Package a clean build so older decoder files cannot enter the installer.
PAYLOAD="$BUILD_STAGE/payload"
mkdir -p "$PAYLOAD"
ditto --norsrc --noextattr "$APP" "$PAYLOAD/QuickUnzip.app"
pkgbuild --analyze --root "$PAYLOAD" "$BUILD_STAGE/component.plist"
python3 - "$BUILD_STAGE/component.plist" <<'PYCONFIG'
from pathlib import Path
import plistlib, sys
config = Path(sys.argv[1])
bundles = plistlib.loads(config.read_bytes())
for bundle in bundles:
    bundle["BundleIsRelocatable"] = False
config.write_bytes(plistlib.dumps(bundles))
PYCONFIG
PKG=QuickUnzip-2.3-macOS-arm64.pkg
pkgbuild --root "$PAYLOAD" --component-plist "$BUILD_STAGE/component.plist" \
  --identifier app.quickunzip.mac.installer --version 2.3.0 --install-location /Applications \
  "$BUILD_STAGE/$PKG"
cp "$BUILD_STAGE/$PKG" "$PWD/dist/$PKG"
# Replace the generated bundle as a unit, excluding files left by older builds.
NEXT=$(mktemp -d "$PWD/dist/quickunzip-stage.XXXXXX")
ditto --norsrc --noextattr "$APP" "$NEXT/QuickUnzip.app"
if [ -d "$PWD/dist/QuickUnzip.app" ]; then mv "$PWD/dist/QuickUnzip.app" "$NEXT/previous.app"; fi
if ! mv "$NEXT/QuickUnzip.app" "$PWD/dist/QuickUnzip.app"; then
  if [ -d "$NEXT/previous.app" ]; then mv "$NEXT/previous.app" "$PWD/dist/QuickUnzip.app"; fi
  exit 1
fi
rm -rf "$NEXT"
printf 'Built: %s\n' "$PWD/dist/$PKG"
