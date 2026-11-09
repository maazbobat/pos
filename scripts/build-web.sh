#!/usr/bin/env bash
# Builds the web apps for one environment: ./scripts/build-web.sh <dev|staging|prod> [app ...]
# Apps default to the three on Hosting: online, manager, admin.
set -euo pipefail
cd "$(dirname "$0")/.."
env="${1:?usage: scripts/build-web.sh <dev|staging|prod> [app ...]}"
shift
apps=("$@")
[ ${#apps[@]} -eq 0 ] && apps=(online manager admin)
config="$PWD/config/$env.json"
[ -f "$config" ] || { echo "No config/$env.json" >&2; exit 2; }
[ "$(node scripts/env.mjs ready "$env")" = true ] || { node scripts/env.mjs check --ready "$env"; exit 1; }
for app in "${apps[@]}"; do
  echo "== Building apps/$app for $env"
  (cd "apps/$app" && flutter build web --release --dart-define-from-file="$config")
done
