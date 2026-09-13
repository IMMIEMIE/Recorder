"""Resolve offline Hub snapshots, including downloads pinned directly to a commit."""
from pathlib import Path
from huggingface_hub import snapshot_download
from adapter import Adapter

def resolve_cached_model(config, cache, validate=None, missing='模型尚未下载完整，请点击「下载模型」。'):
    """`validate(path)` checks the snapshot for the model's role; ASR validation is the default."""
    cache = Path(cache)
    validate = validate or (lambda path: Adapter.validate_config(config, path))
    try:
        path = Path(snapshot_download(config.model_id, revision=config.revision or None,
                                      cache_dir=str(cache), local_files_only=True))
        validate(path)
        return str(path), path.name
    except Exception as original:
        # Explicit revisions must never silently resolve to another version.
        if config.revision:
            raise ValueError(f'本地缺少模型或版本 {config.revision}，请先下载。') from original
        snapshots = cache / ('models--' + config.model_id.replace('/', '--')) / 'snapshots'
        candidates = sorted((p for p in snapshots.glob('*') if p.is_dir()),
                            key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)
        for path in candidates:
            try:
                validate(path)
                return str(path), path.name
            except (ValueError, OSError):
                continue
        raise ValueError(missing) from original
