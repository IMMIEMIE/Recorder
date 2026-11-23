"""Read only the non-secret settings for the timing probe, or compare its JSON reports."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET


def selected_profile():
    path = os.environ.get("PROBE_CONFIG")
    key = "livetranslate.configuration.v1"
    if path and path.endswith(".xml"):
        entry = ET.parse(path).find(f"./string[@name='{key}']")
        if entry is None:
            sys.exit("Android 设置中没有 LiveTranslate 配置")
        config = json.loads(entry.text)
    elif path:
        config = json.loads(Path(path).read_bytes())
    else:
        prefs = plistlib.loads(subprocess.check_output(["defaults", "export", "local.shengjian.recorder", "-"]))
        if key not in prefs:
            sys.exit("请先在 LiveTranslate 设置中保存配置")
        config = json.loads(prefs[key])
    catalog = config.get("catalog")
    if not catalog:
        sys.exit("请先在 LiveTranslate 设置中保存具名配置")
    selector = os.environ.get("PROBE_PROFILE") or catalog["selectedID"]
    by_id = [p for p in catalog["profiles"] if p["id"] == selector]
    matches = by_id or [p for p in catalog["profiles"] if p["name"] == selector]
    if len(matches) != 1:
        sys.exit("请选择唯一的配置名称或 ID")
    profile = matches[0]
    if os.environ.get("LIVETRANSLATE_API_KEY") and os.environ.get("LIVETRANSLATE_KEY_ENDPOINT") != profile["endpoint"]:
        sys.exit("该配置有独立的服务地址。请取消设置 LIVETRANSLATE_API_KEY 后按提示输入，或将 LIVETRANSLATE_KEY_ENDPOINT 设为此密钥对应的完整地址。")
    print(f"使用配置 {profile['name']} · {profile['endpoint']} · {profile['modelID']}", file=sys.stderr)
    return profile


def table(paths):
    print("配置 | 模型 | 轮次 | 断句 | 握手 ms | 已报告语音位置 / 音频时长 | 定稿 p50 ms")
    for path in paths:
        row = json.loads(Path(path).read_bytes())
        p = row["profile"]
        end = row.get("last_speech_end_ms")
        length = row["audio_seconds"]
        coverage = f"{min(1, end / (1000 * length)):.0%}" if end is not None and length else "—"
        detection = p["turnDetection"]
        if detection == "server_vad":
            detection += f" {p['silenceMS']} ms"
        cells = (p["name"], p["modelID"], row["label"], detection, row.get("handshake_ms"),
                 coverage, row["source_final_after_speech_end_ms"].get("p50"))
        print(" | ".join(str(x) if x is not None else "—" for x in cells))


if __name__ == "__main__":
    if sys.argv[1:2] == ["--table"]:
        table(sys.argv[2:])
    else:
        print(json.dumps(selected_profile(), ensure_ascii=False))
