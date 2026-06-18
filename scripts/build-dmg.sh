#!/usr/bin/env bash
# Wraps Allofit.app into a compressed read-only DMG suitable for
# distribution from the GitHub Releases page. The DMG opens to a window
# with the .app and an /Applications symlink so the user can drag-install.
#
# Can be called from anywhere - paths are resolved relative to the
# script's own location:
#     ./scripts/build-dmg.sh                       # from project root
#     scripts/build-dmg.sh --version 1.0.0
#     ./build-dmg.sh -v 1.0.0 --skip-build          # from scripts/
#     ALLOFIT_VERSION=1.0.0 ./scripts/build-dmg.sh  # env var still works
#
# Version precedence: --version arg > ALLOFIT_VERSION env > default 0.0.0.
# Output: <project root>/outputs/Allofit-<version>.dmg.
set -euo pipefail

kAppName="Allofit"

# Resolve the project root from the script's own location (scripts/..),
# so this script works regardless of the caller's CWD.
vProjectRoot="$(cd "$(dirname "$0")/.." && pwd)"
vOutputsDir="${vProjectRoot}/outputs"
vStagingDir="${vProjectRoot}/.build/dmg-staging"

mkdir -p "${vOutputsDir}"

# vAppBundle is set after kVersion is resolved below - the .app bundle's
# filename includes the version, so we can't construct the path until we
# know which version we're targeting.

# ==================
# MARK: Args
# ==================

vSkipBuild=0
vVersionArg=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--version|-v)
			if [[ $# -lt 2 ]]; then
				echo "$1 requires a value" >&2
				exit 1
			fi
			vVersionArg="$2"
			shift 2
			;;
		--skip-build)
			vSkipBuild=1
			shift
			;;
		-h|--help)
			sed -n '2,/^set /p' "$0" | sed -E 's/^#( |$)//;/^set /d'
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
	esac
done

# version precedence: --version arg > env var > default
if [[ -n "$vVersionArg" ]]; then
	kVersion="$vVersionArg"
else
	kVersion="${ALLOFIT_VERSION:-0.0.0}"
fi
vDmgPath="${vOutputsDir}/${kAppName}-${kVersion}.dmg"
vAppBundle="${vOutputsDir}/${kAppName}-${kVersion}.app"

# ==================
# MARK: Build .app
# ==================

if [[ "$vSkipBuild" -eq 0 ]]; then
	echo "==> Rebuilding ${kAppName}.app first"
	# Propagate the resolved version into build-app.sh so the bundled
	# Info.plist matches what we're naming the DMG.
	ALLOFIT_VERSION="${kVersion}" "${vProjectRoot}/scripts/build-app.sh"
fi

if [[ ! -d "${vAppBundle}" ]]; then
	echo "Run ./scripts/build-app.sh first - ${kAppName}.app is missing" >&2
	exit 1
fi

# ==================
# MARK: Stage + create DMG
# ==================

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
