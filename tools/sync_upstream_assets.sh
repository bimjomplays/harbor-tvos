#!/bin/sh
# Copies the upstream assets the TV app bundles verbatim (paths must match upstream's URLs).
set -eu
cd "$(dirname "$0")/.."
rm -rf App/Upstream && mkdir -p App/Upstream
cp -R reference/harbor/public/avatars App/Upstream/avatars
mkdir -p App/Upstream/kids && cp -R reference/harbor/public/kids/avatars App/Upstream/kids/avatars
# Kids mode art (views/kids*, kids/play): sea doodles, franchise cut-outs, the wordmark wheel and
# the hero sea (kidsbg.png is the raster twin of kidbgsvg.svg; tvOS cannot draw the SVGs).
cp -R reference/harbor/public/kids/doodles App/Upstream/kids/doodles
cp -R reference/harbor/public/kids/cta App/Upstream/kids/cta
cp reference/harbor/public/kids/wheel.png reference/harbor/public/kids/kidsbg.png App/Upstream/kids/
# Top 10 ribbon art (bp-card-state-marks.tsx).
mkdir -p App/Upstream/marks && cp reference/harbor/public/toptabl.png reference/harbor/public/toptabr.png App/Upstream/marks/
# Stream format badges (components/format-badge.tsx SRC; the picker rows draw them).
mkdir -p App/Upstream/badges && cp reference/harbor/src/assets/badges/*.png reference/harbor/src/assets/badges/*.webp App/Upstream/badges/
# Offline awards catalog (4 MB JSON), handed to the engine on first use.
mkdir -p App/Engine && cp reference/harbor/src/data/awards.json App/Engine/awards.json
