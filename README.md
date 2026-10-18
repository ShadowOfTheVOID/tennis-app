# Serve Coach 🎾

An app for **iPhone and Android** that watches your tennis serve, checks your posture at the two key
moments (the **trophy position** and **contact**), and uses on-device AI to tell you how to improve.

Everything runs on the phone: no accounts, no API keys, no servers, and your video is never uploaded.
It works on an **iPhone 11 Pro Max** and on most 64-bit Android phones.

## Features

- **Live coaching**: point the camera at yourself and serve. The app spots each serve
  automatically, grades it, reads a tip aloud, and lets you open a full review.
- **Hold-pose mode**: freeze in the trophy position and get real-time feedback while you adjust.
- **Video analysis**: pick a serve clip from your library. The app finds the trophy and contact
  frames and draws your skeleton on them.
- **AI coach** ("How do I improve?"):
  - double-checks every measurement and flags any it doesn't trust (for example a leg it couldn't see),
  - lists what you're already doing well,
  - gives up to three prioritised fixes, each with why it matters, an on-court cue and a drill,
  - suggests a focus for your next practice.
- **History**: every serve is saved on the phone, with your average, your trend over recent serves and
  the fix that comes up most often.
- Right- and left-handed players are supported.

### What it checks

| Trophy position | Contact |
| --- | --- |
| Tossing arm straight | Hitting arm fully extended |
| Tossing arm reaching up | High contact point |
| Hitting elbow bent to ~90° ("L" shape) | Legs extended (leg drive) |
| Hitting elbow at shoulder height | Torso tall and balanced |
| Shoulders tilted up toward the toss | Tossing arm tucked in |
| Knees loaded | |

Distances are measured relative to your torso length, so results don't depend on how far you stand
from the camera.

## How the AI works

There are two layers of AI, both on the phone:

1. **Pose AI** tracks 13 body joints in every frame: Apple Vision on iPhone, Google ML Kit on Android.
   Built-in expert rules turn the joint angles into grades, tips and drills. This works instantly, on
   every phone, with nothing to download.
2. **Coaching AI** is a language model that reviews the measurements, double-checks them, and writes
   personalised coaching. The app uses the best one available:

| Engine | Where it runs | Sees your photos | Setup |
| --- | --- | --- | --- |
| **Gemma 4 E2B** via Google LiteRT-LM | iPhone and Android with 4 GB+ RAM (iPhone 11 Pro Max included) | ✅ | One-time 2.6 GB download in Settings. Free, open licence, no account |
| **Apple Intelligence** | iPhone 15 Pro and newer, iOS 26 | ❌ | None |
| **Built-in coach** | Every phone | ❌ | None |

If an AI engine fails or answers badly, the app falls back to the built-in coach, so you always get a
report.

**Tested here:** the coaching prompt, JSON schema and answer parsing were run end to end with the real
Gemma 4 E2B model on a 4-core Linux CPU. It correctly flagged a low-confidence knee reading, fixed the
right things in the right direction, and returned valid output in about 40 s (about 75 s with both
photos). Peak memory was about 0.45 GB, plus the model file memory-mapped from storage. Expect about
1–2 minutes per review on a phone. A smaller model (Qwen3 0.6B) was also tried and couldn't produce
usable coaching, so it isn't offered.

## Tech stack

| Layer | iPhone | Android |
| --- | --- | --- |
| Language / UI | Swift, SwiftUI | Kotlin, Jetpack Compose (Material 3) |
| Camera | AVFoundation | CameraX |
| Pose detection | Apple Vision (`VNDetectHumanBodyPoseRequest`) | Google ML Kit Pose Detection (accurate) |
| AI coach | LiteRT-LM (Swift package) + Apple Foundation Models | LiteRT-LM (`litertlm-android`) |
| Voice tips | AVSpeechSynthesizer | TextToSpeech |
| Shared logic | Swift package `ServeAnalysis` | Kotlin module `:analysis` |
| Tests | XCTest (`swift test`, also on Linux) | JUnit via Gradle |
| Build | Checked-in Xcode project | Gradle 9, Android Gradle Plugin 9.4, compile SDK 37 |

The posture checks, coaching prompt, JSON schema, answer parsing, rule-based coach and history
are implemented twice, once per language, and kept in sync. The unit tests use identical poses on both
platforms, and the generated AI prompt was checked to be byte-for-byte identical.

## Project layout

```
Package.swift                  # ServeAnalysis Swift package
Sources/ServeAnalysis/         # Checks, serve tracking, coaching prompt/parsing, history (pure Swift)
Tests/ServeAnalysisTests/      # Swift unit tests
App/ServeCoach.xcodeproj       # Xcode project for the iPhone app (open this)
App/ServeCoach/                # iPhone app: camera, Vision, AI coach, SwiftUI screens
android/                       # Android Studio project (open this folder)
android/analysis/              # Shared Kotlin logic + JUnit tests (mirrors ServeAnalysis)
android/app/                   # Android app: CameraX, ML Kit, LiteRT-LM, Compose screens
```

## Getting started

### iPhone

Requirements: a Mac with **Xcode 26** and an iPhone with iOS 17 or later (an iPhone 11 Pro Max is fine).

1. Open `App/ServeCoach.xcodeproj` in Xcode. It fetches the LiteRT-LM package automatically.
2. Choose the **ServeCoach** target, then *Signing & Capabilities*, and pick your team. Change the
   bundle ID `com.example.ServeCoach` to something unique.
3. Plug in your iPhone, select it as the run destination, and press **Run** (⌘R).
4. In the app, open **Settings** and tap **Download** next to Gemma 4 E2B (2.6 GB, on Wi-Fi).

Use a real iPhone, because the camera doesn't work in the simulator.

### Android

Requirements: **Android Studio** (recent) and a 64-bit Android phone with Android 8.0 or later.

1. Open the `android/` folder in Android Studio and let Gradle sync.
2. Plug in your phone with USB debugging on, and press **Run**.
   Or from a terminal: `cd android && ./gradlew installDebug`.
3. In the app, open **Settings** and tap **Download** next to Gemma 4 E2B.

`./gradlew assembleRelease` builds a shrunk, about 56 MB APK at
`android/app/build/outputs/apk/release/`. It's signed with the debug key; use your own signing key
before publishing.

### Tests

```bash
swift test                              # Swift package (macOS or Linux)
cd android && ./gradlew :analysis:test  # Kotlin module
```

## Filming tips

- Stand **side-on** to the camera, about 4 m away, with your **whole body** in frame.
- Use good light. Prop the phone at about hip height on a tripod or against your bag.
- For videos, trim the clip to a single serve.

## Limits

- One camera angle only. Racket face and toss placement aren't measured.
- The grading thresholds come from standard serve coaching and haven't been tuned on real players yet.
- The AI review takes 1–2 minutes on a phone. The first run after a download also prepares the
  model, which takes a little longer.
