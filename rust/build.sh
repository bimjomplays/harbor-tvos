#!/bin/sh
# Builds libharbor_ffi.a for the Apple TV and its simulator into rust/out/<PLATFORM_NAME>/.
set -eu
cd "$(dirname "$0")/harbor-ffi"
for pair in "aarch64-apple-tvos appletvos" "aarch64-apple-tvos-sim appletvsimulator"; do
  set -- $pair
  rustup target add "$1" >/dev/null
  cargo build --release --target "$1"
  mkdir -p "../out/$2"
  cp "target/$1/release/libharbor_ffi.a" "../out/$2/"
done
