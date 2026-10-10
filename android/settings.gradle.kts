pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id("com.android.application") version "8.9.1"
        id("org.jetbrains.kotlin.android") version "2.1.20"
        id("org.jetbrains.kotlin.jvm") version "2.1.20"
        id("org.jetbrains.kotlin.plugin.compose") version "2.1.20"
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
    }
}

// Gradle 8.14 cannot run on the JDK 25 bundled with current Android Studio; the daemon JDK is pinned in
// gradle/gradle-daemon-jvm.properties (regenerate with `./gradlew updateDaemonJvm`) and downloaded on demand.
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

rootProject.name = "shengjian-android"

// :core is plain Kotlin/JVM (protocol, event joining, PCM decoding) and builds without the Android SDK.
// `-PcoreOnly=true` skips :app, e.g. on machines without the SDK or Google's Maven repository.
include(":core")
if (providers.gradleProperty("coreOnly").orNull != "true") {
    include(":app")
}
