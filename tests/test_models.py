import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from adapter import Adapter, WHISPER_LANGUAGES
from core import Config

DIMS = dict(n_mels=128,n_audio_ctx=1500,n_audio_state=1280,n_audio_head=20,n_audio_layer=32,
            n_vocab=51866,n_text_ctx=448,n_text_state=1280,n_text_head=20,n_text_layer=4)

class ModelTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.path=Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def config(self, value): (self.path/'config.json').write_text(json.dumps(value))
    def test_whisper_uses_own_weight_layout_not_qwen_tokenizer(self):
        self.config(dict(model_type='whisper',**DIMS))
        (self.path/'weights.safetensors').touch()
        self.assertEqual(Adapter.validate_config(Config(),self.path),self.path)
        (self.path/'weights.safetensors').unlink()
        with self.assertRaisesRegex(ValueError,'weights.safetensors'): Adapter.validate_config(Config(),self.path)
        (self.path/'weights.npz').touch()
        self.assertEqual(Adapter.validate_config(Config(),self.path),self.path)
    def test_transformers_whisper_format_rejected(self):
        self.config({'model_type':'whisper','d_model':1280})
        with self.assertRaisesRegex(ValueError,'MLX Whisper 格式'): Adapter.validate_config(Config(),self.path)
    def test_unsupported_architecture_and_custom_code_rejected(self):
        self.config({'model_type':'other'})
        with self.assertRaisesRegex(ValueError,'仅支持'): Adapter.validate_config(Config(),self.path)
        self.config({'model_type':'qwen3_asr','auto_map':{'x':'remote.code'}})
        with self.assertRaisesRegex(ValueError,'自定义'): Adapter.validate_config(Config(),self.path)
    def test_missing_qwen_tokenizer_reported(self):
        self.config({'model_type':'qwen3_asr'})
        with self.assertRaisesRegex(ValueError,'tokenizer_config.json'): Adapter.validate_config(Config(),self.path)
    def test_unload_clears_global_whisper_cache(self):
        holder=types.SimpleNamespace(model=object(),model_path='old-model')
        backend=types.SimpleNamespace(ModelHolder=holder)
        adapter=Adapter(); adapter.model=holder.model; adapter.architecture='whisper'
        with patch.dict(sys.modules,{'mlx_whisper.transcribe':backend}): adapter.unload()
        self.assertIsNone(adapter.model)
        self.assertIsNone(holder.model)
        self.assertIsNone(holder.model_path)
    def test_failed_validation_preserves_loaded_model(self):
        self.config({'model_type':'bad'})
        adapter=Adapter(); previous=object(); adapter.model=previous
        with self.assertRaises(ValueError): adapter.load(Config(),self.path)
        self.assertIs(adapter.model,previous)
    def test_pinned_download_can_be_found_without_main_ref(self):
        from model_cache import resolve_cached_model
        snapshot=self.path/'models--owner--model'/'snapshots'/'commit123'
        snapshot.mkdir(parents=True)
        (snapshot/'config.json').write_text(json.dumps(dict(model_type='whisper',**DIMS)))
        (snapshot/'weights.safetensors').touch()
        with patch('model_cache.snapshot_download',side_effect=FileNotFoundError('no main ref')):
            path,revision=resolve_cached_model(Config(model_id='owner/model'),self.path)
            self.assertEqual(Path(path),snapshot)
            self.assertEqual(revision,'commit123')
            with self.assertRaisesRegex(ValueError,'missing-revision'):
                resolve_cached_model(Config(model_id='owner/model',revision='missing-revision'),self.path)
    def test_incomplete_cached_snapshot_does_not_count_as_downloaded(self):
        from model_cache import resolve_cached_model
        snapshot=self.path/'models--owner--model'/'snapshots'/'incomplete'
        snapshot.mkdir(parents=True)
        (snapshot/'config.json').write_text(json.dumps(dict(model_type='whisper',**DIMS)))
        with patch('model_cache.snapshot_download',side_effect=FileNotFoundError()):
            with self.assertRaisesRegex(ValueError,'下载完整'):
                resolve_cached_model(Config(model_id='owner/model'),self.path)

    def test_language_mapping(self):
        self.assertEqual(WHISPER_LANGUAGES['Chinese'],'zh')
        self.assertEqual(WHISPER_LANGUAGES['Cantonese'],'yue')
        self.assertIsNone(WHISPER_LANGUAGES['auto'])

if __name__=='__main__': unittest.main()
