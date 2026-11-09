#!/bin/zsh
# 开发用：用已编译的一瞥把指针移到一个有窗口的应用（默认访达）的 Dock 图标上，再移到预览上、移开，
# 检查 Dock 预览是否按时出现、停留和关闭。结果和两张预览截图写入 dock-preview-test/。指针最后回到原处。
cd "$(dirname "$0")/.."
rm -rf dock-preview-test; mkdir -p dock-preview-test
open -n "$PWD/Glance.app" --args --restart --dock-preview-selftest "$PWD/dock-preview-test" --dock-preview-log "$PWD/dock-preview-test/dock-preview.log" "$@"
for i in {1..40}; do test -f dock-preview-test/dock-preview-report.json && break; sleep 1; done
test -f dock-preview-test/dock-preview-report.json && echo "已写入 dock-preview-test/" || echo "没有等到结果。"
