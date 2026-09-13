#!/bin/bash
# Build both signed rootless binaries before packaging.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build packages
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -isysroot "$sdk_path" \
  -arch arm64 -arch arm64e -miphoneos-version-min=16.0 \
  -dynamiclib -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
  -framework Foundation \
  -install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/MutedRead.dylib \
  MutedRead.m -o build/MutedRead.dylib
codesign --force --sign - --timestamp=none build/MutedRead.dylib
codesign --verify --strict build/MutedRead.dylib
xcrun lipo build/MutedRead.dylib -verify_arch arm64 arm64e
mkdir -p build/Preferences.framework
cat > build/Preferences.framework/Preferences.tbd <<'TBD'
--- !tapi-tbd-v3
archs: [ arm64, arm64e ]
platform: ios
install-name: /System/Library/PrivateFrameworks/Preferences.framework/Preferences
exports:
  - archs: [ arm64, arm64e ]
    objc-classes: [ PSViewController ]
...
TBD
xcrun --sdk iphoneos clang -isysroot "$sdk_path" -arch arm64 -arch arm64e -miphoneos-version-min=16.0 \
  -dynamiclib -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -framework Foundation -framework UIKit \
  -Fbuild -framework Preferences -install_name /var/jb/Library/PreferenceBundles/MutedReadPrefs.bundle/MutedReadPrefs \
  prefs/MRRootController.m -o build/MutedReadPrefs
codesign --force --sign - --timestamp=none build/MutedReadPrefs
codesign --verify --strict build/MutedReadPrefs
xcrun lipo build/MutedReadPrefs -verify_arch arm64 arm64e
python3 package.py
