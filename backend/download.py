"""Runs in a separate process: terminate cancels active transfers, cached blobs survive."""
import json
import sys
from pathlib import Path
from huggingface_hub import HfApi, hf_hub_download
from tqdm.auto import tqdm

def event(**value):
    print(json.dumps(value), flush=True)

class Progress(tqdm):
    def update(self, n=1):
        result = super().update(n)
        if self.total:
            event(type='progress', detail=str(self.desc), completed=self.n, total=self.total)
        return result

if __name__ == '__main__':
    try:
        model, revision, cache = sys.argv[1:]
        info = HfApi().model_info(model, revision=revision or None, files_metadata=True)
        files = [x for x in info.siblings if x.rfilename.endswith(('.json', '.safetensors', '.txt', '.model', '.tiktoken', '.npz', '.jinja'))]
        total = sum(x.size or 0 for x in files)
        done = 0
        folder = None
        for f in files:
            event(type='progress', detail=f.rfilename, completed=done, total=total)
            file = hf_hub_download(model, f.rfilename, revision=info.sha, cache_dir=cache, tqdm_class=Progress)
            if f.rfilename == 'config.json':
                folder = str(Path(file).parent)
            done += f.size or 0
        if not folder:
            raise ValueError('模型缺少 config.json')
        event(type='downloaded', path=folder, revision=info.sha)
    except Exception as e:
        event(type='error', message=f'下载失败 ({type(e).__name__}): {e}')
        sys.exit(1)
