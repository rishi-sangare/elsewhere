#!/usr/bin/env bash
# Downloads the pinned idevice XCFramework (MIT, github.com/jkcoxson/idevice)
# and verifies its checksum. Needed only for real-iPhone builds; Simulator
# development works without it.
set -euo pipefail
VERSION="v0.1.68"
SHA256="c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor/IDevice"
ZIP="$DEST/idevice-xcframework-$VERSION.zip"

mkdir -p "$DEST"
if [ -d "$DEST/IDevice.xcframework" ]; then
  echo "IDevice.xcframework already present"; exit 0
fi
echo "Downloading idevice $VERSION…"
curl -fL --progress-bar -o "$ZIP" \
  "https://github.com/jkcoxson/idevice/releases/download/$VERSION/idevice-xcframework-$VERSION.zip"
echo "$SHA256  $ZIP" | shasum -a 256 -c -
TMP="$(mktemp -d)"
unzip -q "$ZIP" -d "$TMP"
mv "$TMP/swift/IDevice.xcframework" "$DEST/"
rm -rf "$TMP" "$ZIP"
echo "Done → Vendor/IDevice/IDevice.xcframework"
