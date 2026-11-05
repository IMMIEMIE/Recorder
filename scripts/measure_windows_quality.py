"""Score fixed synthetic fixtures, without treating Mac model output as a Windows equality test."""
import json
import re
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def distance(left, right):
    row = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        next_row = [i]
        for j, b in enumerate(right, 1):
            next_row.append(min(next_row[-1] + 1, row[j] + 1, row[j - 1] + (a != b)))
        row = next_row
    return row[-1]
def chars(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text).lower() if c.isalnum())
def words(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower())
def main():
    references = json.loads((ROOT / 'tests/shared/asr-reference.json').read_text(encoding='utf-8-sig'))
    verification = json.loads((ROOT / 'windows/native-verification.json').read_text(encoding='utf-8-sig'))
    reports = []
    for group in ('cpu_results', 'cuda_results'):
        for model in verification[group]:
            for sample in model.get('samples', []):
                reference = references[sample['fixture']]
                expected, actual = chars(reference), chars(sample['text'])
                item = dict(model=model['model'], device=model['device'], fixture=sample['fixture'], cer=distance(expected, actual)/max(1,len(expected)), real_time_factor=sample['elapsed_ms']/1000/sample['audio_seconds'])
                if sample['fixture'] == 'english':
                    expected, actual = words(reference), words(sample['text'])
                    item['wer'] = distance(expected, actual)/max(1,len(expected))
                item['protocol_marker_leak'] = any(marker in sample['text'] for marker in ('<asr_text>', '<|im_', '<|audio'))
                reports.append(item)
    output = dict(note=references['note'], results=reports)
    (ROOT / 'windows/quality-verification.json').write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
if __name__ == '__main__': main()
