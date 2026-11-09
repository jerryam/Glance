#!/bin/zsh
# 开发用：编译后让一瞥记录菜单栏在“辅助功能”里的结构，写入 menubar-probe.json。不会隐藏任何图标。
cd "$(dirname "$0")/.."
zsh ./build-and-log.command
grep -q "^EXIT=0" build.log || { echo "编译失败，详见 build.log"; exit 1; }
rm -f menubar-probe.json
open -n "$PWD/Glance.app" --args --restart --menubar-probe "$PWD/menubar-probe.json"
for i in {1..30}; do test -f menubar-probe.json && break; sleep 1; done
test -f menubar-probe.json && echo "已写入 menubar-probe.json" || echo "没有等到结果。"
