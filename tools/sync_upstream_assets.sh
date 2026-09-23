#!/bin/sh
# Copies the upstream assets the TV app bundles verbatim (paths must match upstream's URLs).
set -eu
cd "$(dirname "$0")/.."
rm -rf App/Upstream && mkdir -p App/Upstream
cp -R reference/harbor/public/avatars App/Upstream/avatars
mkdir -p App/Upstream/kids && cp -R reference/harbor/public/kids/avatars App/Upstream/kids/avatars
# Top 10 ribbon art (bp-card-state-marks.tsx).
mkdir -p App/Upstream/marks && cp reference/harbor/public/toptabl.png reference/harbor/public/toptabr.png App/Upstream/marks/
# Offline awards catalog (4 MB JSON), handed to the engine on first use.
mkdir -p App/Engine && cp reference/harbor/src/data/awards.json App/Engine/awards.json
