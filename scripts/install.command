#!/bin/zsh
# 把刚编译好的 Glance.app 安装到“应用程序”文件夹：旧版移到废纸篓（可以从那里放回），
# 然后从“应用程序”启动新版，由它接替正在运行的一瞥。结果写入 install.log。
cd "$(dirname "$0")/.."
exec > >(tee install.log) 2>&1
test -d Glance.app || { echo "还没有编译，请先运行 build-and-log.command。"; exit 1; }
codesign --verify --deep --strict Glance.app || { echo "Glance.app 签名检查没有通过，没有安装。"; exit 1; }
target=/Applications/Glance.app
if test -d "$target"; then
  old=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null)
  name="Glance-${old:-旧版}-$(date +%H%M%S).app"
  mv "$target" "$HOME/.Trash/$name" || { echo "无法移走旧版，没有安装。"; exit 1; }
  echo "旧版 ${old} 已移到废纸篓：$name"
fi
ditto Glance.app "$target" || { echo "复制失败。"; exit 1; }
new=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
echo "已安装 $new 到 $target"
open -n "$target" --args --restart
echo "已从“应用程序”启动。"
