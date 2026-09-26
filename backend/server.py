import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import asdict
from pathlib import Path
from core import Config, FRAME, RATE, TranslationConfig, read_message, encode_message, Segmenter
from adapter import Adapter
from asr_api import APIRecognizer
from asr_bridge import NativeASRBridge
from recognition import RecognitionCache
from translation import CONTEXT_PAIRS, TranslationPlanner, Translator, already_in_target, same_text, validate_translator

MAX_PENDING_TRANSLATIONS = 4
TRANSLATOR_BUSY = ('downloading', 'loading', 'warming')

class Server:
    def __init__(self, connection, root):
        self.conn, self.root = connection, Path(root)
        self.send_lock = threading.Lock()
        self.cv = threading.Condition(threading.RLock())
        self.jobs = deque()
        self.preview = None
        self.active = False
        self.alive = True
        self.state = 'idle'
        self.session = ''
        self.request = ''
        self.config = Config()
        self.adapter = Adapter()
        self.api_recognizer = APIRecognizer()
        self.qwen_recognizer = NativeASRBridge(self.send, lambda: self.alive)
        self.recognition = RecognitionCache()
        self.downloader = None
        self.download_role = 'asr'
        self.pending = bytearray()
        self.seq = self.samples = 0
        self.segmenter = None
        self.final_segments = set()
        # Translation shares the single GPU worker. Only the worker touches the planner and live streams.
        self.translation = TranslationConfig()
        self.translator = Translator()
        self.translator_state = 'idle'
        self.translator_detail = ''
        self.translations = deque()
        self.translating = None
        self.planner = TranslationPlanner()
        self.context = deque(maxlen=CONTEXT_PAIRS)
        self.unit = 0
        self.overload_session = None
        self.config_path = self.root / 'config.json'
        self.translation_path = self.root / 'translation.json'
        try:
            self.config = Config.parse(json.loads(self.config_path.read_text()))
        except FileNotFoundError:
            pass
        except Exception:
            self.send(type='error', message='保存的配置无效，已恢复默认值')
        try:
            self.translation = TranslationConfig.parse(json.loads(self.translation_path.read_text()))
        except FileNotFoundError:
            pass
        except Exception:
            self.send(type='error', message='保存的翻译配置无效，已恢复默认值')
        threading.Thread(target=self.worker, daemon=True).start()

    def send(self, **event):
        event = {'protocol_version': 1, 'session_id': self.session, 'request_id': self.request, **event}
        data = encode_message(b'J', json.dumps(event, ensure_ascii=False).encode())
        try:
            with self.send_lock:
                self.conn.sendall(data)
        except OSError:
            self.alive = False

    def status(self, state, detail=''):
        self.state = state
        self.send(type='status', state=state, detail=detail)

    def translator_status(self, state, detail=''):
        self.translator_state, self.translator_detail = state, detail
        self.send(type='translator', state=state, detail=detail, config=asdict(self.translation),
                  active_model=self.translator.model_id)

    def enqueue(self, item):
        with self.cv:
            if self.config.provider == 'api' and self.config.api_protocol == 'qwen_realtime' and not item['final']:
                return  # Submit each finalized segment once; no repeated paid preview requests.
            item['session_id'] = self.session
            if item['final']:
                self.final_segments.add(item['segment_id'])
                self.preview = None
                self.jobs.append(('infer', item))
            else:
                self.preview = item
            self.cv.notify()

    def flush(self):
        if self.state != 'recording':
            return
        self.status('finalizing', '正在处理最后一段语音…')
        if self.pending:
            pcm = bytes(self.pending).ljust(FRAME * 2, b'\0')
            self.segmenter.feed(pcm, self.vad.is_speech(pcm, RATE))
            self.pending.clear()
        self.segmenter.flush()
        with self.cv:
            self.preview = None
            self.jobs.append(('finish', self.session))
            self.cv.notify()

    def worker(self):
        while self.alive:
            with self.cv:
                self.cv.wait_for(lambda: self.jobs or self.preview or self.translating or self.translations or not self.alive)
                if not self.alive:
                    return
                if self.jobs:
                    kind, value = self.jobs.popleft()
                elif self.translating or self.translations:
                    # Translation outranks previews but yields to every queued job between tokens.
                    kind, value = 'translate', None
                else:
                    kind, value = 'infer', self.preview
                    self.preview = None
                self.active = kind != 'translate'
            try:
                if kind in ('load_translator', 'unload_translator', 'translate'):
                    self.translator_job(kind, value)
                elif kind == 'load_api':
                    config, key = value
                    if config.api_protocol == 'openai':
                        self.api_recognizer.load(config, key)
                    else:
                        self.api_recognizer.key = ''
                    self.adapter.unload()
                    self.recognition.clear()
                    config.save(self.config_path)
                    self.config = config
                    self.send(type='config', config=asdict(config))
                    self.status('ready', '识别 API 已就绪 · 语音片段将发送到所选服务')
                    if self.translation.enabled and self.translation.provider == 'local' and self.translator.model is None and self.translator_state not in TRANSLATOR_BUSY:
                        self.queue_translator_load(TranslationConfig(**asdict(self.translation)))
                elif kind == 'load':
                    config, path = value
                    self.status('loading', '加载模型到本机内存…')
                    if not path:
                        from model_cache import resolve_cached_model
                        path, config.revision = resolve_cached_model(config, self.root / 'models')
                    self.recognition.clear()
                    self.adapter.load(config, path)
                    self.status('warming', '正在预热模型…')
                    self.adapter.warmup()
                    self.api_recognizer.key = ''
                    config.save(self.config_path)
                    self.config = config
                    self.send(type='config', config=asdict(config))
                    self.status('ready', '模型已就绪 · 本地推理')
                    if self.translation.enabled and self.translation.provider == 'local' and self.translator.model is None and self.translator_state not in TRANSLATOR_BUSY:
                        self.queue_translator_load(TranslationConfig(**asdict(self.translation)))
                elif kind == 'infer':
                    def obsolete():
                        with self.cv:
                            return (value['session_id'] != self.session or
                                    (not value['final'] and value['segment_id'] in self.final_segments))
                    recognizer = self.api_recognizer if self.config.provider == 'api' else self.adapter
                    if self.config.provider == 'api' and self.config.api_protocol == 'qwen_realtime':
                        recognizer = self.qwen_recognizer
                    text, duration = self.recognition.transcribe(recognizer, self.config, value, obsolete)
                    with self.cv:
                        valid = value['session_id'] == self.session
                        valid &= value['final'] or value['segment_id'] not in self.final_segments
                    if valid:
                        self.send(type='final' if value['final'] else 'partial', text=text,
                                  elapsed_ms=duration, **{k:v for k,v in value.items() if k not in ('pcm','final','last_voiced_sample')})
                        if value['final']:
                            self.plan_translation(value, text)
                        else:
                            with self.cv:
                                if self.segmenter is not None and value['session_id'] == self.session:
                                    self.segmenter.accept_preview(value, text)
                    if value['final']:
                        self.recognition.forget(value)
                        with self.cv:
                            self.final_segments.discard(value['segment_id'])
                elif kind == 'finish':
                    self.queue_unit(value, self.planner.flush(value))
                    if value == self.session:
                        self.status('ready', '尾句处理完成')
            except Exception as e:
                with self.cv:
                    self.recognition.clear()
                    dropped = list(self.jobs)
                    self.jobs.clear()
                    self.preview = None
                if any(job == 'load_translator' for job, _ in dropped):
                    self.translator_status('ready' if self.translator.model is not None else 'idle')
                self.status('error', f'{type(e).__name__}: {e}')
                self.send(type='error', message=f'识别处理失败 ({type(e).__name__}): {e}。已确认文字仍保留，可重新加载识别服务恢复。')
            finally:
                with self.cv:
                    self.active = False

    def queue_translator_load(self, config, path=''):
        self.translator_status('loading', '等待加载翻译模型…')
        with self.cv:
            self.jobs.append(('load_translator', (config, path)))
            self.cv.notify()

    def translator_job(self, kind, value):
        """Translator failures never touch the ASR state or its queue."""
        try:
            if kind == 'translate':
                self.translation_step()
            elif kind == 'unload_translator':
                self.cancel_translations()
                self.translator.unload()
                self.translator_status('idle', '实时翻译已关闭')
            else:
                config, path = value
                self.translator_status('loading', '加载翻译模型到本机内存…')
                if not path:
                    from model_cache import resolve_cached_model
                    path, config.revision = resolve_cached_model(config, self.root / 'models', validate_translator,
                                                                 '翻译模型尚未下载，请在设置 → 翻译中点击「下载翻译模型」。')
                validate_translator(path)
                # Suspended generators hold the previous model; end them before it is released.
                self.cancel_translations()
                self.translator.load(config, path)
                self.translator_status('warming', '正在预热翻译模型…')
                self.translator.warmup()
                config.enabled, config.target_language = True, self.translation.target_language
                config.save(self.translation_path)
                self.translation = config
                self.translator_status('ready', '翻译模型已就绪 · 本地推理')
        except Exception as e:
            self.cancel_translations()
            if self.translator.model is None and self.translation.enabled:
                self.translation.enabled = False
                self.translation.save(self.translation_path)
            label = '翻译模型加载失败' if kind == 'load_translator' else '翻译失败'
            self.send(type='error', message=f'{label} ({type(e).__name__}): {e}。原文不受影响。')
            self.translator_status('ready' if self.translator.model is not None else 'error', f'{label}：{e}')

    def plan_translation(self, value, text):
        if self.translation.enabled and self.translation.provider == 'local' and self.translator.model is not None:
            unit = self.planner.add(value['session_id'], value['segment_id'], text, value.get('forced_cut', False))
            self.queue_unit(value['session_id'], unit)

    def queue_unit(self, session, unit):
        if unit is None or already_in_target(unit[1], self.translation.target_language):
            return
        with self.cv:
            dropped = []
            while len(self.translations) >= MAX_PENDING_TRANSLATIONS:
                dropped.append(self.translations.popleft())
            self.unit += 1
            job = {'unit_id': self.unit, 'session_id': session, 'segment_id': unit[0], 'source': unit[1]}
        for old in dropped:
            self.end_translation(old)
        if dropped and self.overload_session != session:
            self.overload_session = session
            self.send(type='error', message='翻译跟不上语速，已跳过部分句子的译文；原文不受影响。')
        self.send(type='translation', session_id=session, segment_id=job['segment_id'], unit_id=job['unit_id'],
                  revision=0, text='', done=False)
        with self.cv:
            self.translations.append(job)
            self.cv.notify()

    def translation_step(self):
        with self.cv:
            if self.translating is None and self.translations:
                self.translating = self.translations.popleft()
            job = self.translating
        if job is None:
            return
        if job.get('cancelled') or not self.translation.enabled or self.translation.provider != 'local' or self.translator.model is None:
            return self.finish_translation(job)
        if 'stream' not in job:
            target = self.translation.target_language
            context = [(source, text) for t, session, source, text in self.context
                       if t == target and session == job['session_id']]
            job.update(target=target, text='', revision=0, sent=0.0, started=time.monotonic(),
                       stream=self.translator.stream(job['source'], target, context))
        for text in job['stream']:
            job['text'] = text
            if text.strip() and time.monotonic() - job['sent'] >= 0.2:
                job['revision'] += 1
                job['sent'] = time.monotonic()
                self.send(type='translation', session_id=job['session_id'], segment_id=job['segment_id'],
                          unit_id=job['unit_id'], revision=job['revision'], text=text.strip(), done=False)
            if self.jobs or job.get('cancelled') or not self.alive:
                return  # Suspended between tokens; queued ASR work runs first.
        text = job['text'].strip()
        if text and not same_text(text, job['source']):
            self.context.append((job['target'], job['session_id'], job['source'], text))
            return self.finish_translation(job, text)
        self.finish_translation(job)

    def finish_translation(self, job, text=''):
        with self.cv:
            if self.translating is job:
                self.translating = None
        self.end_translation(job, text)

    def end_translation(self, job, text=''):
        """An empty final text means skipped: same language, overload, or cancellation."""
        stream = job.pop('stream', None)
        if stream is not None:
            stream.close()
        elapsed = (time.monotonic() - job['started']) * 1000 if 'started' in job else 0
        self.send(type='translation', session_id=job['session_id'], segment_id=job['segment_id'],
                  unit_id=job['unit_id'], revision=job.get('revision', 0) + 1, text=text, done=True,
                  skipped=not text, elapsed_ms=elapsed)

    def drop_pending_translations(self):
        """Safe from any thread: queued jobs have no stream; the running one is only flagged."""
        with self.cv:
            pending = list(self.translations)
            self.translations.clear()
            if self.translating is not None:
                self.translating['cancelled'] = True
            self.cv.notify()
        for job in pending:
            self.end_translation(job)

    def cancel_translations(self):
        """Worker thread only, because it closes the running generator."""
        self.drop_pending_translations()
        with self.cv:
            job, self.translating = self.translating, None
        if job is not None:
            self.end_translation(job)

    def download(self, config, role='asr'):
        self.download_role = role
        if role == 'translator':
            self.translator_status('downloading', '正在查询翻译模型资源…')
        else:
            self.status('downloading', '正在查询模型资源…')
        env = {k:v for k,v in os.environ.items() if k not in ('HF_HUB_OFFLINE','TRANSFORMERS_OFFLINE')}
        process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('download.py')),
                    config.model_id, config.revision, str(self.root / 'models')], stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True, env=env)
        self.downloader = process
        def monitor():
            downloaded = None
            for line in process.stdout:
                try:
                    event = json.loads(line)
                    if self.downloader is not process:
                        continue
                    if event['type'] == 'downloaded':
                        downloaded = event
                    else:
                        self.send(role=role, **event)
                except ValueError:
                    continue
            process.wait()
            with self.cv:
                if self.downloader is not process:
                    return
                self.downloader = None
                if downloaded and process.returncode == 0:
                    config.revision = downloaded['revision']
                    if role == 'translator':
                        self.translator_status('loading')
                        self.jobs.append(('load_translator', (config, downloaded['path'])))
                    else:
                        self.status('loading')
                        self.jobs.append(('load', (config, downloaded['path'])))
                    self.cv.notify()
                elif role == 'translator':
                    self.translator_status('error', '翻译模型下载失败；可重试，已下载缓存可复用')
                else:
                    self.status('error', '下载失败；可重试，已下载缓存可复用')
        threading.Thread(target=monitor, daemon=True).start()

    def control(self, message):
        if message.get('protocol_version') != 1:
            raise ValueError('协议版本不兼容')
        self.request = message.get('request_id', '')
        cmd = message['command']
        if cmd == 'hello':
            self.send(type='config', config=asdict(self.config))
            self.translator_status(self.translator_state, self.translator_detail)
            self.status(self.state, '请加载本地模型，或下载默认模型')
        elif cmd in ('load', 'download') and message.get('role', 'asr') == 'translator':
            if self.translator_state in TRANSLATOR_BUSY:
                raise ValueError('请等待翻译模型操作结束')
            config = TranslationConfig.parse({**asdict(self.translation), **message.get('translation', {})})
            if config.provider != 'local':
                raise ValueError('请先选择本地模型翻译')
            if cmd == 'download':
                if self.downloader:
                    raise ValueError('请等待当前下载结束')
                self.download(config, 'translator')
            else:
                self.queue_translator_load(config)
        elif cmd in ('load', 'download'):
            if message.get('role', 'asr') != 'asr':
                raise ValueError('未知模型角色')
            if self.state not in ('idle', 'ready', 'error') or self.active or self.jobs:
                raise ValueError('请等待当前操作结束再切换模型')
            config = Config.parse(message.get('config', asdict(self.config)))
            if cmd == 'download':
                if config.provider == 'api':
                    raise ValueError('API 服务无需下载，请使用加载 / 切换')
                if config.local_model_path:
                    raise ValueError('本地目录无需下载，请使用加载')
                if self.downloader:
                    raise ValueError('请等待当前下载结束')
                self.download(config)
            else:
                self.status('loading')
                with self.cv:
                    if config.provider == 'api':
                        self.jobs.append(('load_api', (config, message.get('api_key', ''))))
                    else:
                        self.jobs.append(('load', (config, config.local_model_path)))
                    self.cv.notify()
        elif cmd == 'translation_settings':
            values = asdict(self.translation)
            values.update({key: message[key] for key in ('enabled', 'target_language', 'provider', 'api_profile') if key in message})
            config = TranslationConfig.parse(values)
            busy = self.translator_state in TRANSLATOR_BUSY
            if busy and (config.enabled != self.translation.enabled or config.provider != self.translation.provider):
                raise ValueError('请等待翻译模型操作结束')
            config.save(self.translation_path)
            self.translation = config
            if busy:
                self.translator_status(self.translator_state, self.translator_detail)
            elif not config.enabled or config.provider == 'api':
                self.drop_pending_translations()
                if self.translator.model is None:
                    self.translator_status('idle')
                else:
                    self.translator_status('loading', '正在关闭实时翻译…')
                    with self.cv:
                        self.jobs.append(('unload_translator', None))
                        self.cv.notify()
            elif self.translator.model is None:
                self.queue_translator_load(TranslationConfig(**asdict(config)))
            else:
                self.translator_status(self.translator_state, self.translator_detail)
        elif cmd == 'asr_api_result':
            self.qwen_recognizer.resolve(message.get('call_id'), message.get('text', ''), message.get('error', ''))
        elif cmd == 'cancel_download':
            if self.downloader:
                process, self.downloader = self.downloader, None
                process.terminate()
                if self.download_role == 'translator':
                    self.translator_status('ready' if self.translator.model is not None else 'idle', '下载已取消，可重试续传')
                else:
                    self.status('ready' if self.adapter.model is not None else 'idle', '下载已取消，可重试续传')
        elif cmd == 'start':
            if self.state != 'ready':
                raise ValueError('模型尚未就绪')
            config = Config.parse({**asdict(self.config),
                                   'endpoint_mode': 'fixed' if self.config.provider == 'api' and self.config.api_protocol == 'qwen_realtime' else message.get('endpoint_mode', self.config.endpoint_mode),
                                   'endpoint_silence_ms': message.get('endpoint_silence_ms', self.config.endpoint_silence_ms)})
            if config != self.config:
                config.save(self.config_path)
                self.config = config
            import webrtcvad
            self.vad = webrtcvad.Vad(2)
            self.session = message['session_id']
            self.final_segments.clear()
            self.pending.clear()
            self.seq = self.samples = 0
            self.segmenter = Segmenter(self.config, self.enqueue, self.cv)
            self.status('recording', '正在聆听…')
        elif cmd == 'stop':
            if message.get('session_id') == self.session:
                self.flush()
        elif cmd == 'shutdown':
            self.alive = False
        else:
            raise ValueError('未知控制指令')

    def audio(self, payload):
        size = struct.unpack('!I', payload[:4])[0]
        if size > 4096:
            raise ValueError('音频头过长')
        header = json.loads(payload[4:4+size])
        pcm = payload[4+size:]
        if self.state != 'recording' or header.get('session_id') != self.session:
            return
        if header.get('sequence') != self.seq or header.get('start_sample') != self.samples:
            self.flush()
            raise ValueError('音频序号不连续，已停止采集并处理已接收音频')
        if header.get('sample_rate') != RATE or header.get('channels') != 1 or header.get('format') != 's16le' or len(pcm) % 2:
            self.flush()
            raise ValueError('音频格式必须为 16 kHz 单声道 PCM16')
        self.seq += 1
        self.samples += len(pcm) // 2
        self.pending.extend(pcm)
        while len(self.pending) >= FRAME * 2:
            frame = bytes(self.pending[:FRAME * 2])
            del self.pending[:FRAME * 2]
            self.segmenter.feed(frame, self.vad.is_speech(frame, RATE))
        # Stop accepting audio before the finite final queue can grow indefinitely.
        with self.cv:
            overloaded = len(self.jobs) >= 6
        if overloaded:
            self.send(type='error', message='推理落后：已自动停止录音，正在完成已接收语音。请等待处理完成后再开始。')
            self.flush()

    def run(self):
        self.conn.settimeout(None)
        try:
            while self.alive:
                kind, payload = read_message(self.conn)
                try:
                    if kind == b'J':
                        self.control(json.loads(payload))
                    elif kind == b'A':
                        self.audio(payload)
                    else:
                        raise ValueError('未知消息类型')
                except Exception as e:
                    self.send(type='error', message=str(e))
        except (EOFError, OSError, ValueError):
            pass
        finally:
            self.alive = False
            if self.downloader:
                self.downloader.terminate()
            with self.cv:
                self.cv.notify_all()
            self.conn.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--socket', required=True)
    parser.add_argument('--root', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(args.socket)
        listener.listen(1)
        listener.settimeout(30)
        connection, _ = listener.accept()
        listener.close()
        Server(connection, args.root).run()
    finally:
        listener.close()
        Path(args.socket).unlink(missing_ok=True)
