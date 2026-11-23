#!/usr/bin/env python3
"""Reference implementation of the session export format (docs/SESSIONS.md) and generator of its fixtures.

The macOS and Android exporters must reproduce tests/fixtures/session_export/expected/* byte for byte.
Change the format here first, regenerate, then update both platforms:

    python3 scripts/make_session_export_fixtures.py
"""
import json
import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "session_export"
# Fixtures are rendered in a fixed zone; the apps use the device's zone.
ZONE = ZoneInfo("Asia/Shanghai")

BREAK_MARKER = "连接中断，此处内容可能有缺失"
MODES = ("bilingual", "source", "translation")
MD_SPECIAL = set("\\`*_[]<>#|~")
FILENAME_FORBIDDEN = set('/\\:*?"<>|')


def stamp(ms, pattern="%Y-%m-%d %H:%M"):
    return datetime.fromtimestamp(ms / 1000, ZONE).strftime(pattern)


def clean(text):
    """One line: CR/LF sequences become one space, then surrounding whitespace is trimmed."""
    return re.sub(r"\r\n|\r|\n", " ", text).strip()


def entries(session, mode):
    """("marker", text) or ("row", [parts]) in export order."""
    out = []
    previous_segment = None
    for row in session["rows"]:
        segment = row["segment"]
        if previous_segment is not None and segment != previous_segment:
            out.append(("marker", "继续录制 " + stamp(session["segments"][segment]["started_at_ms"])))
        previous_segment = segment
        if row["kind"] == "break":
            out.append(("marker", BREAK_MARKER))
            continue
        source, translation = clean(row["source"]), clean(row["translation"])
        if mode == "source":
            parts = [("source", source)] if source else []
        elif mode == "translation":
            parts = [("translation", translation)] if translation else []
        else:
            parts = [p for p in (("source", source), ("translation", translation)) if p[1]]
        if parts:
            out.append(("row", parts))
    return out


def export_txt(session, mode):
    blocks = []
    for kind, value in entries(session, mode):
        blocks.append(f"【{value}】" if kind == "marker" else "\n".join(text for _, text in value))
    head = f"{clean(session['title'])}\n{stamp(session['created_at_ms'])}\n"
    return head + ("\n" + "\n\n".join(blocks) + "\n" if blocks else "")


def md_escape(text):
    escaped = "".join("\\" + c if c in MD_SPECIAL else c for c in text)
    if escaped[:1] in ("-", "+"):
        escaped = "\\" + escaped
    match = re.match(r"^(\d+)\.", escaped)
    if match:
        escaped = match.group(1) + "\\." + escaped[match.end():]
    return escaped


def export_md(session, mode):
    blocks = []
    for kind, value in entries(session, mode):
        if kind == "marker":
            blocks.append(f"*【{value}】*")
            continue
        lines = []
        for part, text in value:
            # Bilingual exports set the translation in bold; single-language exports are plain.
            lines.append(f"**{md_escape(text)}**" if mode == "bilingual" and part == "translation" else md_escape(text))
        blocks.append("  \n".join(lines))
    head = f"# {md_escape(clean(session['title']))}\n\n{stamp(session['created_at_ms'])}\n"
    return head + ("\n" + "\n\n".join(blocks) + "\n" if blocks else "")


def file_name(session, extension):
    title = "".join("_" if c in FILENAME_FORBIDDEN or ord(c) < 0x20 or ord(c) == 0x7F else c for c in session["title"])
    title = clean(title)[:50].strip()
    date = stamp(session["created_at_ms"], "%Y-%m-%d %H-%M")
    return f"声笺 {date} {title}.{extension}" if title else f"声笺 {date}.{extension}"


def default_title(created_at_ms, rows):
    """Used until the user renames a session: time plus the first 20 code points of the first source text."""
    first = next((clean(r["source"]) for r in rows if r["kind"] == "text" and clean(r["source"])), "")
    return f"{stamp(created_at_ms, '%m-%d %H:%M')} {first[:20] if first else '新会话'}"


def ms(text):
    return int(datetime.strptime(text, "%Y-%m-%d %H:%M:%S").replace(tzinfo=ZONE).timestamp() * 1000)


def session_fixture():
    def row(segment, source, translation, offset, kind="text"):
        return {"segment": segment, "kind": kind, "offset_ms": offset, "source": source, "translation": translation}

    return {
        "schema_version": 1,
        "id": "0b8f6c2e-4d1a-4c47-9a53-2f1e6d7c8a90",
        "title": "周会：Q4 *计划* #1 / 草稿?",
        "title_edited": True,
        "created_at_ms": ms("2026-11-23 14:05:00"),
        "updated_at_ms": ms("2026-11-24 09:41:10"),
        "segments": [
            {"started_at_ms": ms("2026-11-23 14:05:00"), "ended_at_ms": ms("2026-11-23 14:31:42"),
             "target_language": "zh", "mode": "live_translate"},
            {"started_at_ms": ms("2026-11-24 09:30:05"), "ended_at_ms": ms("2026-11-24 09:41:10"),
             "target_language": "ja", "mode": "live_translate"},
        ],
        "rows": [
            row(0, "Good morning, everyone.", "大家早上好。", 1200),
            row(0, "- Agenda: [budget] & <hiring>", "- 议程：[预算] 与 <招聘>", 5400),
            row(0, "3. Next steps\nfollow up", "", 9800),
            row(0, "", "仅有译文的一行", 14100),
            row(0, "", "", 15000, kind="break"),
            row(0, "  We're back.  ", "我们回来了。", 21000),
            row(1, "Second day_test | ok ~ done", "二日目のテスト", 800),
            row(1, "   ", "", 4000),
            row(1, "C:\\path `code`", "パス", 6000),
        ],
        # Unknown fields must be ignored by readers.
        "future_field": {"ignored": True},
    }


def title_cases():
    created = ms("2026-11-23 14:05:00")
    text = lambda s: {"segment": 0, "kind": "text", "offset_ms": 0, "source": s, "translation": ""}
    brk = {"segment": 0, "kind": "break", "offset_ms": 0, "source": "", "translation": ""}
    cases = [
        [],
        [brk, text("   "), text("Hello there, this sentence is longer than twenty.")],
        [text("今天我们讨论第四季度的预算安排和招聘计划")],
        [text("emoji 😀 counts as one code point here")],
    ]
    return [{"created_at_ms": created, "rows": rows, "expected": default_title(created, rows)} for rows in cases]


def main():
    session = session_fixture()
    (FIXTURES / "expected").mkdir(parents=True, exist_ok=True)
    (FIXTURES / "session.json").write_text(json.dumps(session, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for mode in MODES:
        (FIXTURES / "expected" / f"{mode}.txt").write_text(export_txt(session, mode), encoding="utf-8")
        (FIXTURES / "expected" / f"{mode}.md").write_text(export_md(session, mode), encoding="utf-8")
    meta = {
        "zone": "Asia/Shanghai",
        "file_names": {"txt": file_name(session, "txt"), "md": file_name(session, "md")},
        "default_titles": title_cases(),
    }
    (FIXTURES / "expected" / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
