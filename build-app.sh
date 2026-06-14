#!/usr/bin/env bash
# Builds Allofit.app from the SwiftPM executable so the binary can be
# launched like any other macOS app (double-click in Finder, dragged into
# /Applications, etc.). Run from the project root:
#     ./build-app.sh
# The produced bundle ends up at ./Allofit.app
set -euo pipefail

kAppName="Allofit"
kBundleId="com.bitsycore.allofit"
kVersion="1.0"
kBuildNumber="1"

vProjectRoot="$(cd "$(dirname "$0")" && pwd)"
vAppBundle="${vProjectRoot}/${kAppName}.app"
vMacOSDir="${vAppBundle}/Contents/MacOS"
vResourcesDir="${vAppBundle}/Contents/Resources"
vBinarySrc="${vProjectRoot}/.build/release/${kAppName}"

echo "==> Building release binary"
( cd "${vProjectRoot}" && swift build -c release )

if [[ ! -f "${vBinarySrc}" ]]; then
	echo "Build did not produce ${vBinarySrc}" >&2
	exit 1
fi

echo "==> Assembling ${kAppName}.app"
rm -rf "${vAppBundle}"
mkdir -p "${vMacOSDir}" "${vResourcesDir}"
cp "${vBinarySrc}" "${vMacOSDir}/${kAppName}"
chmod +x "${vMacOSDir}/${kAppName}"

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
