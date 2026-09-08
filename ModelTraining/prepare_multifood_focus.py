"""Retain every multi-food training image and a fixed single-food subset.

Uses existing splits unchanged; no held-out image enters training. Images
are linked to avoid copying. Fixed recipe: 1,800 single-food training and
200 single-food validation images plus all multi-food images in each split.
"""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
if args.output.exists():
    parser.error('Use a fresh output directory')
report = {}
for split in ('train', 'validation', 'test'):
    rows = json.loads((args.source / split / 'annotations.json').read_text())
    if split != 'test':
        multiple = [r for r in rows if len(r['annotations']) > 1]
        single = [r for r in rows if len(r['annotations']) == 1]
        rows = multiple + single[:1800 if split == 'train' else 200]
    destination = args.output / split
    destination.mkdir(parents=True)
    for row in rows:
        (destination / row['image']).symlink_to((args.source / split / row['image']).resolve())
    (destination / 'annotations.json').write_text(json.dumps(rows))
    report[split] = {'images': len(rows), 'boxes': sum(len(r['annotations']) for r in rows),
                     'multi_food_images': sum(len(r['annotations']) > 1 for r in rows)}
(args.output / 'inventory.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
