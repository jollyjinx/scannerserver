#!/usr/bin/env python3
import argparse
from pathlib import Path

import pikepdf


def copy_docinfo(source_pdf, target_pdf):
    for key, value in source_pdf.docinfo.items():
        target_pdf.docinfo[key] = str(value)


def split_pdf_pages(pdf_path, output_dir, prefix):
    output_dir.mkdir(parents=True, exist_ok=True)
    output_paths = []
    with pikepdf.open(pdf_path) as pdf:
        if not pdf.pages:
            raise RuntimeError("PDF has no pages.")

        for index, page in enumerate(pdf.pages, start=1):
            output_path = output_dir / f"{prefix}-page-{index:04d}.pdf"
            if output_path.exists():
                raise FileExistsError(f"Output file already exists: {output_path}")

            output_pdf = pikepdf.Pdf.new()
            copy_docinfo(pdf, output_pdf)
            output_pdf.pages.append(page)
            output_pdf.save(output_path)
            output_paths.append(output_path)
    return output_paths


def main():
    parser = argparse.ArgumentParser(description="Split a scan PDF into one PDF per page.")
    parser.add_argument("pdf_path", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("prefix")
    args = parser.parse_args()

    for output_path in split_pdf_pages(args.pdf_path, args.output_dir, args.prefix):
        print(output_path)


if __name__ == "__main__":
    main()
