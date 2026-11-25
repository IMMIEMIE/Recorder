#!/usr/bin/env python3
"""Validate macOS (.lproj) and Android (values*/strings.xml) localization assets."""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent

MACOS_LOCALES = [
    "zh-Hans",
    "en",
    "zh-Hant",
    "ja",
    "ko",
    "es",
    "fr",
    "de",
    "ta",
]

ANDROID_DIRS = {
    "en": "values",
    "zh-Hans": "values-b+zh+Hans",
    "zh-Hant": "values-b+zh+Hant",
    "ja": "values-ja",
    "ko": "values-ko",
    "es": "values-es",
    "fr": "values-fr",
    "de": "values-de",
    "ta": "values-ta",
}

EXPECTED_LOCALE_CONFIG_TAGS = set(MACOS_LOCALES)

# Apple .strings format placeholder matcher (ignoring escaped %%).
APPLE_FMT_RE = re.compile(
    r"%(?!%)(?:(\d+)\$)?[-+#0 ]*(?:\d+)?(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiIuUxXoOeEfFgGcCsSpPaA])"
)
# Android strings.xml format placeholder matcher (ignoring escaped %%).
ANDROID_FMT_RE = re.compile(
    r"%(?!%)(?:(\d+)\$)?[-+# 0,(]*(?:\d+)?(?:\.\d+)?([bBhHsScCdoxXeEfgGaAtT])"
)

STRINGS_ENTRY_RE = re.compile(
    r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;'
)


def unescape_strings(s: str) -> str:
    return (
        s.replace(r"\"", '"')
        .replace(r"\n", "\n")
        .replace(r"\r", "\r")
        .replace(r"\t", "\t")
        .replace(r"\\", "\\")
    )


def parse_apple_strings(path: pathlib.Path, errors: list[str]) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    # Strip /* ... */ and // ... comments outside quotes.
    stripped = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    entries: dict[str, str] = {}
    for match in STRINGS_ENTRY_RE.finditer(stripped):
        key = unescape_strings(match.group(1))
        val = unescape_strings(match.group(2))
        if key in entries:
            errors.append(f"[macOS] Duplicate key in {path.relative_to(ROOT)}: {key!r}")
        entries[key] = val
    return entries


def apple_placeholders(text: str) -> Counter[tuple[str, str]]:
    """Return multiset of (positional_index_or_empty, specifier) placeholders."""
    out: list[tuple[str, str]] = []
    pos = 1
    for m in APPLE_FMT_RE.finditer(text):
        idx = m.group(1) or str(pos)
        pos += 1
        out.append((idx, m.group(2)))
    return Counter(out)


