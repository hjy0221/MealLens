#!/usr/bin/env python3
"""Create a compact inventory for the AI Hub Korean food image tree.

AI Hub's archive is organized as ``category/dish/image``.  This inventory
keeps that hierarchy and counts files without copying the 16 GB source tree.
"""
import argparse
import json
from pathlib import Path

EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff"}


def index(root: Path, output: Path) -> dict:
    root = root.resolve()
    if not root.is_dir():
        raise ValueError(f"Source folder does not exist: {root}")
    dishes = []
    total = 0
    for category in sorted(p for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")):
        for dish in sorted(p for p in category.iterdir() if p.is_dir() and not p.name.startswith(".")):
            count = sum(1 for photo in dish.rglob("*") if photo.is_file() and photo.suffix.lower() in EXTENSIONS)
            if count:
                dishes.append({
                    "category": category.name,
                    "label": dish.name,
                    "relative_path": str(dish.relative_to(root)),
                    "images": count,
                })
                total += count
    report = {
        "source": str(root),
        "category_count": len({item["category"] for item in dishes}),
        "dish_count": len(dishes),
        "image_count": total,
        "dishes": dishes,
        "notes": [
            "AI Hub Korean food archive is retained outside the app source tree.",
            "Review AI Hub attribution, redistribution, and export conditions before shipping a derived model.",
        ],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        result = index(args.source, args.output)
        print(json.dumps({key: result[key] for key in ("category_count", "dish_count", "image_count")}, ensure_ascii=False))
    except (ValueError, OSError) as error:
        parser.exit(1, f"AI Hub index failed: {error}\n")
