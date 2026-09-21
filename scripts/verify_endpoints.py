"""Compare both endpoint implementations with identical paced fixtures and cached models."""
import json
import os
import subprocess
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
reports = {}
for name, repo in [('qwen', 'Qwen3-ASR-1.7B-bf16'), ('whisper', 'whisper-large-v3-turbo')]:
    model = next((root / f'models/models--mlx-community--{repo}/snapshots').glob('*/config.json')).parent
    reports[name] = {}
    for mode in ('baseline', 'smart'):
        stem = root / f'docs/endpoint-{name}-{mode}'
        env = {**os.environ, 'RECORDER_ENDPOINT_BASELINE': str(int(mode == 'baseline')),
               'RECORDER_ENDPOINT_METRICS': str(stem) + '-metrics.json'}
        print(f'Checking {name} {mode}', flush=True)
        subprocess.run([sys.executable, str(root / 'scripts/verify_pipeline.py'), '--model', str(model),
                        '--server', str(root / 'scripts/endpoint_benchmark_server.py'), '--output', str(stem) + '.json'],
                       env=env, check=True, stdout=subprocess.DEVNULL)
        reports[name][mode] = {**json.loads(Path(str(stem) + '.json').read_text()),
                              **json.loads(Path(str(stem) + '-metrics.json').read_text())}
    baseline, smart = reports[name]['baseline'], reports[name]['smart']
    reports[name]['calls_pass'] = smart['calls'] <= baseline['calls']
    reports[name]['time_ratio'] = smart['inference_ms'] / baseline['inference_ms']
    reports[name]['time_pass'] = reports[name]['time_ratio'] <= 1.05
    print(name, 'calls', baseline['calls'], '→', smart['calls'], 'time ratio', reports[name]['time_ratio'], flush=True)
(root / 'docs/endpoint-comparison.json').write_text(json.dumps(reports, ensure_ascii=False, indent=2))

if not all(report['calls_pass'] and report['time_pass'] for report in reports.values()):
    raise SystemExit('Endpoint inference performance regression; see docs/endpoint-comparison.json')
