#!/bin/bash
# Prepares the tree for xcodebuild (CI and local): Libbox.xcframework (pinned release + sha256 from the public
# DE0CH/libbox-apple: iOS, simulator and macOS), the sing-box rule sets, a build-time snapshot of both subscriptions
# (from env LIANGXIN_SUB_URL / GULU_SUB_URL; when a live fetch fails here, the stored snapshot in
# LIANGXIN_SUB_SNAPSHOT / GULU_SUB_SNAPSHOT — 咕噜云's host refuses GitHub's runners) and the China node (env
# CN_NODE_JSON: our Guangzhou server's outbounds as a sing-box profile; without it the build warns and China goes
# direct only), all sealed into App/Bundled/sealed.json with PROXY_UNLOCK_PASSWORD (scripts/seal.py), then
# `xcodegen generate`.
# Never prints the subscription URLs or contents.
set -euo pipefail
cd "$(dirname "$0")/.."
LIBBOX_TAG=v1.14.3-r2
LIBBOX_SHA=34e6c61c583b9e6a40bc8666d373cb9a5be4005ccb436e9b269a220ad21e6bac
UA="SFI/1.12.0 (sing-box 1.12.0)"

if [ ! -d Libbox.xcframework ] || [ "$(cat Libbox.xcframework/.tag 2>/dev/null)" != "$LIBBOX_TAG" ]; then
  rm -rf Libbox.xcframework
  curl -fsSL -o /tmp/Libbox.zip "https://github.com/DE0CH/libbox-apple/releases/download/$LIBBOX_TAG/Libbox.xcframework.zip"
  echo "$LIBBOX_SHA  /tmp/Libbox.zip" | shasum -a 256 -c -
  unzip -q /tmp/Libbox.zip && rm /tmp/Libbox.zip && echo "$LIBBOX_TAG" > Libbox.xcframework/.tag
fi

mkdir -p PacketTunnel/Rules
for f in geosite-cn geosite-category-ai-!cn; do
  curl -fsSL -o "PacketTunnel/Rules/$f.srs" "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/$f.srs"
done
curl -fsSL -o PacketTunnel/Rules/geoip-cn.srs https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs
ls -l PacketTunnel/Rules/*.srs

# The subscriptions in plain text go to build/subs (private: never in the app, the repo or an artifact; the replica
# runs them in a desktop sing-box); the app gets only App/Bundled/sealed.json, sealed with PROXY_UNLOCK_PASSWORD.
SUBS=build/subs; rm -rf "$SUBS" App/Generated; mkdir -p "$SUBS" App/Bundled; chmod 700 "$SUBS"
for a in liangxin gulu; do
  v=$(echo "$a" | tr a-z A-Z)_SUB_URL; u="${!v:-}"
  [ -n "$u" ] || { echo "$a: no URL"; continue; }
  printf '%s' "$u" > "$SUBS/$a.url"
  if curl -fsS -m 30 -A "$UA" -o "$SUBS/$a.tmp" "$u" && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d['outbounds'])>3" "$SUBS/$a.tmp"; then
    mv "$SUBS/$a.tmp" "$SUBS/$a.json"; echo "$a: snapshot ok"
  else
    rm -f "$SUBS/$a.tmp"
    sv=$(echo "$a" | tr a-z A-Z)_SUB_SNAPSHOT
    if [ -n "${!sv:-}" ]; then
      printf '%s' "${!sv}" > "$SUBS/$a.json"; echo "::warning::$a live fetch failed here; using the stored snapshot ($sv)"
    else
      echo "::warning::$a subscription fetch failed; no snapshot"
    fi
  fi
done
if [ -n "${CN_NODE_JSON:-}" ] && printf '%s' "$CN_NODE_JSON" | python3 -c "import json,sys; assert json.load(sys.stdin)['outbounds']" 2>/dev/null; then
  printf '%s' "$CN_NODE_JSON" > "$SUBS/cn.json"; echo "cn: China node ok"
else
  echo "::warning::no valid CN_NODE_JSON: this build has no China node (China goes direct only)"
fi
if [ -n "${PROXY_UNLOCK_PASSWORD:-}" ]; then
  python3 -c "import cryptography" 2>/dev/null || python3 -m pip install -q --user --break-system-packages cryptography >/dev/null
  python3 scripts/seal.py "$SUBS" App/Bundled/sealed.json
else
  echo "::warning::no PROXY_UNLOCK_PASSWORD: no sealed subscriptions (the app will say so at unlock)"
  rm -f App/Bundled/sealed.json; echo '{}' > App/Bundled/sealed.json
fi

command -v xcodegen >/dev/null || brew install xcodegen >/dev/null
xcodegen generate --quiet
