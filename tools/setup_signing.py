#!/usr/bin/env python3
"""One-time signing setup from Linux, using only an App Store Connect API key.

Registers the bundle ID, creates an Apple Distribution certificate and a tvOS
App Store provisioning profile, then stores everything CI needs as GitHub secrets.

Expects secrets/asc.json: {"key_id": "...", "issuer_id": "...", "team_id": "..."}
and secrets/AuthKey_<key_id>.p8 next to it. Safe to re-run: reuses what exists.
"""
import base64, json, os, secrets as pysecrets, subprocess, sys, time
import requests

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEC = os.path.join(ROOT, "secrets")
API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.dltnp.harbor"
PROFILE_NAME = "Harbor tvOS App Store"
REPO = "bimjomplays/harbor-tvos"

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def der_to_raw(der):
    """ECDSA DER signature -> 64-byte r||s, as JWT ES256 wants."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        n = der[i + 1]
        out += der[i + 2:i + 2 + n].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + n
    return out

def token(cfg, key_path):
    now = int(time.time())
    head = b64url(json.dumps({"alg": "ES256", "kid": cfg["key_id"], "typ": "JWT"}).encode())
    body = b64url(json.dumps({"iss": cfg["issuer_id"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    msg = f"{head}.{body}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=msg, capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64url(der_to_raw(der))}"

class Client:
    def __init__(self, cfg, key_path):
        self.h = {"Authorization": "Bearer " + token(cfg, key_path)}
    def get(self, path, **params):
        r = requests.get(API + path, headers=self.h, params=params, timeout=60)
        r.raise_for_status()
        return r.json()["data"]
    def post(self, path, payload):
        r = requests.post(API + path, headers=self.h, json=payload, timeout=60)
        if r.status_code >= 400:
            sys.exit(f"POST {path} failed {r.status_code}: {r.text}")
        return r.json()["data"]

def gh_secret(name, value):
    subprocess.run(["gh", "secret", "set", name, "-R", REPO], input=value.encode(), check=True)
    print("  secret set:", name)

def main():
    cfg = json.load(open(os.path.join(SEC, "asc.json")))
    key_path = os.path.join(SEC, f"AuthKey_{cfg['key_id']}.p8")
    api = Client(cfg, key_path)

    found = [b for b in api.get("/bundleIds", **{"filter[identifier]": BUNDLE_ID}) if b["attributes"]["identifier"] == BUNDLE_ID]
    if found:
        bundle = found[0]
        print("bundle ID exists:", BUNDLE_ID)
    else:
        bundle = api.post("/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": BUNDLE_ID, "name": "Harbor", "platform": "IOS"}}})
        print("bundle ID registered:", BUNDLE_ID)

    priv, cer, p12, pw_file = (os.path.join(SEC, n) for n in ("dist.key", "dist.cer", "dist.p12", "dist.p12.password"))
    cert_id_file = os.path.join(SEC, "dist.cert_id")
    if not os.path.exists(p12):
        csr = os.path.join(SEC, "dist.csr")
        subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", priv, "-out", csr,
                        "-subj", "/CN=Harbor tvOS CI/C=US"], check=True, capture_output=True)
        cert = api.post("/certificates", {"data": {"type": "certificates", "attributes": {
            "certificateType": "DISTRIBUTION", "csrContent": open(csr).read()}}})
        open(cer, "wb").write(base64.b64decode(cert["attributes"]["certificateContent"]))
        open(cert_id_file, "w").write(cert["id"])
        password = pysecrets.token_urlsafe(18)
        open(pw_file, "w").write(password)
        pem = os.path.join(SEC, "dist.pem")
        subprocess.run(["openssl", "x509", "-inform", "DER", "-in", cer, "-out", pem], check=True)
        # macOS `security import` cannot read OpenSSL 3's default PKCS#12 encryption.
        subprocess.run(["openssl", "pkcs12", "-export", "-inkey", priv, "-in", pem, "-out", p12, "-passout", "pass:" + password,
                        "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"], check=True)
        os.chmod(priv, 0o600)
        print("distribution certificate created:", cert["id"])
    else:
        print("distribution certificate exists")
    cert_id = open(cert_id_file).read().strip()

    prof_path = os.path.join(SEC, "harbor.mobileprovision")
    if not os.path.exists(prof_path):
        prof = api.post("/profiles", {"data": {"type": "profiles",
            "attributes": {"name": PROFILE_NAME, "profileType": "TVOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})
        open(prof_path, "wb").write(base64.b64decode(prof["attributes"]["profileContent"]))
        print("provisioning profile created:", PROFILE_NAME)
    else:
        print("provisioning profile exists")

    print("writing GitHub secrets")
    gh_secret("TEAM_ID", cfg["team_id"])
    gh_secret("PROFILE_NAME", PROFILE_NAME)
    gh_secret("ASC_KEY_ID", cfg["key_id"])
    gh_secret("ASC_ISSUER_ID", cfg["issuer_id"])
    gh_secret("ASC_KEY_P8", open(key_path).read())
    gh_secret("DIST_CERT_P12", base64.b64encode(open(p12, "rb").read()).decode())
    gh_secret("DIST_CERT_PASSWORD", open(pw_file).read().strip())
    gh_secret("PROVISIONING_PROFILE", base64.b64encode(open(prof_path, "rb").read()).decode())
    print("done")

if __name__ == "__main__":
    main()
