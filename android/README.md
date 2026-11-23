# 声笺安卓版

只保留实时翻译：麦克风音频通过 WebSocket 发送到所选的 Qwen 3.8 兼容服务，预设为 Qwen LiveTranslate（`qwen3.8-livetranslate-flash-realtime`），实时显示原文与译文，可选播放译音。没有本地模型，所有识别与翻译都由云端 API 完成。

分阶段计划见 [`docs/ANDROID-PLAN.md`](../docs/ANDROID-PLAN.md)。

## 构建

需要能启动 Gradle 的任意 JDK（包括 Android Studio 自带的 JBR）：Gradle 守护进程固定使用 JDK 17，本机没有时会按 `gradle/gradle-daemon-jvm.properties` 自动下载。命令行构建若没有 `java`，可先 `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`。

```bash
./gradlew -PcoreOnly=true :core:test   # 协议核心测试，无需 Android SDK（mock 服务器需要 python3）
./gradlew :app:assembleDebug           # 需要 Android SDK；APK 位于 app/build/outputs/apk/debug/
```

也可以直接用 Android Studio 打开 `android/` 目录。GitHub Actions（`.github/workflows/android.yml`）会运行测试并上传调试 APK。

## 发布构建与签名

```bash
./gradlew :app:assembleRelease   # 开启 R8 与资源压缩；没有签名环境变量时生成未签名的 app-release-unsigned.apk
../scripts/check_android_apk.sh app/build/outputs/apk/release/app-release-unsigned.apk   # 体积上限 10 MB
```

正式签名只从环境变量读取，keystore 不入库：`SHENGJIAN_KEYSTORE`（文件路径）、`SHENGJIAN_KEYSTORE_PASSWORD`、`SHENGJIAN_KEY_ALIAS`、`SHENGJIAN_KEY_PASSWORD`。

### 发布清单（macOS 与安卓同版本、同一个 Release）

版本号只写在仓库根目录的 `VERSION`（`x.y.z`，例如 `0.5.0`）。`app/build.gradle.kts` 从中读取 `versionName`，并算出 `versionCode = 主版本*10000 + 次版本*100 + 修订号`（0.5.0 → 500）；`VERSION` 不是 `x.y.z` 时 Gradle 构建直接失败。macOS 的 `scripts/build.sh`、`scripts/package.sh` 读取同一个文件。`scripts/check_version.sh` 检查各处是否一致（安卓 CI 也会运行它）。

1. 修改 `VERSION`，写好 `docs/RELEASE-<ver>.md`（创建 Release 时作为说明），运行 `scripts/check_version.sh`，合并到 `main`。
2. 推送标签 `v<ver>`（必须等于 `v$(cat VERSION)`）。`.github/workflows/release.yml` 会核对标签与 `VERSION`，运行 `:core:test`，用仓库 Secret 签名构建，`check_android_apk.sh --signed` 校验 v2 签名（拒绝调试证书）和体积，然后把 `Recorder-<ver>-android.apk` 及 `.sha256` 上传到该标签的 Release（不存在时创建草稿）。
3. 在本机运行 `./scripts/build.sh && ./scripts/package.sh`（需要 Metal 工具链，所以不放在 CI），再运行 `./scripts/publish_mac_release.sh`：它确认 origin 上有标签、DMG 及其签名（`codesign --verify --deep --strict`）有效，然后把 `Recorder-<ver>-arm64.dmg` 及 `.sha256` 上传到同一个 Release（不存在时创建草稿）。脚本不会创建或推送标签，也不会发布。
4. 在 GitHub 上检查草稿里的两个安装包与校验文件，确认后手动发布。

首次配置（只需一次；keystore 和密码请离线备份，丢失后无法给已安装的用户推送更新）：

```bash
keytool -genkeypair -v -keystore shengjian-release.jks -alias shengjian -keyalg RSA -keysize 4096 -validity 10000
base64 -i shengjian-release.jks | gh secret set SHENGJIAN_KEYSTORE_BASE64
gh secret set SHENGJIAN_KEYSTORE_PASSWORD
gh secret set SHENGJIAN_KEY_ALIAS --body shengjian
gh secret set SHENGJIAN_KEY_PASSWORD
```

## 结构

- `core/` — 纯 Kotlin/JVM，从 macOS 版 `LiveTranslate*.swift` 移植：
  - `LiveTranslateConfig` 具名配置、按地址隔离密钥、按模型建连、`session.update`、与 macOS 相同的设置 JSON；
  - `LiveTranslateEvents` 按 item ID 关联原文和译文；
  - `LiveTranslateAudioDecoder` / `LiveTranslatePlaybackQueue` 拼接 PCM16、定稿后按句播放；
  - `LiveTranslateClient` OkHttp WebSocket 会话（单线程状态机、拒绝重定向、发送队列上限、收尾超时）；
  - `LiveSession` 会话状态机：一次会话可跨多条连接（断线重连、网络切换、弱网积压、字幕上限），通过 `SessionPlatform` 接口使用麦克风、播放器和定时器，不依赖 Android；
  - `sessions/`：会话记录（`SessionRecord` 文件格式、`SessionStore` 原子读写、`SessionRecorder` 只保留定稿行）与 TXT/Markdown 导出（`SessionExport`），规范见 [`docs/SESSIONS.md`](../docs/SESSIONS.md)，与 macOS 逐字节一致。
