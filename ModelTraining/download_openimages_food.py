"""Download attribution-verified Open Images food boxes and classification crops.

Only images whose metadata explicitly states CC BY 2.0 are retained. Google
licenses annotations under CC BY 4.0 but warns users to verify image rights;
the per-image attribution table is therefore kept with the local dataset.
"""
import argparse
import csv
import io
import json
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from PIL import Image

LABELS = {
    '/m/02wbm': 'food', '/m/01_bhs': 'fast_food', '/m/0270h': 'dessert',
    '/m/09728': 'bread', '/m/0fszt': 'cake', '/m/02xwb': 'fruit',
    '/m/0cdn1': 'hamburger', '/m/01dwwc': 'pancake', '/m/05z55': 'pasta',
    '/m/0663v': 'pizza', '/m/0grw1': 'salad', '/m/0l515': 'sandwich',
    '/m/06nwz': 'seafood', '/m/07030': 'sushi', '/m/0f4s2w': 'vegetable'
}
URLS = {
    'train': ('https://storage.googleapis.com/openimages/v6/oidv6-train-annotations-bbox.csv',
              'https://storage.googleapis.com/openimages/2018_04/train/train-images-boxable-with-rotation.csv'),
    'validation': ('https://storage.googleapis.com/openimages/v5/validation-annotations-bbox.csv',
                   'https://storage.googleapis.com/openimages/2018_04/validation/validation-images-with-rotation.csv'),
    'test': ('https://storage.googleapis.com/openimages/v5/test-annotations-bbox.csv',
             'https://storage.googleapis.com/openimages/2018_04/test/test-images-with-rotation.csv')
}
ALLOWED_LICENSE = 'https://creativecommons.org/licenses/by/2.0/'


def rows(url):
    with urllib.request.urlopen(url) as response:
        yield from csv.DictReader(io.TextIOWrapper(response, encoding='utf-8', newline=''))


def collect(split, maximum):
    annotations = defaultdict(list)
    counts = defaultdict(set)
    # IDs are hashes and the source CSV is ordered by ID, giving a stable sample.
    for row in rows(URLS[split][0]):
        label = LABELS.get(row['LabelName'])
        if not label or row.get('IsGroupOf') == '1' or row.get('IsDepiction') == '1' or row.get('IsInside') == '1':
            continue
        image_id = row['ImageID']
        if image_id not in counts[label] and len(counts[label]) >= maximum * 2:
            continue
        counts[label].add(image_id)
        annotations[image_id].append({
            'label': label, 'xmin': float(row['XMin']), 'xmax': float(row['XMax']),
            'ymin': float(row['YMin']), 'ymax': float(row['YMax'])})
    candidates = set(annotations)
    metadata = {}
    for row in rows(URLS[split][1]):
        image_id = row['ImageID']
        if image_id in candidates and row['License'] == ALLOWED_LICENSE:
            metadata[image_id] = row
    selected, accepted = {}, defaultdict(int)
    for image_id in sorted(metadata):
        boxes = [box for box in annotations[image_id] if accepted[box['label']] < maximum]
        if boxes:
            selected[image_id] = boxes
            for label in {box['label'] for box in boxes}:
                accepted[label] += 1
    return selected, metadata


def download_one(split, image_id, folder):
    destination = folder / (image_id + '.jpg')
    if not destination.exists():
        url = f'https://open-images-dataset.s3.amazonaws.com/{split}/{image_id}.jpg'
        with urllib.request.urlopen(url, timeout=60) as response:
            destination.write_bytes(response.read())
    with Image.open(destination) as image:
        image.verify()
    return image_id


def run(split, output, maximum, workers):
    selected, metadata = collect(split, maximum)
    images = output / split / 'images'
    images.mkdir(parents=True, exist_ok=True)
    failed = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(download_one, split, image_id, images): image_id for image_id in selected}
        for index, future in enumerate(as_completed(futures), 1):
            try: future.result()
            except Exception as error: failed[futures[future]] = str(error)
            if index % 500 == 0: print(f'{split}: downloaded {index}/{len(futures)}', flush=True)
    for image_id in failed: selected.pop(image_id, None)
    attribution_fields = ['ImageID', 'OriginalURL', 'OriginalLandingURL', 'License', 'AuthorProfileURL', 'Author', 'Title']
    with (output / split / 'attribution.csv').open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=attribution_fields); writer.writeheader()
        for image_id in sorted(selected):
            writer.writerow({field: metadata[image_id].get(field, '') for field in attribution_fields})
    crop_counts = defaultdict(int)
    detector = []
    for image_id, boxes in sorted(selected.items()):
        path = images / (image_id + '.jpg')
        with Image.open(path) as source:
            image = source.convert('RGB'); width, height = image.size
            object_boxes = []
            for index, box in enumerate(boxes):
                x1, x2 = box['xmin'] * width, box['xmax'] * width
                y1, y2 = box['ymin'] * height, box['ymax'] * height
                if x2 <= x1 or y2 <= y1: continue
                label = box['label']
                crop_folder = output / split / 'classification' / label
                crop_folder.mkdir(parents=True, exist_ok=True)
                image.crop((x1, y1, x2, y2)).save(crop_folder / f'{image_id}_{index}.jpg', quality=90)
                crop_counts[label] += 1
                object_boxes.append({'label': 'food', 'coordinates': {'x': (x1+x2)/2, 'y': (y1+y2)/2,
                                     'width': x2-x1, 'height': y2-y1}})
            if object_boxes:
                detector.append({'image': image_id + '.jpg', 'annotations': object_boxes})
    (output / split / 'annotations.json').write_text(json.dumps(detector))
    report = {'source': 'Open Images', 'split': split, 'image_license': 'CC BY 2.0 verified from metadata',
              'annotation_license': 'CC BY 4.0', 'images': len(detector), 'boxes': sum(map(len, (r['annotations'] for r in detector))),
              'classification_crops': dict(sorted(crop_counts.items())), 'failed_downloads': failed}
    (output / split / 'inventory.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('split', choices=URLS)
    parser.add_argument('output', type=Path)
    parser.add_argument('--max-per-class', type=int, default=1000)
    parser.add_argument('--workers', type=int, default=12)
    args = parser.parse_args()
    # One root can be populated by separate split runs. Existing image files
    # are reused so interrupted downloads can resume safely.
    split_output = args.output / args.split
    if split_output.exists():
        run(args.split, args.output, args.max_per_class, args.workers)
        raise SystemExit(0)
    # run() expects a new root, so use a temporary wrapper when root already exists.
    if args.output.exists():
        # Reuse implementation by staging into a sibling, then move only the split.
        staging = args.output.with_name(args.output.name + '-' + args.split + '-staging')
        run(args.split, staging, args.max_per_class, args.workers)
        (staging / args.split).rename(split_output)
        staging.rmdir()
    else:
        run(args.split, args.output, args.max_per_class, args.workers)
