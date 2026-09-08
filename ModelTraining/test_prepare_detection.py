import json
import tempfile
import unittest
from pathlib import Path
from PIL import Image
from prepare_detection import prepare, deduplicate_boxes


class DetectionPreparationTests(unittest.TestCase):
    def test_overlapping_dish_labels_merge_but_adjacent_dishes_remain(self):
        self.assertEqual(len(deduplicate_boxes([(0, 0, 100, 100), (2, 2, 98, 98), (110, 0, 210, 100)])), 2)

    def test_unrelated_images_with_same_id_are_not_merged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'source'
            for category, color in [('1', 'red'), ('2', 'blue')]:
                folder = root / category
                folder.mkdir(parents=True)
                Image.new('RGB', (100, 100), color).save(folder / '1.jpg')
                (folder / 'bb_info.txt').write_text('img x1 y1 x2 y2\n1 0 0 100 100\n')
            output = Path(directory) / 'out'
            prepare(root, output, 0)
            rows = [row for path in output.glob('*/annotations.json') for row in json.loads(path.read_text())]
            self.assertEqual(len(rows), 2)
            self.assertTrue(all(len(row['annotations']) == 1 for row in rows))

    def test_repeated_images_merge_boxes_before_split_and_scale_coordinates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'source'
            for category in ('1', '2'):
                folder = root / category
                folder.mkdir(parents=True)
                Image.new('RGB', (1280, 640), 'red').save(folder / '1.jpg')
            (root / '1' / 'bb_info.txt').write_text('img x1 y1 x2 y2\n1 0 0 640 640\n')
            (root / '2' / 'bb_info.txt').write_text('img x1 y1 x2 y2\n1 640 0 1280 640\n')
            # Include distinct IDs with identical content: they must not leak.
            (root / '2' / '2.jpg').write_bytes((root / '2' / '1.jpg').read_bytes())
            with (root / '2' / 'bb_info.txt').open('a') as f:
                f.write('2 640 0 1280 640\n')
            output = Path(directory) / 'prepared'
            prepare(root, output, 0)
            rows = []
            for path in output.glob('*/annotations.json'):
                rows.extend(json.loads(path.read_text()))
            self.assertEqual(len(rows), 1)
            self.assertEqual(len(rows[0]['annotations']), 2)
            self.assertEqual(rows[0]['annotations'][0]['coordinates'],
                             {'x': 160, 'y': 160, 'width': 320, 'height': 320})


if __name__ == '__main__':
    unittest.main()