- `app/` — 安卓应用：
  - `SessionController` 实现 `SessionPlatform`（主线程），并负责设置保存、测试连接、通知内容；
  - `MicrophoneSource`（AudioRecord 16 kHz，外放译音时走回声消除通路）、`SpeechPlayer`（AudioTrack 24 kHz，带音频焦点）、`AudioRouting`（耳机检测、蓝牙耳机麦克风）；
  - `SecretStore`（Android Keystore AES-GCM 加密 API Key）、`SettingsStore`（与 macOS 相同的配置 JSON，另存安卓专有选项）；
  - `SessionLibrary` 会话列表与文件读写（单独的 I/O 线程）；
  - `RecordingService` 麦克风类型前台服务，通知显示最新译文；`MainActivity` Compose 界面（会话抽屉 / 宽屏常驻侧栏、导出）。

## 使用

1. 打开「设置」，选择 Qwen 预设或新建具名配置，填写模型 ID、LiveTranslate 服务地址（默认 `wss://maas.qianwenaiapi.com/api-ws/v1/realtime`）和专用 API Key，选择目标语言，点「保存」，可先「测试连接」。
   「断句和上行音频」可调整静音检测或选择说话人检测。点「复制已保存的探针配置」，将内容存为 JSON 后可在 Mac 运行 `PROBE_CONFIG=settings.json PROBE_PROFILE="配置名称" PROBE_SESSION=1 scripts/probe_livetranslate.sh`。探针会提示输入该地址的密钥。
2. 回到主界面点「开始实时翻译」，授予麦克风（和通知）权限，看到「正在转写」后开始说话（连接通常不到 1 秒；连接建立前说的话只补发最后 1 秒）。
3. 点「停止」后会等待服务端返回最后一句。

普通模式下，点主界面的目标语言即可在录制中切换。当前句继续使用原目标语言，后续字幕会标出切换位置。

面对面交流时，点主界面的「双人对话」，选择 A、B 各自使用的语言。手机上半屏默认朝向对方；中间操作栏可以改为同向显示、互换语言或退出。每侧以大字显示给自己的译文，以小字显示自己说的原文。无法确定语种时，两侧都显示原文并标记「语种未识别」。双路会同时接收同一麦克风的音频，音频输入用量约为普通模式的两倍。

对话译音可在中间操作栏的更多菜单中开关。确认说话方后播放给另一方的译音。使用扬声器时，播报期间上传等长静音以免把译音再次翻译，此时插话也会被静音。需要边播报边说话时可使用耳机。

连接中断或切换网络时会自动重新连接并在字幕中标出断点（可在设置中关闭），重连状态里显示最近一次断开的原因；开启译音但没戴耳机时会启用回声消除并提示。

网络跟不上时不会断开重连：上传积压超过约 1.5 秒就暂停上传、丢弃新的语音，积压降到约 0.3 秒以下再继续，并在字幕中插入「网络拥塞，约 N 秒语音未翻译」；只有积压约 8 秒完全不下降才重新连接。服务端限流（关闭码 1007）时至少等 20 秒再连，之后加倍；任意 60 秒内最多建立 8 次连接。长时间静音被服务端结束（60 秒无识别结果）时立即无感续接。

### 会话

- 点左上角「会话」打开会话列表（平板等宽屏上常驻左侧）。每次在「新建会话」里开始翻译都会生成一个会话，按最后更新时间分为「今天 / 昨天 / 7 天内 / 更早」，正在录制的会话标有「录制中」。
- 打开历史会话可查看内容，点「继续录制」会在该会话末尾追加新的一段。录制时也可以翻看其他会话，新内容仍写入正在录制的会话。
- 长按列表项或在会话顶栏的「更多」里可以重命名（留空恢复自动标题）和删除（需确认；录制中的会话不能删除）；设置里有「清空全部会话」。
- 「导出」可选 TXT 或 Markdown、双语 / 仅原文 / 仅译文，然后通过系统分享发送、「保存到文件」（系统文件选择器，无需存储权限）或复制。导出只含已定稿的文字，不含服务地址和 API Key。

## 用 mock 服务器做端到端验证

调试构建允许 `ws://127.0.0.1`（正式构建只接受 `wss://`），可以不用真实 API Key 在模拟器或真机上跑通整条链路：

```bash
python3 ../tests/mock_livetranslate_server.py /tmp/port.txt &
adb reverse tcp:18080 tcp:$(cat /tmp/port.txt)
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

在应用设置里把服务地址填成 `ws://127.0.0.1:18080/ok`、API Key 填 `mock-only`。开始后会出现固定的示例字幕；中途结束 mock 进程再重启（并重新执行 `adb reverse`）可以观察自动重连。

隐私：开始翻译后麦克风音频会持续发送到所配置的服务；应用不保存录音、译音和未定稿的字幕。已定稿的原文和译文默认保存在本机（`filesDir/sessions/`），不上传，不参与系统备份和设备迁移；在设置中关闭「保存会话记录」后不再写盘，新内容只保留到应用退出。API Key 加密保存在本机，不参与备份。