def android_placeholders(text: str) -> Counter[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    pos = 1
    for m in ANDROID_FMT_RE.finditer(text):
        idx = m.group(1) or str(pos)
        pos += 1
        out.append((idx, m.group(2)))
    return Counter(out)


def check_macos(errors: list[str]) -> None:
    loc_root = ROOT / "assets" / "localization"
    for table in ("Localizable.strings", "InfoPlist.strings"):
        tables: dict[str, dict[str, str]] = {}
        for lang in MACOS_LOCALES:
            path = loc_root / f"{lang}.lproj" / table
            if not path.is_file():
                errors.append(f"[macOS] Missing file: {path.relative_to(ROOT)}")
                continue
            tables[lang] = parse_apple_strings(path, errors)
            if shutil.which("plutil"):
                proc = subprocess.run(
                    ["plutil", "-lint", str(path)],
                    capture_output=True,
                    text=True,
                )
                if proc.returncode != 0:
                    errors.append(
                        f"[macOS] plutil -lint failed for {path.relative_to(ROOT)}: "
                        f"{proc.stdout.strip()} {proc.stderr.strip()}"
                    )

        if "zh-Hans" not in tables:
            continue
        base_keys = set(tables["zh-Hans"].keys())
        base_map = tables["zh-Hans"]

        for lang, data in tables.items():
            keys = set(data.keys())
            missing = sorted(base_keys - keys)
            extra = sorted(keys - base_keys)
            if missing:
                errors.append(
                    f"[macOS] {lang}.lproj/{table} missing {len(missing)} keys: {missing[:5]}"
                )
            if extra:
                errors.append(
                    f"[macOS] {lang}.lproj/{table} has {len(extra)} extra keys: {extra[:5]}"
                )
            for k in sorted(base_keys & keys):
                if not data[k].strip():
                    errors.append(f"[macOS] {lang}.lproj/{table} empty value for key {k!r}")
                base_ph = apple_placeholders(base_map[k])
                lang_ph = apple_placeholders(data[k])
                if base_ph != lang_ph:
                    errors.append(
                        f"[macOS] Placeholder mismatch in {lang}.lproj/{table} for {k!r}: "
                        f"expected {dict(base_ph)}, got {dict(lang_ph)} ({data[k]!r})"
                    )

        if table == "Localizable.strings":
            iface = (ROOT / "Sources" / "Recorder" / "InterfaceLanguage.swift").read_text(
                encoding="utf-8"
            )
            # Check format("...", ...) calls and rule tuples in InterfaceLanguage.swift.
            referenced = set(re.findall(r'format\("([^"]+)"', iface))
            referenced.update(
                re.findall(r'\("[^"]*",\s*"[^"]*",\s*"([^"]+)"\)', iface)
            )
            missing_in_table = sorted(k for k in referenced if k not in base_keys)
            if missing_in_table:
                errors.append(
                    f"[macOS] InterfaceLanguage.swift references keys missing from Localizable.strings: "
                    f"{missing_in_table}"
                )


def check_android(errors: list[str]) -> None:
    res_root = ROOT / "android" / "app" / "src" / "main" / "res"
    legacy_zh = res_root / "values-zh"
    if legacy_zh.exists():
        errors.append(
            f"[Android] Legacy {legacy_zh.relative_to(ROOT)} still exists; should use values-b+zh+Hans."
        )

    tables: dict[str, dict[str, str]] = {}
    for lang, dirname in ANDROID_DIRS.items():
        path = res_root / dirname / "strings.xml"
        if not path.is_file():
            errors.append(f"[Android] Missing file: {path.relative_to(ROOT)}")
            continue
        try:
            tree = ET.parse(path)
        except ET.ParseError as exc:
            errors.append(f"[Android] Invalid XML in {path.relative_to(ROOT)}: {exc}")
            continue
        root = tree.getroot()
        entries: dict[str, str] = {}
        for elem in root.findall("string"):
            name = elem.attrib.get("name")
            if not name:
                errors.append(f"[Android] <string> without name in {path.relative_to(ROOT)}")
                continue
            if name in entries:
                errors.append(f"[Android] Duplicate key {name!r} in {path.relative_to(ROOT)}")
            text = "".join(elem.itertext())
            # Android strings.xml forbids unescaped single quotes unless wrapped in double quotes.
            if not (text.startswith('"') and text.endswith('"')):
                if re.search(r"(?<!\\)'", text):
                    errors.append(
                        f"[Android] Unescaped apostrophe in {path.relative_to(ROOT)} key {name!r}: {text!r}"
                    )
            entries[name] = text
        tables[lang] = entries

    if "en" in tables:
        base_map = tables["en"]
        base_keys = set(base_map.keys())
        for lang, data in tables.items():
            keys = set(data.keys())
            missing = sorted(base_keys - keys)
            extra = sorted(keys - base_keys)
            if missing:
                errors.append(
                    f"[Android] {ANDROID_DIRS[lang]}/strings.xml missing {len(missing)} keys: {missing[:5]}"
                )
            if extra:
                errors.append(
                    f"[Android] {ANDROID_DIRS[lang]}/strings.xml has {len(extra)} extra keys: {extra[:5]}"
                )
            for k in sorted(base_keys & keys):
                if not data[k].strip():
                    errors.append(
                        f"[Android] {ANDROID_DIRS[lang]}/strings.xml empty value for key {k!r}"
                    )
                base_ph = android_placeholders(base_map[k])
                lang_ph = android_placeholders(data[k])
                if base_ph != lang_ph:
                    errors.append(
                        f"[Android] Placeholder mismatch in {ANDROID_DIRS[lang]}/strings.xml for {k!r}: "
                        f"expected {dict(base_ph)}, got {dict(lang_ph)} ({data[k]!r})"
                    )

        # Verify all R.string.<name> references in Kotlin sources exist.
        referenced: set[str] = set()
        for src_dir in (
            ROOT / "android" / "app" / "src" / "main" / "java",
            ROOT / "android" / "app" / "src" / "screenshotTest" / "kotlin",
        ):
            if not src_dir.exists():
                continue
            for kt in src_dir.rglob("*.kt"):
                referenced.update(re.findall(r"\bR\.string\.([A-Za-z0-9_]+)", kt.read_text(encoding="utf-8")))
        missing_refs = sorted(k for k in referenced if k not in base_keys)
        if missing_refs:
            errors.append(
                f"[Android] Kotlin sources reference missing R.string keys: {missing_refs}"
            )

    # Verify locales_config.xml lists all 9 locales.
    locales_xml = res_root / "xml" / "locales_config.xml"
    if not locales_xml.is_file():
        errors.append(f"[Android] Missing {locales_xml.relative_to(ROOT)}")
    else:
        try:
            tree = ET.parse(locales_xml)
            ns = "{http://schemas.android.com/apk/res/android}name"
            declared = {elem.attrib.get(ns) for elem in tree.getroot().findall("locale")}
            if declared != EXPECTED_LOCALE_CONFIG_TAGS:
                errors.append(
                    f"[Android] locales_config.xml mismatch: expected {sorted(EXPECTED_LOCALE_CONFIG_TAGS)}, "
                    f"got {sorted(x for x in declared if x)}"
                )
        except ET.ParseError as exc:
            errors.append(f"[Android] Invalid XML in {locales_xml.relative_to(ROOT)}: {exc}")


def main() -> int:
    errors: list[str] = []
    check_macos(errors)
    check_android(errors)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        print(f"Localization check failed with {len(errors)} error(s).", file=sys.stderr)
        return 1
    print(
        f"Localization check passed: {len(MACOS_LOCALES)} macOS .lproj bundles and "
        f"{len(ANDROID_DIRS)} Android strings.xml catalogs validated."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
