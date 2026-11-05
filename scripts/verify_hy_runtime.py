#!/usr/bin/env python3
"""Exercise the real bundled Hy helper with paced PCM, without storing transcripts.

Input WAVs must be mono PCM16 at 16 kHz. A release gate requires at least 600
seconds in each direction; a short smoke run always reports passed=false.
"""
import argparse
import base64
import hashlib
import json
import os
import platform
from pathlib import Path
import queue
import re
import subprocess
import tempfile
import threading
import time
import uuid
import wave

RUNTIME_COMMIT = "d38e66aac7bb18101f417338b795e4546a5a1a59"


def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(16 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


class Client:
    def __init__(self, helper, model, context, log, reference=False):
        print(json.dumps(dict(phase="loading_model", context=context, reference=reference)), flush=True)
        self.events = queue.Queue()
        self.process = subprocess.Popen(
            [str(helper), "--model", str(model), "--ctx", str(context), "--trace-tokens"] + (["--reference-mode"] if reference else []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            text=True, encoding="utf-8", bufsize=1)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.hello = self.until("hello", timeout=180)
        if self.hello.get("runtime_commit") != RUNTIME_COMMIT:
            raise RuntimeError("helper runtime commit mismatch")
        print(json.dumps(dict(phase="model_ready", load_ms=self.hello.get("load_ms"), peak_rss_bytes=self.hello.get("peak_rss_bytes"))), flush=True)

    def _read(self):
        try:
            for line in self.process.stdout:
                event = json.loads(line)
                if event.get("protocol_version") != 1:
                    raise RuntimeError("helper protocol mismatch")
                self.events.put(event)
        except Exception as error:
            self.events.put({"type": "error", "message": str(error)})
        finally:
            self.events.put({"type": "exit"})

    def send(self, kind, session=None, **fields):
        message = dict(type=kind, protocol_version=1, **fields)
        if session is not None:
            message["session_id"] = session
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def until(self, kind, session=None, timeout=60):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"helper did not send {kind}")
            event = self.events.get(timeout=remaining)
            if event["type"] in ("error", "exit"):
                raise RuntimeError(event.get("message", "helper exited"))
            if event["type"] == kind and (session is None or event.get("session_id") == session):
                return event

    def empty(self):
        session = str(uuid.uuid4())
        self.send("start", session, language="zh")
        self.until("ready", session)
        self.send("finish", session)
        done = self.until("done", session)
        return done.get("complete") is True and done.get("duration_ms") == 0

    def cancel(self, path):
        session = str(uuid.uuid4())
        self.send("start", session, language="zh")
        self.until("ready", session)
        with wave.open(str(path), "rb") as source:
            pcm = source.readframes(25600)
        if len(pcm) != 51200 or not any(pcm):
            raise ValueError("cancellation fixture must contain at least 1.6 seconds of nonzero PCM")
        self.send("audio", session, pcm=base64.b64encode(pcm).decode())
        self.until("inference_started", session)
        self.send("cancel", session)
        done = self.until("done", session)
        return done.get("cancelled") is True and not done.get("complete")

    def run(self, path, direction, repeat_seconds=0, realtime=True, anchors=None, trace=False):
        with wave.open(str(path), "rb") as source:
            if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getcomptype()) != (1, 2, 16000, "NONE"):
                raise ValueError(f"{path}: need uncompressed 16 kHz mono PCM16 WAV")
            pcm = source.readframes(source.getnframes())
        if not pcm:
            raise ValueError("empty verification audio")
        if repeat_seconds:
            count = int(repeat_seconds * 32000)
            pcm = (pcm * ((count + len(pcm) - 1) // len(pcm)))[:count]
        session = str(uuid.uuid4())
        self.send("start", session, language=direction.split("-")[1])
        self.until("ready", session)
        started = time.monotonic()
        finish_sent = threading.Event()
        send_errors = []

        def audio_writer():
            try:
                # Vary packet sizes; model turn boundaries must not depend on IPC packets.
                sizes = (640, 2114, 3200, 962, 6400)
                offset = index = 0
                last_progress = started
                while offset < len(pcm):
                    block = pcm[offset:offset + sizes[index % len(sizes)]]
                    if realtime:
                        delay = started + (offset + len(block)) / 32000 - time.monotonic()
                        if delay > 0:
                            time.sleep(delay)
                    self.send("audio", session, pcm=base64.b64encode(block).decode())
                    offset += len(block)
                    index += 1
                    if time.monotonic() - last_progress >= 30:
                        print(json.dumps(dict(phase="streaming", direction=direction,
                                             sent_audio_seconds=round(offset / 32000, 2))), flush=True)
                        last_progress = time.monotonic()
                finish_sent.set()
                self.send("finish", session)
            except Exception as error:
                send_errors.append(str(error))

        writer = threading.Thread(target=audio_writer, daemon=True)
        writer.start()
        segments = {}
        committed_ids = set()
        before_eof = duplicate_commit = invalid_interval = invalid_revision = False
        source_chars = target_chars = warnings = 0
        first_translation = None
        token_trace = []
        source_text = target_text = ""
        deadline = started + len(pcm) / 32000 * (2 if realtime else 3) + 180
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=min(30, max(0.1, deadline - time.monotonic())))
            except queue.Empty:
                continue
            if event["type"] in ("error", "exit"):
                raise RuntimeError(event.get("message", "helper exited during session"))
            if event.get("session_id") != session:
                continue
            if event["type"] == "warning":
                warnings += 1
            if event["type"] == "trace":
                token_trace.append(event["token_ids"])
            if event["type"] == "update":
                key = event["segment_id"]
                revision = event["revision"]
                previous = segments.get(key)
                invalid_revision |= previous is not None and revision <= previous["revision"]
                invalid_interval |= not (0 <= event["start_sample"] <= event["end_sample"] <= len(pcm) // 2)
                segments[key] = event
                if event.get("translation") and first_translation is None:
                    first_translation = (time.monotonic() - started) * 1000
                if event.get("committed"):
                    duplicate_commit |= key in committed_ids
                    committed_ids.add(key)
                    before_eof |= not finish_sent.is_set()
                    source_chars += len(event.get("source", ""))
                    target_chars += len(event.get("translation", ""))
                    source_text += event.get("source", "")
                    target_text += event.get("translation", "")
            if event["type"] == "done":
                done = event
                break
        else:
            raise TimeoutError("translation session did not finish")
        writer.join(timeout=5)
        if send_errors or writer.is_alive():
            raise RuntimeError("audio writer did not finish: " + str(send_errors))
        audio_seconds = len(pcm) / 32000
        result = dict(
            direction=direction, audio_seconds=audio_seconds,
            repeated_fixture=bool(repeat_seconds), fixture=str(Path(path).resolve()),
            realtime_factor=done.get("inference_ms", float("inf")) / (audio_seconds * 1000),
            complete=done.get("complete") is True,
            max_queue_seconds=done.get("max_queue_seconds", float("inf")),
            first_translation_ms=first_translation,
            committed_segments=len(committed_ids), source_characters=source_chars,
            translated_characters=target_chars, streamed_before_eof=before_eof,
            duplicate_commits=duplicate_commit, invalid_interval=invalid_interval,
            invalid_revision=invalid_revision, warnings=warnings,
            window_resets=done.get("window_resets", 0),
            context_resets=done.get("context_resets", 0),
            early_rollovers=done.get("early_rollovers", 0),
            malformed_turns=done.get("malformed_turns", 0),
            tail_padding_samples=done.get("tail_padding_samples", 0),
            recovery_attempts=done.get("recovery_attempts", 0),
            successful_recoveries=done.get("successful_recoveries", 0),
            eof_recovery_attempts=done.get("eof_recovery_attempts", 0),
            successful_eof_recoveries=done.get("successful_eof_recoveries", 0),
            peak_rss_bytes=done.get("peak_rss_bytes", 0),
            unresolved_audio_ms=done.get("unresolved_audio_ms", -1),
            skipped_untranslated_audio_ms=done.get("skipped_untranslated_audio_ms", -1),
            duration_accounted=done.get("duration_ms") == len(pcm) // 32)
        if anchors:
            def hits(text, groups):
                compact = re.sub(r"\s+", "", text).casefold()
                return [any(re.sub(r"\s+", "", candidate).casefold() in compact for candidate in group) for group in groups]
            source_hits = hits(source_text, anchors.get("source", []))
            target_hits = hits(target_text, anchors.get("target", []))
            # Translation is the product. The model's source line can drop a word it translates
            # correctly ("decreased by 5" -> "减少了5%"), so a source miss is recorded, not fatal.
            result["anchors_passed"] = bool(target_hits) and all(target_hits)
            result["source_anchor_misses"] = source_hits.count(False)
            result["source_anchor_hits"] = source_hits
            result["target_anchor_hits"] = target_hits
        if trace:
            result["_trace"] = token_trace
        return result

    def close(self):
        if self.process.poll() is None:
            try:
                self.send("shutdown")
                self.process.wait(timeout=20)
            except Exception:
                self.process.kill()
                self.process.wait()


def cli_parity(helper, reference, model, paths, log):
    results = []
    for direction, path in paths.items():
        print(json.dumps(dict(phase="cli_parity", direction=direction)), flush=True)
        with tempfile.TemporaryDirectory(prefix="hy-parity-") as directory:
            clip = Path(directory) / "clip.wav"
            with wave.open(str(path), "rb") as source:
                params = source.getparams()
                pcm = source.readframes(16000 * 8)
            with wave.open(str(clip), "wb") as target:
                target.setparams(params)
                target.writeframes(pcm)
            language = "中文" if direction == "en-zh" else "英文"
            prompt = ("<｜hy_begin▁of▁sentence｜><｜reasoning_mode｜>reasoning_effort:no_think<｜hy_User｜>"
                      f"请完成下面的同声传译任务，将陆续收到的语音翻译成{language}。请结合上下文边听边译，输出能够确定的译文，不必等待整句结束。"
                      "<__media__><｜hy_Assistant｜><think></think><｜hy_place▁holder▁no▁790｜>")
            result = subprocess.run(
                [str(reference), "-m", str(model), "--audio", str(clip), "-c", "16384", "-n", "4096",
                 "--temp", "0", "--repeat-penalty", "1", "-t", "10", "-tb", "10", "-ngl", "999",
                 "--no-warmup", "-p", prompt], capture_output=True, text=True, timeout=180)
            reference_turns = {}
            for turn, token in re.findall(r"HY_REFERENCE_TOKEN (\d+) (\d+)", result.stderr):
                reference_turns.setdefault(int(turn), []).append(int(token))
            if result.returncode or not reference_turns:
                raise RuntimeError(f"reference CLI failed ({result.returncode}): " + result.stderr[-1600:])
            client = Client(helper, model, 16384, log, reference=True)
            try:
                actual = client.run(clip, direction, trace=True).pop("_trace")
            finally:
                client.close()
            expected = [reference_turns[key] for key in sorted(reference_turns)]
            results.append(dict(direction=direction, exact_token_match=actual == expected,
                                turns=len(expected), generated_tokens=sum(map(len, expected))))
    return results


def tail_probes(client, path):
    """Exercise a genuine WAIT-at-EOF path, without changing model scheduling.

    These deliberately truncated fragments check recovery/control flow only;
    the full runs' final content anchors separately check meaningful tail text.
    The model translates short openings straight away, so the search continues
    into longer cuts until one ends while the model is still waiting.
    """
    print(json.dumps(dict(phase="eof_recovery_probes")), flush=True)
    with wave.open(str(path), "rb") as source:
        params = source.getparams()
        pcm = source.readframes(16000 * 30)
    results = []
    with tempfile.TemporaryDirectory(prefix="hy-tail-") as directory:
        clip = Path(directory) / "tail.wav"
        cuts = (0.12, 0.35, 0.9, 1.75, 2.65) + tuple(3 + 0.55 * step for step in range(49))
        for seconds in (cut for cut in cuts if cut * 32000 <= len(pcm)):
            with wave.open(str(clip), "wb") as target:
                target.setparams(params)
                target.writeframes(pcm[:int(seconds * 16000) * 2])
            result = client.run(clip, "en-zh")
            result["fixture"] = str(path.resolve())
            result["truncated_probe"] = True
            results.append(result)
            if result["successful_eof_recoveries"]:
                break
    return results


def tail_recovery_passed(runs, probes):
    return (all(run["tail_padding_samples"] > 0 and run["complete"] for run in runs)
            and all(run["complete"] and run["duration_accounted"] and not run["duplicate_commits"]
                    and not run["invalid_interval"] and not run["invalid_revision"]
                    and run["unresolved_audio_ms"] == 0 for run in probes)
            and any(run["successful_eof_recoveries"] > 0 for run in probes))


def noise_floor_runs(client, folder):
    """A microphone never delivers digital zero; pauses must still cost nothing and report nothing."""
    print(json.dumps(dict(phase="noise_floor")), flush=True)
    return dict(room_tone=client.run(folder / "room-tone.wav", "en-zh"),
                speech=[client.run(folder / "english-noisy.wav", "en-zh"),
                        client.run(folder / "chinese-noisy.wav", "zh-en")])


def noise_floor_passed(runs):
    room = runs["room_tone"]
    return (room["complete"] and room["committed_segments"] == 0 and room["warnings"] == 0
            and room["recovery_attempts"] == 0
            and all(run["complete"] and run["committed_segments"] > 0 and run["warnings"] == 0
                    and run["window_resets"] == 0 and run["duration_accounted"] for run in runs["speech"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--helper", type=Path, default=Path(".build/hy-runtime/bin/HySimulMTHelper"))
    parser.add_argument("--en-zh", required=True, type=Path)
    parser.add_argument("--zh-en", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("docs/hy-runtime-verification.json"))
    parser.add_argument("--ctx", type=int, default=16384)
    parser.add_argument("--reference-cli", type=Path, default=Path(".build/hy-runtime/bin/HySimulMTReferenceCLI"))
    parser.add_argument("--anchors", type=Path, help="JSON with per-direction source/target lists of alternative anchor strings")
    parser.add_argument("--tail-fixture", type=Path, help="English WAV for actual WAIT-at-EOF probes; defaults to --en-zh")
    parser.add_argument("--noise-fixtures", type=Path, default=Path(".build/hy-verification"),
                        help="folder with the room-tone and noisy speech WAVs from make_hy_validation_audio.py")
    parser.add_argument("--synthetic-fixtures", action="store_true", help="Explicitly identify all input fixtures as synthetic speech")
    parser.add_argument("--skip-extended", action="store_true", help="smoke only: skip parity and rollover; passed stays false")
    parser.add_argument("--repeat-seconds", type=float, default=0,
                        help="repeat fixtures to this length; report clearly labels synthetic input")
    args = parser.parse_args()
    report = dict(schema_version=1, runtime_commit=RUNTIME_COMMIT,
                  model_sha256=digest(args.model), helper_sha256=digest(args.helper),
                  passed=False, context_size=args.ctx, checks={}, runs=[],
                  synthetic_input=args.synthetic_fixtures,
                  platform=platform.platform(), architecture=platform.machine(),
                  started_at_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  input_fixtures={direction: dict(path=str(getattr(args, direction.replace("-", "_")).resolve()),
                                                  sha256=digest(getattr(args, direction.replace("-", "_"))))
                                  for direction in ("en-zh", "zh-en")},
                  memory_measurement="native getrusage(RUSAGE_SELF).ru_maxrss; bytes on macOS")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    client = None
    anchors = json.loads(args.anchors.read_text()) if args.anchors else {}
    try:
        with open(args.output.with_suffix(".log"), "w", encoding="utf-8") as log:
            client = Client(args.helper.resolve(), args.model.resolve(), args.ctx, log)
            report["model_load_ms"] = client.hello.get("load_ms")
            report["checks"]["runtime_identity"] = True
            report["checks"]["empty_session"] = client.empty()
            report["checks"]["cancel_and_restart"] = client.cancel(args.en_zh) and client.empty()
            for direction in ("en-zh", "zh-en"):
                report["failed_direction"] = direction
                run = client.run(getattr(args, direction.replace("-", "_")), direction, args.repeat_seconds, anchors=anchors.get(direction))
                report["runs"].append(run)
                print(json.dumps(run, ensure_ascii=False), flush=True)
                report.pop("failed_direction", None)
            report["checks"]["long_bilingual_streaming"] = all(
                run["audio_seconds"] >= 600 and run["complete"] and run["realtime_factor"] <= 1
                and run["max_queue_seconds"] <= 10 and run["streamed_before_eof"]
                and run["source_characters"] > 0 and run["translated_characters"] > 0
                and run["duration_accounted"] and not run["duplicate_commits"]
                and not run["invalid_interval"] and not run["invalid_revision"]
                and run["unresolved_audio_ms"] == 0 and run["skipped_untranslated_audio_ms"] == 0
                for run in report["runs"])
            report["checks"]["post_session_restart"] = client.empty()
            report["checks"]["streaming_before_eof"] = all(run["streamed_before_eof"] for run in report["runs"])
            report["checks"]["content_anchors"] = all(run.get("anchors_passed") is True for run in report["runs"])
            report["checks"]["tail_recovery"] = False
            report["checks"]["noise_floor"] = False
            if not args.skip_extended:
                report["noise_floor"] = noise_floor_runs(client, args.noise_fixtures)
                report["checks"]["noise_floor"] = noise_floor_passed(report["noise_floor"])
                report["tail_probes"] = tail_probes(client, args.tail_fixture or args.en_zh)
                report["checks"]["tail_recovery"] = tail_recovery_passed(report["runs"], report["tail_probes"])
            client.close()
            client = None
            report["checks"]["cli_parity"] = False
            report["checks"]["rollover"] = False
            if not args.skip_extended:
                report["parity"] = cli_parity(args.helper.resolve(), args.reference_cli.resolve(), args.model.resolve(),
                                             {"en-zh": args.en_zh, "zh-en": args.zh_en}, log)
                report["checks"]["cli_parity"] = all(result["exact_token_match"] for result in report["parity"])
                client = Client(args.helper.resolve(), args.model.resolve(), 2048, log)
                report["rollover_runs"] = [client.run(args.en_zh, "en-zh", repeat_seconds=240),
                                           client.run(args.zh_en, "zh-en", repeat_seconds=240)]
                report["checks"]["rollover"] = all(
                    rollover["context_resets"] >= 2 and rollover["complete"]
                    and rollover["duration_accounted"] and not rollover["duplicate_commits"]
                    and not rollover["invalid_interval"] and not rollover["invalid_revision"]
                    for rollover in report["rollover_runs"])
            report["passed"] = all(report["checks"].values()) and len(report["runs"]) == 2
    except Exception as error:
        report["error"] = str(error)
    finally:
        if client is not None:
            client.close()
        report["peak_rss_bytes"] = max(run.get("peak_rss_bytes", 0) for run in report["runs"] + report.get("rollover_runs", []) + [{}])
        temporary = args.output.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, args.output)
    print(f"verification report: {args.output.resolve()}; passed={report['passed']}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
