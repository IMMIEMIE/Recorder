import json
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

if __name__=='__main__': unittest.main()
