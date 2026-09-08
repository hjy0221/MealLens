"""Build a leakage-resistant manifest from Open Images food box crops."""
import argparse
import csv
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
if args.output.exists(): parser.error('Use a fresh output directory')
args.output.mkdir(parents=True)
(args.output/'images').mkdir()
mapping = {}
records = []
seen_content = set()
for source_split in ('train', 'validation'):
    attribution = {row['ImageID']: row for row in csv.DictReader((args.source/source_split/'attribution.csv').open())}
    for label_folder in sorted((args.source/source_split/'classification').iterdir()):
        label = 'openimages__' + label_folder.name
        mapping[label] = label
        for path in sorted(label_folder.glob('*.jpg')):
            image_id = path.stem.split('_')[0]
            if image_id not in attribution: raise ValueError(f'Missing attribution: {image_id}')
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest in seen_content: continue
            seen_content.add(digest)
            prepared = args.output/'images'/(digest+'.jpg')
            prepared.symlink_to(path.resolve())
            split = 'train' if source_split == 'train' else ('test' if int(hashlib.sha256(image_id.encode()).hexdigest()[:8],16)%2 else 'validation')
            records.append({'prepared': 'images/'+digest+'.jpg', 'label': label, 'split': split, 'sha256': digest})
counts = {}
for record in records:
    key = record['split'] + ':' + record['label']; counts[key] = counts.get(key, 0) + 1
for label in mapping:
    for split in ('train','validation','test'):
        if counts.get(split+':'+label, 0) < 10: raise ValueError(f'Too few {split} samples for {label}')
(args.output/'manifest.json').write_text(json.dumps({'records':records},indent=2))
(args.output/'class-labels.json').write_text(json.dumps(mapping,indent=2))
(args.output/'inventory.json').write_text(json.dumps({'records':len(records),'counts':counts,
    'license':'Images CC BY 2.0 per retained attribution; annotations CC BY 4.0'},indent=2))
print(json.dumps({'records':len(records),'classes':len(mapping),'counts':counts},indent=2))
