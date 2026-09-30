import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from core import Config, Segmenter, FRAME, sentence_complete
from recognition import RecognitionCache

PCM = b'\x01\x02' * FRAME

class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.s = Segmenter(Config(), self.events.append)
    def feed(self, count, voiced):
        for _ in range(count): self.s.feed(PCM, voiced)
    def result(self, text):
        item = dict(self.events[-1])
        self.s.accept_preview(item, text)
        return item
    def finals(self):
        return [e for e in self.events if e['final']]
    def test_default_and_legacy(self):
        self.assertEqual(Config.parse({'endpoint_silence_ms':760}).endpoint_mode, 'smart')
        with self.assertRaises(ValueError): Config.parse({'endpoint_mode':'bad'})
    def test_terminal_hints(self):
        for text in ('完成了。', 'Hello world.', '完成测试 done!', '“真的吗？”'):
            self.assertTrue(sentence_complete(text), text)
        for text in ('等一下…', 'Well...', 'Mr.', 'Dr.', 'U.S.', '3.14.', '1.', '你好，', '未完成', 'A.'):
            self.assertFalse(sentence_complete(text), text)
    def test_one_result_one_second_reuses_silence_without_previews(self):
        self.feed(60, True); self.result('完成了。')
        self.feed(49, False); self.assertFalse(self.finals())
        self.feed(1, False); self.assertEqual(len(self.finals()), 1)
        self.assertEqual(len(self.events), 2)
    def test_two_stable_results_half_second(self):
        self.feed(60, True); self.result('完成了。')
        self.feed(60, True); self.result('完成了。')
        self.feed(24, False); self.assertFalse(self.finals())
        self.feed(1, False); self.assertEqual(len(self.finals()), 1)
    def test_changed_or_incomplete_waits(self):
        for tail in ('现在完成了。', '还没有完成', '3.14.'):
            self.setUp()
            self.feed(60, True); self.result('完成了。')
            self.feed(60, True); self.result(tail)
            self.feed(89, False); self.assertFalse(self.finals())
            self.feed(1, False); self.assertEqual(len(self.finals()), 1)
    def test_resumed_speech_invalidates_old_punctuation(self):
        self.feed(60, True); old = self.result('完成了。')
        self.feed(20, False); self.feed(1, True)
        self.s.accept_preview(old, '完成了。')
        self.feed(50, False); self.assertFalse(self.finals())
        self.feed(40, False); self.assertEqual(len(self.finals()), 1)
    def test_late_feedback_can_finalize_but_never_new_segment(self):
        self.feed(60, True); old = dict(self.events[-1])
        self.feed(50, False)
        self.s.accept_preview(old, '完成了。')
        self.assertEqual(len(self.finals()), 1)
        self.feed(60, True)
        self.s.accept_preview(old, '旧句。')
        self.feed(50, False); self.assertEqual(len(self.finals()), 1)
        self.s.flush(); self.s.flush(); self.assertEqual(len(self.finals()), 2)
    def test_out_of_order_feedback_does_not_replace_newer_text(self):
        self.feed(60, True); old = dict(self.events[-1])
        self.feed(60, True); self.result('还没说完')
        self.s.accept_preview(old, '旧句。')
        self.feed(50, False); self.assertFalse(self.finals())
        self.feed(40, False); self.assertEqual(len(self.finals()), 1)

    def preview_frames(self, config, frames=240, ratio=0.0, low_power=False):
        self.events = []
        self.s = Segmenter(config, self.events.append, low_power=low_power)
        self.s.cost_ratio = ratio  # inference ms per ms of audio, as measured by earlier previews
        self.feed(frames, True)
        return [e['end_sample'] // FRAME for e in self.events if not e['final']]
    def test_power_mode_config(self):
        self.assertEqual((Config().power_mode, Config().idle_release_minutes), ('balanced', 15))
        for bad in ({'power_mode':'turbo'}, {'idle_release_minutes':7}, {'idle_release_minutes':True}):
            with self.assertRaises(ValueError): Config.parse(bad)
    def test_preview_budget_scales_with_measured_cost(self):
        # Next preview once L - last >= max(interval, factor * ratio * L), L = segment length.
        self.assertEqual(self.preview_frames(Config(power_mode='performance'), ratio=0.25), [60, 120, 180, 240])
        self.assertEqual(self.preview_frames(Config(), ratio=0.05), [60, 120, 180, 240])
        self.assertEqual(self.preview_frames(Config(), ratio=0.25), [60, 120, 240])
        self.assertEqual(self.preview_frames(Config(power_mode='saver'), frames=400), [120, 240, 360])
        self.assertEqual(self.preview_frames(Config(power_mode='saver'), frames=500, ratio=0.125), [120, 480])
    def test_low_power_uses_saver_budget_unless_performance(self):
        self.assertEqual(self.preview_frames(Config(), frames=400, low_power=True), [120, 240, 360])
        self.assertEqual(self.preview_frames(Config(power_mode='performance'), frames=180, low_power=True), [60, 120, 180])
    def test_preview_cost_is_measured_per_audio_ms_and_cached_results_ignored(self):
        self.feed(60, True)
        self.s.accept_preview(dict(self.events[-1]), '还没说完', elapsed_ms=300)
        self.assertEqual(self.s.cost_ratio, 0.25)
        self.s.accept_preview(dict(self.events[-1]), '还没说完', elapsed_ms=0)
        self.assertEqual(self.s.cost_ratio, 0.25)

    def test_never_force_cut_speech(self):
        self.feed(2000, True)
        self.assertFalse(self.finals())
        self.s.flush()
        self.assertEqual(self.finals()[0]['pcm'], PCM * 2000)

class FakeAdapter:
    def __init__(self): self.calls = []
    def transcribe(self, pcm):
        self.calls.append(pcm)
        return '重复', 10

class CacheTests(unittest.TestCase):
    def setUp(self):
        self.cache = RecognitionCache(); self.adapter = FakeAdapter()
        self.config = Config(max_segment_seconds=5)
    def item(self, frames, voiced=None, segment=1):
        return dict(session_id='s', segment_id=segment, start_sample=0,
                    pcm=PCM * frames, last_voiced_sample=(voiced or frames) * FRAME)
    def run_item(self, item): return self.cache.transcribe(self.adapter, self.config, item)
    def test_same_speech_reuses_result_and_preserves_repetition(self):
        self.assertEqual(self.run_item(self.item(600))[0], '重复重复重复')
        self.assertEqual(self.run_item(self.item(650, 600)), ('重复重复重复', 0))
        self.assertEqual(len(self.adapter.calls), 3)
    def test_prefix_cached_tail_updated_and_new_session_isolated(self):
        self.run_item(self.item(600)); self.run_item(self.item(650))
        self.assertEqual([len(p) // (FRAME * 2) for p in self.adapter.calls], [250,250,100,150])
        item = self.item(650); item['session_id'] = 'new'
        self.run_item(item); self.assertEqual(len(self.adapter.calls), 7)
        self.cache.forget(item); self.assertEqual(len(self.cache.entries), 1)
        self.cache.clear(); self.assertFalse(self.cache.entries)
    def test_new_voiced_tail_requires_inference_even_if_previous_text_complete(self):
        self.run_item(self.item(60))
        self.run_item(self.item(61))
        self.assertEqual(len(self.adapter.calls), 2)
        self.cache.forget(self.item(61))
        self.assertFalse(self.cache.entries)

    def test_obsolete_result_is_not_reused(self):
        item = self.item(60)
        self.cache.transcribe(self.adapter, self.config, item, lambda: True)
        self.assertFalse(self.adapter.calls)
        self.run_item(item); self.assertEqual(len(self.adapter.calls), 1)

if __name__ == '__main__': unittest.main()
