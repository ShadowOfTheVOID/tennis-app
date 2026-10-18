plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.servecoach.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.servecoach.app"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signed with the debug key so `assembleRelease` produces an installable APK.
            // Replace with your own signing config before publishing to Google Play.
            signingConfig = signingConfigs.getByName("debug")
            // LiteRT-LM ships 64-bit libraries only, and phones are ARM.
            ndk { abiFilters += "arm64-v8a" }
        }
        debug {
            // x86_64 too, for the emulator.
            ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    packaging {
        jniLibs.useLegacyPackaging = false
    }
}

dependencies {
    implementation(project(":analysis"))

    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")

    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")

    // On-device body pose (bundled model, no download).
    implementation("com.google.mlkit:pose-detection-accurate:18.0.0-beta5")
    // Faster model for long match videos.
    implementation("com.google.mlkit:pose-detection:18.0.0-beta5")
    // On-device language models for the AI coach.
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.0")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
}
