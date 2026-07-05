import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

import pikepdf


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "receipt-small-page.pdf"


def load_crop_module():
    spec = importlib.util.spec_from_file_location("crop_pdf_pages", ROOT / "scripts" / "crop_pdf_pages.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def page_sizes(pdf_path):
    with pikepdf.open(pdf_path) as pdf:
        sizes = []
        for page in pdf.pages:
            left, bottom, right, top = [float(value) for value in page.MediaBox]
            sizes.append((round(right - left, 2), round(top - bottom, 2)))
        return sizes


class CropPdfPagesTests(unittest.TestCase):
    def test_receipt_fixture_is_cropped_to_small_page_width(self):
        crop_pdf_pages = load_crop_module()

        with tempfile.TemporaryDirectory() as temp_dir:
            pdf_path = Path(temp_dir) / "receipt.pdf"
            shutil.copyfile(FIXTURE, pdf_path)

            self.assertEqual(page_sizes(pdf_path), [(625.92, 829.44), (625.92, 829.44)])

            cropped = crop_pdf_pages.crop_pdf_pages(
                pdf_path,
                background_delta=8,
                border_px=64,
                margin_points=12,
                max_width_ratio=0.80,
                max_height_ratio=0.80,
                min_density=0.08,
                keep_original_boxes=False,
                debug=False,
            )

            self.assertEqual(cropped, 2)
            self.assertEqual(page_sizes(pdf_path), [(260.4, 823.68), (257.52, 828.0)])


if __name__ == "__main__":
    unittest.main()
