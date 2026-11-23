package com.localrecorder.live

/** The foreground recording's single mic and two independent, rate-limited cloud lanes. Public
 * methods and language callbacks run on the session thread. Only capture callbacks run off-thread. */
class ConversationSession(
    private val platform: SessionPlatform,
    private val identifyLanguage: (String, String, String, (String?) -> Unit) -> Unit,
    private val shouldGateMicrophone: () -> Boolean = { true },
    private val onChange: (SessionSnapshot) -> Unit,
) {
    private data class Mode(val dialogue: Boolean, val a: String, val b: String, val target: String)
    private var requested = Mode(false, "zh", "en", "zh")
    private var config = LiveTranslateConfig()
    private var credential = ""
    private var reconnect = true
    private val budget = LiveConnectionBudget()
    private var groupId = 0
    private val groups = mutableListOf<Group>()
    private val archived = mutableListOf<SubtitleRow>()
    private var trimmed = false
    private var current: Group? = null
    private var tailPlayer: LiveSession? = null
    private var stopping = false
    private var pending: Cancellable? = null
    private var message = ""
    private var failure = ""
    private var mute = false
    private var batch = false
    private var rendering = false
    private var dirty = false
    var snapshot = SessionSnapshot()
        private set

    private val speaker = DialogueSpeaker(platform, shouldGateMicrophone, ::interruptPlayback, ::refresh)
    private val capturing = mutableMapOf<Lane, Pair<(ByteArray) -> Unit, (String) -> Unit>>()
    @Volatile private var sinks = emptyList<Pair<(ByteArray) -> Unit, (String) -> Unit>>()
    private var capturingGroup: Group? = null
    private var microphone = false
    private val activeServices = mutableSetOf<Lane>()

    private data class Mapped(val input: SubtitleRow, val output: SubtitleRow)
    private inner class Group(val mode: Mode, val id: Int, val marker: SubtitleRow?, val changedLanguages: Set<String>) {
        val transcript = if (mode.dialogue) DialogueTranscript(mode.a, mode.b, identifyLanguage, platform::elapsedMs, ::refresh) else null
        val lanes = mutableListOf<Lane>()
        val markers = mutableMapOf<String, SubtitleRow>()
        private val mapped = HashMap<String, Mapped>()
        var classificationDeadline: Cancellable? = null
        private var firstSwitchRow: String? = null
        val idle get() = lanes.all { it.session.snapshot.state == SessionState.IDLE }

        fun rows(): List<SubtitleRow> {
            val rows = transcript?.let { reconciled ->
                (reconciled.rows() + markers.values).sortedBy { it.audioStartMs }
            } ?: lanes.firstOrNull()?.session?.snapshot?.rows.orEmpty()
            if (firstSwitchRow == null && changedLanguages.isNotEmpty())
                firstSwitchRow = rows.firstOrNull { it.sourceDone && it.source.isNotEmpty() && it.targetLanguage in changedLanguages }?.key
            if (mapped.size > LiveSession.MAX_ROWS + LiveSession.MAX_ACTIVE_ROWS) mapped.keys.retainAll(rows.map { it.key }.toSet())
            return listOfNotNull(marker) + rows.map { row ->
                val cached = mapped[row.key]
                if (cached != null && cached.input == row) cached.output else {
                    row.copy(key = "$id:${row.key}", languageSwitch = if (row.key == firstSwitchRow) languageName(row.targetLanguage) else row.languageSwitch)
                        .also { mapped[row.key] = Mapped(row, it) }
                }
            }
        }
    }

    private inner class Lane(val group: Group, val index: Int) : SessionPlatform by platform {
        val session = LiveSession(this, connectionBudget = budget) { update ->
            group.transcript?.let { text ->
                // Older finalized rows are already in the reconciler. Revisit active rows because
                // their source, timestamps and translated text can arrive in any order.
                update.rows.takeLast(LiveSession.MAX_ACTIVE_ROWS + 1).forEach { row ->
                    if (row.marker.isEmpty()) text.observe(index, row)
                    else group.markers.getOrPut("$index:${row.key}") {
                        row.copy(key = "marker:$index:${row.key}", audioStartMs = platform.elapsedMs())
                    }
                }
                while (group.markers.size > LiveSession.MAX_ACTIVE_ROWS) group.markers.remove(group.markers.keys.first())
            }
            refresh()
        }
        var inbox: DialogueSpeechInbox? = null

        override fun transport(configuration: LiveTranslateConfig, listener: LiveTransport.Listener): LiveTransport {
            inbox = null
            if (!group.mode.dialogue || !configuration.audioOutput) return platform.transport(configuration, listener)
            val audio = DialogueSpeechInbox()
            inbox = audio
            var connected = true
            val target = platform.transport(configuration, object : LiveTransport.Listener by listener {
                override fun onEvent(event: LiveSessionEvent) {
                    if (!connected || inbox !== audio) return
                    if (!mute && current === group) {
                        try {
                            when (event) {
                                is LiveSessionEvent.Link -> audio.link(event.output, session.sourceRowKey(event.source))
                                is LiveSessionEvent.Audio -> audio.audio(event)
                                else -> Unit
                            }
                        } catch (error: LiveTranslateException) {
                            interruptPlayback(error.message.orEmpty())
                        }
                    }
                    if (event !is LiveSessionEvent.Audio) listener.onEvent(event)
                    if (event is LiveSessionEvent.Audio && event.final || event is LiveSessionEvent.Link) refresh()
                }
            })
            return object : LiveTransport by target {
                override fun cancel() {
                    connected = false
                    target.cancel()
                }
            }
        }

        override fun speech(): SpeechOutput = if (group.mode.dialogue) silentOutput else platform.speech()

        override fun startCapture(onChunk: (ByteArray) -> Unit, onError: (String) -> Unit) {
            capturing[this] = onChunk to onError
            publishSinks()
            if (!microphone) {
                try {
                    platform.startCapture({ pcm ->
                        val recipients = sinks
                        val samples = if (speaker.gate) ByteArray(pcm.size) else pcm
                        recipients.forEach { it.first(samples) }
                    }, { error -> sinks.forEach { it.second(error) } })
                    microphone = true
                } catch (error: Exception) {
                    capturing.remove(this)
                    publishSinks()
                    throw error
                }
            }
        }

        override fun stopCapture() {
            if (capturing.size == 1 && this in capturing) stopMicrophone()
            capturing.remove(this)
            publishSinks()
        }

        override fun sessionActive(active: Boolean) {
            if (active) {
                if (activeServices.isEmpty()) platform.sessionActive(true)
                activeServices.add(this)
            } else if (activeServices.remove(this) && activeServices.isEmpty()) platform.sessionActive(false)
        }
    }

    private fun publishSinks() {
        sinks = capturing.filterKeys { it.group === capturingGroup }.values.toList()
    }

    private fun stopMicrophone() {
        if (microphone) {
            platform.stopCapture()
            microphone = false
        }
    }

    fun start(config: LiveTranslateConfig, key: String, autoReconnect: Boolean = true) {
        if (snapshot.state != SessionState.IDLE) return
        this.config = config
        requested = requested.copy(target = config.language)
        credential = key
        reconnect = autoReconnect
        stopping = false
        mute = false
        message = ""
        failure = ""
        speaker.stop()
        tailPlayer?.stopPlayback()
        tailPlayer = null
        startGroup(null)
    }

    private fun startGroup(marker: SubtitleRow?, changedLanguages: Set<String> = emptySet()) {
        val old = current
        val next = Group(requested, ++groupId, marker, changedLanguages)
        groups.add(next)
        current = next
        batch = true
        try {
            if (old == null) capturingGroup = next
            if (old != null) {
                speaker.stop()
                old.lanes.forEach { it.session.stopPlayback() }
            }
            val targets = if (requested.dialogue) listOf(requested.a, requested.b) else listOf(requested.target)
            for ((index, language) in targets.withIndex()) {
                val lane = Lane(next, index)
                next.lanes += lane
                lane.session.start(config.copy(language = language, audioOutput = config.audioOutput && !mute), credential,
                    reconnect, plannedHandoff = old != null, recoverInitial = requested.dialogue)
            }
            capturingGroup = next
            publishSinks()
            old?.lanes?.forEach { it.session.stop() }
        } finally {
            batch = false
        }
        refresh()
    }

    fun configure(dialogue: Boolean, languageA: String, languageB: String, target: String) {
        if (languageA == languageB || listOf(languageA, languageB, target).any { code ->
                LiveTranslateConfig.LANGUAGES.none { it.first == code }
            }) return
        requested = Mode(dialogue, languageA, languageB, target)
        config = config.copy(language = target)
        val active = current ?: return
        if (stopping) return
        pending?.cancel()
        if (!active.mode.dialogue && !dialogue) {
            active.lanes.single().session.setTargetLanguage(target)
        } else if (active.mode.dialogue != dialogue || active.mode.a != languageA || active.mode.b != languageB) {
            pending = platform.schedule(1_000) {
                val label = if (dialogue) "双人对话 ${languageName(languageA)} ↔ ${languageName(languageB)}" else "单向转译 → ${languageName(target)}"
                val changed = if (active.mode.dialogue && dialogue) buildSet {
                    if (active.mode.a != languageA) add(languageA)
                    if (active.mode.b != languageB) add(languageB)
                } else emptySet()
                startGroup(SubtitleRow("mode:${groupId + 1}", "", true, "", true, marker = label,
                    targetLanguage = if (dialogue) languageB else target, languageChange = true), changed)
            }
        }
    }

    fun updatePreferences(configuration: LiveTranslateConfig, autoReconnect: Boolean) {
        if (config.audioOutput != configuration.audioOutput) {
            mute = !configuration.audioOutput
            if (mute) speaker.stop()
        }
        config = configuration
        reconnect = autoReconnect
        speaker.setVolume(configuration.volume)
        val active = current ?: return
        if (stopping) return
        active.lanes.forEach { lane -> lane.session.setPreferences(configuration.copy(audioOutput = configuration.audioOutput && !mute), autoReconnect) }
    }

    fun switchProfile(next: LiveTranslateConfig, credential: String): Boolean {
        val active = current ?: return false
        if (stopping || credential.isBlank() || next.profile.id == config.profile.id) return false
        if (!active.mode.dialogue && !active.lanes.single().session.switchProfile(next, credential)) return false
        this.credential = credential
        config = next
        if (active.mode.dialogue) {
            pending?.cancel()
            startGroup(SubtitleRow("profile:${groupId + 1}", "", true, "", true, "切换到「${next.profile.name}」"))
        }
        return true
    }

    fun stop() {
        if (current == null || stopping) return
        pending?.cancel()
        stopping = true
        batch = true
        try {
            stopMicrophone()
            groups.flatMap { it.lanes }.forEach { it.session.stop() }
        } finally { batch = false }
        refresh()
    }

    fun clear() {
        if (snapshot.state != SessionState.IDLE) return
        archived.clear()
        trimmed = false
        refresh()
    }

    fun stopPlayback() {
        mute = true
        speaker.stop()
        tailPlayer?.stopPlayback()
        tailPlayer = null
        groups.flatMap { it.lanes }.forEach { it.session.stopPlayback() }
        refresh()
    }

    fun interruptPlayback(message: String) { stopPlayback(); notice(message) }
    fun notice(message: String) { this.message = message; refresh() }
    fun dismissMessages() {
        message = ""
        failure = ""
        groups.flatMap { it.lanes }.forEach { it.session.dismissMessages() }
        refresh()
    }
    fun captureInterrupted(message: String) = current?.lanes?.forEach { it.session.captureInterrupted(message) } ?: Unit
    fun networkAvailable(id: Long) = current?.lanes?.forEach { it.session.networkAvailable(id) } ?: Unit
    fun networkLost() = current?.lanes?.forEach { it.session.networkLost() } ?: Unit

    private fun refresh() {
        dirty = true
        if (batch || rendering) return
        rendering = true
        try {
            do {
                dirty = false
                render()
            } while (dirty)
        } finally { rendering = false }
    }

    private fun render() {
        val active = current
        if (!mute && active?.transcript != null) {
            active.lanes.forEach { lane ->
                val other = active.lanes.getOrNull(1 - lane.index)?.session?.snapshot?.state
                lane.inbox?.release({ active.transcript.shouldPlay(lane.index, it,
                    other == SessionState.RECORDING || other == SessionState.CONNECTING || other == SessionState.FINISHING) }) {
                    if (!mute) speaker.enqueue(it, config.volume)
                }
            }
        }
        // Classifiers use an Android worker thread. Give final callbacks a bounded chance before
        // closing the recorder, including when language results arrive after session.finished.
        for (group in groups) {
            if (group.idle && group.transcript?.identifying == true && group.classificationDeadline == null) {
                group.classificationDeadline = platform.schedule(2_000) { group.transcript.settle(); refresh() }
            }
        }
        val lanes = active?.lanes?.map { it.session.snapshot }.orEmpty()
        while (groups.isNotEmpty()) {
            val oldest = groups.first()
            if (!oldest.idle || oldest.transcript?.identifying == true) break
            groups.removeAt(0)
            oldest.classificationDeadline?.cancel()
            oldest.transcript?.settle()
            archived.addAll(oldest.rows())
            trimmed = trimmed || oldest.transcript?.trimmed == true || oldest.lanes.any { it.session.snapshot.trimmed }
            if (oldest === current) {
                if (!oldest.mode.dialogue) tailPlayer = oldest.lanes.single().session.takeIf { it.snapshot.playing }
                current = null
                pending?.cancel()
                failure = lanes.map { it.error }.firstOrNull { it.isNotEmpty() }.orEmpty()
            }
        }
        if (archived.size > LiveSession.MAX_ROWS) {
            archived.subList(0, archived.size - LiveSession.MAX_ROWS).clear()
            trimmed = true
        }
        val states = lanes.map { it.state }
        val state = when {
            current == null && groups.isEmpty() -> SessionState.IDLE
            stopping || states.all { it == SessionState.IDLE } -> SessionState.FINISHING
            SessionState.RECORDING in states -> SessionState.RECORDING
            SessionState.RECONNECTING in states -> SessionState.RECONNECTING
            else -> SessionState.CONNECTING
        }
        val broken = lanes.firstOrNull { it.state == SessionState.IDLE && it.error.isNotBlank() }
        val statuses = lanes.map { it.status }.filter { it.isNotBlank() }.distinct()
        val allRows = archived + groups.flatMap { it.rows() }
        val next = SessionSnapshot(
            state = state, rows = allRows.takeLast(LiveSession.MAX_ROWS),
            status = if (state == SessionState.IDLE) "" else statuses.joinToString(" · "),
            error = if (state == SessionState.IDLE) failure else "",
            notice = message.ifBlank { broken?.error ?: lanes.firstOrNull { it.notice.isNotBlank() }?.notice.orEmpty() },
            playing = speaker.playing || tailPlayer?.snapshot?.playing == true || (active?.mode?.dialogue == false && lanes.any { it.playing }),
            slowNetwork = lanes.any { it.slowNetwork }, slowService = lanes.any { it.slowService },
            trimmed = trimmed || allRows.size > LiveSession.MAX_ROWS || lanes.any { it.trimmed } || active?.transcript?.trimmed == true,
        )
        if (next != snapshot) { snapshot = next; onChange(next) }
    }

    private companion object {
        fun languageName(code: String?) = LiveTranslateConfig.LANGUAGES.firstOrNull { it.first == code }?.second ?: code
        val silentOutput = object : SpeechOutput {
            override fun start(volume: Float) {}
            override fun append(pcm: ByteArray) = true
            override fun finish(done: () -> Unit) = done()
            override fun stop() {}
        }
    }
}
