# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

声笺 (Local Recorder) — an Apple Silicon–only macOS app (macOS 14+) for near-real-time local speech transcription. A SwiftUI front end captures audio and talks to a separate Python/MLX inference process. User-facing strings, error messages, and docs are in Simplified Chinese; keep new UI text and error messages consistent with that. The project is not a git repository.

## Commands

```bash
./scripts/setup.sh      # bootstrap uv into .bootstrap/, create .venv with Python 3.12.14, sync requirements.lock
./scripts/build.sh      # swift build -c release, assemble dist/声笺.app (bundles backend/ + a copied Python runtime), ad-hoc codesign
./scripts/package.sh    # verify signature, refuse if model weights are in the bundle, create dist/声笺-<ver>-arm64.dmg + .sha256
```

Tests:

```bash
.venv/bin/python -m unittest discover -s tests -v                          # all Python tests
.venv/bin/python -m unittest tests.test_core.CoreTests.test_silence_never_emits  # single test (run from repo root)
./scripts/test_ai.sh    # Swift AI-client tests: starts tests/mock_ai_server.py, compiles AIClient.swift + AIProfiles.swift + tests/AIClientTests.swift with swiftc
```

There is no XCTest target; Swift tests are a standalone `@main` executable built by `test_ai.sh`. When adding Swift code needed by those tests, add the file to the `swiftc` line in that script.

Real-model verification (needs Metal GPU and a local model snapshot; writes JSON results into `docs/`):

```bash
.venv/bin/python scripts/verify_model.py --model /abs/snapshot --audio tests/fixtures/chinese.aiff
.venv/bin/python scripts/verify_switching.py --qwen /abs/qwen/snapshot --whisper /abs/whisper/snapshot
.venv/bin/python scripts/verify_pipeline.py --model /abs/snapshot   # paced PCM through the real socket server
.venv/bin/python scripts/verify_translation.py                      # ASR + local translation via the socket server; needs both default models cached in models/
```

Version bumps: the version string is hardcoded in `scripts/build.sh` (Info.plist `CFBundleShortVersionString`/`CFBundleVersion`), `scripts/package.sh` (DMG name, volume name, install notes), and `README.md`. `package.sh` refuses to overwrite an existing DMG of the same name. After replacing `assets/AppIcon.png`, run `python3 scripts/make_icon.py`.

## Architecture

**Two processes.** `AppModel.launch()` (`Sources/Recorder/AppModel.swift`) spawns `Contents/Resources/runtime/bin/python3 backend/server.py --socket /tmp/recorder-<uuid>.sock --root ~/Library/Application Support/LocalRecorder`, with `HF_HUB_OFFLINE`/`TRANSFORMERS_OFFLINE=1` and `PYTHONDONTWRITEBYTECODE=1` (the app bundle is signed and must not be mutated at runtime). The app only runs from the built bundle, not via `swift run`, because it needs the bundled runtime. The backend accepts exactly one connection on the Unix socket (umask 077) and exits when the connection drops.

**Wire protocol** (`Transport.swift` ↔ `backend/core.py`): frames are a 4-byte big-endian length, then a 1-byte kind, then the payload. Kind `J` (74) is JSON; every message carries `protocol_version: 1`. Kind `A` (65) is audio: a 4-byte header length, a JSON header (`session_id`, `sequence`, `start_sample`, 16 kHz, mono, `s16le`), then raw PCM16. Control commands are `hello`, `load` and `download` (with `role: "translator"` and a `translation` dict they target the translation model), `translation_settings` (`enabled` / `target_language` / `provider: local|api` / `api_profile`), `cancel_download`, `start` (optional validated `endpoint_mode` and `endpoint_silence_ms`, saved for subsequent sessions), `stop`, and `shutdown`. ASR `load` accepts `provider: api` in its config and an ephemeral `api_key` beside the config. Events are `status`, `config`, `partial`, `final` (carries `forced_cut`), `translator` (translator state plus the saved translation config), `translation` (per unit: `unit_id`, anchor `segment_id`, `revision`, `text`, `done`, `skipped`), `error`, and download `progress` (carries `role`). If you change the protocol, update both sides and `scripts/verify_pipeline.py`.

**Swift side:**
- `AudioCapture` resamples microphone input to 16 kHz mono PCM16. `AdditionalAudioInput` reads audio files at their original pace with AVAudioFile or captures system audio with ScreenCaptureKit (audio output only). Both use `InputPCMConverter`; EOF flushes resampling and asks AppModel to finalize. Stop drains callbacks on the serial input queue before sending the backend stop command; stale system-start completions are generation-guarded. `scripts/test_audio.sh` checks file conversion, EOF, stop and restart without capture permissions.
- `Transport` caps buffered audio at 320 KB and drops chunks beyond that.
- `AppModel` holds session and transcript state. `Transcript.translations` is keyed by backend unit id, and `rows` maps `session:segment` to a row, so translations that finish after a new session starts still land on their row. `AppModel.translationTargets` must match `TRANSLATION_TARGETS` in `core.py`.
- `RecorderApp` contains the views, menu bar, and settings.
- The AI client (`AIClient`, `AIProfiles`, `AIWorkspace`) uses native HTTP. `APITranslationQueue` also reuses this client for finalized transcript translation when `TranslationConfig.provider` is `api`; `api_profile` selects a saved base URL. The backend persists these choices but never sees API keys or sends API requests. API mode unloads and bypasses the local translator. Queue callbacks use transcript IDs across sessions, and negative translation unit IDs are reserved for API output. It streams from OpenAI-compatible `/chat/completions` endpoints. It stores one JSON profile per normalized base URL under `LocalRecorder/AIProfiles`, API keys in the Keychain keyed by endpoint, and the current selection in UserDefaults.

