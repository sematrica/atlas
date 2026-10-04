#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp="$(mktemp -d /tmp/atlas-libzim.XXXXXX)"
trap 'rm -rf "$task_tmp"' EXIT
version=9.8.2-1
for architecture in arm64 x86_64; do
  name="libzim_macos-${architecture}-${version}"
  curl --fail --location --proto '=https' --tlsv1.2 "https://download.openzim.org/release/libzim/$name.tar.gz" -o "$task_tmp/$name.tar.gz"
  if [[ "$architecture" == arm64 ]]; then
    expected=46da5c485d7ba4ad419d55d031c493ce8996e070edaa622203b5e1dde90b2442
  else
    expected=55986239e453bd7fdc77f67d1acc006d896662ad63b17c7e345f49e17363bc40
  fi
  actual="$(shasum -a 256 "$task_tmp/$name.tar.gz" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "Checksum mismatch: $name" >&2; exit 1; }
  tar -xzf "$task_tmp/$name.tar.gz" -C "$task_tmp"
done
mkdir -p Vendor/libzim/include Vendor/libzim/lib
cp -R "$task_tmp/libzim_macos-arm64-$version/include/zim" Vendor/libzim/include/
lipo -create "$task_tmp/libzim_macos-arm64-$version/lib/libzim.9.dylib" "$task_tmp/libzim_macos-x86_64-$version/lib/libzim.9.dylib" -output Vendor/libzim/lib/libzim.9.dylib
install_name_tool -id '@rpath/libzim.9.dylib' Vendor/libzim/lib/libzim.9.dylib
ln -sf libzim.9.dylib Vendor/libzim/lib/libzim.dylib
codesign --force --sign - Vendor/libzim/lib/libzim.9.dylib
