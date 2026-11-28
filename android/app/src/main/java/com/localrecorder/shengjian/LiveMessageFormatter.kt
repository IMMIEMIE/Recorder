package com.localrecorder.shengjian

import android.content.Context
import com.localrecorder.live.LiveMessage
import com.localrecorder.live.SessionSnapshot
import com.localrecorder.live.SubtitleRow

internal fun Context.formatLiveMessage(message: LiveMessage): String = when (message) {
    LiveMessage.UnsupportedProtocol -> getString(R.string.err_unsupported_protocol)
    LiveMessage.InvalidProfileNameOrModel -> getString(R.string.err_invalid_profile_name_or_model)
    LiveMessage.InvalidTurnDetection -> getString(R.string.err_invalid_turn_detection)
    LiveMessage.InvalidSourceLanguage -> getString(R.string.err_invalid_source_language)
    LiveMessage.InvalidAppKeyFormat -> getString(R.string.err_invalid_app_key_format)
    LiveMessage.InvalidEndpointOrLanguage -> getString(R.string.err_invalid_endpoint_or_language)

    LiveMessage.MissingApiKey -> getString(R.string.err_missing_api_key)
    LiveMessage.InvalidApiKeyFormat -> getString(R.string.err_invalid_api_key_format)
    LiveMessage.ConnectTimeout -> getString(R.string.err_connect_timeout)
    LiveMessage.FinishTimeout -> getString(R.string.err_finish_timeout)
    LiveMessage.InvalidServerData -> getString(R.string.err_invalid_server_data)
    LiveMessage.InvalidSessionOrder -> getString(R.string.err_invalid_session_order)
    LiveMessage.UnconfirmedOutputOrLanguage -> getString(R.string.err_unconfirmed_output_or_language)
    LiveMessage.UnconfirmedPcmFormat -> getString(R.string.err_unconfirmed_pcm_format)
    LiveMessage.SessionEndedUnexpectedly -> getString(R.string.err_session_ended_unexpectedly)
    LiveMessage.TranslationIncomplete -> getString(R.string.err_translation_incomplete)
    LiveMessage.RateLimited -> getString(R.string.err_rate_limited)
    LiveMessage.NoResult -> getString(R.string.err_no_result)
    LiveMessage.AuthError -> getString(R.string.err_auth)
    LiveMessage.QuotaOrLimitError -> getString(R.string.err_quota_or_limit)
    LiveMessage.Http429Error -> getString(R.string.err_http_429)
    LiveMessage.ServiceFailed -> getString(R.string.err_service_failed)
    LiveMessage.ConnectionLost -> getString(R.string.err_connection_lost)

    LiveMessage.CauseConnectTimeout -> getString(R.string.cause_connect_timeout)
    LiveMessage.CauseServerFinished -> getString(R.string.cause_server_finished)
    LiveMessage.CauseNoResult -> getString(R.string.cause_no_result)
    LiveMessage.CauseRateLimited -> getString(R.string.cause_rate_limited)
    is LiveMessage.CauseServerClosed -> getString(R.string.cause_server_closed, message.code)
    is LiveMessage.CauseRateLimitedCode -> getString(R.string.cause_rate_limited_code, message.code)
    LiveMessage.CauseDisconnected -> getString(R.string.cause_disconnected)
    is LiveMessage.CauseHandshakeFailed -> getString(R.string.cause_handshake_failed, message.status)
    is LiveMessage.CauseNetworkFailure -> getString(R.string.cause_network_failure, message.type)
    LiveMessage.CauseNetworkSwitched -> getString(R.string.cause_network_switched)
    LiveMessage.CauseNetworkLost -> getString(R.string.cause_network_lost)
    is LiveMessage.CauseUploadStalled -> getString(R.string.cause_upload_stalled, message.seconds)
    is LiveMessage.CauseProfileSwitch -> getString(R.string.profile_switch, message.name)

    LiveMessage.AudioMissingItemId -> getString(R.string.err_audio_missing_item_id)
    LiveMessage.AudioIncomplete -> getString(R.string.err_audio_incomplete)
    LiveMessage.AudioInvalidFormat -> getString(R.string.err_audio_invalid_format)
    LiveMessage.AudioPendingTimeout -> getString(R.string.err_audio_pending_timeout)
    LiveMessage.AudioBacklogStopped -> getString(R.string.err_audio_backlog_stopped)
    LiveMessage.DialogueAudioPendingTimeout -> getString(R.string.err_dialogue_audio_pending_timeout)
    LiveMessage.DialogueAudioBacklog -> getString(R.string.err_dialogue_audio_backlog)
    LiveMessage.DialogueAudioPlayError -> getString(R.string.err_dialogue_audio_play)
    LiveMessage.DialogueAudioPlayNotice -> getString(R.string.err_dialogue_audio_play_notice)
    LiveMessage.PlaybackStartFailed -> getString(R.string.err_playback_start_failed)

    LiveMessage.Connecting -> getString(R.string.connecting)
    LiveMessage.ReconnectingSimple -> getString(R.string.status_reconnecting)
    LiveMessage.ApplyingSettings -> getString(R.string.status_applying_settings)
    LiveMessage.SwitchingLanguage -> getString(R.string.status_switching_language)
    LiveMessage.WaitingFinalResult -> getString(R.string.status_waiting_final)
    is LiveMessage.RecordingTo -> getString(R.string.status_recording_to, message.languageName)
    LiveMessage.NetworkWaiting -> getString(R.string.status_network_waiting)
    LiveMessage.NetworkUnavailableStopped -> getString(R.string.err_network_unavailable_stopped)
    LiveMessage.QuietRenewing -> getString(R.string.status_quiet_renewing)
    is LiveMessage.Reconnecting -> {
        val base = if (message.attempt > 0) getString(R.string.status_reconnecting_attempt, message.attempt)
        else getString(R.string.status_reconnecting_interrupted)
        val detail = message.cause?.let { formatLiveMessage(it) }.orEmpty()
        if (detail.isEmpty()) base else getString(R.string.status_reconnecting_with_cause, base, detail)
    }
    is LiveMessage.CooldownWait -> getString(
        if (message.rateLimited) R.string.status_cooldown_rate_limited else R.string.status_cooldown_frequent,
        message.seconds,
    )
    is LiveMessage.CooldownError -> getString(R.string.err_cooldown_retry, message.seconds)
    LiveMessage.ForegroundServiceFailed -> getString(R.string.err_foreground_service_failed)
    LiveMessage.HandoffStoppedEarly -> getString(R.string.err_handoff_stopped_early)
    LiveMessage.MicOpenFailed -> getString(R.string.err_mic_open_failed)
    LiveMessage.ReconnectedNotice -> getString(R.string.notice_reconnected)
    LiveMessage.UploadStalledStopped -> getString(R.string.err_upload_stalled_stopped)
    LiveMessage.ContinuousRateLimitStopped -> getString(R.string.err_continuous_rate_limit_stopped)
    is LiveMessage.ReconnectFailed -> {
        val tail = message.lastError?.let { formatLiveMessage(it) }.orEmpty()
        if (tail.isEmpty()) getString(R.string.err_reconnect_failed)
        else getString(R.string.err_reconnect_failed_detail, tail)
    }

    LiveMessage.BreakMarker -> getString(R.string.marker_connection_break)
    is LiveMessage.CongestionMarker -> getString(R.string.marker_congestion, message.seconds)
    is LiveMessage.LanguageSwitchedMarker -> getString(R.string.marker_language_switched, message.languageName)
    is LiveMessage.ProfileSwitchedMarker -> getString(R.string.profile_switch, message.profileName)
    is LiveMessage.DialogueModeMarker -> getString(R.string.marker_dialogue_mode, message.languageA, message.languageB)
    is LiveMessage.OneWayModeMarker -> getString(R.string.marker_one_way_mode, message.target)
    is LiveMessage.ContinuedMarker -> getString(R.string.marker_continued, message.stamp)

    LiveMessage.MicUnsupported -> getString(R.string.err_mic_unsupported)
    LiveMessage.MicOpenPermissionOrBusy -> getString(R.string.err_mic_open_permission_or_busy)
    LiveMessage.MicStartFailed -> getString(R.string.err_mic_start_failed)
    is LiveMessage.MicReadFailed -> getString(R.string.err_mic_read_failed, message.code)
    LiveMessage.MicOccupied -> getString(R.string.err_mic_occupied)
    LiveMessage.SystemAudioUnsupported -> getString(R.string.err_system_audio_unsupported)
    LiveMessage.SystemAudioPermissionDenied -> getString(R.string.err_system_audio_permission_denied)
    LiveMessage.SystemAudioOpenFailed -> getString(R.string.err_system_audio_open_failed)
    LiveMessage.SystemAudioStartFailed -> getString(R.string.err_system_audio_start_failed)
    is LiveMessage.SystemAudioReadFailed -> getString(R.string.err_system_audio_read_failed, message.code)
    LiveMessage.SystemAudioProjectionStopped -> getString(R.string.err_system_audio_projection_stopped)
    LiveMessage.SystemAudioSilentNotice -> getString(R.string.notice_system_audio_silent)
    LiveMessage.MixedModeHeadphonesNotice -> getString(R.string.notice_mixed_mode_headphones)
    LiveMessage.AudioFocusLost -> getString(R.string.notice_audio_focus_lost)
    LiveMessage.BluetoothFallback -> getString(R.string.notice_bluetooth_fallback)
    LiveMessage.LoudspeakerEchoCancelled -> getString(R.string.notice_loudspeaker_echo_cancelled)
    LiveMessage.LoudspeakerNoEchoCancel -> getString(R.string.notice_loudspeaker_no_echo_cancel)
    is LiveMessage.ProfileKeyMissing -> getString(R.string.notice_profile_key_missing, message.name)
    LiveMessage.SettingsSaveFailed -> getString(R.string.err_settings_save_failed)
    LiveMessage.SecretSaveFailed -> getString(R.string.err_secret_save_failed)
    is LiveMessage.SessionSaveFailed -> getString(R.string.err_session_save_failed, message.detail)

    is LiveMessage.Composite -> message.parts.joinToString(message.separator) { formatLiveMessage(it) }
    is LiveMessage.Raw -> message.text
}

internal fun Context.formatStatus(snapshot: SessionSnapshot): String =
    snapshot.statusMessage?.let { formatLiveMessage(it) } ?: snapshot.status

internal fun Context.formatError(snapshot: SessionSnapshot): String =
    snapshot.errorMessage?.let { formatLiveMessage(it) } ?: snapshot.error

internal fun Context.formatNotice(snapshot: SessionSnapshot): String =
    snapshot.noticeMessage?.let { formatLiveMessage(it) } ?: snapshot.notice

internal fun Context.formatMarker(row: SubtitleRow): String =
    row.markerMessage?.let { formatLiveMessage(it) } ?: row.marker
