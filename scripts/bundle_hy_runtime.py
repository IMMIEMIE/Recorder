#!/usr/bin/env python3
"""Bundle only the exact Hy helper which passed the real-model release gate."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess

RUNTIME_COMMIT = "d38e66aac7bb18101f417338b795e4546a5a1a59"
MODEL_SHA256 = "26c87f0a5f6409f3a57f8c4d2a49d58ad0f5c0753141643789e73564339cedbc"
REQUIRED_CHECKS = ("streaming_before_eof", "rollover", "tail_recovery", "cli_parity", "content_anchors", "cancel_and_restart", "noise_floor")


def sha256(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def validate(report, helper):
    if (report.get("schema_version") != 1 or report.get("passed") is not True
            or report.get("runtime_commit") != RUNTIME_COMMIT
            or report.get("model_sha256") != MODEL_SHA256
            or report.get("helper_sha256") != sha256(helper)):
        raise ValueError("验证记录缺失、不通过，或与当前推理程序/模型版本不符")
    checks = report.get("checks", {})
    if not all(checks.get(name) is True for name in REQUIRED_CHECKS) or not all(value is True for value in checks.values()):
        raise ValueError("流式输出、上下文切换、尾句恢复、底噪或 CLI 对照未通过")
    for direction in ("en-zh", "zh-en"):
        valid = False
        for run in report.get("runs", []):
            try:
                seconds, factor, queued = (float(run[key]) for key in
                                           ("audio_seconds", "realtime_factor", "max_queue_seconds"))
                valid |= (run.get("direction") == direction and run.get("complete") is True
                          and math.isfinite(seconds) and seconds >= 600
                          and math.isfinite(factor) and 0 < factor <= 1
                          and math.isfinite(queued) and 0 <= queued <= 10)
            except (KeyError, TypeError, ValueError):
                pass
        if not valid:
            raise ValueError(f"缺少 {direction} 至少 600 秒的成功实时验证")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--helper", type=Path, default=Path(".build/hy-runtime/bin/HySimulMTHelper"))
    parser.add_argument("--report", type=Path, default=Path("docs/hy-runtime-verification.json"))
    parser.add_argument("--require", action="store_true", help="Fail the build if local Hy is unavailable")
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text())
        validate(report, args.helper)
    except (OSError, ValueError, TypeError) as error:
        message = f"Hy-SimulMT 本地入口保持禁用：{error}"
        if args.require:
            raise SystemExit(message)
        print(message)
        return
    destination = args.app / "Contents/Helpers/HySimulMTHelper"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.helper, destination)
    destination.chmod(0o755)
    subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True)
    report["bundled_helper_sha256"] = sha256(destination)
    output = args.app / "Contents/Resources/hy-runtime-validation.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    for name in ("LICENSE-llama.cpp", "LICENSE-jsonhpp"):
        shutil.copy2(Path("native/HySimulMT") / name, args.app / "Contents/Resources" / name)
    print("已打包通过验证的 Hy-SimulMT 本地推理程序")


if __name__ == "__main__":
    main()
