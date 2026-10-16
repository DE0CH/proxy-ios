#!/usr/bin/env python3
"""Checks a built Proxy.app (the exported, Developer ID signed one) against Apple's requirements for a NetworkExtension
system extension, so a missing Info.plist key or entitlement fails CI instead of failing on Deyao's Mac at Connect.

Usage: check-mac-bundle.py PATH/Proxy.app [--no-entitlements]
  --no-entitlements  only the Info.plist checks (for an ad hoc build signed without entitlements).
Prints one line per check and exits 1 if any fails. Prints nothing derived from the subscriptions."""
import plistlib, re, shutil, subprocess, sys
from pathlib import Path

APP_ID = "dev.de0ch.proxy"
EXT_ID = "dev.de0ch.proxy.tunnel"
TEAM = "S64YL394S3"
PROVIDER = "PacketTunnel.PacketTunnelProvider"
NE_KEY = "com.apple.developer.networking.networkextension"

fails = 0
def check(ok, what):
    global fails
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok: fails += 1

def entitlements(binary: Path) -> dict:
    """The signed entitlements: codesign on a Mac, else the plist embedded in the code signature."""
    if shutil.which("codesign"):
        out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(binary)],
                             capture_output=True).stdout
        i = out.find(b"<?xml")
        if i >= 0: return plistlib.loads(out[i:])
        return {}
    data = binary.read_bytes()
    for m in re.finditer(rb"<\?xml[^>]*\?>\s*<!DOCTYPE plist.{0,200}?<plist.*?</plist>", data, re.S):
        try: d = plistlib.loads(m.group(0))
        except Exception: continue
        if "com.apple.application-identifier" in d or NE_KEY in d: return d
    return {}

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    with_ent = "--no-entitlements" not in sys.argv
    app = Path(args[0])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    check(info.get("CFBundleIdentifier") == APP_ID, f"app CFBundleIdentifier = {APP_ID}")

    sx = app / f"Contents/Library/SystemExtensions/{EXT_ID}.systemextension"
    check(sx.is_dir(), f"system extension at Contents/Library/SystemExtensions/{EXT_ID}.systemextension")
    if not sx.is_dir(): sys.exit(1)
    sxi = plistlib.loads((sx / "Contents/Info.plist").read_bytes())
    check(sxi.get("CFBundleIdentifier") == EXT_ID, f"extension CFBundleIdentifier = {EXT_ID}")
    check(EXT_ID.startswith(APP_ID + "."), "extension bundle id is prefixed by the app's")
    check(sxi.get("CFBundlePackageType") == "SYSX", "extension CFBundlePackageType = SYSX")
    exe = sxi.get("CFBundleExecutable", "")
    check(bool(exe) and (sx / "Contents/MacOS" / exe).is_file(), "extension CFBundleExecutable exists in Contents/MacOS")
    desc = sxi.get("NSSystemExtensionUsageDescription")
    check(isinstance(desc, str) and desc.strip() != "", "extension NSSystemExtensionUsageDescription present, non-empty")
    for k in ("CFBundleVersion", "CFBundleShortVersionString"):
        check(sxi.get(k) == info.get(k), f"extension {k} matches the app's")
    ne = sxi.get("NetworkExtension") or {}
    mach = ne.get("NEMachServiceName", "")
    check(bool(mach), "extension NetworkExtension.NEMachServiceName present")
    prov = (ne.get("NEProviderClasses") or {}).get("com.apple.networkextension.packet-tunnel")
    check(prov == PROVIDER, f"extension NEProviderClasses packet-tunnel = {PROVIDER}")

    if with_ent:
        aent = entitlements(app / "Contents/MacOS" / info.get("CFBundleExecutable", ""))
        sent = entitlements(sx / "Contents/MacOS" / exe)
        check(aent.get("com.apple.developer.system-extension.install") is True, "app entitlement system-extension.install")
        check("packet-tunnel-provider-systemextension" in (aent.get(NE_KEY) or []),
              "app entitlement networkextension packet-tunnel-provider-systemextension")
        check("packet-tunnel-provider-systemextension" in (sent.get(NE_KEY) or []),
              "extension entitlement networkextension packet-tunnel-provider-systemextension")
        check(sent.get("com.apple.developer.team-identifier") == TEAM, f"extension signed for team {TEAM}")
        groups = sent.get("com.apple.security.application-groups") or []
        check(any(g.startswith(TEAM + ".") for g in groups), "extension has a team-prefixed app group")
        check(any(mach.startswith(g) for g in groups), "NEMachServiceName is prefixed by one of the extension's app groups")
        check((sx / "Contents/embedded.provisionprofile").is_file(), "extension embeds its provisioning profile")
        check((app / "Contents/embedded.provisionprofile").is_file(), "app embeds its provisioning profile")
    sys.exit(1 if fails else 0)

main()
