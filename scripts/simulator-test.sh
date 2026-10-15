#!/bin/bash
# The phone (or Mac: PLATFORM=mac) replica: runs the real generated config in a desktop sing-box on this Mac (mixed inbound + Clash API
# on loopback, the same nodes the phone uses), then the UI test on an iPhone 17 simulator walks every flow against
# it. Only screenshots go to $OUT/screens (the app hides exit IPs in test mode); everything that can hold
# subscription data (config, sing-box log, xcresult, the full xcodebuild log — the latter two also hold the unlock
# password the test types) stays in $PRIVATE, which CI never uploads. Prints nothing derived from the subscriptions.
# Needs scripts/prepare.sh first (build/subs and the sealed bundle) and PROXY_UNLOCK_PASSWORD.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$PWD/test-output}; mkdir -p "$OUT/screens"
PRIVATE=${PRIVATE:-$(mktemp -d)}; mkdir -p "$PRIVATE"
SB_VERSION=1.14.3
DEVICE=${DEVICE:-iPhone 17}

(cd Packages/ProxyCore && swift build -c release --product proxy-config >/dev/null 2>&1)
CFG="$PRIVATE/sb"; mkdir -p "$CFG"; SECRET=$(uuidgen)
CN_ARGS=(); EXPECT_CN=0
if [ -f build/subs/cn.json ]; then CN_ARGS=(--cn build/subs/cn.json); EXPECT_CN=1; fi
Packages/ProxyCore/.build/release/proxy-config --liangxin build/subs/liangxin.json \
  --gulu build/subs/gulu.json "${CN_ARGS[@]}" --rules "$PWD/PacketTunnel/Rules" --data "$CFG" --secret "$SECRET" \
  --mixed 17891 --controller 127.0.0.1:19090 --check-port-base 17901 > "$CFG/config.json"   # stderr: per-region node counts only
ARCH=$(uname -m | sed 's/x86_64/amd64/')
curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/sing-box-$SB_VERSION-darwin-$ARCH.tar.gz" | tar xz -C "$CFG"
"$CFG/sing-box-$SB_VERSION-darwin-$ARCH/sing-box" run -c "$CFG/config.json" > "$PRIVATE/sing-box.log" 2>&1 &
SB=$!; trap 'kill $SB 2>/dev/null || true; rm -rf "$CFG"' EXIT
for i in $(seq 1 30); do curl -sf -H "Authorization: Bearer $SECRET" http://127.0.0.1:19090/proxies >/dev/null && break; sleep 1; done
echo "international exit from the runner: $(curl -s -m 15 -x http://127.0.0.1:17891 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^loc=//p')"
echo "network probe from the runner (verdicts and countries only):"; Packages/ProxyCore/.build/release/proxy-config --probe | sed "s/^/  /"
# the real check from the runner (it is outside China: direct valid for International and AI), as the extension runs it
echo "real check from the runner (verdicts, node names, countries):"
Packages/ProxyCore/.build/release/proxy-config --health --controller 127.0.0.1:19090 --secret "$SECRET" --check-port-base 17901 \
  --direct "China=0,International=1,AI=1" | sed "s/^/  /" || true

TEST_ENV=(TEST_RUNNER_PROXY_MOCK_CLASH=http://127.0.0.1:19090 TEST_RUNNER_PROXY_MOCK_SECRET="$SECRET"
  TEST_RUNNER_PROXY_MOCK_HTTP_PROXY=127.0.0.1:17891 TEST_RUNNER_PROXY_MOCK_CHECK_PORT_BASE=17901
  TEST_RUNNER_PROXY_UNLOCK_PASSWORD="$PROXY_UNLOCK_PASSWORD" TEST_RUNNER_SCREENSHOT_DIR="$OUT/screens"
  TEST_RUNNER_PROXY_EXPECT_CN=$EXPECT_CN)
if [ "${PLATFORM:-ios}" = mac ]; then
  # the Mac app in test mode, signed ad hoc without its restricted entitlements (test mode never starts the tunnel)
  env "${TEST_ENV[@]}" xcodebuild test -project Proxy.xcodeproj -scheme ProxyMac -configuration Release -destination 'platform=macOS' \
    -resultBundlePath "$PRIVATE/ui.xcresult" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_ENTITLEMENTS= ENABLE_HARDENED_RUNTIME=NO > "$PRIVATE/xcodebuild-test.log" 2>&1 || true
else
  UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['devices']
rts=sorted((k for k in d if 'iOS' in k), key=lambda k:[int(x) for x in re.findall(r'\d+',k)])
for rt in reversed(rts):
    for dev in d[rt]:
        if dev['name']==sys.argv[1]: print(dev['udid']); sys.exit()
" "$DEVICE")
  [ -n "$UDID" ] || { echo "no $DEVICE simulator"; exit 1; }
  xcrun simctl boot "$UDID" 2>/dev/null || true
  env "${TEST_ENV[@]}" xcodebuild test -project Proxy.xcodeproj -scheme Proxy -configuration Release -destination "id=$UDID" \
    -resultBundlePath "$PRIVATE/ui.xcresult" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO > "$PRIVATE/xcodebuild-test.log" 2>&1 || true
fi
# printed: build errors and test verdicts only (node names at most, no subscription values)
grep -E "error:|\*\* TEST|Test Case .*(passed|failed)" "$PRIVATE/xcodebuild-test.log" | sed -E 's#/Users/[^ ]*/proxy-ios/##' | head -40 || true
# the built app's identity (not secret): catches an unexpanded Info.plist
for a in $(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*Release*' -name Proxy.app -maxdepth 6 2>/dev/null); do
  pl="$a/Info.plist"; [ -f "$pl" ] || pl="$a/Contents/Info.plist"
  echo "built ${a##*/Build/Products/}: $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$pl" 2>/dev/null)"
done
# screenshots: the test's PNG attachments from the result bundle (the runner can't always write to $SCREENSHOT_DIR)
xcrun xcresulttool export attachments --path "$PRIVATE/ui.xcresult" --output-path "$PRIVATE/attachments" >/dev/null 2>&1 || true
python3 - "$PRIVATE/attachments" "$OUT/screens" <<'PY' || true
import json, os, shutil, sys
src, dst = sys.argv[1:]
try: m = json.load(open(os.path.join(src, "manifest.json")))
except Exception: sys.exit()
n = 0
for t in m:
    for a in t.get("attachments", []):
        f = a.get("exportedFileName", "")
        if f.endswith(".png"):
            n += 1; name = a.get("suggestedHumanReadableName", f).split("_")[0]
            shutil.copy(os.path.join(src, f), os.path.join(dst, "%02d-%s.png" % (n, name)))
print(f"screenshots from the result bundle: {n}")
PY
rm -f "$OUT/screens/"*.txt   # view-hierarchy dumps can include node names and test lines: keep them private
grep -q "\*\* TEST SUCCEEDED \*\*" "$PRIVATE/xcodebuild-test.log"
