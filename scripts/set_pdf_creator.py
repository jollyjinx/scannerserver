#!/usr/bin/env python3
import argparse
from pathlib import Path

import pikepdf


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--creator", default="ScanSnap")
    args = parser.parse_args()

    with pikepdf.open(args.pdf, allow_overwriting_input=True) as pdf:
        with pdf.open_metadata(set_pikepdf_as_editor=False) as metadata:
            metadata["pdf:Producer"] = metadata.get("pdf:Producer", "ScanSnap Linux")
            metadata["xmp:CreatorTool"] = args.creator
        pdf.docinfo["/Creator"] = args.creator
        pdf.save(args.pdf)


if __name__ == "__main__":
    main()
