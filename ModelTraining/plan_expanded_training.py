"""Plan a reproducible 251-class experiment with fixed Food-101 test images.

Original Food-101 train/validation/test membership is preserved. Korean
duplicates with conflicting labels are excluded globally before splitting.
No original data is modified. The output is consumed by NormalizeTrainingImages.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import random
import unicodedata

def plan(food101, korean, output, baseline):
    records = []
    seen = {}
    conflicts = set()
    for category in sorted(korean.iterdir()):
        if not category.is_dir() or category.name.startswith('.'):
            continue
        for dish in sorted(category.iterdir()):
            if not dish.is_dir():
                continue
            label = 'aihub_korea__' + unicodedata.normalize('NFC', dish.name)
            for photo in sorted(dish.rglob('*')):
                if not photo.is_file() or photo.suffix.lower() not in {'.jpg', '.jpeg', '.png'}:
                    continue
                digest = hashlib.sha256(photo.read_bytes()).hexdigest()
                if digest in seen and seen[digest]['label'] != label:
                    conflicts.add(digest)
                else:
                    seen.setdefault(digest, dict(source=str(photo.resolve()), label=label, sha256=digest))
    grouped = collections.defaultdict(list)
    for digest, record in seen.items():
        if digest not in conflicts:
            grouped[record['label']].append(record)
    for label, batch in sorted(grouped.items()):
        batch.sort(key=lambda r:r['sha256'])
        random.Random('korean-20260906-' + label).shuffle(batch)
        for split, start, end in [('test',0,30), ('validation',30,60), ('train',60,210)]:
            for record in batch[start:end]:
                records.append(dict(record, split=split, prepared=f'{split}/{label}/{record["sha256"]}.jpg'))
    # Use the actual baseline predictions: directory iteration order is not
    # reproducible, so choosing the first sorted filenames is not equivalent.
    baseline_tests = collections.defaultdict(set)
    for prediction in json.loads(baseline.read_text())['predictions']:
        baseline_tests[prediction['expected']].add(prediction['image'])
    for split, count in [('train',150), ('validation',30), ('test',15)]:
        for folder in sorted((food101 / split).iterdir()):
            if not folder.is_dir():
                continue
            photos = sorted(folder.iterdir())[:count] if split != 'test' else [folder / name for name in sorted(baseline_tests[folder.name])]
            if split == 'test' and len(photos) != count:
                raise ValueError('Missing baseline test set: ' + folder.name)
            for photo in photos:
                digest = hashlib.sha256(photo.read_bytes()).hexdigest()
                if digest in seen:
                    raise ValueError('Cross-source duplicate requires review: ' + str(photo))
                records.append(dict(source=str(photo.resolve()), label=folder.name, sha256=digest,
                                    split=split, prepared=f'{split}/{folder.name}/{digest}.jpg'))
    counts = dict(collections.Counter(r['split'] for r in records))
    report = dict(records=records, counts=counts, korean_classes=len(grouped),
                  conflicts_excluded=len(conflicts), food101_test='Original fixed 15 images per class',
                  limitations=['Korean source has no capture-session groups; near-duplicate leakage remains possible.',
                               'Classifier accuracy is not portion or calorie accuracy.'])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(counts, 'korean classes', len(grouped), 'conflicts', len(conflicts), flush=True)

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('food101',type=Path); p.add_argument('korean',type=Path); p.add_argument('output',type=Path)
    p.add_argument('--baseline', type=Path, required=True)
    a=p.parse_args(); plan(a.food101,a.korean,a.output,a.baseline)
