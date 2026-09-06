"""Remove normalized duplicates and stale generated files; never touches raw data.

Conflicting labels are excluded. For a single label, preserve test before
validation before train. Exclusions and final counts are retained in manifest.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import unicodedata

def audit(root):
    manifest = json.loads((root / 'manifest.json').read_text())
    groups = collections.defaultdict(list)
    records = manifest['records']
    desired = {unicodedata.normalize('NFC', r['prepared']) for r in records}
    for split in ['train', 'validation', 'test']:
        for photo in (root / split).glob('*/*.jpg'):
            if unicodedata.normalize('NFC', str(photo.relative_to(root))) not in desired:
                photo.unlink()  # Only derived files in the explicit output root.
    for record in records:
        digest = hashlib.sha256((root / record['prepared']).read_bytes()).hexdigest()
        groups[digest].append(record)
    kept, excluded = [], []
    priority = {'test':0, 'validation':1, 'train':2}
    for batch in groups.values():
        batch.sort(key=lambda r:(priority[r['split']],r['prepared']))
        retain = 0 if len({r['label'] for r in batch}) > 1 else 1
        kept.extend(batch[:retain])
        for record in batch[retain:]:
            excluded.append(dict(record, reason='Identical normalized image'))
            (root / record['prepared']).unlink()
    manifest['records'] = kept
    manifest['normalized_exclusions'] = manifest.get('normalized_exclusions', []) + excluded
    manifest['counts'] = dict(collections.Counter(r['split'] for r in kept))
    (root / 'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    print('Normalized duplicate exclusions',len(excluded),'final counts',manifest['counts'],flush=True)

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path)
    audit(p.parse_args().root)
