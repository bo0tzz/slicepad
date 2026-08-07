#!/usr/bin/env python3
"""Add a release to sidestore.json, the AltStore-format source SideStore reads.

Kept as a script rather than a here-doc in the workflow because it has to be
idempotent: re-running a release must replace that version's entry rather than
append a second one, and a source with two entries for the same version is the
kind of thing that only misbehaves on someone's device.
"""
import argparse
import datetime
import hashlib
import json
import pathlib

SOURCE = pathlib.Path(__file__).resolve().parent.parent / "sidestore.json"

DESCRIPTION = """\
Slice 3D models on an iPad with OrcaSlicer's own engine, driven by a profile you \
export from desktop Orca.

Open a mesh — Shapr3D's export works directly — adjust wall count, infill and \
supports, slice, and send the G-code to a Klipper printer over Moonraker.

Unsigned and distributed outside the App Store: OrcaSlicer is AGPL-3.0, which \
Apple's terms are incompatible with."""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--ipa", required=True, type=pathlib.Path)
    parser.add_argument("--repo", required=True, help="owner/name on GitHub")
    args = parser.parse_args()

    payload = args.ipa.read_bytes()
    entry = {
        "version": args.version,
        "date": datetime.date.today().isoformat(),
        "localizedDescription": f"SlicePad {args.version}.",
        "downloadURL": (
            f"https://github.com/{args.repo}/releases/download/"
            f"v{args.version}/SlicePad.ipa"
        ),
        "size": len(payload),
        # SideStore verifies what it downloaded against this.
        "sha256": hashlib.sha256(payload).hexdigest(),
        "minOSVersion": "17.0",
    }

    if SOURCE.exists():
        source = json.loads(SOURCE.read_text())
    else:
        source = {
            "name": "SlicePad",
            "identifier": f"{args.repo.split('/')[0]}.slicepad.source",
            "apps": [
                {
                    "name": "SlicePad",
                    "bundleIdentifier": "me.bo0tzz.slicepad",
                    "developerName": args.repo.split("/")[0],
                    "subtitle": "OrcaSlicer's engine, on an iPad.",
                    "iconURL": (
                        f"https://raw.githubusercontent.com/{args.repo}/main/"
                        "app/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
                    ),
                    "localizedDescription": DESCRIPTION,
                    "versions": [],
                }
            ],
        }

    app = source["apps"][0]
    # Replace rather than append: re-running a release must not leave two entries
    # claiming to be the same version.
    app["versions"] = [v for v in app["versions"] if v["version"] != args.version]
    app["versions"].insert(0, entry)

    SOURCE.write_text(json.dumps(source, indent=2) + "\n")
    print(f"sidestore.json now lists {len(app['versions'])} version(s), newest {args.version}")


if __name__ == "__main__":
    main()
