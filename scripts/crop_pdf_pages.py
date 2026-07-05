#!/usr/bin/env python3
import argparse
import statistics
from pathlib import Path

import pikepdf
from pikepdf import PdfImage
from PIL import Image, ImageChops


def sample_background(image, border_px):
    width, height = image.size
    border_px = min(border_px, max(1, width // 4), max(1, height // 4))
    strips = [
        image.crop((0, 0, width, border_px)),
        image.crop((0, height - border_px, width, height)),
        image.crop((0, 0, border_px, height)),
        image.crop((width - border_px, 0, width, height)),
    ]
    pixels = []
    for strip in strips:
        pixels.extend(strip.getdata())
    return int(statistics.median(pixels))


def content_bbox(image, background_delta, border_px):
    grayscale = image.convert("L")
    background = sample_background(grayscale, border_px)
    diff = ImageChops.difference(grayscale, Image.new("L", grayscale.size, background))
    mask = diff.point(lambda pixel: 255 if pixel > background_delta else 0)
    bbox = mask.getbbox()
    if not bbox:
        return None, background, 0.0

    x0, y0, x1, y1 = bbox
    mask_crop = mask.crop(bbox)
    content_pixels = sum(1 for pixel in mask_crop.getdata() if pixel)
    density = content_pixels / ((x1 - x0) * (y1 - y0))
    return bbox, background, density


def largest_page_image(page):
    images = []
    for image_obj in page.images.values():
        image = PdfImage(image_obj).as_pil_image()
        images.append(image)
    if not images:
        return None
    return max(images, key=lambda image: image.size[0] * image.size[1])


def crop_box_for_page(page, image, bbox, margin_points):
    image_width, image_height = image.size
    x0, y0, x1, y1 = bbox
    media_box = [float(value) for value in page.MediaBox]
    page_left, page_bottom, page_right, page_top = media_box
    page_width = page_right - page_left
    page_height = page_top - page_bottom
    x_scale = page_width / image_width
    y_scale = page_height / image_height

    left = max(page_left, page_left + x0 * x_scale - margin_points)
    right = min(page_right, page_left + x1 * x_scale + margin_points)
    top = min(page_top, page_top - y0 * y_scale + margin_points)
    bottom = max(page_bottom, page_top - y1 * y_scale - margin_points)
    return [left, bottom, right, top]


def should_crop(image, bbox, density, max_width_ratio, max_height_ratio, min_density):
    image_width, image_height = image.size
    x0, y0, x1, y1 = bbox
    width_ratio = (x1 - x0) / image_width
    height_ratio = (y1 - y0) / image_height
    is_small_object = width_ratio <= max_width_ratio or height_ratio <= max_height_ratio
    return is_small_object and density >= min_density, width_ratio, height_ratio


def crop_pdf_pages(
    pdf_path,
    background_delta,
    border_px,
    margin_points,
    max_width_ratio,
    max_height_ratio,
    min_density,
    keep_original_boxes,
    debug,
):
    cropped = 0
    details = []
    with pikepdf.open(pdf_path, allow_overwriting_input=True) as pdf:
        for index, page in enumerate(pdf.pages, start=1):
            image = largest_page_image(page)
            if image is None:
                details.append((index, "skipped", "no page image"))
                continue
            bbox, background, density = content_bbox(image, background_delta, border_px)
            if bbox is None:
                details.append((index, "skipped", f"no content background={background}"))
                continue
            crop, width_ratio, height_ratio = should_crop(
                image,
                bbox,
                density,
                max_width_ratio,
                max_height_ratio,
                min_density,
            )
            detail = (
                f"bbox={bbox} width_ratio={width_ratio:.3f} "
                f"height_ratio={height_ratio:.3f} density={density:.3f} background={background}"
            )
            if not crop:
                details.append((index, "kept", detail))
                continue

            crop_box = crop_box_for_page(page, image, bbox, margin_points)
            page.CropBox = pikepdf.Array(crop_box)
            if not keep_original_boxes:
                page.MediaBox = pikepdf.Array(crop_box)
            cropped += 1
            details.append((index, "cropped", f"{detail} crop_box={crop_box}"))

        if cropped:
            pdf.save(pdf_path)

    if debug:
        for page_number, status, detail in details:
            print(f"page {page_number}: {status} {detail}")
    return cropped


def main():
    parser = argparse.ArgumentParser(description="Auto-crop scanned PDF pages around smaller documents.")
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--background-delta", type=int, default=8)
    parser.add_argument("--border-px", type=int, default=64)
    parser.add_argument("--margin-points", type=float, default=12.0)
    parser.add_argument("--max-width-ratio", type=float, default=0.80)
    parser.add_argument("--max-height-ratio", type=float, default=0.80)
    parser.add_argument("--min-density", type=float, default=0.08)
    parser.add_argument("--keep-original-boxes", action="store_true")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    cropped = crop_pdf_pages(
        args.pdf,
        args.background_delta,
        args.border_px,
        args.margin_points,
        args.max_width_ratio,
        args.max_height_ratio,
        args.min_density,
        args.keep_original_boxes,
        args.debug,
    )
    print(f"Cropped {cropped} page{'s' if cropped != 1 else ''}.")


if __name__ == "__main__":
    main()
