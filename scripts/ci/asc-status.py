#!/usr/bin/env python3
"""Prints the latest App Store Connect builds of this app (processing state, TestFlight state,
platform, version, build number) and the team's signing certificates. Read-only.

env: ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 (or ASC_KEY_PATH); BUNDLE_ID (default: APP_BUNDLE_ID
     from Config/Base.xcconfig). Synced from the Binisoft handbook.
"""
import os
import subprocess
import sys

import asc
import certificates

here = os.path.dirname(os.path.abspath(__file__))


def bundle_id():
    if os.environ.get("BUNDLE_ID"):
        return os.environ["BUNDLE_ID"]
    out = subprocess.run([sys.executable, os.path.join(here, "xcconfig.py"), "APP_BUNDLE_ID"],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def main():
    if not asc.has_key():
        sys.exit("ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 are needed (repository secrets).")
    bundle = bundle_id()
    apps, _ = asc.get_all("/apps", {"filter[bundleId]": bundle})
    if not apps:
        print(f"No App Store Connect app with bundle ID {bundle}. Create it first (SETUP_CHECKLIST.md, section 3).")
        sys.exit(1)
    app = apps[0]
    print(f"App: {app['attributes']['name']} ({bundle}), id {app['id']}")
    result = asc.request("GET", "/builds", {
        "filter[app]": app["id"], "sort": "-uploadedDate", "limit": "10",
        "include": "preReleaseVersion,buildBetaDetail",
        "fields[preReleaseVersions]": "version,platform",
        "fields[buildBetaDetails]": "internalBuildState,externalBuildState",
    })
    included = {(i["type"], i["id"]): i["attributes"] for i in result.get("included", [])}
    print(f"\nLatest builds ({len(result['data'])}):")
    for build in result["data"]:
        a = build["attributes"]
        rel = build.get("relationships", {})
        version_ref = (rel.get("preReleaseVersion", {}).get("data") or {})
        beta_ref = (rel.get("buildBetaDetail", {}).get("data") or {})
        version = included.get(("preReleaseVersions", version_ref.get("id")), {})
        beta = included.get(("buildBetaDetails", beta_ref.get("id")), {})
        print(f"- {version.get('platform', '?'):6} {version.get('version', '?')} ({a.get('version')}) · "
              f"uploaded {(a.get('uploadedDate') or '?')[:16]} · processing {a.get('processingState')} · "
              f"TestFlight {beta.get('internalBuildState', '?')} · expired {a.get('expired')}")
    print()
    certificates.list_all()


if __name__ == "__main__":
    main()
