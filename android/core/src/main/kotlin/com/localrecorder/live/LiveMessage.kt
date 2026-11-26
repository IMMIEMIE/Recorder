package com.localrecorder.live

/**
 * Structured runtime status, error, notice, disconnect-cause and marker messages emitted by `:core`.
 * [defaultText] preserves the canonical Chinese text for JVM unit tests and logging; Android UI
 * formats each variant through string resources in `LiveMessageFormatter.kt`.
 */
sealed interface LiveMessage {
    val defaultText: String

    // Profile & config validation
    data object UnsupportedProtocol : LiveMessage {
        override val defaultText = "此协议版本或上行音频格式尚不受支持"
    }
    data object InvalidProfileNameOrModel : LiveMessage {
        override val defaultText = "请填写配置名称和有效的模型 ID"
    }
    data object InvalidTurnDetection : LiveMessage {
        override val defaultText = "请检查断句方式、阈值及静音时长"
    }
    data object InvalidEndpointOrLanguage : LiveMessage {
        override val defaultText = "请填写有效的 WSS 实时服务地址，并选择支持的目标语言"
    }

    // Client & connection errors
    data object MissingApiKey : LiveMessage {
        override val defaultText = "请在 LiveTranslate 设置中保存专用 API Key"
    }
    data object InvalidApiKeyFormat : LiveMessage {
        override val defaultText = "API Key 格式无效，请重新填写"
    }
    data object ConnectTimeout : LiveMessage {
        override val defaultText = "LiveTranslate 连接或会话配置超时，请检查网络和服务地址"
    }
    data object FinishTimeout : LiveMessage {
        override val defaultText = "LiveTranslate 尾句处理超时，已保留收到的文字，末句可能不完整"
    }
    data object InvalidServerData : LiveMessage {
        override val defaultText = "LiveTranslate 返回无效数据"
    }
    data object InvalidSessionOrder : LiveMessage {
        override val defaultText = "LiveTranslate 会话配置顺序异常"
    }
    data object UnconfirmedOutputOrLanguage : LiveMessage {
        override val defaultText = "LiveTranslate 未确认所选输出方式及目标语言，请检查模型和接口兼容性"
    }
    data object UnconfirmedPcmFormat : LiveMessage {
        override val defaultText = "LiveTranslate 未确认 24 kHz PCM 译音格式"
    }
    data object SessionEndedUnexpectedly : LiveMessage {
        override val defaultText = "LiveTranslate 会话意外结束，已保留收到的文字"
    }
    data object TranslationIncomplete : LiveMessage {
        override val defaultText = "LiveTranslate 译文未完成，已保留收到的文字"
    }
    data object RateLimited : LiveMessage {
        override val defaultText = "LiveTranslate 请求过于频繁（限流），请稍后重试；已有文字已保留"
    }
    data object NoResult : LiveMessage {
        override val defaultText = "LiveTranslate 长时间没有识别结果，服务端结束了会话；已有文字已保留"
    }
    data object AuthError : LiveMessage {
        override val defaultText = "LiveTranslate API Key 无效或无权访问，请核对密钥、区域和工作空间"
    }
    data object QuotaOrLimitError : LiveMessage {
        override val defaultText = "LiveTranslate 请求受限或额度不足，请检查账户余额并稍后重试"
    }
    data object Http429Error : LiveMessage {
        override val defaultText = "LiveTranslate 请求受限或额度不足，请稍后重试"
    }
    data object ServiceFailed : LiveMessage {
        override val defaultText = "LiveTranslate 服务处理失败，请检查模型权限和会话配置；已有文字已保留"
    }
    data object ConnectionLost : LiveMessage {
        override val defaultText = "LiveTranslate 连接中断或无法连接，请检查网络、服务地址及 API Key；已有文字已保留"
    }

    // Disconnect causes
    data object CauseConnectTimeout : LiveMessage {
        override val defaultText = "连接超时：20 秒内未完成会话配置"
    }
    data object CauseServerFinished : LiveMessage {
        override val defaultText = "服务端结束会话"
    }
    data object CauseNoResult : LiveMessage {
        override val defaultText = "服务端长时间无结果"
    }
    data object CauseRateLimited : LiveMessage {
        override val defaultText = "服务限流"
    }
    data class CauseServerClosed(val code: Int) : LiveMessage {
        override val defaultText = "服务端关闭：$code"
    }
    data class CauseRateLimitedCode(val code: Int) : LiveMessage {
        override val defaultText = "服务限流：$code"
    }
    data object CauseDisconnected : LiveMessage {
        override val defaultText = "连接断开"
    }
    data class CauseHandshakeFailed(val status: Int) : LiveMessage {
        override val defaultText = "握手失败：HTTP $status"
    }
    data class CauseNetworkFailure(val type: String) : LiveMessage {
        override val defaultText = "网络故障：$type"
    }
    data object CauseNetworkSwitched : LiveMessage {
        override val defaultText = "网络已切换"
    }
    data object CauseNetworkLost : LiveMessage {
        override val defaultText = "网络已断开"
    }
    data class CauseUploadStalled(val seconds: Long) : LiveMessage {
        override val defaultText = "上行发送停滞超过 $seconds 秒"
    }
    data class CauseProfileSwitch(val name: String) : LiveMessage {
        override val defaultText = "切换到「$name」"
    }

