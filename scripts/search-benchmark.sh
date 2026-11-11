#!/bin/zsh
# Times the search on made-up windows, apps and settings pages, built with the optimiser on as the app is. It prints
# a line for each case and, given a path, writes the numbers there as JSON. Nothing is judged: times on a shared
# build machine vary too much to fail a build over, so this is for reading.
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$PWD/.build"
mkdir -p "$build_dir"
"$(xcrun --find swiftc)" -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$build_dir/ModuleCache" -O \
    Sources/Core.swift Sources/PreferencesExtras.swift Sources/Interaction.swift Sources/Search.swift Sources/MenuBarCore.swift Tests/SearchBenchmark.swift \
    -o "$build_dir/SearchBenchmark"
"$build_dir/SearchBenchmark" "$@"
