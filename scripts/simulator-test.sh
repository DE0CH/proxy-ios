#!/bin/bash
# The phone replica: runs the real generated config in a desktop sing-box on this Mac (mixed inbound + Clash API
# on loopback, the same nodes the phone uses), then the UI test on an iPhone 17 simulator walks every flow against
# it. Screenshots + the sing-box log land in $OUT. Needs scripts/prepare.sh first (bundled subscriptions).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-$PWD/test-output}; mkdir -p "$OUT/screens"
SB_VERSION=1.14.3
DEVICE=${DEVICE:-iPhone 17}

(cd Packages/ProxyCore && swift build -c release --product proxy-config >/dev/null)
CFG=$(mktemp -d); SECRET=$(uuidgen)
Packages/ProxyCore/.build/release/proxy-config --liangxin App/Bundled/Subscriptions/liangxin.json \
  --gulu App/Bundled/Subscriptions/gulu.json --rules "$PWD/PacketTunnel/Rules" --data "$CFG" --secret "$SECRET" \
  --mixed 17891 --controller 127.0.0.1:19090 > "$CFG/config.json"
ARCH=$(uname -m | sed 's/x86_64/amd64/')
curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/sing-box-$SB_VERSION-darwin-$ARCH.tar.gz" | tar xz -C "$CFG"
"$CFG/sing-box-$SB_VERSION-darwin-$ARCH/sing-box" run -c "$CFG/config.json" > "$OUT/sing-box.log" 2>&1 &
SB=$!; trap 'kill $SB 2>/dev/null || true; rm -rf "$CFG"' EXIT
for i in $(seq 1 30); do curl -sf -H "Authorization: Bearer $SECRET" http://127.0.0.1:19090/proxies >/dev/null && break; sleep 1; done
curl -s -m 15 -x http://127.0.0.1:17891 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc)=' | tr '\n' ' '; echo " <- international exit from the runner"

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['devices']
rts=sorted((k for k in d if 'iOS' in k), key=lambda k:[int(x) for x in re.findall(r'\d+',k)])
for rt in reversed(rts):
    for dev in d[rt]:
        if dev['name']==sys.argv[1]: print(dev['udid']); sys.exit()
" "$DEVICE")
[ -n "$UDID" ] || { echo "no $DEVICE simulator"; xcrun simctl list devices available | head -40; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
set -o pipefail
TEST_RUNNER_PROXY_MOCK_CLASH=http://127.0.0.1:19090 TEST_RUNNER_PROXY_MOCK_SECRET="$SECRET" \
TEST_RUNNER_PROXY_MOCK_HTTP_PROXY=127.0.0.1:17891 TEST_RUNNER_SCREENSHOT_DIR="$OUT/screens" \
xcodebuild test -project Proxy.xcodeproj -scheme Proxy -configuration Release -destination "id=$UDID" \
  -resultBundlePath "$OUT/ui.xcresult" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO 2>&1 | tee "$OUT/xcodebuild-test.log" \
  | grep -E "error:|Test Case|\*\* TEST|failed|passed" || true
grep -q "\*\* TEST SUCCEEDED \*\*" "$OUT/xcodebuild-test.log"
