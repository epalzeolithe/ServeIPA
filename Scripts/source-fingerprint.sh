#!/bin/sh
# Empreinte des sources de ServeIPA et ServeIPAClient, affichée sur la sortie standard.
# Utilisée par Scripts/build-number.sh (numéro de build) et par ServeIPA (mise à jour disponible).
# Couvre le code, les ressources (dont les icônes), la configuration, les scripts et le projet Xcode.
set -e
cd "${1:-$(dirname "$0")/..}"
find ServeIPA ServeIPAClient Configuration Scripts ServeIPA.xcodeproj/project.pbxproj \
    -type f ! -name .DS_Store -print0 \
    | LC_ALL=C sort -z | xargs -0 shasum | shasum | cut -d' ' -f1
