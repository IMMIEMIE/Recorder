#!/usr/bin/env python3
"""Create reproducible synthetic audio for the two 10-minute Hy soak runs.

Only test speech is saved. This is a timing/regression fixture, not a claim about
translation quality for real meetings. Requires installed macOS system voices.

System voices pause in digital zero, which no microphone produces, so the noise
fixtures lay seeded room tone under the same speech and add a pure room-tone clip.
"""
import argparse
import array
import json
import math
from pathlib import Path
import random
import subprocess
import wave

TEXT = {
    "english": """Good morning. Today we are reviewing the plan for a local translation application.
The first version must work without sending the microphone audio to a remote server.
Please remember that activating three billion parameters does not mean the complete model needs only three gigabytes of memory.
We have forty-eight gigabytes of unified memory, and we need to measure the actual peak usage.
The meeting was originally scheduled for Tuesday at nine thirty, but it has been moved to Thursday at eleven.
The cost did not increase by fifteen percent. It decreased by five percent compared with the previous month.
Before we publish the software, we must test both English to Chinese and Chinese to English.
If a sentence is unfinished when the recording stops, the application should keep the text it has already received and explain what remains incomplete.
The audio can come from a microphone, a file, or the sound currently playing on the computer.
Please turn off spoken translation if you only want to read the subtitles.
The next speaker will talk for a while without pausing, so the program must manage its context without losing any words, restarting the entire model, or allowing the audio queue to grow indefinitely.
At the end of this test, we will compare the original text, the translated text, and the timing report.
Thank you for listening. We will now continue with another section of the demonstration.""",
    "chinese": """大家好，今天我们讨论本地同声传译应用的开发计划。
第一版必须能够在不上传麦克风音频的情况下工作。
请注意，每次激活三十亿参数，并不意味着整个模型只需要三吉字节内存。
这台电脑有四十八吉字节统一内存，我们需要测量实际运行时的峰值占用。
会议原定于星期二上午九点半举行，现在改为星期四上午十一点。
费用并没有增加百分之十五，而是比上个月减少了百分之五。
在发布软件之前，我们必须分别验证英语到中文，以及中文到英语的翻译。
如果停止录音时还有一句话没有说完，应用应该保留已经收到的文字，并明确说明哪些内容没有完成。
声音可以来自麦克风、一个音频文件，或者电脑当前正在播放的系统声音。
如果只想阅读字幕，可以关闭播放译音的选项。
接下来发言的人会连续讲一段较长的话，因此程序必须正确管理上下文，不能丢失文字，不能每次都重新加载整个模型，也不能让等待处理的音频无限增长。
测试结束后，我们会对比原文、译文和记录下来的处理时间。
感谢大家参与，我们现在继续演示的下一部分。""",
}
TAIL = {
    "english": "The final verification code is seven hundred and forty-two. Please keep this last sentence.",
    "chinese": "最后的验证编号是七百四十二。请保留这最后一句话。",
}


def read_pcm(path):
    with wave.open(str(path), "rb") as audio:
        assert audio.getnchannels() == 1 and audio.getsampwidth() == 2 and audio.getframerate() == 16000
        pcm = audio.readframes(audio.getnframes())
        if not pcm:
            raise RuntimeError(f"{path}: system speech produced no audio; check installed voices and speech-service permissions")
        return pcm


def room_tone(seconds, rms, generator):
    # A one-pole low-pass over white noise is closer to a room than white noise is.
    values, state = [], 0.0
    for _ in range(int(seconds * 16000)):
        state = 0.97 * state + generator.gauss(0, 1)
        values.append(state)
    scale = rms / math.sqrt(sum(value * value for value in values) / len(values))
    return [value * scale for value in values]


def write_floats(path, samples):
    pcm = array.array("h", (max(-32768, min(32767, int(value * 32768))) for value in samples))
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
        audio.writeframes(pcm.tobytes())


def write_noise_fixtures(output, manifest):
    generator = random.Random(20261105)
    quiet, fan = 0.0015, 0.008  # about -56 dBFS (quiet room) and -42 dBFS (fan, louder than a fixed 0.003 RMS gate)
    write_floats(output / "room-tone.wav", room_tone(60, fan, generator))
    manifest["files"].append({"path": str(output / "room-tone.wav"), "seconds": 60, "rms": fan})
    for language, level in (("english", quiet), ("chinese", fan)):
        speech = [value / 32768 for value in array.array("h", read_pcm(output / f"{language}-validation.wav"))][:16000 * 30]
        # Speech, a long pause, then speech again: the shape of a real conversation.
        samples = room_tone(3, level, generator)
        samples += [a + b for a, b in zip(speech, room_tone(len(speech) / 16000, level, generator))]
        samples += room_tone(12, level, generator)
        samples += [a + b for a, b in zip(speech, room_tone(len(speech) / 16000, level, generator))]
        samples += room_tone(6, level, generator)
        write_floats(output / f"{language}-noisy.wav", samples)
        manifest["files"].append({"path": str(output / f"{language}-noisy.wav"), "seconds": len(samples) / 16000, "rms": level})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".build/hy-verification"))
    parser.add_argument("--seconds", type=int, default=610)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {"synthetic": True, "description": "System TTS plus repository fixtures; timing/regression only", "files": []}
    for language, voice in (("english", "Samantha"), ("chinese", "Tingting")):
        text = args.output / f"{language}-validation.txt"
        text.write_text(TEXT[language])
        aiff = args.output / f"{language}-validation.aiff"
        spoken = args.output / f"{language}-validation.wav"
        short = args.output / f"{language}.wav"
        subprocess.run(["say", "-v", voice, "-r", "170", "-f", str(text), "-o", str(aiff)], check=True)
        for source, output in ((aiff, spoken), (Path("tests/fixtures") / f"{language}.aiff", short)):
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(source), str(output)], check=True)
        # Complete spoken passages are never truncated to meet the duration.
        clips = [read_pcm(spoken), read_pcm(short)]
        result = bytearray()
        index = 0
        while len(result) / 32000 < args.seconds:
            result.extend(clips[index % 2])
            result.extend(bytes(int([0.15, 2.7, 0.5, 1.3][index % 4] * 32000)))
            index += 1
        tail_text = args.output / f"{language}-tail.txt"
        tail_text.write_text(TAIL[language])
        tail_aiff = args.output / f"{language}-tail.aiff"
        tail_wav = args.output / f"{language}-tail.wav"
        subprocess.run(["say", "-v", voice, "-r", "170", "-f", str(tail_text), "-o", str(tail_aiff)], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(tail_aiff), str(tail_wav)], check=True)
        result.extend(read_pcm(tail_wav))
        output = args.output / f"{language}-long.wav"
        with wave.open(str(output), "wb") as audio:
            audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
            audio.writeframes(result)
        manifest["files"].append({"path": str(output), "seconds": len(result) / 32000,
                                  "voice": voice, "target_language": "zh" if language == "english" else "en"})
        print(f"{output}: {len(result) / 32000:.2f}s")
    write_noise_fixtures(args.output, manifest)
    (args.output / "fixtures.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
