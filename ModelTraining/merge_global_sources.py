#!/usr/bin/env python3
"""Merge independently licensed food datasets into one namespaced raw tree.

Each source must contain one folder per label. A label can contain capture
group folders, or images directly. The output uses ``source__label`` classes
so similarly named dishes from different datasets are never silently merged.
Exact duplicate files with different labels are quarantined so they cannot
leak across train/test splits. No network access is performed by this tool.
"""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff"}


def safe_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9가-힣._-]+", "_", value.strip())
    value = value.strip("._")
    if not value:
        raise ValueError("Source and label names must contain letters or numbers.")
    return value[:100]


def merge(specs, destination: Path):
    if destination.exists():
        raise ValueError("Choose a new output folder; existing data is never overwritten.")
    destination.mkdir(parents=True)
    records = []
    hashes = {}
    conflicts = []
    for source_name, source_path in specs:
        source_name = safe_name(source_name)
        source_path = source_path.resolve()
        if not source_path.is_dir():
            raise ValueError(f"Source folder does not exist: {source_path}")
        labels = sorted(p for p in source_path.iterdir() if p.is_dir() and not p.name.startswith("."))
        if not labels:
            raise ValueError(f"No label folders found in {source_path}")
        for label_path in labels:
            class_name = f"{source_name}__{safe_name(label_path.name)}"
            for photo in sorted(label_path.rglob("*")):
                if not photo.is_file() or photo.suffix.lower() not in EXTENSIONS:
                    continue
                digest = hashlib.sha256(photo.read_bytes()).hexdigest()
                previous = hashes.get(digest)
                if previous and previous["class"] != class_name:
                    previous_path = destination / previous["staged"]
                    previous_path.unlink(missing_ok=True)
                    records = [record for record in records if record["sha256"] != digest]
                    conflict_path = destination / ".conflicts" / (digest + photo.suffix.lower())
                    conflict_path.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(photo, conflict_path)
                    conflicts.append({"sha256": digest, "first": previous, "second": str(photo),
                                      "quarantined": str(conflict_path.relative_to(destination))})
                    del hashes[digest]
                    continue
                if previous:
                    continue
                relative = photo.relative_to(label_path)
                # A flat class folder has no capture-session metadata. Treat
                # each image as its own group, matching prepare_dataset.py's
                # safe fallback and avoiding a split with only one group.
                group = relative.parts[0] if len(relative.parts) > 1 else digest
                output = destination / class_name / safe_name(group) / (digest + photo.suffix.lower())
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(photo, output)
                record = {
                    "source_name": source_name,
                    "source": str(photo),
                    "label": label_path.name,
                    "class": class_name,
                    "group": group,
                    "sha256": digest,
                    "staged": str(output.relative_to(destination)),
                }
                hashes[digest] = record
                records.append(record)
    if len({record["class"] for record in records}) < 2:
        raise ValueError("At least two namespaced classes are required.")
    report = {"sources": [name for name, _ in specs], "image_count": len(records),
              "conflicts_quarantined": conflicts, "records": records,
              "limitations": ["Exact duplicates are checked and contradictory labels are quarantined; near-duplicates require manual review.",
                              "Namespaced classes stay separate until a reviewed label map merges them."]}
    (destination / "sources-manifest.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--source", action="append", required=True, metavar="NAME=PATH",
                        help="Repeat for every dataset root, e.g. --source food101=/data/food101")
    args = parser.parse_args()
    specs = []
    for value in args.source:
        if "=" not in value:
            parser.error("--source must use NAME=PATH")
        name, path = value.split("=", 1)
        specs.append((name, Path(path)))
    try:
        report = merge(specs, args.destination)
        print(json.dumps({"sources": report["sources"], "image_count": report["image_count"]}, ensure_ascii=False))
    except (ValueError, OSError) as error:
        parser.exit(1, f"Sources not merged: {error}\n")
