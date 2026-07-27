#!/usr/bin/env bash
#
# Manual deploy of the web build to a gh-pages branch.
#
# Use this if you would rather not run GitHub Actions, or to push a build
# without committing source. The Actions workflow in .github/workflows does the
# same thing automatically on every push to main.
#
#   ./tools/deploy_web.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

REMOTE_URL="$(git config --get remote.origin.url || true)"
if [ -z "$REMOTE_URL" ]; then
  echo "error: no git remote named 'origin'." >&2
  echo "       add one first:  git remote add origin git@github.com:USER/REPO.git" >&2
  exit 1
fi

REPO_NAME="$(basename -s .git "$REMOTE_URL")"

echo "==> building for /$REPO_NAME/"
# base-href must match the served subpath, or every asset 404s and the page
# loads blank.
flutter build web --release --base-href "/$REPO_NAME/"

# Pages runs Jekyll by default, which drops paths starting with an underscore.
touch build/web/.nojekyll

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging"
cp -R build/web/. "$STAGE/"

cd "$STAGE"
git init -q
git checkout -qb gh-pages
git add -A
git -c user.email=deploy@local -c user.name=deploy commit -qm "deploy $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git remote add origin "$REMOTE_URL"

echo "==> pushing gh-pages (force; this branch holds only build output)"
git push -f origin gh-pages

USER_NAME="$(basename "$(dirname "$REMOTE_URL")" | sed 's/.*://')"
echo
echo "done. Set Pages source to the gh-pages branch, then it will be at:"
echo "  https://${USER_NAME}.github.io/${REPO_NAME}/"
