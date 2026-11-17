#!/bin/bash
set -e

# Navigate to the script's directory
cd "$(dirname "$0")"

# Go to the project root
cd ..

site_dir="${1:-}"
if [[ -n "$site_dir" ]]; then
    site_dir="$(realpath "$site_dir")"
    [[ -f "$site_dir/config.toml" ]] || { echo "Expected a Zola site checkout: $site_dir" >&2; exit 1; }
fi

python3 scripts/prepare_local_packages.py

echo "Building Flutter example app..."
cd legacy_gantt_chart/example
flutter pub get
# sqlite_crdt currently selects its native backend under Dart Wasm.
# Use its supported JavaScript/CanvasKit target for the persistent web demo.
flutter build web --release --base-href /demo/

cd ../..
if [[ -z "$site_dir" ]]; then
    echo "Demo built in legacy_gantt_chart/example/build/web. Pass a site checkout path to copy it for deployment."
    exit 0
fi

echo "Copying artifacts to $site_dir/static/demo..."
mkdir -p "$site_dir/static/demo"
rm -f "$site_dir/static/demo/main.dart.wasm" "$site_dir/static/demo/main.dart.mjs"
cp -r legacy_gantt_chart/example/build/web/* "$site_dir/static/demo/"

# Remove the Flutter-generated index.html so it doesn't overwrite our Zola page
rm "$site_dir/static/demo/index.html"

echo "Done!"
