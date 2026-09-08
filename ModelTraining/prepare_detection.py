"""Merge UEC annotations before deterministic image-group splitting.

Produces a class-agnostic food detector dataset. Original category labels
remain in the source folders. Source images stay outside git.
"""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image


def deduplicate_boxes(boxes):
    """Collapse near-identical dish annotations after class-agnostic merging."""
    kept = []
    def area(b):
        return max(0, b[2]-b[0]) * max(0, b[3]-b[1])
    for box in sorted(boxes, key=lambda b: (-area(b), b)):
        if area(box) == 0:
            continue
        duplicate = False
        for other in kept:
            intersection = max(0, min(box[2], other[2])-max(box[0], other[0])) * max(0, min(box[3], other[3])-max(box[1], other[1]))
            if intersection / (area(box)+area(other)-intersection) >= 0.75:
                duplicate = True
                break
        if not duplicate:
            kept.append(box)
    return sorted(kept)


def prepare(root, output, limit):
    unique = {}
    image_ids = set()
    paths = set()
    for annotations in sorted(root.glob('*/bb_info.txt')):
        for row in annotations.read_text().splitlines()[1:]:
            fields = row.split()
            if len(fields) != 5:
                continue
            image_id, *coords = fields
            path = annotations.parent / (image_id + '.jpg')
            if not path.exists():
                continue
            image_ids.add(image_id)
            paths.add(path)
            # Filenames are NOT globally unique: unrelated photos may reuse
            # an ID across categories. Only content identity may merge boxes.
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            entry = unique.setdefault(digest, {'path': path, 'boxes': set()})
            entry['boxes'].add(tuple(map(int, coords)))
    partitions = {name: [] for name in ('train', 'validation', 'test')}
    for digest, entry in sorted(unique.items())[:limit or None]:
        split_value = int(hashlib.sha256(('split:' + digest).encode()).hexdigest()[:8], 16) % 10
        split = 'test' if split_value == 0 else 'validation' if split_value == 1 else 'train'
        folder = output / split
        folder.mkdir(parents=True, exist_ok=True)
        with Image.open(entry['path']) as original:
            width, height = original.size
            image = original.convert('RGB')
            image.thumbnail((640, 640))
            sx, sy = image.width / width, image.height / height
            boxes = []
            for x1, y1, x2, y2 in deduplicate_boxes(entry['boxes']):
                x1, y1, x2, y2 = max(0, x1), max(0, y1), min(width, x2), min(height, y2)
                if x2 <= x1 or y2 <= y1:
                    continue
                boxes.append({'label': 'food', 'coordinates': {
                    'x': (x1+x2)*sx/2, 'y': (y1+y2)*sy/2,
                    'width': (x2-x1)*sx, 'height': (y2-y1)*sy}})
            if not boxes:
                continue
            image.save(folder / (digest + '.jpg'), quality=90)
        partitions[split].append({'image': digest + '.jpg', 'annotations': boxes})
    report = {'source_image_ids': len(image_ids), 'source_paths': len(paths), 'unique_images': len(unique), 'splits': {}}
    for split, rows in partitions.items():
        (output / split).mkdir(parents=True, exist_ok=True)
        (output / split / 'annotations.json').write_text(json.dumps(rows))
        report['splits'][split] = {'images': len(rows), 'boxes': sum(len(r['annotations']) for r in rows),
                                  'multi_food_images': sum(len(r['annotations']) > 1 for r in rows)}
    (output / 'inventory.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--limit', type=int, default=0)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a fresh output directory')
    prepare(args.root, args.output, args.limit)
