import json
import base64
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from core import Config, Segmenter, FRAME, read_message, encode_message
from asr_api import APIRecognizer
from server import Server

PCM = b'\x01\x02' * FRAME

class CoreTests(unittest.TestCase):
    def test_invalid_config_and_atomic_save(self):
        for value in ({'schema_version':2}, {'preview_interval_ms':1}, {'max_segment_seconds':300}, {'endpoint_silence_ms':299}, {'endpoint_silence_ms':2001}, {'endpoint_silence_ms':True}, {'save_audio':True}, {'language':'bogus'}, {'model_id':'bad'}):
            with self.assertRaises(ValueError): Config.parse(value)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'config.json'
            Config().save(p)
            self.assertEqual(Config.parse(json.loads(p.read_text())), Config())
            self.assertFalse(p.with_suffix('.tmp').exists())

    def test_api_config_validates_address_without_saving_key(self):
        values = {'provider':'api', 'api_base_url':'https://example.com/v1', 'api_model':'speech-model'}
        self.assertEqual(Config.parse(values).provider, 'api')
        for bad in ('http://example.com/v1', 'https://user:pass@example.com/v1',
                    'https://example.com/v1?key=secret', 'https://example.com/v1/'):
            with self.assertRaises(ValueError): Config.parse({**values, 'api_base_url':bad})
        with self.assertRaises(ValueError): Config.parse({**values, 'api_key':'secret'})
        qwen = {**values, 'api_protocol':'qwen_realtime', 'api_base_url':'wss://maas.qianwenaiapi.com/api-ws/v1/realtime'}
        self.assertEqual(Config.parse(qwen).api_protocol, 'qwen_realtime')
        for bad in ('https://example.com/realtime', 'ws://example.com/realtime', 'wss://example.com/realtime?key=secret'):
            with self.assertRaises(ValueError): Config.parse({**qwen, 'api_base_url':bad})

    def test_api_request_is_wav_multipart_and_never_follows_redirect(self):
        config = Config(provider='api', api_base_url='https://example.com/v1', api_model='speech-model', language='Chinese')
        client = APIRecognizer(); client.load(config, 'secret')
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return b'{"text":"\xe4\xbd\xa0\xe5\xa5\xbd"}'
        class Opener:
            def open(self, request, timeout):
                self_request = request
                self.assertions(self_request)
                return Response()
            def assertions(self, request):
                self_outer.assertEqual(request.full_url, 'https://example.com/v1/audio/transcriptions')
                self_outer.assertIn(b'name="model"\r\n\r\nspeech-model', request.data)
                self_outer.assertIn(b'name="language"\r\n\r\nzh', request.data)
                self_outer.assertIn(b'RIFF', request.data)
                self_outer.assertEqual(request.get_header('Authorization'), 'Bearer secret')
        self_outer = self
        client.opener = Opener()
        self.assertEqual(client.transcribe(PCM)[0], '你好')

    def test_silence_never_emits(self):
        events=[]; s=Segmenter(Config(),events.append)
        for _ in range(90000): s.feed(PCM,False)
        s.flush()
        self.assertEqual(events,[])
        self.assertEqual(len(s.preroll),0)

    def test_preroll_flush_preserves_short_tail(self):
        events=[]; s=Segmenter(Config(),events.append)
        for _ in range(20): s.feed(PCM,False)
        for _ in range(3): s.feed(PCM,True)
        s.flush(); s.flush()
        self.assertEqual(len(events),1)
        self.assertTrue(events[0]['final'])
        self.assertEqual(events[0]['start_sample'],8*FRAME)
        self.assertEqual(events[0]['end_sample'],23*FRAME)
        self.assertEqual(len(events[0]['pcm']),15*FRAME*2)

    def test_pause_threshold_and_short_pause_reset(self):
        for threshold in (300, 1000, 1500, 2000):
            events = []
            s = Segmenter(Config(endpoint_mode="fixed", endpoint_silence_ms=threshold, preview_interval_ms=10000), events.append)
            for _ in range(130): s.feed(PCM, True)
            for _ in range(threshold // 20 - 1): s.feed(PCM, False)
            self.assertEqual(events, [])
            s.feed(PCM, True)  # Resumed speech resets the silence timer.
            for _ in range(threshold // 20 - 1): s.feed(PCM, False)
            self.assertEqual(events, [])
            s.feed(PCM, False)
            self.assertEqual(len(events), 1)
            self.assertTrue(events[0]['final'])
            self.assertFalse(events[0]['forced_cut'])
            s.flush()
            self.assertEqual(len(events), 1)

    def test_long_speech_previews_but_waits_for_pause_to_finalize(self):
        events = []
        s = Segmenter(Config(endpoint_mode="fixed", max_segment_seconds=5), events.append)
        for _ in range(1600): s.feed(PCM, True)
        self.assertTrue(events)
        self.assertTrue(all(not e["final"] for e in events))  # Previews only, beyond 32 seconds.
        for _ in range(50): s.feed(PCM, False)
        events[:] = [e for e in events if e["final"]]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['pcm'], PCM * 1650)
        self.assertFalse(events[0]['forced_cut'])
        for _ in range(10): s.feed(PCM, True)
        s.flush()
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]['end_sample'], events[1]['start_sample'])
        self.assertEqual(b''.join(e['pcm'] for e in events), PCM * 1660)

    def test_framing_fragmented_and_bounds(self):
        a,b=socket.socketpair()
        def send():
            message=encode_message(b'J',b'{"ok":true}')
            for x in message: a.send(bytes([x]))
            a.close()
        threading.Thread(target=send).start()
        self.assertEqual(read_message(b),(b'J',b'{"ok":true}'))
        with self.assertRaises(EOFError): read_message(b)
        b.close()
        a,b=socket.socketpair(); a.send(struct.pack('!I',999999))
        with self.assertRaises(ValueError): read_message(b)
        a.close(); b.close()

