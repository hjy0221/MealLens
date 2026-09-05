#!/usr/bin/env python3
"""Prepare class folders for Create ML without leaking identical photos across splits.
Input: raw/<class>/<capture-group>/<photo>, or raw/<class>/<photo>.
No downloads, external libraries, or training happen here.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random
import shutil

EXTENSIONS = {'.jpg', '.jpeg', '.png', '.heic', '.tif', '.tiff'}

def prepare(source: Path, destination: Path, seed=20260905, minimum=50):
    source = source.resolve()
    if not source.is_dir():
        raise ValueError('Source folder does not exist.')
    if destination.exists():
        raise ValueError('Choose a new output folder; existing datasets are never overwritten.')
    classes = sorted(p for p in source.iterdir() if p.is_dir() and not p.name.startswith('.'))
    if len(classes) < 2:
        raise ValueError('At least two labeled classes are required.')
    known = {}
    grouped = {}
    duplicates = []
    ungrouped = 0
    for folder in classes:
        groups = {}
        for photo in sorted(folder.rglob('*')):
            if not photo.is_file() or photo.suffix.lower() not in EXTENSIONS:
                continue
            digest = hashlib.sha256(photo.read_bytes()).hexdigest()
            if digest in known:
                previous = known[digest]
                if previous['label'] != folder.name:
                    raise ValueError(f'Conflicting labels for identical image: {previous["source"]} and {photo.relative_to(source)}')
                duplicates.append(str(photo.relative_to(source)))
                continue
            relative = photo.relative_to(folder)
            # All photos in the same capture/session folder stay in one split.
            group = relative.parts[0] if len(relative.parts) > 1 else digest
            ungrouped += len(relative.parts) == 1
            record = {'label': folder.name, 'source': str(photo.relative_to(source)),
                      'sha256': digest, 'group': group}
            known[digest] = record
            groups.setdefault(group, []).append(record)
        count = sum(map(len, groups.values()))
        if count < minimum or len(groups) < 3:
            raise ValueError(f'{folder.name}: {count} unique images / {len(groups)} groups; need {minimum} images and 3+ groups.')
        grouped[folder.name] = groups
    records = []
    counts = {}
    for label, groups in grouped.items():
        keys = sorted(groups)
        random.Random(f'{seed}:{label}').shuffle(keys)
        # Group-wise split, approximately 70/15/15 by group count.
        holdout = max(1, round(len(keys) * .15))
        assignments = [('test', keys[:holdout]), ('validation', keys[holdout:2*holdout]), ('train', keys[2*holdout:])]
        counts[label] = {}
        for split, selected in assignments:
            batch = [dict(r, split=split) for key in selected for r in groups[key]]
            counts[label][split] = len(batch)
            if len(batch) < (20 if split == 'train' else 5):
                raise ValueError(f'{label}/{split} is too small ({len(batch)}). Add more independent capture groups.')
            records.extend(batch)
    destination.mkdir(parents=True)
    for record in records:
        original = source / record['source']
        name = record['sha256'] + original.suffix.lower()
        output = destination / record['split'] / record['label'] / name
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, output)
        record['prepared'] = str(output.relative_to(destination))
    report = {'seed': seed, 'counts': counts, 'records': records, 'exact_duplicates_removed': duplicates,
              'ungrouped_images': ungrouped,
              'limitations': ['No automatic near-duplicate detection. Review similar photos and assign capture groups.',
                              'Group split is approximate by group count, not guaranteed by image count.',
                              'Image decoding is checked by the Swift trainer before training.']}
    (destination / 'manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--seed', type=int, default=20260905)
    parser.add_argument('--minimum', type=int, default=50)
    args = parser.parse_args()
    try:
        result = prepare(args.source, args.destination, args.seed, args.minimum)
        print(json.dumps(result['counts'], ensure_ascii=False, indent=2))
    except (ValueError, OSError) as error:
        parser.exit(1, f'Dataset not prepared: {error}\n')
