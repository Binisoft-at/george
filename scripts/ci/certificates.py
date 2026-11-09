#!/usr/bin/env python3
"""Keeps automatic signing on CI from piling up Apple development certificates.

Every TestFlight run starts on a fresh Mac, so `xcodebuild -allowProvisioningUpdates` creates a new
"Apple Development" certificate named "Created via API" whose private key vanishes with the
runner. Apple caps how many a team may have ("maximum number of certificates").

Standing approval (HOW_WE_WORK.md): CI may revoke development certificates named "Created via API"
that it created itself or that are older than two hours – nothing else. Certificates of people
on the team and distribution certificates are never touched.

Output never names people or other projects (team members' certificates, pass type IDs): it ends
up in logs and on the ci-* branches, which anyone can read on a public repository. Only CI's own
"Created via API" certificates are shown one by one.

usage: certificates.py prune              revoke "Created via API" development certificates older than 2 h
       certificates.py list               count the certificates per type, list CI's own (read-only)
       certificates.py snapshot <file>    record the Apple Development serials in this Mac's keychain
       certificates.py revoke-new <file>  revoke the "Created via API" certificate(s) this run added
env:   ASC_KEY_ID ASC_ISSUER_ID and ASC_KEY_PATH or ASC_KEY_P8

Synced from the Binisoft handbook.
"""
import base64
import datetime
import re
import subprocess
import sys

import asc

DEVELOPMENT_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT", "MAC_APP_DEVELOPMENT"}
MIN_AGE = datetime.timedelta(hours=2)
CI_NAME = re.compile(r"created via api", re.I)


def normalize(serial):
    return (serial or "").strip().upper().lstrip("0")


def certificates():
    data, _ = asc.get_all("/certificates", {
        "limit": "200",
        "fields[certificates]": "name,displayName,certificateType,serialNumber,expirationDate,certificateContent",
    })
    return data


def is_ci_development(cert):
    a = cert["attributes"]
    name = f"{a.get('name') or ''} {a.get('displayName') or ''}"
    return a.get("certificateType") in DEVELOPMENT_TYPES and bool(CI_NAME.search(name))


def created_at(cert):
    """notBefore from the certificate itself; falls back to expiry minus one year."""
    a = cert["attributes"]
    content = a.get("certificateContent")
    if content:
        try:
            out = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-startdate"],
                                 input=base64.b64decode(content), capture_output=True, check=True).stdout.decode()
            value = out.strip().split("=", 1)[1]
            return datetime.datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
        except Exception:
            pass
    expires = datetime.datetime.fromisoformat(a["expirationDate"].replace("Z", "+00:00"))
    return expires - datetime.timedelta(days=365)


def describe(cert):
    """Type, name (only for CI's own certificates), shortened serial, expiry – no personal names."""
    a = cert["attributes"]
    name = (a.get("displayName") or a.get("name")) if is_ci_development(cert) else "name not shown"
    serial = (a.get("serialNumber") or "?")[-6:]
    return f"{a.get('certificateType')} · {name} · serial …{serial} · expires {(a.get('expirationDate') or '?')[:10]}"


def prune():
    now = datetime.datetime.now(datetime.timezone.utc)
    revoked = kept = 0
    for cert in certificates():
        if not is_ci_development(cert):
            continue
        age = now - created_at(cert)
        if age < MIN_AGE:
            kept += 1
            print(f"kept (younger than 2 h, maybe a running job): {describe(cert)}")
            continue
        asc.request("DELETE", f"/certificates/{cert['id']}")
        revoked += 1
        print(f"revoked: {describe(cert)}")
    print(f"Revoked {revoked} leftover CI development certificate(s); kept {kept} recent one(s).")


def list_all():
    certs = certificates()
    counts = {}
    for cert in certs:
        kind = cert["attributes"].get("certificateType") or "?"
        counts[kind] = counts.get(kind, 0) + 1
    ci = [c for c in certs if is_ci_development(c)]
    print(f"{len(certs)} certificate(s) on the team: " + ", ".join(f"{kind} {n}" for kind, n in sorted(counts.items())))
    print(f"{len(ci)} of them created by CI (\"Created via API\" development){':' if ci else '.'}")
    for cert in sorted(ci, key=lambda c: c["attributes"].get("expirationDate") or ""):
        print("  [CI] " + describe(cert))
    print("(People's and other projects' certificates are counted, not named – this output may be public.)")


def keychain_serials():
    pems = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
                          capture_output=True, text=True).stdout
    serials = set()
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", pems, re.S):
        out = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=pem, capture_output=True, text=True).stdout
        if out.startswith("serial="):
            serials.add(normalize(out[len("serial="):]))
    return serials


def snapshot(path):
    serials = keychain_serials()
    with open(path, "w") as handle:
        handle.write("\n".join(sorted(serials)) + "\n")
    print(f"Recorded {len(serials)} Apple Development identities before signing.")


def revoke_new(path):
    with open(path) as handle:
        before = {line.strip() for line in handle if line.strip()}
    new = keychain_serials() - before
    if not new:
        print("No development certificate was created in this run.")
        return
    for cert in certificates():
        serial = normalize(cert["attributes"].get("serialNumber"))
        if serial not in new:
            continue
        if is_ci_development(cert):
            asc.request("DELETE", f"/certificates/{cert['id']}")
            print(f"Revoked this run's certificate: {describe(cert)}")
        else:
            print(f"Not revoked (not a \"Created via API\" development certificate): {describe(cert)}")
        new.discard(serial)
    for serial in new:
        print(f"Not on the account (nothing revoked): {serial}")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command in ("prune", "list", "revoke-new") and not asc.has_key():
        print("No App Store Connect key in the environment – nothing to do.")
        return
    if command == "prune" and len(sys.argv) == 2:
        prune()
    elif command == "list" and len(sys.argv) == 2:
        list_all()
    elif command == "snapshot" and len(sys.argv) == 3:
        snapshot(sys.argv[2])
    elif command == "revoke-new" and len(sys.argv) == 3:
        revoke_new(sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