class FakeAdapter:
    def __init__(self): self.model=True
    def transcribe(self,pcm): return '重复重复', 1
    def unload(self): self.model=None

class ServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.a,self.b=socket.socketpair()
        self.b.settimeout(3)
        with patch('server.Adapter',FakeAdapter): self.s=Server(self.a,self.tmp.name)
        self.s.state='ready'
        self.thread=threading.Thread(target=self.s.run); self.thread.start()
    def tearDown(self):
        self.b.close(); self.thread.join(3); self.tmp.cleanup()
    def command(self,name,**kw):
        body={'command':name,'protocol_version':1,'session_id':'test','request_id':'req',**kw}
        self.b.sendall(encode_message(b'J',json.dumps(body).encode()))
    def event(self): return json.loads(read_message(self.b)[1])
    def test_stop_finalizes_once_and_preserves_repetition(self):
        self.command('start'); self.assertEqual(self.event()['state'],'recording')
        # Segmentation is independently tested; inject explicit speech to avoid synthetic VAD assumptions.
        for _ in range(8): self.s.segmenter.feed(PCM,True)
        self.command('stop')
        events=[]
        while True:
            e=self.event(); events.append(e)
            if e.get('state')=='ready': break
        finals=[e for e in events if e['type']=='final']
        self.assertEqual(len(finals),1)
        self.assertEqual(finals[0]['text'],'重复重复')
        self.assertEqual(finals[0]['session_id'],'test')
        self.command('stop')
        self.assertEqual(self.s.state,'ready')
    def test_start_applies_and_saves_pause_without_model_reload(self):
        self.command('start', endpoint_mode='fixed', endpoint_silence_ms=1500)
        self.assertEqual(self.event()['state'], 'recording')
        self.assertEqual(self.s.segmenter.config.endpoint_mode, 'fixed')
        self.assertEqual(self.s.segmenter.config.endpoint_silence_ms, 1500)
        self.assertEqual(json.loads(self.s.config_path.read_text())['endpoint_silence_ms'], 1500)

    def test_invalid_pause_does_not_start_recording(self):
        self.command('start', endpoint_silence_ms=0)
        self.assertEqual(self.event()['type'], 'error')
        self.assertEqual(self.s.state, 'ready')
        self.assertEqual(self.s.config.endpoint_silence_ms, 1000)

    def test_audio_gap_stops_and_reports(self):
        self.command('start'); self.event()
        h=json.dumps({'session_id':'test','sequence':2,'start_sample':0}).encode()
        self.b.sendall(encode_message(b'A',struct.pack('!I',len(h))+h+PCM))
        events=[self.event() for _ in range(3)]
        self.assertTrue(any(e['type']=='error' and '序号' in e['message'] for e in events))
        self.assertEqual(self.s.state,'ready')
    def test_latest_preview_coalesces(self):
        with self.s.cv:
            for revision in range(100):
                self.s.enqueue({'segment_id':1,'revision':revision,'final':False,'pcm':PCM})
            self.assertEqual(self.s.preview['revision'],99)
            self.assertEqual(len(self.s.jobs),0)
            self.s.preview=None

    def test_api_load_uses_memory_key_and_persists_only_settings(self):
        config = Config(provider='api', api_base_url='https://example.com/v1', api_model='speech-model')
        self.command('load', config=config.__dict__, api_key='top-secret')
        events=[]
        while True:
            event=self.event(); events.append(event)
            if event.get('state')=='ready': break
        self.assertEqual(self.s.api_recognizer.key, 'top-secret')
        self.assertEqual(self.s.config.provider, 'api')
        self.assertNotIn('top-secret', self.s.config_path.read_text())
        self.assertTrue(any(e['type']=='config' for e in events))

    def test_api_recognition_uses_existing_final_event(self):
        config = Config(provider='api', api_base_url='https://example.com/v1', api_model='speech-model')
        self.command('load', config=config.__dict__, api_key='top-secret')
        while self.event().get('state') != 'ready': pass
        sent=[]
        def transcribe(pcm):
            sent.append(pcm)
            return 'API 转写', 5
        self.s.api_recognizer.transcribe = transcribe
        self.command('start'); self.assertEqual(self.event()['state'], 'recording')
        for _ in range(8): self.s.segmenter.feed(PCM, True)
        self.command('stop')
        events=[]
        while True:
            event=self.event(); events.append(event)
            if event.get('state')=='ready': break
        self.assertEqual(len(sent), 1)
        self.assertEqual([e['text'] for e in events if e['type']=='final'], ['API 转写'])

    def test_qwen_bridge_final_is_drained_before_ready_without_previews_or_key(self):
        config = Config(provider='api', api_protocol='qwen_realtime',
                        api_base_url='wss://maas.qianwenaiapi.com/api-ws/v1/realtime',
                        api_model='qwen-audio-3.1-realtime-plus')
        self.command('load', config=config.__dict__)
        while self.event().get('state') != 'ready': pass
        self.assertEqual(self.s.api_recognizer.key, '')
        self.command('start'); self.assertEqual(self.event()['state'], 'recording')
        self.assertEqual(self.s.config.endpoint_mode, 'fixed')
        for _ in range(130): self.s.segmenter.feed(PCM, True)
        self.command('stop')
        events=[]; audio=bytearray(); replied=False
        while True:
            event=self.event(); events.append(event)
            if event['type']=='asr_api_audio':
                audio.extend(base64.b64decode(event['audio']))
                if event['done']:
                    self.assertEqual(self.s.state, 'finalizing')
                    self.command('asr_api_result', call_id='stale', text='必须忽略')
                    self.command('asr_api_result', call_id=event['call_id'], text='千问转写')
                    replied=True
            if event.get('state')=='ready': break
        self.assertTrue(replied)
        self.assertEqual(audio, PCM * 130)
        self.assertFalse(any(e['type']=='partial' for e in events))
        self.assertEqual([e['text'] for e in events if e['type']=='final'], ['千问转写'])

if __name__=='__main__': unittest.main()
