#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
xcodebuild -project JapaneseReader.xcodeproj -scheme JapaneseReader -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
mkdir -p build/package/Payload
cp -R build/Build/Products/Release-iphoneos/JapaneseReader.app build/package/Payload/
python3 - <<'PY'
import plistlib
from pathlib import Path
info = plistlib.loads(Path('build/package/Payload/JapaneseReader.app/Info.plist').read_bytes())
assert info['UIFileSharingEnabled'] is True, 'Files sharing must be enabled'
assert info['LSSupportsOpeningDocumentsInPlace'] is True
assert info['MinimumOSVersion'] == '17.4'
assert info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'] == 'AppIcon'
print('PASS: packaged iPhone Files integration, OS version, and icon')
PY
(cd build/package && ditto -c -k --keepParent Payload ../JapaneseReader.ipa)
echo "Built: ios/build/JapaneseReader.ipa (unsigned; sign with AltStore or your Apple account)"
