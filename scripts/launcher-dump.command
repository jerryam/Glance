#!/bin/zsh
# 开发用：列出搜索能打开的应用和系统设置页面数量，以及几个示例搜索的结果，写入 launcher-dump.json。
cd "$(dirname "$0")/.."
rm -f launcher-dump.json
open -n "$PWD/Glance.app" --args --restart --launcher-dump "$PWD/launcher-dump.json"
for i in {1..30}; do test -f launcher-dump.json && break; sleep 1; done
test -f launcher-dump.json && echo "已写入 launcher-dump.json" || echo "没有等到结果。"
