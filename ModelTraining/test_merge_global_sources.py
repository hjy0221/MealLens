import tempfile
import unittest
from pathlib import Path

from merge_global_sources import merge


class MergeGlobalSourcesTests(unittest.TestCase):
    def test_namespaces_sources_and_quarantines_cross_label_duplicate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            for folder in [first / "sushi", first / "ramen", second / "pizza"]:
                folder.mkdir(parents=True)
            (first / "sushi" / "a.jpg").write_bytes(b"same")
            (first / "ramen" / "b.jpg").write_bytes(b"ramen")
            (second / "pizza" / "c.jpg").write_bytes(b"pizza")
            report = merge([("food101", first), ("uec", second)], root / "merged")
            self.assertGreaterEqual(report["image_count"], 2)
            self.assertEqual(len(report["conflicts_quarantined"]), 0)
            self.assertTrue((root / "merged" / "food101__sushi").is_dir())

    def test_conflict_between_labels_is_quarantined(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            for label in ["sushi", "ramen", "pizza", "salad"]:
                (source / label).mkdir(parents=True)
            (source / "sushi" / "same.jpg").write_bytes(b"same")
            (source / "ramen" / "same.jpg").write_bytes(b"same")
            (source / "pizza" / "other.jpg").write_bytes(b"other")
            (source / "salad" / "salad.jpg").write_bytes(b"salad")
            report = merge([("food", source)], root / "merged")
            self.assertEqual(len(report["conflicts_quarantined"]), 1)
            self.assertTrue((root / "merged" / ".conflicts").is_dir())


if __name__ == "__main__":
    unittest.main()
