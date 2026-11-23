plugins {
    id("com.android.compose.screenshot") version "0.0.1-alpha10"
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// One version for macOS and Android: the repository's VERSION file (x.y.z). versionCode = major*10000 + minor*100 + patch.
val releaseVersion = rootProject.file("../VERSION").readText().trim()
val releaseVersionCode = Regex("""(\d+)\.(\d+)\.(\d+)""").matchEntire(releaseVersion)?.destructured
    ?.let { (major, minor, patch) -> major.toInt() * 10000 + minor.toInt() * 100 + patch.toInt() }
    ?: throw GradleException("VERSION 必须是 x.y.z，当前内容：\"$releaseVersion\"")

android {
    experimentalProperties["android.experimental.enableScreenshotTest"] = true
    namespace = "com.localrecorder.shengjian"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.localrecorder.shengjian"
        minSdk = 26
        targetSdk = 35
        versionCode = releaseVersionCode
        versionName = releaseVersion
    }

    // Release signing comes only from the environment (CI secrets, see android/README.md); the keystore
    // never enters the repository. Without SHENGJIAN_KEYSTORE the release APK is built unsigned, which is
    // enough for CI to check R8 and the size budget.
    val releaseKeystore = providers.environmentVariable("SHENGJIAN_KEYSTORE").orNull?.takeIf { it.isNotBlank() }
    signingConfigs {
        if (releaseKeystore != null) {
            fun secret(name: String) = providers.environmentVariable(name).orNull?.takeIf { it.isNotEmpty() }
                ?: throw GradleException("SHENGJIAN_KEYSTORE is set but $name is missing")
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = secret("SHENGJIAN_KEYSTORE_PASSWORD")
                keyAlias = secret("SHENGJIAN_KEY_ALIAS")
                keyPassword = secret("SHENGJIAN_KEY_PASSWORD")
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
    }

    dependenciesInfo {
        // The APK is distributed on GitHub Releases; the dependency block only Google Play reads stays in bundles.
        includeInApk = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    screenshotTestImplementation("com.android.tools.screenshot:screenshot-validation-api:0.0.1-alpha10")
    screenshotTestImplementation("androidx.compose.ui:ui-tooling")
    implementation(project(":core"))
    implementation(platform("androidx.compose:compose-bom:2025.04.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
