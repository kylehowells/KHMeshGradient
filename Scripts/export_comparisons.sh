#!/bin/bash
set -euo pipefail

# Supply the UDID of an already booted simulator running iOS 18 or later.
# Build the example first, then run this from any directory.
simulator_id="${1:?Usage: export_comparisons.sh SIMULATOR_UDID}"
repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id="com.kylehowells.KHMeshGradientExample"
app_path="$repository_dir/DerivedData/Build/Products/Debug-iphonesimulator/KHMeshGradientExample.app"

xcrun simctl install "$simulator_id" "$app_path"
xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
container_dir="$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)"
source_dir="$container_dir/Documents/Comparisons"
rm -f "$source_dir/manifest.json"
xcrun simctl launch "$simulator_id" "$bundle_id" --export-comparisons

for attempt in {1..30}; do
	if [[ -f "$source_dir/manifest.json" ]]; then
		mkdir -p "$repository_dir/Documentation/Comparisons/raw"
		cp "$source_dir/"*.png "$source_dir/manifest.json" "$repository_dir/Documentation/Comparisons/raw/"
		cd "$repository_dir"
		python3 Scripts/make_contact_sheet.py Documentation/Comparisons/raw
		exit 0
	fi
	sleep 1
done
echo "Comparison export did not complete. Inspect the example app's console." >&2
exit 1
