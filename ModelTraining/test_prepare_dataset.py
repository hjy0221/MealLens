import tempfile
from pathlib import Path
import unittest
from prepare_dataset import prepare

class PreparationTests(unittest.TestCase):
    def populate(self, root):
        for label in ['seaweed_soup', 'beef_radish_soup']:
            for group in range(10):
                directory = root / label / f'capture-{group}'
                directory.mkdir(parents=True)
                for index in range(8):
                    # Dummy file bytes test the splitting/hash logic, not image validity.
                    (directory / f'{index}.jpg').write_bytes(f'{label}:{group}:{index}'.encode())
    def test_capture_groups_and_duplicates_never_leak(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw = Path(tmp) / 'raw'; self.populate(raw)
            first = next(raw.rglob('*.jpg'))
            first.with_name('duplicate.jpg').write_bytes(first.read_bytes())
            report = prepare(raw, Path(tmp) / 'ready')
            self.assertEqual(len(report['exact_duplicates_removed']), 1)
            self.assertEqual(len(report['records']), 160)
            groups = {}
            for record in report['records']:
                key = (record['label'], record['group'])
                groups.setdefault(key, set()).add(record['split'])
            self.assertTrue(all(len(splits) == 1 for splits in groups.values()))
            self.assertTrue(all(set(counts) == {'train', 'validation', 'test'} for counts in report['counts'].values()))
    def test_conflicting_labels_are_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw = Path(tmp) / 'raw'; self.populate(raw)
            source = next((raw / 'seaweed_soup').rglob('*.jpg'))
            (raw / 'beef_radish_soup' / 'wrong.jpg').write_bytes(source.read_bytes())
            destination = Path(tmp) / 'ready'
            with self.assertRaisesRegex(ValueError, 'Conflicting labels'):
                prepare(raw, destination)
            self.assertFalse(destination.exists())
    def test_small_dataset_cannot_claim_training_readiness(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw = Path(tmp) / 'raw'
            for name in ['a', 'b']:
                folder = raw / name; folder.mkdir(parents=True)
                (folder / 'one.jpg').write_bytes(name.encode())
            with self.assertRaisesRegex(ValueError, 'need 50'):
                prepare(raw, Path(tmp) / 'ready')

if __name__ == '__main__': unittest.main()
