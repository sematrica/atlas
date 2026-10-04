#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="${ATLAS_BUILD_DIR:-/tmp/AtlasStage2Build}"
products="$build_dir/Build/Products/Debug"
smoke_dir="/tmp/AtlasBrowserSmoke.app"
mkdir -p "$smoke_dir/Contents/MacOS"
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -swift-version 5 \
  -I "$products" -I Native/ZIMBridge/include \
  -Xcc "-fmodule-map-file=$build_dir/Build/Intermediates.noindex/GeneratedModuleMaps/ZIMBridge.modulemap" \
  Atlas/App/BrowserModel.swift Atlas/Crawler/*.swift Atlas/UI/OfflineWebView.swift Tests/BrowserSmoke/BrowserSmoke.swift \
  "$products/AtlasCore.o" "$products/ZIMBridge.o" \
  -L Vendor/libzim/lib -lzim -lc++ -Xlinker -rpath -Xlinker "$PWD/Vendor/libzim/lib" \
  -o "$smoke_dir/Contents/MacOS/AtlasBrowserSmoke"
cat > "$smoke_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>AtlasBrowserSmoke</string><key>CFBundleIdentifier</key><string>com.atlas.browser-smoke</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
if [[ "${ATLAS_DENY_NETWORK:-0}" == "1" ]]; then
  sandbox-exec -p '(version 1)(allow default)(deny network*)' "$smoke_dir/Contents/MacOS/AtlasBrowserSmoke"
else
  "$smoke_dir/Contents/MacOS/AtlasBrowserSmoke"
fi
