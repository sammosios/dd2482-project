#!/usr/bin/env python3
"""Dokploy's one-time setup, run by the control plane's startup script
(node/cp.sh.tftpl) against Dokploy on this node's loopback:

  1. the first admin, from the Secret Manager secret Terraform writes
     (terraform/gcp: dokploy-admin, JSON with name, email and password)
  2. an API key for Terraform and CI, stored in the dokploy-api-key secret,
     where the later stages read it
  3. Dokploy's own domain, with a Let's Encrypt certificate

Every step checks first, so it runs on every boot. Creating the admin and
the key goes through Dokploy's own sign-up and tRPC endpoints, the ones its
UI uses: there is no documented API for this, so a Dokploy upgrade may need
a look here.

Usage: dokploy-bootstrap.py <admin secret> <api key secret> <host> <acme email>
"""
import base64
import http.cookiejar
import json
import sys
import time
import urllib.error
import urllib.request

DOKPLOY = "http://127.0.0.1:3000/api"
METADATA = "http://metadata.google.internal/computeMetadata/v1"
SECRETS = "https://secretmanager.googleapis.com/v1"


def log(msg):
    print(f"[dokploy-bootstrap] {msg}", flush=True)


def request(url, data=None, headers=None, opener=None, method=None):
    """Returns (status, parsed JSON or None). Never raises on HTTP errors."""
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with (opener or urllib.request.build_opener()).open(req, timeout=30) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, None


# --- Secret Manager, with this VM's service account --------------------------

def gcp_headers():
    _, tok = request(f"{METADATA}/instance/service-accounts/default/token",
                     headers={"Metadata-Flavor": "Google"})
    return {"Authorization": f"Bearer {tok['access_token']}"}


def secret_read(secret):
    status, body = request(f"{SECRETS}/{secret}/versions/latest:access", headers=gcp_headers())
    if status == 404:
        return None
    if status != 200:
        raise RuntimeError(f"reading {secret}: HTTP {status} {body}")
    return base64.b64decode(body["payload"]["data"]).decode()


def secret_write(secret, value):
    status, body = request(f"{SECRETS}/{secret}:addVersion", headers=gcp_headers(),
                           data={"payload": {"data": base64.b64encode(value.encode()).decode()}})
    if status != 200:
        raise RuntimeError(f"writing {secret}: HTTP {status} {body}")


# --- Dokploy -----------------------------------------------------------------

def wait_for_dokploy():
    for _ in range(120):
        status, _ = request(f"{DOKPLOY}/settings.getDokployVersion")
        if status in (200, 401, 403):
            return
        time.sleep(5)
    raise RuntimeError("Dokploy didn't answer on 127.0.0.1:3000 within 10 minutes")


def key_works(key):
    status, _ = request(f"{DOKPLOY}/settings.getDokployVersion", headers={"x-api-key": key})
    return status == 200


def create_api_key(admin):
    """Signs up the first admin (or signs in, if it exists) and mints a key."""
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    status, body = request(f"{DOKPLOY}/auth/sign-up/email", opener=opener, data=admin)
    if status // 100 == 2:
        log(f"created the admin {admin['email']}")
    else:
        # Only possible before any owner exists; afterwards, sign in.
        status, body = request(f"{DOKPLOY}/auth/sign-in/email", opener=opener,
                               data={"email": admin["email"], "password": admin["password"]})
        if status // 100 != 2:
            raise RuntimeError(f"neither sign-up nor sign-in worked (HTTP {status}): {body}")
        log(f"signed in as the existing admin {admin['email']}")

    status, body = request(f"{DOKPLOY}/trpc/organization.all", opener=opener)
    org_id = body["result"]["data"]["json"][0]["id"]

    # rateLimitEnabled must be explicit: better-auth's api-key plugin
    # defaults to 10 requests a day, and an exhausted key answers 401.
    status, body = request(f"{DOKPLOY}/trpc/user.createApiKey", opener=opener, data={"json": {
        "name": "terraform", "metadata": {"organizationId": org_id}, "rateLimitEnabled": False}})
    if status != 200:
        raise RuntimeError(f"user.createApiKey: HTTP {status} {body}")
    return body["result"]["data"]["json"]["key"]


def ensure_domain(key, host, email):
    auth = {"x-api-key": key}
    _, current = request(f"{DOKPLOY}/settings.getWebServerSettings", headers=auth)
    want = {"host": host, "certificateType": "letsencrypt", "https": True, "letsEncryptEmail": email}
    if current and all(current.get(k) == v for k, v in want.items()):
        return
    status, body = request(f"{DOKPLOY}/settings.assignDomainServer", headers=auth, data=want)
    if status != 200:
        raise RuntimeError(f"settings.assignDomainServer: HTTP {status} {body}")
    log(f"Dokploy's UI is at https://{host}")


def main(admin_secret, key_secret, host, email):
    wait_for_dokploy()
    admin = json.loads(secret_read(admin_secret))

    key = secret_read(key_secret)
    if not (key and key_works(key)):
        key = create_api_key(admin)
        secret_write(key_secret, key)
        log("stored a new API key in Secret Manager")

    # The admin has to exist before the UI goes public: on a fresh Dokploy,
    # whoever opens it first can create the owner account.
    ensure_domain(key, host, email)


if __name__ == "__main__":
    main(*sys.argv[1:])
