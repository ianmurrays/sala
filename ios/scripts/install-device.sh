#!/bin/sh
# Build Sala and install it on a connected device: scripts/install-device.sh "<device name>"
# Signing comes from Config/Local.xcconfig (see Config/Local.example.xcconfig).
set -eu
device=${1:?usage: $0 "<device name, as in xcrun devicectl list devices>"}
cd "$(dirname "$0")/.."
[ -f Config/Local.xcconfig ] || { echo "Config/Local.xcconfig missing: copy Config/Local.example.xcconfig and set your team" >&2; exit 1; }
xcodegen generate --quiet
dd=build/DerivedData
xcodebuild -project Sala.xcodeproj -scheme Sala -configuration Debug \
  -destination "platform=iOS,name=$device" -derivedDataPath "$dd" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
xcrun devicectl device install app --device "$device" "$dd/Build/Products/Debug-iphoneos/Sala.app"
