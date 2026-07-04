#!/usr/bin/env python3
import argparse
from pathlib import Path

import pikepdf
from pikepdf import PdfImage
from PIL import Image, ImageStat


def page_images(page):
    resources = page.get("/Resources", {})
    xobjects = resources.get("/XObject", {})
    for _, obj in xobjects.items():
        try:
            if obj.get("/Subtype") == "/Image":
                yield obj
        except AttributeError:
            continue


def nonwhite_ratio(image, white_threshold):
    image.thumbnail((512, 512), Image.Resampling.LANCZOS)
    grayscale = image.convert("L")
    histogram = grayscale.histogram()
    nonwhite = sum(histogram[:white_threshold])
    total = grayscale.size[0] * grayscale.size[1]
    return nonwhite / total if total else 0.0


def image_stats(image_obj, white_threshold):
    image = PdfImage(image_obj).as_pil_image()
    if image.mode not in {"1", "L", "RGB", "RGBA", "CMYK"}:
        image = image.convert("RGB")
    width, height = image.size
    ratio = nonwhite_ratio(image, white_threshold)
    mean = ImageStat.Stat(image.convert("L")).mean[0]
    return width * height, ratio, mean


def page_is_blank(page, white_threshold, content_ratio_threshold, mean_threshold):
    images = list(page_images(page))
    if not images:
        return False, "no image"

    stats = [image_stats(image, white_threshold) for image in images]
    _, ratio, mean = max(stats, key=lambda item: item[0])
    return ratio < content_ratio_threshold and mean >= mean_threshold, f"nonwhite={ratio:.5f} mean={mean:.1f}"


def remove_blank_pages(pdf_path, white_threshold, content_ratio_threshold, mean_threshold, keep_one):
    with pikepdf.open(pdf_path, allow_overwriting_input=True) as pdf:
        blank_indexes = []
        kept_indexes = []
        details = []

        for index, page in enumerate(pdf.pages):
            blank, detail = page_is_blank(page, white_threshold, content_ratio_threshold, mean_threshold)
            details.append((index + 1, blank, detail))
            if blank:
                blank_indexes.append(index)
            else:
                kept_indexes.append(index)

        if keep_one and not kept_indexes and blank_indexes:
            kept_indexes.append(blank_indexes.pop(0))

        for index in reversed(blank_indexes):
            del pdf.pages[index]

        if blank_indexes:
            pdf.save(pdf_path)

    return details, len(blank_indexes)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--white-threshold", type=int, default=245)
    parser.add_argument("--content-ratio-threshold", type=float, default=0.003)
    parser.add_argument("--mean-threshold", type=float, default=248.0)
    parser.add_argument("--keep-one", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    details, removed = remove_blank_pages(
        args.pdf,
        args.white_threshold,
        args.content_ratio_threshold,
        args.mean_threshold,
        args.keep_one,
    )

    if args.debug:
        for page_number, blank, detail in details:
            status = "blank" if blank else "keep"
            print(f"page {page_number}: {status} {detail}")
    print(f"Removed {removed} blank page{'s' if removed != 1 else ''}.")


if __name__ == "__main__":
    main()
