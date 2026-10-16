#!/bin/bash
# The Mac app's release (CI): imports the Developer ID certificate (MAC_DEVID_P12 base64 + MAC_DEVID_P12_PASSWORD)
# into a throwaway keychain and the two Developer ID profiles (MAC_PROFILE_APP / MAC_PROFILE_TUNNEL, base64), archives
# the ProxyMac scheme, exports it signed for Developer ID, notarizes it with the App Store Connect key (ASC_KEY_ID /
# ASC_ISSUER_ID / ASC_PRIVATE_KEY), staples the ticket and leaves $OUT/Proxy-mac.zip. The subscriptions inside are
# sealed (App/Bundled/sealed.json), so the zip may go to a public GitHub Release. Prints verdicts only.
set -euo pipefail
cd "$(dirname "$0")/.."
T=${RUNNER_TEMP:-$(mktemp -d)}; OUT=${OUT:-$T/mac-out}; mkdir -p "$OUT"
KC="$T/signing.keychain-db" KCPW=$(uuidgen)
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPW" "$KC"
printf '%s' "$MAC_DEVID_P12" | base64 --decode > "$T/devid.p12"
security import "$T/devid.p12" -k "$KC" -P "$MAC_DEVID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
rm -f "$T/devid.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$KC" | grep -o '"Developer ID Application: [^"]*"' | head -1
for d in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$d"
  for p in APP TUNNEL; do v=MAC_PROFILE_$p; printf '%s' "${!v}" | base64 --decode > "$d/proxy-mac-$p.provisionprofile"; done
done

xcodebuild archive -project Proxy.xcodeproj -scheme ProxyMac -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$T/mac.xcarchive" OTHER_CODE_SIGN_FLAGS="--keychain $KC" > "$T/private-mac-archive.log" 2>&1 || true
grep -E "error:|\*\* ARCHIVE" "$T/private-mac-archive.log" | sed -E 's#/Users/[^ ]*/proxy-ios/##' | head -40 || true
grep -q "ARCHIVE SUCCEEDED" "$T/private-mac-archive.log"
xcodebuild -exportArchive -archivePath "$T/mac.xcarchive" -exportOptionsPlist scripts/ExportOptions-mac.plist \
  -exportPath "$T/mac-export" > "$T/private-mac-export.log" 2>&1 || true
grep -E "error|EXPORT" "$T/private-mac-export.log" | sed "s#$T/##" | tail -n 15 || true
grep -q "EXPORT SUCCEEDED" "$T/private-mac-export.log"
APP="$T/mac-export/Proxy.app"
SX="$APP/Contents/Library/SystemExtensions/dev.de0ch.proxy.tunnel.systemextension"
[ -d "$SX" ] || { echo "no system extension in the app"; find "$APP" -maxdepth 4 -name '*.systemextension'; exit 1; }
codesign --verify --deep --strict "$APP" && echo "codesign: valid"
echo "Mac bundle check (exported app):"; python3 scripts/check-mac-bundle.py "$APP" | sed "s/^/  /"
codesign -d --entitlements - "$SX" 2>&1 | grep -E "systemextension|application-groups" | head -3
codesign -dv "$APP" 2>&1 | grep -E "^Authority=Developer ID Application|^TeamIdentifier|flags=.*runtime" | head -3

KEY="$T/AuthKey_$ASC_KEY_ID.p8"; printf '%s\n' "$ASC_PRIVATE_KEY" > "$KEY"
ditto -c -k --keepParent "$APP" "$T/notarize.zip"
xcrun notarytool submit "$T/notarize.zip" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 30m \
  > "$T/private-notary.log" 2>&1 || true
rm -f "$KEY"
grep -E "status:|id:" "$T/private-notary.log" | tail -3
grep -q "status: Accepted" "$T/private-notary.log" || {
  id=$(sed -n 's/^ *id: //p' "$T/private-notary.log" | head -1)
  [ -n "$id" ] && printf '%s\n' "$ASC_PRIVATE_KEY" > "$KEY" && xcrun notarytool log "$id" --key "$KEY" --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" 2>&1 | grep -E '"(message|path|severity)"' | sed "s#$T/##" | head -30; rm -f "$KEY"; exit 1; }
xcrun stapler staple "$APP" | tail -1
spctl -a -vv -t exec "$APP" 2>&1 | head -3
python3 scripts/check-mac-bundle.py "$APP" > /dev/null || { echo "Mac bundle check failed after stapling"; exit 1; }
ditto -c -k --keepParent "$APP" "$OUT/Proxy-mac.zip"
du -h "$OUT/Proxy-mac.zip" | sed "s#$T/##"
security delete-keychain "$KC"
