#!/bin/zsh
# Opens every settings page and the switcher panel in the built app, in light and dark, and saves a picture of each
# in ui-snapshots/, with a list of what the search can open on this Mac. A page that crashes the app, hangs it or
# cannot be drawn fails the check. It needs no permissions: without Screen Recording the app draws its own windows
# into the pictures. It quits every copy of 一瞥 running under this user, so it is for CI or a Mac not in use.
set -u
cd "$(dirname "$0")/.."
binary="$PWD/Glance.app/Contents/MacOS/Glance"
out="$PWD/ui-snapshots"

pkill -x Glance 2>/dev/null
sleep 1
rm -rf "$out"
mkdir -p "$out"

# Started directly rather than with `open`, so that what it prints can be kept.
"$binary" --ui-snapshots "$out" > "$out/app.log" 2>&1 &
sleep 3
tries=180
while (( tries-- > 0 )); do
    [[ -f "$out/done.txt" ]] && break
    pgrep -x Glance > /dev/null || break
    sleep 1
done
sleep 1
pkill -x Glance 2>/dev/null
sleep 1

if [[ ! -f "$out/done.txt" ]]; then
    echo "::error::the app stopped or hung before every picture was made"
    echo "--- pictures made so far"
    find "$out" -name '*.png' | sort
    echo "--- what the app printed"
    tail -40 "$out/app.log"
    echo "--- crash reports"
    ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i glance | head -5
    exit 1
fi
cat "$out/done.txt"
pictures=$(find "$out" -name '*.png' | wc -l | tr -d ' ')
echo "pictures: $pictures"
if grep -q '^missing: ' "$out/done.txt"; then
    echo "::error::some pictures could not be made"
    exit 1
fi
if (( pictures == 0 )); then
    echo "::error::no pictures were made"
    exit 1
fi

# What the search can open here, and how a few searches rank, with real app names and the system's real pinyin.
"$binary" --launcher-dump "$out/launcher-dump.json" > /dev/null 2>&1 &
tries=30
while (( tries-- > 0 )); do
    [[ -f "$out/launcher-dump.json" ]] && break
    sleep 1
done
pkill -x Glance 2>/dev/null
[[ -f "$out/launcher-dump.json" ]] || echo "::warning::the list of what the search can open was not written"

echo "UI snapshots: every picture was made"
