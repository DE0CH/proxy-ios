#!/usr/bin/env python3
"""Seals the subscriptions into App/Bundled/sealed.json for the apps (App/Vault.swift opens it).

  scripts/seal.py SUBS_DIR OUT          password from env PROXY_UNLOCK_PASSWORD

SUBS_DIR holds what prepare.sh fetched: liangxin.json / gulu.json / cn.json (sing-box profiles, each optional) and
liangxin.url / gulu.url (the subscription URLs). PBKDF2-HMAC-SHA256 (600 000 rounds, random 16-byte salt) ->
AES-256-GCM (random 12-byte nonce). Format: {"v":1,"iter":N,"salt":b64,"nonce":b64,"ct":b64(ciphertext+tag)}.
Prints only which parts went in.
"""
import base64, hashlib, json, os, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ITER = 600_000
subs, out = sys.argv[1], sys.argv[2]
pw = os.environ.get("PROXY_UNLOCK_PASSWORD", "")
if not pw:
    sys.exit("seal: PROXY_UNLOCK_PASSWORD is empty")


def read(name):
    p = os.path.join(subs, name)
    return open(p, encoding="utf-8").read().strip() if os.path.exists(p) else None


payload = {"liangxin_url": read("liangxin.url"), "gulu_url": read("gulu.url"),
           "liangxin": read("liangxin.json"), "gulu": read("gulu.json"), "cn": read("cn.json")}
salt, nonce = os.urandom(16), os.urandom(12)
key = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, ITER, 32)
ct = AESGCM(key).encrypt(nonce, json.dumps(payload).encode(), None)
b = lambda x: base64.b64encode(x).decode()
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    json.dump({"v": 1, "iter": ITER, "salt": b(salt), "nonce": b(nonce), "ct": b(ct)}, f)
print("sealed:", ", ".join(k for k, v in payload.items() if v) or "nothing")
