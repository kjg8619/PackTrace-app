#!/usr/bin/env python3
"""Catalogue snapshots outside Git: manifest, bundle, verify, install, rebuild.

The card catalogues the app ships (Sources/PackTraceCore/Resources/catalog)
are generated from TCGdex data. A public checkout does not carry them; it
carries catalog-manifest.json instead, which names every snapshot the pool
pins with its content hash and file hash. The snapshots themselves come from
a bundle (a .tar.gz made by `pack`, published separately) or are rebuilt from
TCGdex with the pinned versions.

  catalogs.py manifest            write catalog-manifest.json from the installed snapshots
  catalogs.py pack [OUT.tar.gz]   bundle the installed snapshots (checked against the manifest)
  catalogs.py verify              check the installed snapshots against the manifest
  catalogs.py install SRC         install from a bundle path or https URL, verifying every file
  catalogs.py rebuild [SET ...]   rebuild from TCGdex with the pinned versions (network, slow)

Standard library only. Nothing here reads or writes anything outside the
repository except the bundle path or URL it is given.
"""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CATALOG_DIR = os.path.join(ROOT, "Sources", "PackTraceCore", "Resources", "catalog")
POOL_DIR = os.path.join(ROOT, "Sources", "PackTraceCore", "Resources", "pool")
MANIFEST = os.path.join(ROOT, "catalog-manifest.json")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def installed():
    if not os.path.isdir(CATALOG_DIR):
        return []
    return sorted(f for f in os.listdir(CATALOG_DIR) if f.endswith(".json"))


def load_manifest():
    if not os.path.exists(MANIFEST):
        sys.exit("catalog-manifest.json is missing")
    return json.load(open(MANIFEST))


def active_pool():
    pools = sorted(f for f in os.listdir(POOL_DIR) if f.startswith("pool-v") and f.endswith(".json"))
    return pools[-1] if pools else None


def write_manifest():
    entries = []
    for name in installed():
        data = open(os.path.join(CATALOG_DIR, name), "rb").read()
        catalog = json.loads(data)
        entries.append({
            "file": name,
            "set": catalog["set"]["externalSetID"],
            "catalogVersion": catalog["catalogVersion"],
            "contentHash": catalog["contentHash"],
            "sha256": sha256(data),
            "bytes": len(data),
        })
    if not entries:
        sys.exit("no installed snapshots to describe")
    manifest = {
        "note": ("Card catalogue snapshots the app is built with. They are generated from TCGdex data "
                 "(MIT, see NOTICE) and are not tracked in Git: install them with "
                 "scripts/prepare-catalogs.sh. contentHash is the app's own hash of the catalogue; "
                 "sha256 is the file's."),
        "pool": active_pool(),
        "catalogs": entries,
    }
    with open(MANIFEST, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"wrote {os.path.relpath(MANIFEST, ROOT)}: {len(entries)} snapshots, pool {manifest['pool']}")


def verify(quiet=False):
    manifest = load_manifest()
    present = set(installed())
    missing, mismatched = [], []
    for entry in manifest["catalogs"]:
        path = os.path.join(CATALOG_DIR, entry["file"])
        if entry["file"] not in present:
            missing.append(entry["file"])
            continue
        if sha256(open(path, "rb").read()) != entry["sha256"]:
            mismatched.append(entry["file"])
    extra = sorted(present - {e["file"] for e in manifest["catalogs"]})
    if not quiet:
        print(f"manifest {len(manifest['catalogs'])} · installed {len(present)} · "
              f"missing {len(missing)} · different {len(mismatched)} · not in manifest {len(extra)}")
        for label, items in (("missing", missing), ("different", mismatched), ("not in manifest", extra)):
            if items:
                print(f"  {label}: {' '.join(items[:8])}{' …' if len(items) > 8 else ''}")
    return not missing and not mismatched


def pack(out):
    if not verify(quiet=True):
        sys.exit("installed snapshots do not match catalog-manifest.json; run `catalogs.py verify`")
    manifest = load_manifest()
    out = out or os.path.join(ROOT, ".build", f"packtrace-catalogs-{(manifest['pool'] or 'pool').replace('.json', '')}.tar.gz")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with tarfile.open(out, "w:gz") as tar:
        for entry in manifest["catalogs"]:
            info = tar.gettarinfo(os.path.join(CATALOG_DIR, entry["file"]), arcname=f"catalog/{entry['file']}")
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            with open(os.path.join(CATALOG_DIR, entry["file"]), "rb") as f:
                tar.addfile(info, f)
    data = open(out, "rb").read()
    print(f"wrote {out} ({len(data):,} bytes, sha256 {sha256(data)})")


def install(source):
    manifest = load_manifest()
    wanted = {e["file"]: e for e in manifest["catalogs"]}
    if source.startswith("https://"):
        request = urllib.request.Request(source, headers={"User-Agent": "PackTrace catalog install"})
        with urllib.request.urlopen(request, timeout=120) as response:
            blob = response.read()
    else:
        blob = open(source, "rb").read()
    staged = {}
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        for member in tar.getmembers():
            name = os.path.basename(member.name)
            # Only regular files the manifest names; nothing else is written.
            if not member.isfile() or name not in wanted:
                continue
            data = tar.extractfile(member).read()
            if sha256(data) != wanted[name]["sha256"]:
                sys.exit(f"{name}: file hash does not match the manifest; nothing installed")
            staged[name] = data
    missing = sorted(set(wanted) - set(staged))
    if missing:
        sys.exit(f"bundle lacks {len(missing)} snapshots ({' '.join(missing[:5])}…); nothing installed")
    os.makedirs(CATALOG_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.dirname(CATALOG_DIR)) as tmp:
        for name, data in staged.items():
            with open(os.path.join(tmp, name), "wb") as f:
                f.write(data)
        for name in staged:
            shutil.move(os.path.join(tmp, name), os.path.join(CATALOG_DIR, name))
    print(f"installed {len(staged)} snapshots into {os.path.relpath(CATALOG_DIR, ROOT)}")


def rebuild(sets):
    manifest = load_manifest()
    entries = [e for e in manifest["catalogs"] if not sets or e["set"] in sets]
    drifted = []
    for entry in entries:
        source = os.path.join(ROOT, "catalog-sources", f"{entry['set']}.json")
        out = os.path.join(CATALOG_DIR, entry["file"])
        print(f"== {entry['set']} → {entry['catalogVersion']}", flush=True)
        subprocess.run(["swift", "run", "-c", "release", "packtrace-catalog", "fetch", "--products", source,
                        "--version", entry["catalogVersion"], "--out", out, "--force"], cwd=ROOT, check=True)
        rebuilt = json.load(open(out))
        if rebuilt["contentHash"] != entry["contentHash"]:
            drifted.append(entry["set"])
    print(f"rebuilt {len(entries)} snapshots")
    if drifted:
        print(f"TCGdex data changed since the manifest for {len(drifted)} sets: {' '.join(drifted)}")
        print("The app works with them; tests pinned to the published snapshots may not.")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    command, rest = argv[0], argv[1:]
    if command == "manifest":
        write_manifest()
    elif command == "verify":
        return 0 if verify() else 1
    elif command == "pack":
        pack(rest[0] if rest else None)
    elif command == "install":
        if not rest:
            sys.exit("install needs a bundle path or https URL")
        install(rest[0])
    elif command == "rebuild":
        rebuild(set(rest))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
