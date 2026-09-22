#!/bin/sh
# Copies the upstream assets the TV app bundles verbatim (paths must match upstream's URLs).
set -eu
cd "$(dirname "$0")/.."
rm -rf App/Upstream && mkdir -p App/Upstream
cp -R reference/harbor/public/avatars App/Upstream/avatars
mkdir -p App/Upstream/kids && cp -R reference/harbor/public/kids/avatars App/Upstream/kids/avatars
