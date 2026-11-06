#!/usr/bin/env python3
"""Writes kubeconform JSON schemas for the Shadewright CRDs into schemas/<group>/<kind>_<version>.json.

Usage: scripts/crd_schemas.py CRD_FILE... (needs PyYAML; run by hand when the pinned chart changes, not in CI)

Take the CRDs from the operator tag the chart in infrastructure/shadewright/ocirepository.yaml was built from:

    git -C ../shadewright show v0.3.0-rc.2:config/crd/bases/remediation.shadewright.io_remediationsettings.yaml > /tmp/s.yaml

The CRD catalog that render_dir uses (scripts/lib.sh) has no Shadewright schemas, and kubeconform -strict refuses a
kind without one. Like kubeconform's openapi2jsonschema, every object schema that does not say otherwise gets
additionalProperties: false, so a misspelled field fails the render.
"""
import json
import os
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def strict(node):
    if isinstance(node, dict):
        if node.get("type") == "object" and "properties" in node and "additionalProperties" not in node \
                and not node.get("x-kubernetes-preserve-unknown-fields"):
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)
    return node


def main(paths):
    if not paths:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    for path in paths:
        with open(path, encoding="utf-8") as f:
            crd = yaml.safe_load(f)
        if crd.get("kind") != "CustomResourceDefinition":
            print(f"{path}: not a CustomResourceDefinition", file=sys.stderr)
            return 1
        group, kind = crd["spec"]["group"], crd["spec"]["names"]["kind"].lower()
        os.makedirs(os.path.join(ROOT, "schemas", group), exist_ok=True)
        for version in crd["spec"]["versions"]:
            schema = strict(version["schema"]["openAPIV3Schema"])
            # metadata is validated by the API server, not here; the CRD leaves it as a bare object.
            schema.get("properties", {}).pop("metadata", None)
            schema.setdefault("properties", {})["metadata"] = {"type": "object"}
            out = os.path.join(ROOT, "schemas", group, f"{kind}_{version['name']}.json")
            with open(out, "w", encoding="utf-8") as f:
                json.dump(schema, f, indent=2, sort_keys=True)
                f.write("\n")
            print(os.path.relpath(out, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
