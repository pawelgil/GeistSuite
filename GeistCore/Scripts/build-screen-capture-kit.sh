#!/bin/sh
set -eu

output_zip="$1"
package_root="$2"
work_root="${output_zip%.zip}.work"
framework="$work_root/ScreenCaptureKit.framework"
device_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
source_framework="$device_sdk/System/Library/Frameworks/ScreenCaptureKit.framework"

if [ ! -d "$source_framework/Headers" ]; then
    echo "error: ScreenCaptureKit iOS headers require Xcode 27 or newer" >&2
    exit 1
fi

rm -rf "$work_root"
trap 'rm -rf "$work_root"' EXIT HUP INT TERM
mkdir -p "$framework/Headers" "$framework/Modules/ScreenCaptureKit.swiftmodule" "$work_root/Objects"
cp -R "$source_framework/Headers/." "$framework/Headers/"
cp "$source_framework/Modules/module.modulemap" "$framework/Modules/module.modulemap"

cat > "$framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScreenCaptureKit</string>
<key>CFBundleIdentifier</key><string>com.apple.ScreenCaptureKit</string>
<key>CFBundleName</key><string>ScreenCaptureKit</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>27.0</string>
</dict></plist>
PLIST

for arch in arm64 x86_64; do
    target="$arch-apple-ios27.0-simulator"
    objects="$work_root/Objects/$arch"
    mkdir -p "$objects"
    for source in "$package_root"/GeistCast/Sources/ScreenCaptureKitSimulator/*.m; do
        name="$(basename "$source" .m)"
        xcrun --sdk iphonesimulator clang \
            -arch "$arch" -target "$target" -fobjc-arc -fmodules -Wno-availability \
            -F "$source_framework/.." \
            -I "$package_root/GeistCast/Sources/GeistScreenCaptureShimCore/include" \
            -I "$package_root/GeistCore/Sources/SharedShimCore/include" \
            -c "$source" -o "$objects/$name.o"
    done
    xcrun --sdk iphonesimulator clang -arch "$arch" -target "$target" \
        -I "$package_root/GeistCast/Sources/GeistScreenCaptureShimCore/include" \
        -c "$package_root/GeistCast/Sources/GeistScreenCaptureShimCore/FrameValidation.c" \
        -o "$objects/FrameValidation.o"
    xcrun --sdk iphonesimulator clang -arch "$arch" -target "$target" \
        -I "$package_root/GeistCore/Sources/SharedShimCore/include" \
        -c "$package_root/GeistCore/Sources/SharedShimCore/SocketIO.c" \
        -o "$objects/SocketIO.o"

    xcrun --sdk iphonesimulator swiftc \
        -target "$target" \
        -sdk "$simulator_sdk" \
        -F "$work_root" \
        -module-name ScreenCaptureKit \
        -swift-version 6 \
        -import-underlying-module \
        -enable-library-evolution \
        -parse-as-library \
        -emit-module \
        -emit-module-interface-path "$framework/Modules/ScreenCaptureKit.swiftmodule/$arch-apple-ios-simulator.swiftinterface" \
        -emit-module-path "$framework/Modules/ScreenCaptureKit.swiftmodule/$arch-apple-ios-simulator.swiftmodule" \
        -emit-object "$package_root/GeistCast/Sources/ScreenCaptureKitSimulator/Overlay.swift" \
        -o "$objects/Overlay.o"

    xcrun --sdk iphonesimulator swiftc \
        -target "$target" \
        -sdk "$simulator_sdk" \
        -emit-library \
        "$objects/"*.o \
        -framework Foundation \
        -framework UIKit \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework AudioToolbox \
        -Xlinker -install_name \
        -Xlinker @rpath/ScreenCaptureKit.framework/ScreenCaptureKit \
        -o "$objects/ScreenCaptureKit"
done

xcrun lipo -create \
    "$work_root/Objects/arm64/ScreenCaptureKit" \
    "$work_root/Objects/x86_64/ScreenCaptureKit" \
    -output "$framework/ScreenCaptureKit"

ditto -c -k --norsrc --keepParent "$framework" "$work_root/framework.zip"
mv -f "$work_root/framework.zip" "$output_zip"
