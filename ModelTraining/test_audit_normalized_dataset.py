import json
from pathlib import Path
import tempfile
import unittest
from audit_normalized_dataset import audit

class NormalizedAuditTests(unittest.TestCase):
    def test_duplicate_content_cannot_cross_splits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = []
            for split in ['train', 'validation', 'test']:
                path = root / split / 'food' / 'photo.jpg'
                path.parent.mkdir(parents=True)
                path.write_bytes(b'same decoded and re-encoded photo')
                records.append(dict(split=split,label='food',prepared=str(path.relative_to(root))))
            (root/'manifest.json').write_text(json.dumps(dict(records=records)))
            audit(root)
            result = json.loads((root/'manifest.json').read_text())
            self.assertEqual([r['split'] for r in result['records']], ['test'])
            self.assertEqual(len(result['normalized_exclusions']),2)
            self.assertFalse((root/'train/food/photo.jpg').exists())
            audit(root)
            self.assertEqual(json.loads((root/'manifest.json').read_text()), result)

    def test_conflicting_labels_are_excluded_instead_of_chosen(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); records=[]
            for label in ['soup','cake','rice']:
                path=root/'train'/label/'photo.jpg';path.parent.mkdir(parents=True)
                path.write_bytes(b'rice' if label=='rice' else b'conflicting labels')
                records.append(dict(split='train',label=label,prepared=str(path.relative_to(root))))
            (root/'manifest.json').write_text(json.dumps(dict(records=records)))
            audit(root)
            result=json.loads((root/'manifest.json').read_text())
            self.assertEqual([r['label'] for r in result['records']],['rice'])
            self.assertEqual(len(result['normalized_exclusions']),2)

if __name__ == '__main__': unittest.main()
