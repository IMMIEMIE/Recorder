# Whisper 离线辅助资源

进程内（mlx-swift）Whisper 引擎所需的资源，原样取自 `mlx-whisper==0.4.3`（`requirements.lock` 钉住的版本）wheel 中的 `mlx_whisper/assets/`：

| 文件 | 用途 | sha256 |
| --- | --- | --- |
| `mel_filters.npz` | librosa slaney mel 滤波器组（`mel_80`、`mel_128`） | `7450ae70723a5ef9d341e3cee628c7cb0177f36ce42c44b7ed2bf3325f0f6d4c` |
| `multilingual.tiktoken` | 多语言模型词表（tiktoken BPE ranks） | `b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126` |
| `gpt2.tiktoken` | 纯英文模型词表 | `306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930` |

来源许可：MIT（OpenAI Whisper，经 Apple mlx-examples / mlx-whisper 分发）。`scripts/build.sh` 在 `RECORDER_INPROCESS=1` 时把本目录拷到 `Contents/Resources/whisper/`。它们不是模型权重，`package.sh` 的权重检查不受影响。
