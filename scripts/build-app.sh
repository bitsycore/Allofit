#!/usr/bin/env bash
# Builds Allofit.app from the SwiftPM executable so the binary can be
# launched like any other macOS app (double-click in Finder, dragged into
# /Applications, etc.). Can be called from anywhere - paths are resolved
# relative to the script's own location:
#     ./scripts/build-app.sh                       # from project root
#     scripts/build-app.sh --version 1.0.0
#     ./build-app.sh -v 1.0.0 -b 42                # from scripts/
#     ALLOFIT_VERSION=1.0.0 ./scripts/build-app.sh # env var still works
#
# Version precedence: --version arg > ALLOFIT_VERSION env > default 0.0.0.
# The produced bundle ends up at <project root>/outputs/Allofit-<version>.app
# (the version is appended so multiple builds can coexist in outputs/).
#
# Icon support (optional, first match wins):
#     icons/Allofit.icns          - pre-built .icns, copied straight in
#     icons/Allofit.iconset/      - Apple iconset dir, fed to iconutil
#     icons/icon.png              - single PNG (ideally 1024x1024), resized
#                                   to every required slot via sips
# If no icon source exists the bundle is built without one (Finder shows
# the generic executable icon).
set -euo pipefail

kAppName="Allofit"
kBundleId="com.bitsycore.allofit"

# ==================
# MARK: Args
# ==================

