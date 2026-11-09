#!/bin/zsh
# 开发用：编译后用示例窗口截取每个设置页和切换面板（浅色、深色各一套），保存在 ui-snapshots 文件夹。
# 只截一瞥自己的窗口，背后垫一张示意背景，不会录下屏幕上的其他内容。
cd "$(dirname "$0")/.."
zsh ./build-and-log.command
grep -q "^EXIT=0" build.log || { echo "编译失败，详见 build.log"; exit 1; }
out="$PWD/ui-snapshots"
mkdir -p "$out"; rm -f "$out/done.txt"
open -n "$PWD/Glance.app" --args --restart --ui-snapshots "$out"
for i in {1..120}; do test -f "$out/done.txt" && break; sleep 1; done
cat "$out/done.txt" 2>/dev/null || echo "没有等到截图完成。"
echo "截图结束，可以关闭这个窗口。"
