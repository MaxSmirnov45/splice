#!/usr/bin/env bash
#
# Builds the web bundle for a specific host.
#
#   ./tools/build_web.sh pages        GitHub Pages  (absolute base href, no SDK)
#   ./tools/build_web.sh itch         itch.io etc.  (relative base href, no SDK)
#   ./tools/build_web.sh poki         Poki          (Poki SDK)
#   ./tools/build_web.sh crazygames   CrazyGames    (CrazyGames SDK)
#
# Two things differ per host and both fail silently if wrong:
#
#   base href — portals that take a zip serve it from an unpredictable path, so
#   the page must resolve assets relatively. An absolute href 404s every asset
#   and shows a blank screen with no error at all.
#
#   portal SDK — exactly one, or none. The game detects at runtime which is
#   present, so shipping the wrong script means the wrong integration with no
#   visible symptom until an ad is requested.
#
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-pages}"
OUT="build/web"
SRC="web/index.html"

case "$TARGET" in
  pages)      BASE="/$(basename "$(git config --get remote.origin.url 2>/dev/null || echo splice)" .git)/"; SDK=none ;;
  itch)       BASE="/"; SDK=none ;;
  poki)       BASE="/"; SDK=poki ;;
  crazygames) BASE="/"; SDK=crazygames ;;
  *) echo "usage: $0 {pages|itch|poki|crazygames}" >&2; exit 1 ;;
esac

echo "==> target=$TARGET  base=$BASE  sdk=$SDK"

# Keep the source file canonical: mutate, build, restore.
BACKUP="$(mktemp)"
cp "$SRC" "$BACKUP"
restore() { cp "$BACKUP" "$SRC"; rm -f "$BACKUP"; }
trap restore EXIT

python3 tools/portal_sdk.py "$SRC" "$SDK"

flutter build web --release --base-href "$BASE"

if [ "$TARGET" != "pages" ]; then
  python3 -c "
import sys
p = '$OUT/index.html'
s = open(p).read()
s = s.replace('<base href=\"/\">', '<base href=\"./\">')
open(p, 'w').write(s)
"
  echo "==> base href rewritten to ./"
fi

touch "$OUT/.nojekyll"

if [ "$TARGET" != "pages" ]; then
  ZIP="build/splice-$TARGET.zip"
  rm -f "$ZIP"
  (cd "$OUT" && zip -qr "../../$ZIP" .)
  echo "==> $ZIP  ($(du -h "$ZIP" | cut -f1))"
fi

echo "==> done"