vVersionArg=""
vBuildArg=""
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
		--build|-b)
			if [[ $# -lt 2 ]]; then
				echo "$1 requires a value" >&2
				exit 1
			fi
			vBuildArg="$2"
			shift 2
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

# version / build precedence: --flag arg > env var > default
if [[ -n "$vVersionArg" ]]; then
	kVersion="$vVersionArg"
else
	kVersion="${ALLOFIT_VERSION:-0.0.0}"
fi
if [[ -n "$vBuildArg" ]]; then
	kBuildNumber="$vBuildArg"
else
	kBuildNumber="${ALLOFIT_BUILD:-0}"
fi

# Resolve the project root from the script's own location (scripts/..),
# so this script works regardless of the caller's CWD.
vProjectRoot="$(cd "$(dirname "$0")/.." && pwd)"
vOutputsDir="${vProjectRoot}/outputs"
vAppBundle="${vOutputsDir}/${kAppName}-${kVersion}.app"
vMacOSDir="${vAppBundle}/Contents/MacOS"
vResourcesDir="${vAppBundle}/Contents/Resources"
vBinarySrc="${vProjectRoot}/.build/release/${kAppName}"
vIconStagingDir="${vProjectRoot}/.build/icon-staging"

mkdir -p "${vOutputsDir}"

# ==================
# MARK: Build binary
# ==================

echo "==> Building release binary"
( cd "${vProjectRoot}" && swift build -c release )

if [[ ! -f "${vBinarySrc}" ]]; then
	echo "Build did not produce ${vBinarySrc}" >&2
	exit 1
fi

# ==================
# MARK: Prepare bundle
# ==================

echo "==> Assembling ${kAppName}.app"
rm -rf "${vAppBundle}"
mkdir -p "${vMacOSDir}" "${vResourcesDir}"
cp "${vBinarySrc}" "${vMacOSDir}/${kAppName}"

# drop library search paths that point outside the system (the toolchain
# embeds one into /Applications/Xcode.app): the same binary runs as the root
# daemon, which must never look for libraries in an admin-writable folder
while read -r vRpath; do
	[[ -z "${vRpath}" ]] && continue
	install_name_tool -delete_rpath "${vRpath}" "${vMacOSDir}/${kAppName}"
done < <(otool -l "${vMacOSDir}/${kAppName}" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -v '^/usr/lib' || true)
chmod +x "${vMacOSDir}/${kAppName}"

# ==================
# MARK: Resolve icon
# ==================

# Locates an icon source in icons/ and emits an .icns into the bundle.
# Echoes the basename (without extension) when one was installed; nothing
# otherwise. Caller uses the result to fill CFBundleIconFile / CFBundleIconName.
vBuiltIconName=""
vIcnsSrc="${vProjectRoot}/icons/${kAppName}.icns"
vIconsetSrc="${vProjectRoot}/icons/${kAppName}.iconset"
vPngSrc="${vProjectRoot}/icons/icon.png"

if [[ -f "${vIcnsSrc}" ]]; then
	echo "==> Using pre-built icon ${vIcnsSrc}"
	cp "${vIcnsSrc}" "${vResourcesDir}/${kAppName}.icns"
	vBuiltIconName="${kAppName}"
elif [[ -d "${vIconsetSrc}" ]]; then
	echo "==> Building .icns from iconset ${vIconsetSrc}"
	iconutil -c icns "${vIconsetSrc}" -o "${vResourcesDir}/${kAppName}.icns"
	vBuiltIconName="${kAppName}"
elif [[ -f "${vPngSrc}" ]]; then
	echo "==> Building .icns from ${vPngSrc} (multi-size resample)"
	rm -rf "${vIconStagingDir}"
	mkdir -p "${vIconStagingDir}/${kAppName}.iconset"
	# (pt-size, pixel-size, filename) tuples per Apple's iconset spec
	vSlots=(
		"16  16   icon_16x16.png"
		"16  32   icon_16x16@2x.png"
		"32  32   icon_32x32.png"
		"32  64   icon_32x32@2x.png"
		"128 128  icon_128x128.png"
		"128 256  icon_128x128@2x.png"
		"256 256  icon_256x256.png"
		"256 512  icon_256x256@2x.png"
		"512 512  icon_512x512.png"
		"512 1024 icon_512x512@2x.png"
	)
	for vRow in "${vSlots[@]}"; do
		read -r _ vPixels vFile <<<"${vRow}"
		sips -z "${vPixels}" "${vPixels}" \
			"${vPngSrc}" \
			--out "${vIconStagingDir}/${kAppName}.iconset/${vFile}" \
			>/dev/null
	done
	iconutil -c icns \
		"${vIconStagingDir}/${kAppName}.iconset" \
		-o "${vResourcesDir}/${kAppName}.icns"
	vBuiltIconName="${kAppName}"
else
	echo "==> No icon source found in icons/ (skipping)"
fi

# ==================
# MARK: Info.plist
# ==================

# Optional icon block - only emitted when an .icns was actually placed
vIconPlistEntry=""
if [[ -n "${vBuiltIconName}" ]]; then
	vIconPlistEntry=$(cat <<EOF
	<key>CFBundleIconFile</key>
	<string>${vBuiltIconName}</string>
	<key>CFBundleIconName</key>
	<string>${vBuiltIconName}</string>
EOF
)
fi

cat > "${vAppBundle}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${kAppName}</string>
	<key>CFBundleIdentifier</key>
	<string>${kBundleId}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${kAppName}</string>
	<key>CFBundleDisplayName</key>
	<string>${kAppName}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${kVersion}</string>
	<key>CFBundleVersion</key>
	<string>${kBuildNumber}</string>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 bitsycore - MIT Licensed</string>
${vIconPlistEntry}
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<!-- text shown in the macOS privacy prompts triggered by the first scan -->
	<key>NSDesktopFolderUsageDescription</key>
	<string>Allofit indexes file names on your Desktop so they show up in searches. File contents are never read.</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Allofit indexes file names in Documents so they show up in searches. File contents are never read.</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Allofit indexes file names in Downloads so they show up in searches. File contents are never read.</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>Allofit indexes file names on external drives you choose to include in searches.</string>
	<key>NSNetworkVolumesUsageDescription</key>
	<string>Allofit indexes file names on network volumes you choose to include in searches.</string>
	<!-- Finder > right-click a folder > Services / Quick Actions > Search in Allofit -->
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>Search in Allofit</string>
			</dict>
			<key>NSMessage</key>
			<string>searchInAllofit</string>
			<key>NSPortName</key>
			<string>${kAppName}</string>
			<key>NSRequiredContext</key>
			<dict/>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.folder</string>
			</array>
		</dict>
	</array>
	<!-- folders dropped on the Dock icon / open -a Allofit <folder> start a search inside them -->
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Folder</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>None</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.folder</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
EOF

cat > "${vAppBundle}/Contents/PkgInfo" <<EOF
APPL????
EOF

# ad-hoc sign so Gatekeeper accepts the bundle when launched from Finder.
# For wider distribution you'd swap "-" for your Developer ID identity.
echo "==> Ad-hoc code signing"
codesign --force --sign - "${vAppBundle}" 2>/dev/null || true

echo
echo "Built ${vAppBundle}"
echo "Run with:    open \"${vAppBundle}\""
echo "Or move it to /Applications and launch from Finder/Spotlight."
