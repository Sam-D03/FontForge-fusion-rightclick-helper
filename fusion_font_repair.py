#!/usr/bin/env python3
"""FontForge worker for generating Fusion 360 friendly font copies."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

import fontforge


STATUS_PREFIX = "FUSION_FONT_REPAIR_JSON:"
SUPPORTED_EXTENSIONS = {".ttf": "TrueType", ".otf": "OpenType"}
NAME_FIELDS = {
    "Family",
    "SubFamily",
    "UniqueID",
    "Fullname",
    "PostScriptName",
    "Preferred Family",
    "Preferred Styles",
    "Compatible Full",
}


def emit(payload: dict) -> None:
    print(STATUS_PREFIX + json.dumps(payload, ensure_ascii=False, sort_keys=True), flush=True)


def fail(message: str, exit_code: int = 1) -> int:
    emit({"ok": False, "error": message})
    return exit_code


def clean_spaces(value: object) -> str:
    return " ".join(str(value or "").split()).strip()


def safe_display_name(value: object) -> str:
    cleaned = clean_spaces(value)
    cleaned = re.sub(r"[\x00-\x1f<>:\"/\\|?*]+", " ", cleaned)
    cleaned = clean_spaces(cleaned)
    return cleaned or "Unnamed Font"


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def postscript_name(source_name: str, digest: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9-]+", "-", source_name)
    cleaned = re.sub(r"-+", "-", cleaned).strip("-") or "Unnamed-Font"
    value = "FUSION-" + cleaned
    if len(value) > 63:
        suffix = "-" + digest[:8]
        value = value[: 63 - len(suffix)].rstrip("-") + suffix
    return value


def output_file_name(display_name: str, style_name: str, extension: str) -> str:
    # Windows' special Fonts folder often searches backing filenames more
    # reliably than virtual font display names, so keep this human-readable.
    filename = safe_display_name(f"{display_name} {style_name}")
    filename = re.sub(r"[\x00-\x1f<>:\"/\\|?*]+", " ", filename)
    filename = clean_spaces(filename).rstrip(".")
    return (filename or "FUSION Font") + extension.lower()


def first_sfnt_value(font, name_id: str) -> str:
    for _language, key, value in font.sfnt_names:
        if key == name_id:
            return clean_spaces(value)
    return ""


def collect_languages(font) -> set[str]:
    languages = {"English (US)"}
    for language, key, _value in font.sfnt_names:
        if key in NAME_FIELDS:
            languages.add(language)
    return languages


def fusion_family_name(source_name: str) -> str:
    target = safe_display_name(source_name)
    if not target.upper().startswith("FUSION "):
        target = "FUSION " + target
    return safe_display_name(target)


def full_name_for_style(family_name: str, style_name: str) -> str:
    style = safe_display_name(style_name)
    if style.upper() == "REGULAR":
        return family_name
    return safe_display_name(f"{family_name} {style}")


def build_plan(source_path: Path, font, target_family: str = "", target_style: str = "") -> dict:
    extension = source_path.suffix.lower()
    if extension not in SUPPORTED_EXTENSIONS:
        supported = ", ".join(sorted(SUPPORTED_EXTENSIONS))
        raise ValueError(f"Unsupported font extension '{extension}'. Supported extensions: {supported}.")

    digest = file_digest(source_path)
    source_family = safe_display_name(getattr(font, "familyname", "") or first_sfnt_value(font, "Family"))
    source_full = safe_display_name(getattr(font, "fullname", "") or first_sfnt_value(font, "Fullname") or source_family)

    if target_family:
        family_name = fusion_family_name(target_family)
        subfamily_name = safe_display_name(target_style or "Regular")
        full_name = full_name_for_style(family_name, subfamily_name)
    else:
        family_name = fusion_family_name(source_full)
        subfamily_name = safe_display_name(target_style or "Regular")
        full_name = full_name_for_style(family_name, subfamily_name)

    ps_source = full_name.removeprefix("FUSION ")
    ps_name = postscript_name(ps_source, digest)
    filename = output_file_name(family_name, subfamily_name, extension)
    font_type = SUPPORTED_EXTENSIONS[extension]

    return {
        "source_path": str(source_path),
        "source_family": source_family,
        "source_full_name": source_full,
        "family_name": family_name,
        "full_name": full_name,
        "subfamily_name": subfamily_name,
        "postscript_name": ps_name,
        "unique_id": f"FusionFontRepair:{ps_name}:{digest[:16]}",
        "output_file_name": filename,
        "font_type": font_type,
        "registry_name": f"{full_name} ({font_type})",
    }


def rewrite_names(font, plan: dict) -> None:
    font.fontname = plan["postscript_name"]
    font.familyname = plan["family_name"]
    font.fullname = plan["full_name"]

    replacements = {
        "Family": plan["family_name"],
        "SubFamily": plan["subfamily_name"],
        "UniqueID": plan["unique_id"],
        "Fullname": plan["full_name"],
        "PostScriptName": plan["postscript_name"],
        "Preferred Family": plan["family_name"],
        "Preferred Styles": plan["subfamily_name"],
        "Compatible Full": plan["full_name"],
    }

    for language in sorted(collect_languages(font)):
        for name_id, value in replacements.items():
            font.appendSFNTName(language, name_id, value)


def remove_overlaps(font) -> tuple[int, list[str]]:
    processed = 0
    warnings: list[str] = []
    for glyph in font.glyphs():
        try:
            glyph.removeOverlap()
            processed += 1
        except Exception as exc:  # FontForge can reject unusual glyph layers.
            glyph_name = getattr(glyph, "glyphname", "<unknown glyph>")
            warnings.append(f"{glyph_name}: {exc}")
    return processed, warnings


def run(args: argparse.Namespace) -> int:
    source_path = Path(args.input).expanduser().resolve()
    if not source_path.is_file():
        return fail(f"Font file not found: {source_path}")

    font = None
    try:
        font = fontforge.open(str(source_path))
        plan = build_plan(source_path, font, args.target_family, args.target_style)

        if args.plan_only:
            emit({"ok": True, "mode": "plan", **plan})
            return 0

        output_dir = Path(args.output_dir).expanduser().resolve()
        output_dir.mkdir(parents=True, exist_ok=True)
        output_path = output_dir / plan["output_file_name"]
        if output_path.exists():
            return fail(f"Output file already exists: {output_path}")

        rewrite_names(font, plan)
        glyph_count, warnings = remove_overlaps(font)
        font.generate(str(output_path))

        emit(
            {
                "ok": True,
                "mode": "generate",
                **plan,
                "output_path": str(output_path),
                "glyphs_processed": glyph_count,
                "warnings": warnings[:25],
                "warning_count": len(warnings),
            }
        )
        return 0
    except Exception as exc:
        return fail(str(exc))
    finally:
        if font is not None:
            try:
                font.close()
            except Exception:
                pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a Fusion-prefixed repaired copy of a font.")
    parser.add_argument("--input", required=True, help="Path to a .ttf or .otf file.")
    parser.add_argument("--output-dir", default=os.getcwd(), help="Directory for the generated font.")
    parser.add_argument("--target-family", default="", help="Original family name to prefix with FUSION.")
    parser.add_argument("--target-style", default="", help="Target style name, such as Bold.")
    parser.add_argument("--plan-only", action="store_true", help="Read metadata and report target names without generating.")
    return parser.parse_args(argv)


if __name__ == "__main__":
    sys.exit(run(parse_args(sys.argv[1:])))
