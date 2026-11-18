#!/usr/bin/env bash
# Sends a signed Allofit.app or .dmg to Apple's notary service, waits for
# the verdict and staples the ticket to it, so Gatekeeper accepts it even
# offline. Used by the release workflow:
#     scripts/notarize.sh outputs/Allofit-1.0.0.app
#     scripts/notarize.sh outputs/Allofit-1.0.0.dmg
#
# Credentials (an App Store Connect API key) come from the environment:
#     NOTARY_KEY_PATH   path to the AuthKey_XXXXXXXXXX.p8 file
#     NOTARY_KEY_ID     the key's ID
#     NOTARY_ISSUER_ID  the issuer ID shown above the key list
# On rejection the notary log (the list of problems) is printed and the
# script fails.
set -euo pipefail

if [[ $# -ne 1 ]]; then
	echo "usage: $0 <path to .app or .dmg>" >&2
	exit 1
fi
vTarget="$1"
: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH is not set}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID is not set}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is not set}"

vWorkDir="$(mktemp -d)"
trap 'rm -rf "${vWorkDir}"' EXIT

# the notary service takes a .zip, .pkg or .dmg: an .app is zipped first
if [[ "${vTarget}" == *.app ]]; then
	vSubmission="${vWorkDir}/$(basename "${vTarget}" .app).zip"
	ditto -c -k --keepParent "${vTarget}" "${vSubmission}"
else
	vSubmission="${vTarget}"
fi

echo "==> Submitting $(basename "${vTarget}") for notarization (usually a few minutes)"
vResult="${vWorkDir}/result.json"
xcrun notarytool submit "${vSubmission}" \
	--key "${NOTARY_KEY_PATH}" \
	--key-id "${NOTARY_KEY_ID}" \
	--issuer "${NOTARY_ISSUER_ID}" \
	--wait --timeout 30m \
	--output-format json > "${vResult}"

vStatus="$(plutil -extract status raw -o - "${vResult}")"
vSubmissionId="$(plutil -extract id raw -o - "${vResult}")"
echo "==> Notarization ${vStatus} (submission ${vSubmissionId})"
if [[ "${vStatus}" != "Accepted" ]]; then
	xcrun notarytool log "${vSubmissionId}" \
		--key "${NOTARY_KEY_PATH}" \
		--key-id "${NOTARY_KEY_ID}" \
		--issuer "${NOTARY_ISSUER_ID}" || true
	exit 1
fi

echo "==> Stapling the ticket"
xcrun stapler staple "${vTarget}"
xcrun stapler validate "${vTarget}"
