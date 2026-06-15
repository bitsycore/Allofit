#!/usr/bin/env bash
# Wraps Allofit.app into a compressed read-only DMG suitable for
# distribution from the GitHub Releases page. The DMG opens to a window
# with the .app and an /Applications symlink so the user can drag-install.
#
# Usage:
#     ./build-dmg.sh                 # rebuilds the .app first, then DMGs it
#     ./build-dmg.sh --skip-build    # assumes Allofit.app already exists
#     ALLOFIT_VERSION=1.0.0 ./build-dmg.sh
#
# Output: Allofit-<version>.dmg in the project root.
set -euo pipefail

kAppName="Allofit"
kVersion="${ALLOFIT_VERSION:-0.0.0}"

vProjectRoot="$(cd "$(dirname "$0")" && pwd)"
vAppBundle="${vProjectRoot}/${kAppName}.app"
vDmgPath="${vProjectRoot}/${kAppName}-${kVersion}.dmg"
vStagingDir="${vProjectRoot}/.build/dmg-staging"

vSkipBuild=0
for vArg in "$@"; do
	case "$vArg" in
		--skip-build) vSkipBuild=1 ;;
		-h|--help)
			sed -n '2,/^set /p' "$0" | sed -E 's/^#( |$)//;/^set /d'
			exit 0
			;;
		*)
			echo "Unknown argument: $vArg" >&2
			exit 1
			;;
	esac
done

if [[ "$vSkipBuild" -eq 0 ]]; then
	echo "==> Rebuilding ${kAppName}.app first"
	"${vProjectRoot}/build-app.sh"
fi

if [[ ! -d "${vAppBundle}" ]]; then
	echo "Run ./build-app.sh first - ${kAppName}.app is missing" >&2
	exit 1
fi

echo "==> Staging DMG contents"
rm -rf "${vStagingDir}"
mkdir -p "${vStagingDir}"
# CoW-friendly copy that preserves bundle metadata, signatures, etc.
ditto "${vAppBundle}" "${vStagingDir}/${kAppName}.app"
# Drag-to-install convention: a symlink to /Applications next to the .app
ln -s /Applications "${vStagingDir}/Applications"

echo "==> Creating compressed DMG (UDZO)"
rm -f "${vDmgPath}"
hdiutil create \
	-volname "${kAppName} ${kVersion}" \
	-srcfolder "${vStagingDir}" \
	-ov \
	-format UDZO \
	"${vDmgPath}" >/dev/null

# ad-hoc sign so Gatekeeper doesn't add an extra layer of confusion when
# the user double-clicks the .dmg. The .app inside is already signed.
echo "==> Ad-hoc code signing the DMG"
codesign --force --sign - "${vDmgPath}" 2>/dev/null || true

echo
echo "Built ${vDmgPath}"
echo "Mount with:  open \"${vDmgPath}\""
