#!/bin/zsh
# 开发用：用已编译的一瞥临时隐藏一个菜单栏应用几秒钟，逐步检查“隐藏 / 显示 / 始终隐藏 / 显示全部”，
# 结果写入 menubar-selftest.json。不保存任何设置，结束后所有图标恢复原样。
cd "$(dirname "$0")/.."
rm -f menubar-selftest.json
open -n "$PWD/Glance.app" --args --restart --menubar-selftest "$PWD/menubar-selftest.json"
for i in {1..40}; do test -f menubar-selftest.json && break; sleep 1; done
test -f menubar-selftest.json && echo "已写入 menubar-selftest.json" || echo "没有等到结果。"
