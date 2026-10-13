#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="${ATLAS_BUILD_DIR:-/tmp/AtlasMechanicalBuild}"
products="$build_dir/Build/Products/Debug"
smoke_dir="/tmp/AtlasLayoutSmoke.app"
mkdir -p "$smoke_dir/Contents/MacOS"
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find Atlas -name '*.swift' ! -name AtlasApp.swift | sort)
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  -I "$products" -I Native/ZIMBridge/include \
  -Xcc "-fmodule-map-file=$build_dir/Build/Intermediates.noindex/GeneratedModuleMaps/ZIMBridge.modulemap" \
  "${sources[@]}" Tests/LayoutSmoke/LayoutSmoke.swift \
  "$products/AtlasCore.o" "$products/ZIMBridge.o" \
  -L Vendor/libzim/lib -lzim -lc++ -Xlinker -rpath -Xlinker "$PWD/Vendor/libzim/lib" \
  -o "$smoke_dir/Contents/MacOS/AtlasLayoutSmoke"
cat > "$smoke_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>AtlasLayoutSmoke</string><key>CFBundleIdentifier</key><string>com.atlas.layout-smoke</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
if [[ "${ATLAS_DENY_NETWORK:-0}" == "1" ]]; then
  sandbox-exec -p '(version 1)(allow default)(deny network*)' "$smoke_dir/Contents/MacOS/AtlasLayoutSmoke"
else
  "$smoke_dir/Contents/MacOS/AtlasLayoutSmoke"
fi
