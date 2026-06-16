#!/usr/bin/env bash
# Removes every trace of Allofit from the system: launchd services, cache
# files, user preferences, build artifacts and log files. Useful for a
# clean reinstall test or to fully uninstall.
#
# Usage:
#     ./clean.sh                  # clean everything
#     ./clean.sh --keep-build     # leave .build/ and Allofit.app/ in place
#     ./clean.sh --keep-prefs     # leave UserDefaults / preferences alone
#     ./clean.sh --dry-run        # print what would happen, change nothing
set -uo pipefail

# ==================
# MARK: Constants
# ==================

kBundleId="com.bitsycore.allofit"
kServiceLabel="${kBundleId}.service"
kServicePlistName="${kServiceLabel}.plist"
kUserAgentPlist="$HOME/Library/LaunchAgents/${kServicePlistName}"
kSystemDaemonPlist="/Library/LaunchDaemons/${kServicePlistName}"
kUserCacheDir="$HOME/Library/Application Support/Allofit"
kSystemCacheDir="/Library/Application Support/Allofit"
kUserPrefsPlist="$HOME/Library/Preferences/${kBundleId}.plist"
kServiceLogStdout="/tmp/allofit-service.log"
kServiceLogStderr="/tmp/allofit-service.err"

# ==================
# MARK: Args
# ==================

vScriptDir="$(cd "$(dirname "$0")" && pwd)"
vKeepBuild=0
vKeepPrefs=0
vDryRun=0

for vArg in "$@"; do
	case "$vArg" in
		--keep-build) vKeepBuild=1 ;;
		--keep-prefs) vKeepPrefs=1 ;;
		--dry-run|-n) vDryRun=1 ;;
		-h|--help)
			# print the comment block at the top of this file
			sed -n '2,/^set /p' "$0" | sed -E 's/^#( |$)//;/^set /d'
			exit 0
			;;
		*)
			echo "Unknown argument: $vArg" >&2
			exit 1
			;;
	esac
done

# ==================
# MARK: Helpers
# ==================

# runs a command, or just prints it under --dry-run
vRun() {
	if [[ "$vDryRun" -eq 1 ]]; then
		echo "  [dry-run] $*"
	else
		"$@"
	fi
}

# caches a sudo session once so later sudo calls don't re-prompt
vGotSudo=0
vNeedsSudo() {
	if [[ "$vGotSudo" -eq 0 ]]; then
		if [[ "$vDryRun" -eq 1 ]]; then
			echo "  [dry-run] sudo -v"
		else
			echo "==> Acquiring sudo (for /Library cleanup)"
			sudo -v
		fi
		vGotSudo=1
	fi
}

# stops a launchd job by plist path then deletes the plist
# inDomain inPlist [inSudo]
vRemoveLaunchd() {
	local inDomain="$1"
	local inPlist="$2"
	local inSudo="${3:-}"
	if [[ ! -f "$inPlist" ]]; then return 0; fi
	if [[ -n "$inSudo" ]]; then vNeedsSudo; fi
	vRun $inSudo launchctl bootout "$inDomain" "$inPlist" >/dev/null 2>&1 || true
	vRun $inSudo launchctl unload -w "$inPlist" >/dev/null 2>&1 || true
	vRun $inSudo rm -f "$inPlist"
}

# ==================
# MARK: launchd services
# ==================

echo "==> Stopping & removing user LaunchAgent (if present)"
vRemoveLaunchd "gui/$(id -u)" "$kUserAgentPlist"

if [[ -f "$kSystemDaemonPlist" ]]; then
	echo "==> Stopping & removing system LaunchDaemon"
	vRemoveLaunchd "system" "$kSystemDaemonPlist" "sudo"
fi

echo "==> Killing any leftover daemon processes"
# `pkill -f` matches against the full command line; the daemon binary is
# now installed as ".../Allofit Service" (renamed copy), so the literal
# "Allofit --service" no longer appears - use a regex that handles both
# the legacy and the renamed binary by anchoring on "Allofit...--service"
vRun pkill -f "Allofit.*--service" >/dev/null 2>&1 || true

# ==================
# MARK: Cache files
# ==================

if [[ -d "$kUserCacheDir" ]]; then
	echo "==> Removing user cache directory"
	vRun rm -rf "$kUserCacheDir"
fi

if [[ -d "$kSystemCacheDir" ]]; then
	echo "==> Removing system cache directory"
	vNeedsSudo
	vRun sudo rm -rf "$kSystemCacheDir"
fi

# ==================
# MARK: Preferences
# ==================

if [[ "$vKeepPrefs" -eq 0 ]]; then
	echo "==> Removing user preferences"
	# defaults handles cfprefsd's cached copy in addition to the on-disk plist
	vRun defaults delete "$kBundleId" >/dev/null 2>&1 || true
	# also clear the SwiftPM "swift run" domain, which may differ from the
	# bundled .app's domain depending on how the binary was launched
	vRun defaults delete "Allofit" >/dev/null 2>&1 || true
	vRun rm -f "$kUserPrefsPlist"
	# wipe ByHost variants if any
	shopt -s nullglob
	for vByHost in "$HOME/Library/Preferences/ByHost/${kBundleId}".*.plist; do
		vRun rm -f "$vByHost"
	done
	shopt -u nullglob
fi

# ==================
# MARK: Logs
# ==================

if [[ -f "$kServiceLogStdout" || -f "$kServiceLogStderr" ]]; then
	echo "==> Removing service log files"
	# /tmp has the sticky bit, so only the file's owner can rm it. Logs
	# left over from a previous *root* daemon run are owned by root - we
	# need sudo to delete them. Plain rm for user-owned logs (user agent
	# mode), sudo rm for root-owned ones.
	for vLog in "$kServiceLogStdout" "$kServiceLogStderr"; do
		if [[ -f "$vLog" ]]; then
			if [[ -O "$vLog" ]]; then
				vRun rm -f "$vLog"
			else
				vNeedsSudo
				vRun sudo rm -f "$vLog"
			fi
		fi
	done
fi

# ==================
# MARK: Build artifacts
# ==================

if [[ "$vKeepBuild" -eq 0 ]]; then
	if [[ -d "${vScriptDir}/.build" ]]; then
		echo "==> Removing SwiftPM .build directory"
		vRun rm -rf "${vScriptDir}/.build"
	fi
	if [[ -d "${vScriptDir}/Allofit.app" ]]; then
		echo "==> Removing Allofit.app bundle"
		vRun rm -rf "${vScriptDir}/Allofit.app"
	fi
fi

echo
echo "Clean complete."
echo
echo "Note: any Full Disk Access grant in System Settings → Privacy & Security"
echo "still points at the previous binary location. Remove it manually if you"
echo "intend to install Allofit at a different path."
