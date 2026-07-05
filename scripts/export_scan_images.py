#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

import pikepdf
from PIL import Image
from pikepdf import PdfImage


def largest_page_image(page):
    images = []
    for image_obj in page.images.values():
        image = PdfImage(image_obj).as_pil_image()
        images.append(image)
    if not images:
        return None
    return max(images, key=lambda image: image.size[0] * image.size[1])


def normalize_for_png(image):
    if image.mode in {"1", "L", "RGB", "RGBA"}:
        return image
    return image.convert("RGB")


def export_scan_images(pdf_path, output_dir, prefix):
    output_dir.mkdir(parents=True, exist_ok=True)
    output_paths = []
    with pikepdf.open(pdf_path) as pdf:
        for index, page in enumerate(pdf.pages, start=1):
            image = largest_page_image(page)
            if image is None:
                print(f"Page {index} has no embedded image.", file=sys.stderr)
                continue

            rotation = int(page.get("/Rotate", 0)) % 360
            if rotation:
                image = image.rotate(-rotation, expand=True)
            image = normalize_for_png(image)

            output_path = output_dir / f"{prefix}-page-{index:04d}.png"
            if output_path.exists():
                raise FileExistsError(f"Output file already exists: {output_path}")
            image.save(output_path, "PNG")
            output_paths.append(output_path)

    if not output_paths:
        raise RuntimeError("No page images were exported.")
    return output_paths


def main():
    parser = argparse.ArgumentParser(description="Export the largest embedded image from each scan PDF page as PNG.")
    parser.add_argument("pdf_path", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("prefix")
    args = parser.parse_args()

    for output_path in export_scan_images(args.pdf_path, args.output_dir, args.prefix):
        print(output_path)


if __name__ == "__main__":
    main()
