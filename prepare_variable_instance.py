#!/usr/bin/env python3
"""Prepare a selected variable-font instance before FontForge processing."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
for vendor_dir in (SCRIPT_DIR / "vendor", SCRIPT_DIR / "build" / "python-vendor"):
    if vendor_dir.is_dir():
        sys.path.insert(0, str(vendor_dir))

STATUS_PREFIX = "FUSION_FONT_REPAIR_JSON:"

try:
    from fontTools.ttLib import TTFont  # noqa: E402
    from fontTools.varLib import instancer  # noqa: E402
    FONTTOOLS_IMPORT_ERROR = None
except Exception as exc:  # pragma: no cover - exercised when vendor is missing.
    TTFont = None
    instancer = None
    FONTTOOLS_IMPORT_ERROR = exc


def emit(payload: dict) -> None:
    print(STATUS_PREFIX + json.dumps(payload, ensure_ascii=False, sort_keys=True), flush=True)


def fail(message: str, exit_code: int = 1) -> int:
    emit({"ok": False, "error": message})
    return exit_code


def normalize_name(value: object) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").casefold())


def clean_spaces(value: object) -> str:
    return " ".join(str(value or "").split()).strip()


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_file_part(value: object) -> str:
    cleaned = re.sub(r"[\x00-\x1f<>:\"/\\|?*]+", " ", clean_spaces(value))
    return clean_spaces(cleaned).rstrip(".") or "instance"


def find_named_instance(font: TTFont, style_name: str):
    if "fvar" not in font:
        return None

    names = font["name"]
    requested = normalize_name(style_name)
    for instance in font["fvar"].instances:
        subfamily = clean_spaces(names.getDebugName(instance.subfamilyNameID))
        postscript = ""
        if instance.postscriptNameID != 0xFFFF:
            postscript = clean_spaces(names.getDebugName(instance.postscriptNameID))

        candidates = {
            normalize_name(subfamily),
            normalize_name(postscript),
        }
        if requested in candidates:
            return instance, subfamily

    return None


def run(args: argparse.Namespace) -> int:
    if FONTTOOLS_IMPORT_ERROR is not None:
        return fail(
            "fontTools is required for selected variable-font styles, but it could not be loaded. "
            f"Reinstall Fusion FontForge Helper or rebuild the installer. Details: {FONTTOOLS_IMPORT_ERROR}"
        )

    source_path = Path(args.input).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    style_name = clean_spaces(args.style_name)

    if not source_path.is_file():
        return fail(f"Font file not found: {source_path}")

    if not style_name:
        emit({"ok": True, "instantiated": False, "input_path": str(source_path), "output_path": str(source_path)})
        return 0

    try:
        font = TTFont(str(source_path))
    except Exception as exc:
        return fail(f"Could not read font with fontTools: {exc}")

    try:
        match = find_named_instance(font, style_name)
        if match is None:
            emit(
                {
                    "ok": True,
                    "instantiated": False,
                    "input_path": str(source_path),
                    "output_path": str(source_path),
                    "warning": f"No matching variable-font instance named '{style_name}' was found.",
                }
            )
            return 0

        instance, matched_style = match
        output_dir.mkdir(parents=True, exist_ok=True)
        digest = file_digest(source_path)
        output_path = output_dir / f"prepared-{digest[:12]}-{safe_file_part(matched_style)}{source_path.suffix.lower()}"

        static_font = instancer.instantiateVariableFont(
            font,
            instance.coordinates,
            inplace=False,
            updateFontNames=True,
            static=True,
        )
        static_font.save(str(output_path))
        static_font.close()

        emit(
            {
                "ok": True,
                "instantiated": True,
                "input_path": str(source_path),
                "output_path": str(output_path),
                "matched_style": matched_style,
                "coordinates": dict(instance.coordinates),
            }
        )
        return 0
    except Exception as exc:
        return fail(str(exc))
    finally:
        try:
            font.close()
        except Exception:
            pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Instantiate a selected variable-font named instance.")
    parser.add_argument("--input", required=True, help="Path to a .ttf or .otf file.")
    parser.add_argument("--output-dir", required=True, help="Directory for the prepared static font.")
    parser.add_argument("--style-name", required=True, help="Requested style, such as Bold or Bold SemiCondensed.")
    return parser.parse_args(argv)


if __name__ == "__main__":
    sys.exit(run(parse_args(sys.argv[1:])))