**Python backend:**
- `server.py` `Server`: a reader loop handles control and audio messages. A single worker thread consumes the `jobs` deque (`load` / `infer` / `finish`) plus one `preview` slot. Final segments are always queued, but only the latest preview is kept, and it is dropped once its segment is finalized. If 6 or more final jobs are pending, the server auto-stops recording. If audio `sequence`/`start_sample` values are non-contiguous, it flushes and raises an error. Downloads run `download.py` as a subprocess with the offline env vars removed, parse its JSON-lines progress, and then queue a `load`. Only one download runs at a time. `download.py` must keep `.jinja` in its file filter, or translation models lose their chat template.
- Translation shares that single worker. Priority is `jobs` (ASR finals, loads, `finish`) > translation > preview. A running translation is a `mlx_lm.stream_generate` generator that is suspended between tokens whenever `jobs` is non-empty, then resumed. Only the worker thread may close a generator (`cancel_translations`); other threads only flag it (`drop_pending_translations`). Translator failures are reported through `translator` events and never change the ASR state or clear its queue. Enabling translation loads the translator, disabling unloads it, and a successful ASR load auto-loads it when enabled.
- `core.py`:
  - `Config` is a strictly validated dataclass. `schema_version` is checked, unknown or out-of-range values raise `ValueError`, and `save` writes atomically with mode 0600. It is saved only after load and warmup succeed, so a failed switch keeps the previous config.
  - `Segmenter` groups 20 ms frames with VAD into segments. Pre-roll is used only after silence. Default `endpoint_mode: smart` uses recognition feedback plus 500/1000/1800 ms silence thresholds; `fixed` uses `endpoint_silence_ms` (default 1000 ms). Explicit stop flushes immediately. Segmenter and feedback share the server condition RLock. `recognition.py` holds worker-only per-segment complete-chunk and whole-preview caches, cleared after final or model load/failure. No repeated previews are queued without new voiced samples. Internal voiced-position metadata never goes onto the wire. Periodic previews remain provisional. `max_segment_seconds` only bounds each model input in the server; it never forces a final. Final segments are contiguous and non-overlapping by design: there is no text dedup, so repeated words the speaker really said are kept. Don't add overlap or dedup. Current finals carry `forced_cut: false`; the field remains for protocol compatibility.
  - `TranslationConfig` is saved to its own `translation.json`, separate from `Config`, so ASR and translator settings commit independently.
- `translation.py`:
  - `TranslationPlanner` turns finals into translation units. A silence-ended final is one unit. Legacy forced-cut handling is retained: after a forced cut, the last sentence carries into the next final with its trailing punctuation removed, because Qwen3-ASR punctuates cut-off audio as if the sentence had ended.
  - `already_in_target` skips same-script text before generation; `same_text` hides output identical to the source.
  - `validate_translator` mirrors the ASR checks: an architecture allowlist, no `auto_map`, and a required chat template. `Translator` loads the model with `mlx_lm`.
- `adapter.py` `Adapter`: holds one loaded model at a time. `validate_config` detects the architecture from `config.json` (MLX Qwen3-ASR or MLX Whisper; Transformers/PyTorch formats are rejected), `load`/`warmup`/`unload` manage the model, and `transcribe(pcm)` returns `(text, elapsed_ms)`. MLX imports are deferred, so the tests can mock them.
- `asr_api.py` sends bounded WAV speech chunks to a configured OpenAI-compatible `/audio/transcriptions` endpoint. The Swift UI stores its API key in Keychain; the backend receives it only in the `load` command and keeps it in memory. Saved `Config` contains the provider, base URL, and model ID, but no key. Redirects are rejected. The existing recognition cache, segmenter, and final/partial event flow are shared with local ASR.
- ASR `api_protocol: qwen_realtime` uses `asr_bridge.py` to forward bounded, base64 PCM chunks through `asr_api_audio` events with a `call_id` and final `done` marker. `AppModel` assembles one request, and `QwenRealtimeASRClient` performs native WSS requests using Keychain credentials. It sends only documented `session.update` fields and waits until the echoed session has no automatic `turn_detection` (null or omitted), then appends PCM, commits once, and reads only input-ASR events (`.text`/`.delta`/`.completed`, bound to the committed item); it never sends `response.create`. A language hint is merged into the server's default `input_audio_transcription`; if the service rejects the update, it retries once with only `turn_detection: null` and remembers that per endpoint and model. Endpoints accept the platform's HTTPS base URL and are converted to `wss://<host>/api-ws/v1/realtime`. Errors show the HTTP status or server code/message with the key masked. The frontend returns `asr_api_result` (same call ID, text or error). The backend worker waits for this result before emitting the normal final and finishing the session. Qwen uses fixed local pause detection and suppresses paid rolling previews. `scripts/test_qwen_asr.sh` tests the native protocol with a local fixture; `test_core` tests the socket bridge and final draining.
- `model_cache.py` resolves HF-cache snapshots under `<root>/models`, using a role-specific `validate` callback.

**Invariants to preserve:**
- Model weights never go in the app bundle (`package.sh` enforces this).
- Local model load, local transcription, and local translation stay offline; explicit downloads, API transcription, AI requests, and enabled API translation use the network.
- Raw audio and transcript history are never persisted (`Config` rejects `save_audio`).
- Dependencies are fully pinned in `requirements.lock`, and nothing is installed at runtime.

`build.sh` writes `initial-config.json` pinning the locally cached Qwen snapshot revision unless `RECORDER_DISTRIBUTION=1`. Release notes and verification history are in `docs/RELEASE-*.md` and `docs/VALIDATION.md`.
