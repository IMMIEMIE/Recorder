# 降低能耗、发热与内存占用（2026-09-30）

## 1. 耗电从哪里来

以下结论来自代码走查与仓库内已有实测数据（`docs/endpoint-*-metrics.json`），不是新测量。

| 来源 | 机制 | 影响 |
| --- | --- | --- |
| **转写中的预览（主要热源）** | Segmenter 每 1.2 s 语音发一次预览，worker 用 Qwen3-ASR 1.7B **从段首重新识别整段**（超过 18 s 的完整块有缓存，但尾块每次重算）。只保留最新一次预览，推理跟不上时 GPU 就一直满载。 | 短句：已有数据中 3 段共约 26 s 语音，18 次推理共 5.18 s GPU 时间，约 20% 占用。长句（系统声音、会议、连续讲话时 VAD 很少遇到 1.8 s 静音，一段可达数十秒）：每次预览要重算最多 18 s 音频，GPU 接近 100%，持续发热。 |
| 模型常驻内存 | Qwen3-ASR 1.7B bf16 权重约 4 GB；MLX 默认把释放的缓冲区留作缓存，上限等于内存上限；本地翻译模型约 2.3 GB。 | 内存压力大时系统换页，间接耗电。 |
| 界面重绘 | `level` 是 `AppModel` 的 `@Published` 属性，每个音频块（约 20 次/秒）都会让整个主窗口（含转写列表）重算视图；API 翻译每个 token 也触发一次。 | 录音期间主线程持续占用 CPU，列表越长越明显。 |
| Python 运行时 | 独立进程与捆绑的 ML 栈。 | 由 `refactor/mlx-swift-20260929` 分支解决，不在本方案内。 |

翻译改用 API 时，后端已会卸载本地翻译模型，所以“翻译全走云端仍然发热”的原因主要是上面第一行：本地识别的预览。

## 2. 本次实现

### A. 预览算力预算（后端，收益最大）

新增 `Config.power_mode`：

| 模式 | 规则 | 预览 GPU 占比上限 |
| --- | --- | --- |
| `balanced`（默认） | 下一次预览须等待 ≥ 2 × 预测耗时 | 约 1/3 |
| `saver` | 等待 ≥ 6 × 预测耗时，且间隔至少为预览间隔的 2 倍 | 约 1/7 |
| `performance` | 原行为，只按预览间隔 | 不限 |

预测耗时 = 本机实测的“每毫秒音频的推理毫秒数” × 当前段长度。实测值来自每次预览的 `elapsed_ms`（命中缓存的结果不更新）。因为代价随段长增长，长段的预览会自动变稀；本机很快、句子较短时与原行为相同（按上面的数据，balanced 在 10 s 以内的句子上几乎不减少预览）。

macOS 开启低电量模式或 `thermalState` 为 serious/critical 时，应用在 `start` 中带上 `low_power: true`，本次会话的 balanced 按 saver 处理（performance 不受影响）。

只影响中途预览：定稿仍对整段识别一次，文字结果不变。代价是中途文字更新变慢，智能定稿拿不到最新预览时按 1.8 s 静音定稿。

### B. 量化模型预设

设置 → 识别模型新增 `mlx-community/Qwen3-ASR-1.7B-8bit`（约 2.5 GB）与 `mlx-community/Qwen3-ASR-0.6B-8bit`（约 1 GB）。解码主要受内存带宽限制，8-bit 权重读取量约为 bf16 的一半，0.6B 的计算量约为 1.7B 的三分之一。两者均需下载；0.6B 准确率略低。模型页的大小取自 Hugging Face 页面，仓库文件是否满足 `validate_config`（`vocab.json`、`merges.txt` 等）需在 Mac 上下载确认。

### C. 空闲释放模型内存

新增 `Config.idle_release_minutes`（0、5、15、30、60，默认 15）。状态为 ready 且超过该时间没有任何命令或推理时，worker 卸载识别模型和本地翻译模型并清空 MLX 缓存，状态说明显示“已释放模型内存”。再次开始转写时，后端先按原快照路径重新加载（`loading → warming → ready`），再开始会话（`recording`）；加载失败时丢弃开始任务并报错，应用清除待开始状态。释放与开始由同一把锁串行化，录音中不会释放。

### D. MLX 缓存上限

加载识别或翻译模型后 `mx.set_cache_limit(512 MB)`，每个会话结束时 `mx.clear_cache()`，空闲时不再保留大段推理留下的缓冲区。

### E. 界面刷新

- 电平表移到独立的 `LevelMeter`（最多约 15 次/秒，变化小于 0.02 不刷新），只重绘 24 个电平条。
- API 翻译的流式文字最多每 0.15 s 刷新一次，最终译文照常立即显示。

### 协议与配置

- 新命令 `power_settings`（`power_mode`、`idle_release_minutes`，立即保存，不重载模型、不回传 config，避免覆盖设置页中尚未应用的修改）。
- `start` 新增可选 `low_power`（布尔）。
- `config.json` 新增两个字段；旧配置文件缺少时使用默认值。

## 3. 如何在 Mac 上验证

1. `./scripts/build.sh` 后，用系统声音播放一段 5 分钟以上的连续讲话视频，分别在“性能”和“均衡/省电”下转写：
   - 活动监视器 → 能耗 / GPU 历史；或 `sudo powermetrics --samplers gpu_power,cpu_power -i 1000` 对比平均 GPU 功耗。
   - 期望：长段期间 GPU 功耗明显下降，定稿文字一致。
2. 设置空闲释放 5 分钟，等待后确认主窗口显示“已释放模型内存”、活动监视器中 python3 内存下降；再点开始，确认先加载后录音。
3. 下载 1.7B 8-bit / 0.6B 8-bit，用 `scripts/verify_model.py --model <快照>` 对比耗时与文字。
4. 结果写入 `docs/VALIDATION.md`。

## 4. 与 mlx-swift 重构分支的关系

`refactor/mlx-swift-20260929` 逐字移植了 `server.py` / `core.py` 的语义。合并前需在 Swift 端同步：`ConfigStore`（两个新字段与校验）、`Segmenter.swift`（`preview_due`、`cost_ratio`、`accept_preview` 的耗时参数、`low_power`）、`BackendCore`（`power_settings`、`start.low_power`、空闲释放与“重载后开始”任务、会话结束清缓存）、`MLXRuntime`（`Memory.cacheLimit`）。界面部分（C/E 的 Swift 代码）两条分支共用。