    // Audio & playback
    data object AudioMissingItemId : LiveMessage {
        override val defaultText = "译音缺少消息标识"
    }
    data object AudioIncomplete : LiveMessage {
        override val defaultText = "译音数据不完整，已停止播放"
    }
    data object AudioInvalidFormat : LiveMessage {
        override val defaultText = "译音数据格式无效，已停止播放"
    }
    data object AudioPendingTimeout : LiveMessage {
        override val defaultText = "等待定稿的译音超过 30 秒，已停止本次播放；字幕继续更新"
    }
    data object AudioBacklogStopped : LiveMessage {
        override val defaultText = "译音播放积压超过 30 秒，已停止播放；字幕继续更新"
    }
    data object DialogueAudioPendingTimeout : LiveMessage {
        override val defaultText = "等待语言识别的译音超过 30 秒，已停止播放"
    }
    data object DialogueAudioBacklog : LiveMessage {
        override val defaultText = "译音播放积压超过 30 秒，已停止播放"
    }
    data object DialogueAudioPlayError : LiveMessage {
        override val defaultText = "无法播放译音"
    }
    data object DialogueAudioPlayNotice : LiveMessage {
        override val defaultText = "无法播放译音，字幕将继续更新"
    }
    data object PlaybackStartFailed : LiveMessage {
        override val defaultText = "无法启动译音播放，仅显示字幕"
    }

    // Session state, errors & notices
    data object Connecting : LiveMessage {
        override val defaultText = "正在连接…"
    }
    data object ReconnectingSimple : LiveMessage {
        override val defaultText = "正在重新连接…"
    }
    data object ApplyingSettings : LiveMessage {
        override val defaultText = "正在应用转译设置…"
    }
    data object SwitchingLanguage : LiveMessage {
        override val defaultText = "正在切换译文语言…"
    }
    data object WaitingFinalResult : LiveMessage {
        override val defaultText = "正在等待尾句结果…"
    }
    data class RecordingTo(val languageName: String) : LiveMessage {
        override val defaultText = "正在转写 → $languageName"
    }
    data object NetworkWaiting : LiveMessage {
        override val defaultText = "网络已断开，等待恢复…"
    }
    data object NetworkUnavailableStopped : LiveMessage {
        override val defaultText = "网络长时间不可用，已停止录音；已有文字已保留"
    }
    data object QuietRenewing : LiveMessage {
        override val defaultText = "长时间无识别结果，正在续接连接…"
    }
    data class Reconnecting(val attempt: Int, val cause: LiveMessage?) : LiveMessage {
        override val defaultText: String
            get() {
                val base = if (attempt > 0) "连接中断，正在重新连接（第 $attempt 次）…" else "连接中断，正在重新连接…"
                val detail = cause?.defaultText.orEmpty()
                return if (detail.isEmpty()) base else "$base 原因：$detail"
            }
    }
    data class CooldownWait(val rateLimited: Boolean, val seconds: Int) : LiveMessage {
        override val defaultText: String
            get() = "${if (rateLimited) "服务限流" else "连接过于频繁"}，$seconds 秒后重试"
    }
    data class CooldownError(val seconds: Int) : LiveMessage {
        override val defaultText = "连接过于频繁或服务限流，请 $seconds 秒后再试"
    }
    data object ForegroundServiceFailed : LiveMessage {
        override val defaultText = "无法启动前台录音服务，请在应用位于前台时开始"
    }
    data object HandoffStoppedEarly : LiveMessage {
        override val defaultText = "连接未就绪，已保留收到的文字；切换期间的尾句可能不完整"
    }
    data object MicOpenFailed : LiveMessage {
        override val defaultText = "无法打开麦克风"
    }
    data object ReconnectedNotice : LiveMessage {
        override val defaultText = "已重新连接；中断期间的内容可能有缺失"
    }
    data object UploadStalledStopped : LiveMessage {
        override val defaultText = "网络发送长时间停滞，已停止录音；已有文字已保留"
    }
    data object ContinuousRateLimitStopped : LiveMessage {
        override val defaultText = "LiveTranslate 持续限流，已停止录音；已有文字已保留"
    }
    data class ReconnectFailed(val lastError: LiveMessage?) : LiveMessage {
        override val defaultText: String
            get() = "多次重新连接失败，已停止录音。${lastError?.defaultText.orEmpty()}"
    }

