#!/usr/bin/env python3
# 偶拾 (Oushi) · Copyright © 2026 Zuming Hu · https://github.com/SolarZumi/Oushi_Public
# Licensed under the GNU GPL v3 with additional terms under its section 7: see LICENSE and ADDITIONAL-TERMS.md.
"""Copy the authoritative license files into the app, or verify them with --check."""
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    resources = root / "App" / "Oushi" / "Resources"
    documents = {
        "LICENSE": "OushiLicense.txt",
        "ADDITIONAL-TERMS.md": "OushiAdditionalTerms.txt",
        "BRANDING.md": "OushiBranding.txt",
    }
    stale = []
    for source, destination in documents.items():
        data = (root / source).read_bytes()
        target = resources / destination
        if args.check:
            if not target.exists() or target.read_bytes() != data:
                stale.append(destination)
        else:
            resources.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    if stale:
        parser.exit(1, "Out-of-date license resources: " + ", ".join(stale) + "; run Tools/sync_legal.py\n")
    print("License resources match the repository." if args.check else "Updated the app's license resources.")


if __name__ == "__main__":
    main()
