"""App Store Connect API helpers for the CI scripts (standard library + openssl, no pip installs).

Env: ASC_KEY_ID, ASC_ISSUER_ID and either ASC_KEY_PATH (the .p8 file) or ASC_KEY_P8 (its text,
including the BEGIN/END lines). Synced from the Binisoft handbook.
"""
import atexit
import base64
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
_key_path = None


def has_key():
    return bool(os.environ.get("ASC_KEY_ID") and os.environ.get("ASC_ISSUER_ID")
                and (os.environ.get("ASC_KEY_PATH") or os.environ.get("ASC_KEY_P8")))


def key_path():
    """Path of the .p8 key; writes ASC_KEY_P8 to a private temp file when needed."""
    global _key_path
    if _key_path:
        return _key_path
    if os.environ.get("ASC_KEY_PATH"):
        _key_path = os.environ["ASC_KEY_PATH"]
        return _key_path
    text = os.environ["ASC_KEY_P8"]
    if "\n" not in text.strip() and "\\n" in text:
        text = text.replace("\\n", "\n")  # pasted with literal \n
    handle, path = tempfile.mkstemp(suffix=".p8")
    with os.fdopen(handle, "w") as file:
        file.write(text.strip() + "\n")
    os.chmod(path, 0o600)
    atexit.register(lambda: os.path.exists(path) and os.remove(path))
    _key_path = path
    return path


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _der_to_raw(signature):
    """ECDSA DER signature (openssl) to the raw r||s form JWT expects."""
    assert signature[0] == 0x30
    index = 2 if signature[1] < 0x80 else 2 + (signature[1] & 0x7F)
    parts = []
    for _ in range(2):
        assert signature[index] == 0x02
        length = signature[index + 1]
        value = signature[index + 2:index + 2 + length].lstrip(b"\x00")
        parts.append(value.rjust(32, b"\x00"))
        index += 2 + length
    return b"".join(parts)


def token():
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = (_b64url(json.dumps(header).encode()) + "." + _b64url(json.dumps(payload).encode())).encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path()],
                         input=signing_input, capture_output=True, check=True).stdout
    return signing_input.decode() + "." + _b64url(_der_to_raw(der))


def request(method, path, params=None, retries=3):
    """GET/DELETE against the API. Retries App Store Connect 5xx answers."""
    url = path if path.startswith("https://") else API + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + token()})
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            if error.code >= 500 and attempt < retries:
                time.sleep(2 ** attempt * 3)
                continue
            detail = error.read().decode(errors="replace")[:500]
            raise RuntimeError(f"{method} {path} → HTTP {error.code}: {detail}") from None


def get_all(path, params=None):
    """Every page of a list endpoint."""
    result = request("GET", path, params)
    data = list(result.get("data", []))
    included = list(result.get("included", []))
    while result.get("links", {}).get("next"):
        result = request("GET", result["links"]["next"])
        data += result.get("data", [])
        included += result.get("included", [])
    return data, included
