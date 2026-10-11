#!/usr/bin/env python3
"""Fails if any file under the given paths contains a value derived from the subscriptions.

Patterns are built at runtime, never printed: the subscription URLs from env (LIANGXIN_SUB_URL, GULU_SUB_URL —
whole URL, host, token-like path segments and query values) and, from the bundled snapshots in
App/Bundled/Subscriptions/*.json, every server host and its resolved IPs, uuid, password, Reality public key /
short id, certificate pin and private key. Files are searched as bytes (screenshots, logs, anything).
Prints only how many files were checked and the names of files with hits. Usage: leak-check.py PATH...
"""
import glob, json, os, socket, sys, urllib.parse

pats = set()
def add(v):
    if isinstance(v, (int, float)) or v is None:
        return
    v = str(v).strip()
    if len(v) >= 6:
        pats.add(v)

for k in ("LIANGXIN_SUB_URL", "GULU_SUB_URL"):
    u = os.environ.get(k, "").strip()
    if not u:
        continue
    add(u)
    p = urllib.parse.urlparse(u)
    add(p.hostname)
    for seg in p.path.split("/"):
        # token-like segments only: a plain word such as the airport's name is not secret
        if len(seg) >= 16 or (len(seg) >= 8 and any(c.isdigit() for c in seg) and any(c.isalpha() for c in seg)):
            add(seg)
    for _, vals in urllib.parse.parse_qs(p.query).items():
        for v in vals:
            add(v)

KEYS = {"server", "uuid", "password", "public_key", "short_id", "certificate_public_key_sha256", "private_key",
        "pre_shared_key", "obfs_password", "auth_str"}
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in KEYS:
                if isinstance(v, list):
                    for x in v: add(x)
                else:
                    add(v)
                if k == "server" and isinstance(v, str):
                    try:
                        for info in socket.getaddrinfo(v, None):
                            add(info[4][0])
                    except OSError:
                        pass
            else:
                walk(v)
    elif isinstance(o, list):
        for x in o:
            walk(x)

for f in glob.glob("App/Bundled/Subscriptions/*.json"):
    try:
        walk(json.load(open(f)))
    except Exception:
        print(f"leak-check: could not read a bundled snapshot ({os.path.basename(f)})")
        sys.exit(2)

if not pats:
    print("leak-check: no patterns (no subscription URLs or snapshots) - refusing to pass blind")
    sys.exit(2)
bpats = [p.encode() for p in pats]
checked, hits = 0, []
for root in sys.argv[1:]:
    files = [root] if os.path.isfile(root) else [os.path.join(d, n) for d, _, ns in os.walk(root) for n in ns]
    for f in files:
        try:
            data = open(f, "rb").read()
        except OSError:
            continue
        checked += 1
        if any(p in data for p in bpats):
            hits.append(f)
print(f"leak-check: {checked} files checked against {len(pats)} derived values: {len(hits)} with a hit")
for h in hits:
    print(f"  HIT: {h}")
sys.exit(1 if hits else 0)
