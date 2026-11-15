#!/bin/sh
# Numéro de build : entier qui augmente de 1 quand le code source a changé depuis le build précédent.
# Le compteur est commun au serveur (ServeIPA) et au client (ServeIPAClient). Il est conservé dans
# .build-number (empreinte des sources, numéro, date du build) et écrit dans le Info.plist du produit :
#   CFBundleVersion  = numéro de build
#   ServeIPABuildDate = date (ISO 8601) du build qui a produit ce numéro
set -e

state="${PROJECT_DIR}/.build-number"
plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

hash=$(cd "$PROJECT_DIR" && find ServeIPA ServeIPAClient Configuration -type f \
    \( -name '*.swift' -o -name '*.plist' -o -name '*.xcstrings' -o -name '*.entitlements' \) -print0 \
    | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1)

last_hash=""
number=0
stamp=""
if [ -f "$state" ]; then
    read -r last_hash number stamp < "$state" || true
fi

if [ "$hash" != "$last_hash" ] || [ -z "$stamp" ]; then
    [ "$hash" != "$last_hash" ] && number=$((number + 1))
    stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$hash $number $stamp" > "$state"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $number" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $number" "$plist"
/usr/libexec/PlistBuddy -c "Set :ServeIPABuildDate $stamp" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :ServeIPABuildDate string $stamp" "$plist"
