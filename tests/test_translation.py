import json
import socket
import sys
import tempfile
import threading
import unittest
from dataclasses import asdict
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from core import FRAME, TranslationConfig, encode_message, read_message
from server import Server
from translation import TranslationPlanner, Translator, already_in_target, build_messages, same_text, validate_translator

PCM = b'\x01\x02' * FRAME

class ConfigTests(unittest.TestCase):
    def test_defaults_to_simplified_chinese_and_disabled(self):
        c = TranslationConfig()
        self.assertEqual(c.target_language, '简体中文')
        self.assertFalse(c.enabled)
        self.assertEqual(TranslationConfig.parse(asdict(c)), c)

    def test_invalid_values_rejected_and_save_atomic(self):
        for value in ({'schema_version': 2}, {'enabled': 1}, {'target_language': 'Klingon'},
                      {'model_id': 'bad'}, {'model_id': 'owner/'}, {'extra': True}):
            with self.assertRaises(ValueError): TranslationConfig.parse(value)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'translation.json'
            TranslationConfig(enabled=True, target_language='English').save(p)
            self.assertEqual(TranslationConfig.parse(json.loads(p.read_text())).target_language, 'English')
            self.assertFalse(p.with_suffix('.tmp').exists())
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)

class PlannerTests(unittest.TestCase):
    def test_silence_ended_finals_are_units(self):
        p = TranslationPlanner()
        self.assertEqual(p.add('s', 1, '你好。', False), (1, '你好。'))
        self.assertIsNone(p.add('s', 2, '  ', False))

    def test_forced_cut_translates_complete_sentences_and_carries_tail(self):
        p = TranslationPlanner()
        self.assertEqual(p.add('s', 1, 'First sentence. Second half', True), (1, 'First sentence.'))
        self.assertEqual(p.add('s', 2, 'continues here.', False), (2, 'Second half continues here.'))

    def test_cut_off_sentence_punctuated_by_asr_still_carries(self):
        # Real Qwen3-ASR output around a 5 s forced cut: it adds 。 where the audio was cut.
        p = TranslationPlanner()
        self.assertEqual(p.add('s', 1, '你好，这是一个本地语音识别测试。今天下午三点。', True), (1, '你好，这是一个本地语音识别测试。'))
        self.assertEqual(p.add('s', 2, '开会，请记住数字一二三四五。', False), (2, '今天下午三点开会，请记住数字一二三四五。'))

    def test_forced_cut_without_sentence_end_waits_for_next_final(self):
        p = TranslationPlanner()
        self.assertIsNone(p.add('s', 1, '我们今天讨论的是', True))
        self.assertEqual(p.add('s', 2, '本地推理。', False), (2, '我们今天讨论的是本地推理。'))
        self.assertIsNone(p.add('s', 3, 'The value is 3.14 and', True))

    def test_flush_anchors_to_last_text_and_sessions_do_not_mix(self):
        p = TranslationPlanner()
        p.add('s', 1, 'Done. Tail', True)
        self.assertIsNone(p.add('s', 2, '', True))
        self.assertEqual(p.flush('s'), (1, 'Tail'))
        self.assertIsNone(p.flush('s'))
        p.add('s', 3, 'Old tail', True)
        self.assertEqual(p.add('t', 1, 'New.', False), (1, 'New.'))
        self.assertIsNone(p.flush('t'))

    def test_long_carry_is_translated_without_waiting(self):
        text = 'word ' * 100
        self.assertEqual(TranslationPlanner().add('s', 1, text, True), (1, text.strip()))

