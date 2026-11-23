#!/bin/bash
# Real-API probe for the Android LiveTranslate client: is a slow, backed-up or dropped session the
# service's doing or the app's? Streams macOS system-voice speech at real-time pace through the app's own
# `LiveTranslateClient` (android/core) and reports uplink backlog, latency per utterance and the transport
# cause of any disconnect. Three passes: normal speech, fast speech, fast speech with translated speech on.
#
#   scripts/probe_livetranslate.sh                  # Chinese speech → English
#   PROBE_SOURCE=en PROBE_TARGET=zh scripts/probe_livetranslate.sh
#
# Needs your LiveTranslate API key: set LIVETRANSLATE_API_KEY, or type it at the prompt (not echoed, not
# saved). LIVETRANSLATE_ENDPOINT overrides the default service address. Uses about 5 minutes of audio on the
# service, which is billed like normal use. Results: .build/livetranslate-probe/*.json
set -euo pipefail
cd "$(dirname "$0")/.."

source_lang="${PROBE_SOURCE:-zh}"
target="${PROBE_TARGET:-en}"
out=".build/livetranslate-probe"
mkdir -p "$out"

if [ -z "${LIVETRANSLATE_API_KEY:-}" ]; then
  read -rsp "LiveTranslate API Key（输入时不显示，不会保存）：" LIVETRANSLATE_API_KEY
  echo
fi
export LIVETRANSLATE_API_KEY

zh_text="今天我们来讨论下个季度的产品计划。首先是安卓版本的发布时间，我们希望在月底之前完成真机测试，然后同时发布苹果电脑和安卓两个版本。其次是会话记录功能，用户可以在侧栏里看到每一次对话，也可以继续录制或者导出成文本。第三点是网络稳定性，我们需要确认在移动网络下，实时翻译的延迟是否可以接受，以及断线以后能不能自动恢复。最后请大家在周五之前把各自负责的部分整理好，我们下周一再开一次会，确认最终的发布清单。"
en_text="Today we are going to talk about the product plan for next quarter. First, the Android release date: we want to finish testing on real phones before the end of the month, and then ship the Mac and Android versions together. Second, the session history feature: people can see every conversation in the sidebar, keep recording, or export it as text. Third, network stability: we need to check whether the real-time translation delay is acceptable on mobile networks, and whether it recovers by itself after a dropped connection. Finally, please get your parts ready by Friday, and we will meet again next Monday to confirm the final release checklist."
if [ "$source_lang" = "zh" ]; then
  text="$zh_text $zh_text"
  voice=$(say -v '?' | awk -F'  +' '/zh_CN/ { print $1; exit }')
  normal_rate=200; fast_rate=330
else
  text="$en_text $en_text"
  voice="Samantha"
  normal_rate=170; fast_rate=280
fi
[ -n "$voice" ] || { echo "没有找到 $source_lang 的系统语音（系统设置 → 辅助功能 → 朗读内容 → 系统声音）" >&2; exit 1; }

make_wav() { # <rate> <out.wav>
  local aiff="$out/speech.aiff"
  say -v "$voice" -r "$1" -o "$aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$2"
  rm -f "$aiff"
}
make_wav "$normal_rate" "$out/normal.wav"
make_wav "$fast_rate" "$out/fast.wav"

endpoint_arg=()
[ -n "${LIVETRANSLATE_ENDPOINT:-}" ] && endpoint_arg=("--endpoint=$LIVETRANSLATE_ENDPOINT")

probe() { # <label> <wav> <speech on|off>
  (cd android && ./gradlew -q -PcoreOnly=true :core:liveProbe --args="--audio=$PWD/../$2 --language=$target --speech=$3 --label=$1 --json=$PWD/../$out/$1.json ${endpoint_arg[*]:-}")
}
if [ -n "${PROBE_BURST_MS:-}" ]; then
  # Like the app after connecting or reconnecting: buffered speech sent at once, then real time.
  probe() { # <label> <wav> <speech on|off>
    (cd android && ./gradlew -q -PcoreOnly=true :core:liveProbe --args="--audio=$PWD/../$2 --language=$target --speech=$3 --label=$1 --burst-ms=$PROBE_BURST_MS --json=$PWD/../$out/$1.json ${endpoint_arg[*]:-}")
  }
  probe "burst-$PROBE_BURST_MS" "$out/normal.wav" off
  echo "结果已保存到 $out/burst-$PROBE_BURST_MS.json"
  exit 0
fi
probe normal "$out/normal.wav" off
probe fast "$out/fast.wav" off
probe fast-speech "$out/fast.wav" on
echo "结果已保存到 $out/{normal,fast,fast-speech}.json"
