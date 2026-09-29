#!/bin/bash
# Frame-exact VAD agreement check: Swift Cwebrtcvad vs the Python webrtcvad wheel.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/golden.py" <<'PY'
import numpy as np, webrtcvad, json, sys
rng = np.random.RandomState(7)
chunks = []
for i in range(300):
    kind = i % 8
    if kind == 0:
        chunks.append(np.zeros(640, dtype=np.int16))
    elif kind == 1:
        t = np.arange(960) / 16000
        chunks.append((np.sin(2 * np.pi * 440 * t) * 8000).astype(np.int16))
    elif kind == 2:
        chunks.append((rng.randn(320) * 8).astype(np.int16))
    elif kind == 3:
        t = np.arange(1600) / 16000
        sig = np.sin(2 * np.pi * 200 * t) * (500 + 3000 * (np.sin(2 * np.pi * 8 * t) > 0))
        chunks.append(sig.astype(np.int16))
    elif kind == 4:
        chunks.append((rng.randn(640) * 60).astype(np.int16))
    elif kind == 5:
        t = np.arange(320) / 16000
        chunks.append((np.sin(2 * np.pi * 90 * t) * 3000).astype(np.int16))
    elif kind == 6:
        chunks.append((rng.randn(640) * 2500).astype(np.int16))
    else:
        t = np.arange(480) / 16000
        chunks.append((np.sin(2 * np.pi * 1200 * t) * 500).astype(np.int16))
pcm = np.concatenate(chunks)
pcm.tobytes() and open(sys.argv[1], 'wb').write(pcm.tobytes())
vad = webrtcvad.Vad(2)
json.dump([vad.is_speech(pcm[i:i+320].tobytes(), 16000) for i in range(0, len(pcm) - len(pcm) % 320, 320)],
          open(sys.argv[2], 'w'))
PY
.venv/bin/python "$work/golden.py" "$work/golden.raw" "$work/golden.json"
cat > "$work/check.swift" <<'SWIFT'
import Foundation

@main struct P {
    static func main() throws {
        let pcm = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let vad = try WebRTCVAD(aggressiveness: 2)
        var decisions: [Bool] = []
        var offset = 0
        while offset + 640 <= pcm.count {
            decisions.append(vad.isSpeech(pcm.subdata(in: offset..<(offset + 640))))
            offset += 640
        }
        print(decisions.map { $0 ? "true" : "false" }.joined(separator: ","))
    }
}
SWIFT
bin=$(swift build --show-bin-path)
swift build --target Cwebrtcvad >/dev/null
objects=$(find "$bin/Cwebrtcvad.build" -name '*.o')
swiftc -o "$work/check" "$work/check.swift" \
  Sources/Recorder/Backend/BackendTypes.swift Sources/Recorder/Backend/ConfigStore.swift \
  Sources/Recorder/Backend/Segmenter.swift Sources/Recorder/Backend/TranslationPlanner.swift \
  Sources/Recorder/Backend/RecognitionCache.swift Sources/Recorder/Backend/ModelCache.swift \
  Sources/Recorder/Backend/BackendCore.swift Sources/Recorder/Backend/WebRTCVAD.swift \
  Sources/Recorder/Backend/ASRAPIClient.swift Sources/Recorder/Backend/InProcessChannel.swift \
  $objects \
  -Xcc -fmodule-map-file="$bin/Cwebrtcvad.build/module.modulemap" \
  -I Sources/Cwebrtcvad/include \
  -module-cache-path "$PWD/.build/module-cache"
"$work/check" "$work/golden.raw" > "$work/swift.txt"
.venv/bin/python - "$work/golden.json" "$work/swift.txt" <<'PY'
import json, sys
golden = json.load(open(sys.argv[1]))
swift = [s == 'true' for s in open(sys.argv[2]).read().strip().split(',')]
assert len(golden) == len(swift), f"frame count mismatch: {len(golden)} vs {len(swift)}"
mismatch = [i for i, (g, s) in enumerate(zip(golden, swift)) if g != s]
print(f"VAD 对拍: {len(golden)} 帧, 不一致 {len(mismatch)} 帧")
assert not mismatch, f"mismatched frames: {mismatch[:10]}"
PY
echo "VAD 对拍通过"
