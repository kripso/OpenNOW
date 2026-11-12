#!/usr/bin/env bash
# Archive the iOS app in Release under your own Apple team and bundle ID, then
# upload it to App Store Connect, where it appears under TestFlight once Apple
# has processed it. The project's committed team and bundle IDs stay untouched.
#
#   IOS_TEAM_ID       Apple Developer team ID (required)
#   IOS_BUNDLE_ID     bundle ID of your own app record, e.g. com.example.opennow
#                     (required); the widget uses <IOS_BUNDLE_ID>.widget
#   IOS_BUILD_NUMBER  CFBundleVersion; defaults to the UTC minute, so each
#                     upload is newer than the last
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
#                     an App Store Connect API key (.p8, Admin role) for signing
#                     and the upload; without them Xcode's own account is used
#   IOS_OUT_DIR       where the archive and export land (default
#                     /tmp/opennow-ios-release)
#   IOS_SKIP_UPLOAD   set to 1 to stop after the archive
#   IOS_REPORTS_REPO, IOS_REPORTS_TOKEN
#                     where the build sends problem reports and, when the player
#                     turns that on, session reports: a GitHub repository as
#                     owner/name whose default branch has an ingest.yml workflow
#                     taking the inputs id, kind and payload, and a fine-grained
#                     token for that repository with the Actions permission only.
#                     Anyone can read the token out of the app, so it must not be
#                     able to do anything but start that workflow. Without both,
#                     the build sends no reports.
#
# Both bundle IDs must be registered as App IDs, and App Store Connect must have
# an app record for IOS_BUNDLE_ID; Apple's API cannot create that record.
# No -u: `auth` may stay empty, which bash 3.2 cannot expand safely under it.
set -eo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$project_dir/../.." && pwd)"

: "${IOS_TEAM_ID:?Set IOS_TEAM_ID to your Apple Developer team ID}"
: "${IOS_BUNDLE_ID:?Set IOS_BUNDLE_ID to the bundle ID of your App Store Connect app}"
build_number="${IOS_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
out="${IOS_OUT_DIR:-/tmp/opennow-ios-release}"

auth=()
if [ -n "${ASC_KEY_ID:-}" ]; then
	: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID alongside ASC_KEY_ID}"
	: "${ASC_KEY_PATH:?Set ASC_KEY_PATH to the .p8 file of the API key}"
	auth=(
		-authenticationKeyID "$ASC_KEY_ID"
		-authenticationKeyIssuerID "$ASC_ISSUER_ID"
		-authenticationKeyPath "$ASC_KEY_PATH"
	)
fi

rm -rf "$out"
mkdir -p "$out"

python3 "$project_dir/BuildScripts/prepare-native-libraries.py"

# Command-line settings outrank the targets' own, and each target resolves its
# bundle ID through its name, so the app and its widget keep distinct IDs.
cat >"$out/Personal.xcconfig" <<EOF
DEVELOPMENT_TEAM = $IOS_TEAM_ID
CURRENT_PROJECT_VERSION = $build_number
PRODUCT_BUNDLE_IDENTIFIER = \$(OPENNOW_BUNDLE_ID_\$(TARGET_NAME))
OPENNOW_BUNDLE_ID_OpenNOWiOS = $IOS_BUNDLE_ID
OPENNOW_BUNDLE_ID_OpenNOWWidget = $IOS_BUNDLE_ID.widget
OPENNOW_BUNDLE_ID_OpenNOWiOSTests = $IOS_BUNDLE_ID.tests
OPENNOW_REPORTS_REPOSITORY = ${IOS_REPORTS_REPO:-}
OPENNOW_REPORTS_TOKEN = ${IOS_REPORTS_TOKEN:-}
EOF

xcodebuild \
	-project "$project_dir/OpenNOWiOS.xcodeproj" \
	-scheme OpenNOWiOS \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$out/OpenNOW.xcarchive" \
	-derivedDataPath "$out/DerivedData" \
	-xcconfig "$out/Personal.xcconfig" \
	-allowProvisioningUpdates \
	"${auth[@]}" \
	archive

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$out/OpenNOW.xcarchive/Info.plist")"
echo "Archived $bundle_id build $build_number from $(git -C "$repo_root" rev-parse --short HEAD)"

if [ "${IOS_SKIP_UPLOAD:-0}" = "1" ]; then
	echo "IOS_SKIP_UPLOAD=1; archive is at $out/OpenNOW.xcarchive"
	exit 0
fi

cat >"$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$IOS_TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

if ! xcodebuild \
	-exportArchive \
	-archivePath "$out/OpenNOW.xcarchive" \
	-exportOptionsPlist "$out/ExportOptions.plist" \
	-exportPath "$out/export" \
	-allowProvisioningUpdates \
	"${auth[@]}"; then
	echo "The upload of $bundle_id failed. If it is the first one, check that App Store Connect has an app record with this bundle ID." >&2
	exit 1
fi

echo "Uploaded $bundle_id build $build_number; it shows under TestFlight once processed."
