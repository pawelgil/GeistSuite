#!/bin/zsh
set -euo pipefail

fixture_root="${0:A:h}"
package_root="${fixture_root:h:h:h:h}"
work_root="$(mktemp -d /tmp/geistsck-client-verify.XXXXXX)"
cleanup() {
  find "$work_root" -depth -delete
}
trap cleanup EXIT

fixture_copy="$work_root/ScreenCaptureKitClient"
framework_root="$work_root/Frameworks"
mkdir -p "$fixture_copy" "$framework_root"
ditto "$fixture_root" "$fixture_copy"

/bin/sh "$package_root/GeistCore/Scripts/build-screen-capture-kit.sh" \
  "$work_root/ScreenCaptureKit.framework.zip" "$package_root"
ditto -x -k "$work_root/ScreenCaptureKit.framework.zip" "$framework_root"

configuration="$work_root/ScreenCaptureKit.xcconfig"
printf '%s\n' \
  "FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = \$(inherited) \"$framework_root\"" \
  "LD_RUNPATH_SEARCH_PATHS[sdk=iphonesimulator*] = \$(inherited) \"$framework_root\"" \
  > "$configuration"

xcodegen generate --spec "$fixture_copy/project.yml" --project "$fixture_copy" --quiet
XCODE_XCCONFIG_FILE="$configuration" xcodebuild \
  -project "$fixture_copy/ScreenCaptureKitClient.xcodeproj" \
  -scheme ScreenCaptureKitClient \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work_root/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build
