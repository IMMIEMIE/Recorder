plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    api("com.squareup.okhttp3:okhttp:4.12.0")
    // Android ships org.json in the platform; the JVM build and tests need the artifact.
    compileOnly("org.json:json:20240303")
    testImplementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    // The WebSocket tests run against tests/mock_livetranslate_server.py and tests/mock_volc_ast_server.py from the repository root.
    systemProperty("livetranslate.mock", rootProject.projectDir.resolve("../tests/mock_livetranslate_server.py").absolutePath)
    systemProperty("volc.ast.mock", rootProject.projectDir.resolve("../tests/mock_volc_ast_server.py").absolutePath)
    // The session export fixtures shared with macOS (docs/SESSIONS.md, scripts/make_session_export_fixtures.py).
    systemProperty("session.fixtures", rootProject.projectDir.resolve("../tests/fixtures/session_export").absolutePath)
    testLogging { events("passed", "failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

// Real-API timing probe (scripts/probe_livetranslate.sh): the app's own client at real-time pace.
// ./gradlew -PcoreOnly=true :core:liveProbe --args="--audio=<wav> [--language=en] [--speech=on] …"
tasks.register<JavaExec>("liveProbe") {
    group = "verification"
    description = "Streams a WAV to LiveTranslate through LiveTranslateClient and reports backlog, latency and disconnect causes."
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("com.localrecorder.live.LiveProbeKt")
}

tasks.register<JavaExec>("dialogueProbe") {
    group = "verification"
    description = "Probes Qwen's second session.update and simultaneous text sessions using one short test WAV."
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("com.localrecorder.live.DialogueProbeKt")
}
