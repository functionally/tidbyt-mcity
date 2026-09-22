#!/usr/bin/env bash
# Render one frame to out.webp.
#   ./scripts/render.sh          → out.webp (what the device receives)
#   ./scripts/render.sh --look   → look.gif at 10x, for eyeballing the layout
# The 10x GIF is the quickest way to catch a clipped column or an
# overflowing label; see design-notes.md ("Checking the layout").
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--look" ]]; then
  pixlet render main.star --gif -m 10 -o look.gif
  echo "Rendered: $PWD/look.gif (64x32 magnified 10x)"
else
  pixlet render main.star -o out.webp
  echo "Rendered: $PWD/out.webp"
fi
