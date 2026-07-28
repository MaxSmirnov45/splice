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
# Leaderboard credentials come from the environment, not the repository:
#
#   export SUPABASE_URL=https://xxxx.supabase.co
#   export SUPABASE_ANON_KEY=sb_publishable_...
#
# Without them the build is perfectly playable but has no scoreboard, and says
# so nowhere — which is how portal bundles shipped without one while the
# GitHub Pages workflow, the only place the credentials were wired up, had it.
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

SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}"
if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
  echo "==> WARNING: no SUPABASE_URL / SUPABASE_ANON_KEY — building WITHOUT a leaderboard" >&2
else
  echo "==> leaderboard: $SUPABASE_URL"
fi

# --pwa-strategy=none: no service worker.
#
# Flutter's default registers one that caches the whole app, so a browser that
# has run the game before keeps serving the previous main.dart.js after an
# update. On a portal that means a freshly uploaded build tests as though the
# fix were never made — and players stay on a stale version after every
# release. There is nothing to gain here in exchange: the game is loaded from
# inside someone else's page, which is online by definition.
flutter build web --release --base-href "$BASE" \
  --pwa-strategy=none \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"

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

# Emitted even with --pwa-strategy=none, and never referenced. Removing it
# saves a file slot against the portal's limit and, more usefully, stops
# anyone concluding from its presence that a service worker is still in play.
rm -f "$OUT/flutter_service_worker.js"

touch "$OUT/.nojekyll"

if [ "$TARGET" != "pages" ]; then
  ZIP="build/splice-$TARGET.zip"
  rm -f "$ZIP"
  # Excludes macOS metadata and the incremental build marker: portals unpack
  # the archive as-is, and a .DS_Store in a game bundle is somebody's desktop
  # state shipped to strangers.
  (cd "$OUT" && zip -qr "../../$ZIP" . \
      -x '.DS_Store' '*/.DS_Store' '.last_build_id')
  echo "==> $ZIP  ($(du -h "$ZIP" | cut -f1))"
fi

echo "==> done"