    // Markers
    data object BreakMarker : LiveMessage {
        override val defaultText = "连接中断，此处内容可能有缺失"
    }
    data class CongestionMarker(val seconds: Int) : LiveMessage {
        override val defaultText = "网络拥塞，约 $seconds 秒语音未翻译"
    }
    data class LanguageSwitchedMarker(val languageName: String) : LiveMessage {
        override val defaultText = "译文语言已切换为 $languageName"
    }
    data class ProfileSwitchedMarker(val profileName: String) : LiveMessage {
        override val defaultText = "切换到「$profileName」"
    }
    data class DialogueModeMarker(val languageA: String, val languageB: String) : LiveMessage {
        override val defaultText = "双人对话 $languageA ↔ $languageB"
    }
    data class OneWayModeMarker(val target: String) : LiveMessage {
        override val defaultText = "单向转译 → $target"
    }
    data class ContinuedMarker(val stamp: String) : LiveMessage {
        override val defaultText = "继续录制 $stamp"
    }

    // Android app platform messages
    data object MicUnsupported : LiveMessage {
        override val defaultText = "设备不支持 16 kHz 单声道录音"
    }
    data object MicOpenPermissionOrBusy : LiveMessage {
        override val defaultText = "无法打开麦克风，请检查录音权限或是否被其他应用占用"
    }
    data object MicStartFailed : LiveMessage {
        override val defaultText = "麦克风启动失败，可能正被其他应用占用"
    }
    data class MicReadFailed(val code: Int) : LiveMessage {
        override val defaultText = "麦克风读取失败（$code），已停止录音；已有文字已保留"
    }
    data object MicOccupied : LiveMessage {
        override val defaultText = "麦克风被通话或其他应用占用，已停止录音；已有文字已保留"
    }
    data object SystemAudioUnsupported : LiveMessage {
        override val defaultText = "系统声音捕获需要 Android 10 及以上版本"
    }
    data object SystemAudioPermissionDenied : LiveMessage {
        override val defaultText = "未授予系统声音捕获权限"
    }
    data object SystemAudioOpenFailed : LiveMessage {
        override val defaultText = "无法启动系统声音捕获，请重试"
    }
    data object SystemAudioStartFailed : LiveMessage {
        override val defaultText = "系统声音采集启动失败"
    }
    data class SystemAudioReadFailed(val code: Int) : LiveMessage {
        override val defaultText = "系统声音读取失败（$code），已停止录制；已有文字已保留"
    }
    data object SystemAudioProjectionStopped : LiveMessage {
        override val defaultText = "系统已停止音频投射，已停止录制；已有文字已保留"
    }
    data object SystemAudioSilentNotice : LiveMessage {
        override val defaultText = "未检测到系统声音：部分受保护内容（如 DRM 媒体、通话或禁止捕获的应用）不允许录制内部音频"
    }
    data object MixedModeHeadphonesNotice : LiveMessage {
        override val defaultText = "混音模式下未检测到耳机：建议佩戴耳机，以减少扬声器外放串入麦克风造成回声"
    }
    data object AudioFocusLost : LiveMessage {
        override val defaultText = "通话或其他应用占用了音频输出，已停止译音；字幕继续更新"
    }
    data object BluetoothFallback : LiveMessage {
        override val defaultText = "未找到可用的蓝牙耳机麦克风，已改用手机麦克风"
    }
    data object LoudspeakerEchoCancelled : LiveMessage {
        override val defaultText = "未检测到耳机：已启用回声消除，外放的译音仍可能被再次收录，建议佩戴耳机"
    }
    data object LoudspeakerNoEchoCancel : LiveMessage {
        override val defaultText = "未检测到耳机，本机也不支持回声消除：外放的译音可能被再次收录，建议佩戴耳机"
    }
    data class ProfileKeyMissing(val name: String) : LiveMessage {
        override val defaultText = "请先保存「$name」对应的密钥"
    }
    data object SettingsSaveFailed : LiveMessage {
        override val defaultText = "服务配置未能写入本机，请检查存储空间"
    }
    data object SecretSaveFailed : LiveMessage {
        override val defaultText = "专用 API Key 未能写入本机"
    }
    data class SessionSaveFailed(val detail: String) : LiveMessage {
        override val defaultText = "会话记录保存失败：$detail"
    }

    // Composition & passthrough
    data class Composite(val parts: List<LiveMessage>, val separator: String = " · ") : LiveMessage {
        override val defaultText: String
            get() = parts.joinToString(separator) { it.defaultText }
    }
    data class Raw(val text: String) : LiveMessage {
        override val defaultText = text
    }
}
