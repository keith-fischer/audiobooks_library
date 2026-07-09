#!/usr/bin/env bash
# Render every Mermaid source (*.mmd) in this directory to a PNG next to it.
# Requires Node (npx) — mermaid-cli + Chromium are fetched on first run.
#
#   ./images/render.sh
#
# PNG (not SVG) is used because it renders in every Markdown viewer, including
# JetBrains IDEs whose preview does not reliably display SVG. Edit a diagram by
# changing its .mmd, then re-run this to refresh the .png the docs embed.
set -euo pipefail
cd "$(dirname "$0")"

conf="$(mktemp)"; pptr="$(mktemp)"
printf '{"theme":"neutral","flowchart":{"htmlLabels":true,"useMaxWidth":false}}' > "$conf"
printf '{"args":["--no-sandbox"]}' > "$pptr"
trap 'rm -f "$conf" "$pptr"' EXIT

for f in *.mmd; do
  out="${f%.mmd}.png"
  echo "rendering $f -> $out"
  npx -y -p @mermaid-js/mermaid-cli mmdc -i "$f" -o "$out" -b white -s 3 -c "$conf" -p "$pptr"
done
echo "done: $(ls -1 *.png | wc -l | tr -d ' ') diagram(s)"
