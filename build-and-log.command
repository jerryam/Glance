#!/bin/zsh
# Builds 一瞥 and writes the full output to build.log next to this file.
cd "$(dirname "$0")"
{
    # The system and toolchain, so a build log says what it was built with.
    echo "== $(date '+%Y-%m-%d %H:%M:%S')"
    sw_vers 2>/dev/null
    echo "SDK: $(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"
    xcrun swiftc --version 2>&1 | head -1
    echo "Developer dir: $(xcode-select -p 2>/dev/null)"
    echo "actool: $(xcrun --find actool 2>/dev/null || echo none)"
} > build.log 2>&1
zsh ./build.sh >> build.log 2>&1
echo "EXIT=$?" >> build.log
tail -5 build.log
echo "编译结束，可以关闭这个窗口。"
