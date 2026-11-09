#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
build_dir="$PWD/.build"
bundle_path="$PWD/Glance.app"
mkdir -p "$build_dir" "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
compiler_path="$(xcrun --find swiftc)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
architecture="$(uname -m)"
common_flags=(-swift-version 5 -sdk "$sdk_path" -target "$architecture-apple-macos14.0" -module-cache-path "$build_dir/ModuleCache")
if ! test -f Resources/AppIcon.icns; then
    "$compiler_path" "${common_flags[@]}" Resources/Icon.swift -o "$build_dir/IconBuilder"
    "$build_dir/IconBuilder" "$build_dir/AppIcon.iconset"
    iconutil -c icns "$build_dir/AppIcon.iconset" -o Resources/AppIcon.icns
fi
"$compiler_path" "${common_flags[@]}" Sources/Core.swift Sources/PreferencesExtras.swift Sources/Interaction.swift Sources/Search.swift Sources/MenuBarCore.swift Tests/CoreTests.swift -o "$build_dir/CoreTests"
"$build_dir/CoreTests"
# The Objective-C bridge to the macOS 27 menu bar interface (see Sources/Bridge/MenuBarBridge.h).
xcrun clang -c -fobjc-arc -fmodules -Wall -Wextra -Werror -O2 -target "$architecture-apple-macos14.0" -isysroot "$sdk_path" \
    Sources/Bridge/MenuBarBridge.m -o "$build_dir/MenuBarBridge.o"
"$compiler_path" "${common_flags[@]}" -O Sources/*.swift -import-objc-header Sources/Bridge/MenuBarBridge.h "$build_dir/MenuBarBridge.o" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices -framework ScreenCaptureKit -framework Carbon -framework ServiceManagement \
    -o "$bundle_path/Contents/MacOS/Glance"
rm -f "$bundle_path/Contents/MacOS/WindowHop"
cp Resources/Info.plist "$bundle_path/Contents/Info.plist"
if test -f Resources/AppIcon.icns; then cp Resources/AppIcon.icns "$bundle_path/Contents/Resources/AppIcon.icns"; fi
# Finder and Spotlight show 一瞥 on Chinese systems and Glance elsewhere.
for region in zh-Hans en; do
    mkdir -p "$bundle_path/Contents/Resources/$region.lproj"
    cp "Resources/$region.lproj/InfoPlist.strings" "$bundle_path/Contents/Resources/$region.lproj/InfoPlist.strings"
done

# On macOS 26 and later the app icon is a layered Liquid Glass icon (Resources/AppIcon.icon), and the
# app's accent colour is amber. Both are compiled by Xcode's actool; without Xcode, the flat
# AppIcon.icns is used everywhere and the system accent colour applies.
rm -f "$bundle_path/Contents/Resources/Assets.car"
if actool_path="$(xcrun --find actool 2>/dev/null)"; then
    if "$actool_path" Resources/AppIcon.icon Resources/Assets.xcassets --compile "$bundle_path/Contents/Resources" \
        --platform macosx --target-device mac --minimum-deployment-target 14.0 \
        --app-icon AppIcon --accent-color AccentColor --include-all-app-icons \
        --enable-on-demand-resources NO --development-region zh_CN \
        --output-partial-info-plist "$build_dir/assetcatalog_generated_info.plist" \
        --output-format human-readable-text --errors --warnings > "$build_dir/actool.log" 2>&1 \
        && test -f "$bundle_path/Contents/Resources/Assets.car"; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" -c "Add :NSAccentColorName string AccentColor" "$bundle_path/Contents/Info.plist"
        # macOS 14 and 15 keep the hand-drawn icon.
        cp Resources/AppIcon.icns "$bundle_path/Contents/Resources/AppIcon.icns"
        echo "Liquid Glass icon and accent colour: compiled"
    else
        echo "提示：液态玻璃图标未能编译，继续使用普通图标。"
    fi
    grep -v "^/\* com.apple.actool.compilation-results \*/" "$build_dir/actool.log" | grep -v "^$" | grep -v "^$bundle_path" || true
fi

# A stable signing identity keeps Accessibility and Screen Recording granted across rebuilds.
# Ad-hoc signing ("-") changes the code hash every build, so macOS forgets the permissions each time.
# The certificate keeps its original name so a certificate made before the rename keeps working.
identity="${GLANCE_SIGN_IDENTITY:-${WINDOWHOP_SIGN_IDENTITY:-WindowHop Local Signing}}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$identity\""; then
    codesign --force --sign "$identity" --identifier com.jethro.windowhop "$bundle_path"
    echo "Signed with: $identity"
else
    codesign --force --sign - --identifier com.jethro.windowhop "$bundle_path"
    echo "提示：当前为临时签名，每次重新编译后都要重新授权。"
    echo "      运行 ./scripts/create-signing-identity.sh 创建本机签名证书，之后编译会保留权限。"
fi
codesign --verify --deep --strict "$bundle_path"
echo "Built: $bundle_path"
