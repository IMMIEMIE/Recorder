#!/bin/bash
# Session file v1, store and export (docs/SESSIONS.md) against tests/fixtures/session_export/ and the
# reference exporter scripts/make_session_export_fixtures.py. No models, no network.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/feature-tests
# Extra parity cases computed by the reference implementation itself (Unicode whitespace, digits, CR/LF...).
python3 - > .build/feature-tests/session-cases.json <<'PY'
import json, sys
sys.path.insert(0, "scripts")
import make_session_export_fixtures as ref
texts = ["", "   ", "a\r\nb\rc\nd", "\r\n\r\n x 　", "\x1c\x1dmid\x1e\x1f", "\x85edge\xa0", " line ",
         "1. one", "12.5 kg", "٣. arabic", "１. fullwidth", "1x. no", "- dash", "+ plus", "-1. both", "#1 * _ [x] <y> | ~z `c` \\",
         "é combining", "😀👍🏽 emoji", "\t tabbed \t", "1.", "."]
cases = {
    "clean": [[t, ref.clean(t)] for t in texts],
    "md_escape": [[t, ref.md_escape(ref.clean(t))] for t in texts],
    "file_names": [],
    "titles": [],
}
created = 1795413900000
for t in texts + ["a/b\\c:d*e?f\"g<h>i|j\x01k\x7f", "x" * 70, " " + "长" * 49 + " tail", "　　"]:
    session = {"title": t, "created_at_ms": created}
    cases["file_names"].append([t, ref.file_name(session, "txt")])
    rows = [{"segment": 0, "kind": "text", "offset_ms": 0, "source": t, "translation": ""}]
    cases["titles"].append([t, ref.default_title(created, rows)])
print(json.dumps(cases, ensure_ascii=False))
PY
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/Recorder/SessionStore.swift Sources/Recorder/SessionExport.swift tests/SessionTests.swift \
  -o .build/feature-tests/session-tests
RECORDER_SESSION_CASES=.build/feature-tests/session-cases.json .build/feature-tests/session-tests