class LanguageTests(unittest.TestCase):
    def test_same_script_speech_is_skipped_before_generation(self):
        self.assertTrue(already_in_target('今天我们测试Python和Swift，所有音频都在本地处理。', '简体中文'))
        self.assertFalse(already_in_target('This is a local speech recognition test.', '简体中文'))
        self.assertFalse(already_in_target('今日はいい天気ですね。', '简体中文'))
        self.assertTrue(already_in_target('今日はいい天気ですね。', '日本語'))
        self.assertTrue(already_in_target('안녕하세요', '한국어'))
        self.assertFalse(already_in_target('你好', '繁體中文'))
        self.assertFalse(already_in_target('Bonjour à tous', 'English'))
        self.assertTrue(already_in_target('123。', 'English'))

    def test_same_text_ignores_case_space_and_punctuation(self):
        self.assertTrue(same_text('Hello, world!', 'hello world'))
        self.assertFalse(same_text('Hello', '你好'))

    def test_prompts_use_context_turns_and_hunyuan_format(self):
        messages = build_messages('qwen3', '第二句。', 'English', [('第一句。', 'First sentence.')])
        self.assertIn('English', messages[0]['content'])
        self.assertEqual([m['role'] for m in messages], ['system', 'user', 'assistant', 'user'])
        self.assertEqual(messages[-1]['content'], '第二句。')
        self.assertEqual(build_messages('hunyuan_v1_dense', 'Hello.', '简体中文', [('ignored', 'context')]),
                         [{'role': 'user', 'content': '把下面的文本翻译成简体中文，不要额外解释。\n\nHello.'}])
        self.assertIn('into French', build_messages('hunyuan_v1_dense', 'Hello.', 'Français')[0]['content'])

class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def model(self, path=None, **config):
        path = path or self.path
        (path / 'config.json').write_text(json.dumps({'model_type': 'qwen3', **config}))
        (path / 'tokenizer_config.json').write_text('{}')
        (path / 'tokenizer.json').write_text('{}')
        (path / 'chat_template.jinja').write_text('{{ messages }}')
        (path / 'model.safetensors').touch()

    def test_mlx_text_model_accepted(self):
        self.model()
        self.assertEqual(validate_translator(self.path), self.path)

    def test_missing_chat_template_reported(self):
        self.model(); (self.path / 'chat_template.jinja').unlink()
        with self.assertRaisesRegex(ValueError, 'chat_template.jinja'): validate_translator(self.path)

    def test_custom_code_and_unsupported_architecture_rejected(self):
        self.model(auto_map={'x': 'remote.code'})
        with self.assertRaisesRegex(ValueError, '自定义'): validate_translator(self.path)
        self.model(model_type='qwen3_asr')
        with self.assertRaisesRegex(ValueError, '仅支持'): validate_translator(self.path)
        self.model(); (self.path / 'tokenizer_config.json').write_text(json.dumps({'auto_map': {'AutoTokenizer': ['x.Tok', None]}}))
        with self.assertRaisesRegex(ValueError, '自定义'): validate_translator(self.path)

    def test_missing_sharded_weight_reported(self):
        self.model()
        (self.path / 'model.safetensors.index.json').write_text(json.dumps({'weight_map': {'a': 'model-00002.safetensors'}}))
        with self.assertRaisesRegex(ValueError, 'model-00002'): validate_translator(self.path)

    def test_failed_validation_preserves_loaded_model(self):
        self.model(model_type='bad')
        translator = Translator(); previous = object(); translator.model = previous
        with self.assertRaises(ValueError): translator.load(TranslationConfig(), self.path)
        self.assertIs(translator.model, previous)

    def test_cached_translator_uses_its_own_validator(self):
        from model_cache import resolve_cached_model
        snapshot = self.path / 'models--owner--mt' / 'snapshots' / 'abc'
        snapshot.mkdir(parents=True)
        self.model(snapshot)
        with patch('model_cache.snapshot_download', side_effect=FileNotFoundError()):
            path, revision = resolve_cached_model(TranslationConfig(model_id='owner/mt'), self.path, validate_translator, '翻译模型尚未下载')
            self.assertEqual((Path(path), revision), (snapshot, 'abc'))
            with self.assertRaisesRegex(ValueError, '翻译模型尚未下载'):
                resolve_cached_model(TranslationConfig(model_id='owner/none'), self.path, validate_translator, '翻译模型尚未下载')

class FakeAdapter:
    def __init__(self): self.model = True
    def transcribe(self, pcm): return '这是测试', 1

class FakeTranslator:
    def __init__(self):
        self.model = True
        self.model_id = 'owner/fake'
        self.calls = []
        self.on_token = None
    def stream(self, text, target, context=()):
        self.calls.append((text, target, list(context)))
        result = ''
        for piece in ('Hello', ' world', '.'):
            if self.on_token: self.on_token()
            result += piece
            yield result
    def unload(self):
        self.model = None
        self.model_id = ''

class TranslationServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.a, self.b = socket.socketpair()
        self.b.settimeout(3)
        with patch('server.Adapter', FakeAdapter), patch('server.Translator', FakeTranslator):
            self.s = Server(self.a, self.tmp.name)
        self.s.state = 'ready'
        self.s.translation = TranslationConfig(enabled=True, target_language='English')
        self.thread = threading.Thread(target=self.s.run); self.thread.start()
    def tearDown(self):
        self.b.close(); self.thread.join(3); self.tmp.cleanup()
    def command(self, name, **kw):
        body = {'command': name, 'protocol_version': 1, 'session_id': 'test', 'request_id': 'req', **kw}
        self.b.sendall(encode_message(b'J', json.dumps(body).encode()))
    def event(self): return json.loads(read_message(self.b)[1])
    def events_until(self, predicate):
        events = []
        while not events or not predicate(events[-1]):
            events.append(self.event())
        return events
    def speak_and_stop(self):
        self.command('start'); self.assertEqual(self.event()['state'], 'recording')
        for _ in range(8): self.s.segmenter.feed(PCM, True)
        self.command('stop')

    def test_final_is_sent_first_then_translation_streams(self):
        self.speak_and_stop()
        events = self.events_until(lambda e: e['type'] == 'translation' and e['done'])
        kinds = [e['type'] for e in events]
        self.assertLess(kinds.index('final'), kinds.index('translation'))
        final = next(e for e in events if e['type'] == 'final')
        translations = [e for e in events if e['type'] == 'translation']
        self.assertEqual((translations[0]['revision'], translations[0]['text']), (0, ''))
        self.assertEqual(translations[-1]['text'], 'Hello world.')
        self.assertFalse(translations[-1]['skipped'])
        self.assertEqual({e['segment_id'] for e in translations}, {final['segment_id']})
        revisions = [e['revision'] for e in translations]
        self.assertEqual(revisions, sorted(set(revisions)))
        self.assertEqual(self.s.translator.calls[0][:2], ('这是测试', 'English'))

    def test_asr_final_preempts_running_translation(self):
        injected = []
        def inject():
            if not injected:
                injected.append(True)
                self.s.enqueue({'segment_id': 99, 'revision': 1, 'start_sample': 0, 'end_sample': FRAME,
                                'final': True, 'forced_cut': False, 'pcm': PCM})
        self.s.translator.on_token = inject
        self.speak_and_stop()
        events = self.events_until(lambda e: e['type'] == 'translation' and e['done'] and e['segment_id'] == 99)
        order = [(e['type'], e.get('segment_id'), e.get('done')) for e in events]
        self.assertLess(order.index(('final', 99, None)), order.index(('translation', 1, True)))
        self.assertEqual(self.s.translator.calls[1][2], [('这是测试', 'Hello world.')])

    def test_same_language_speech_is_not_translated(self):
        self.s.translation = TranslationConfig(enabled=True, target_language='简体中文')
        self.speak_and_stop()
        events = self.events_until(lambda e: e.get('state') == 'ready')
        self.assertTrue(any(e['type'] == 'final' for e in events))
        self.assertFalse(any(e['type'] == 'translation' for e in events))
        self.assertEqual(self.s.translator.calls, [])

    def test_disabling_unloads_and_persists(self):
        self.command('translation_settings', enabled=False)
        events = self.events_until(lambda e: e['type'] == 'translator' and e['state'] == 'idle')
        self.assertFalse(events[-1]['config']['enabled'])
        self.assertIsNone(self.s.translator.model)
        self.assertFalse(json.loads((Path(self.tmp.name) / 'translation.json').read_text())['enabled'])

    def test_enabling_without_downloaded_model_reports_and_turns_off(self):
        self.s.translator.model = None
        self.s.translation = TranslationConfig()
        self.command('translation_settings', enabled=True)
        events = self.events_until(lambda e: e['type'] == 'translator' and e['state'] == 'error')
        self.assertIn('尚未下载', events[-1]['detail'])
        self.assertFalse(events[-1]['config']['enabled'])

    def test_invalid_target_rejected_without_changing_config(self):
        self.command('translation_settings', target_language='Klingon')
        self.assertEqual(self.event()['type'], 'error')
        self.assertEqual(self.s.translation.target_language, 'English')

if __name__ == '__main__': unittest.main()
