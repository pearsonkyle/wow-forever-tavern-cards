#!/usr/bin/env bash
# Builds dist/TavernCards-<version>.zip with only what WoW loads: the .toc, the files it lists and
# Textures/ (plus Libs/ licences). Usage: bash .github/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-$(sed -n 's/^## Version: *//p' TavernCards.toc)}"
stage="$(mktemp -d)/TavernCards"
mkdir -p "$stage" dist
cp TavernCards.toc "$stage/"
sed -i.bak "s/^## Version: .*/## Version: $version/" "$stage/TavernCards.toc" && rm -f "$stage/TavernCards.toc.bak"
grep -E '\.lua\s*$' TavernCards.toc | tr -d '\r' | sed 's#\\#/#g' | while read -r f; do
  mkdir -p "$stage/$(dirname "$f")"
  cp "$f" "$stage/$f"
done
mkdir -p "$stage/Textures" && cp Textures/*.tga "$stage/Textures/"
find Libs -iname '*licen*' -o -iname 'README*' | while read -r f; do mkdir -p "$stage/$(dirname "$f")"; cp "$f" "$stage/$f"; done
cp README.md "$stage/" 2>/dev/null || true
[ -f LICENSE ] && cp LICENSE "$stage/"
out="dist/TavernCards-$version.zip"
rm -f "$out"
(cd "$(dirname "$stage")" && zip -qr "$OLDPWD/$out" TavernCards)
echo "package: $out ($(du -h "$out" | cut -f1))"
