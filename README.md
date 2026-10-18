# Serve Coach 🎾

An app for **iPhone and Android** that coaches your tennis technique and analyzes your matches.
It watches your **serve, forehand, backhand, volley and overhead**, checks your **footwork**, and
uses on-device AI to tell you how to improve.

Everything runs on the phone: no accounts, no API keys, no servers, and your video is never uploaded.
It works on an **iPhone 11 Pro Max** and on most 64-bit Android phones.

## Features

- **Live coaching**: pick a stroke (or "Any" to detect it automatically) and hit. The app spots each
  stroke, grades its key moments, reads a tip aloud, and lets you open a full review.
- **Hold-pose mode**: freeze in the serve's trophy position, or in your **ready position** for the
  other strokes, and get real-time feedback while you adjust.
- **One-stroke video analysis**: pick a clip of one stroke. The app finds its key moments and draws
  your skeleton on them.
- **Match analysis**: pick a match or rally video, up to 10 minutes. The app:
  - finds and grades **every stroke** you hit,
  - breaks them down by type with average scores and the most common thing to fix,
  - estimates **footwork**: split steps before your shots, a knees-bent ready stance between shots,
    and how far you moved,
  - builds a **match plan** with the three changes that will help the most,
  - lets you tap any stroke to review it frame by frame.
- **AI coach** ("How do I improve?"), for one stroke or a whole match:
  - double-checks the measurements and flags any it doesn't trust (anything measured from joints the
    tracker couldn't see clearly is always flagged),
  - lists what you're already doing well,
  - gives up to three prioritised fixes, each with why it matters, an on-court cue and a drill,
  - suggests a focus for your next practice.
- **Stroke review extras**:
  - a **slow-motion replay** with your skeleton, played at quarter speed or scrubbed frame by frame,
  - **compare with your best**: your best-scoring stroke of the same kind as a grey ghost skeleton,
    lined up at the hips and scaled to your size,
  - estimated **hand speed** at contact (your hand, not the racket head, which moves faster),
  - **serve rhythm**: the time from trophy position to contact.
- **Progress**: for each stroke, every check's weekly share graded good, as a small chart with the
  change over time; your serve rhythm consistency; and your fastest swings.
- **Weekly practice plan**: a 7-day plan built from the three checks you've missed most in the last
  two weeks, with drills, plus an optional **daily reminder** that tells you that day's part of the plan.
- **History**: every stroke and match is saved on the phone, filterable by stroke, with averages, a
  trend and the fix that comes up most often.
- Right- and left-handed players are supported.

### What it checks

**Serve**

| Trophy position | Contact |
| --- | --- |
| Tossing arm straight | Hitting arm fully extended |
| Tossing arm reaching up | High contact point |
| Hitting elbow bent to ~90° ("L" shape) | Legs extended (leg drive) |
| Hitting elbow at shoulder height | Torso tall and balanced |
| Shoulders tilted up toward the toss | Tossing arm tucked in |
| Knees loaded | |

**Forehand and backhand** (one- or two-handed, detected automatically)

| Preparation | Contact | Finish |
| --- | --- | --- |
| Racket taken back early | Contact out in front | High finish |
| Knees bent | Room between you and the ball / arm extended (one-handed backhand) | Full swing through the ball |
| Wide, stable stance | Contact between waist and chest | Balanced finish |
| Non-hitting arm out in front (forehand) | Balanced at contact | |

**Volley**: compact backswing, racket head up, knees bent, contact in front, firm arm, short
follow-through, balance.

**Overhead**: non-hitting hand pointing up, racket up early, knees bent, full extension, contact high,
balance.

**Ready position and footwork**: knees bent, feet wider than shoulders, racket up in front; split step
before each shot; ready stance between shots; side-to-side movement.

Distances are measured relative to your torso length, so results don't depend on how far you stand
from the camera.

### How strokes are found and told apart

The app only sees your body, not the ball or racket:

- **Finding swings:** a swing is a burst of hitting-hand speed relative to your hips, and contact is
  taken as the moment of peak speed.
- **Above the head:** a swing that starts from standing still after a toss is a serve; otherwise it's
  an overhead.
- **Forehand or backhand:** decided by whether your hitting shoulder starts turned back (forehand) or
  in front (backhand).
- **Volley:** a short, compact swing.
- **Two-handed backhand:** both hands together at contact.

Film **side-on** for the best results. In match mode the stroke type is a best guess and can
occasionally be wrong; when practising a single stroke you can pick the type yourself.

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

**Tested here:** the coaching prompts, JSON schema and answer parsing were run end to end with the
real Gemma 4 E2B model on a 4-core Linux CPU, for serves, groundstrokes and matches. Those runs found
problems I then fixed:

- Gemma confused the direction of a fix, so the prompts now give the analyzer's fix direction
  explicitly.
- It sometimes trusted readings the tracker wasn't sure of, so low-confidence measurements are now
  always flagged.
- It invented match strengths, so match strengths now come only from the measured data.

After the fixes it named the right problems with the right fixes, and returned valid output in about
35–40 s (about 75 s with photos). Peak memory was about 0.45 GB, plus the model file memory-mapped from storage. Expect about
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
| Shared logic (checks, stroke detection, match analysis, coaching) | Swift package `ServeAnalysis` | Kotlin module `:analysis` |
| Tests | XCTest (`swift test`, also on Linux) | JUnit via Gradle |
| Build | Checked-in Xcode project | Gradle 9, Android Gradle Plugin 9.4, compile SDK 37 |

The posture checks, stroke detection, match analysis, coaching prompts, JSON schema, answer parsing,
rule-based coach and history are implemented twice, once per language, and kept in sync. Both have the
same 45 unit tests built on identical synthetic swings. The AI prompts for serves, groundstrokes and
matches were checked to be byte-for-byte identical on both platforms.

## Project layout

```
Package.swift                  # ServeAnalysis Swift package
Sources/ServeAnalysis/         # Checks, stroke detection, match analysis, coaching, history (pure Swift)
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

`./gradlew assembleRelease` builds a shrunk, about 60 MB APK at
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
- For one-stroke videos, trim the clip to a single stroke.
- For matches, film from the side fence so you're seen side-on, and keep the camera still. The app
  follows the largest person in the frame, which is you if you're on the near side.

## Limits

- One camera angle only, and only your body is tracked. Racket face, ball speed, spin, toss placement
  and where shots land aren't measured, so there are no winner or error counts.
- In match mode, stroke types are detected from body position and can occasionally be wrong.
- Footwork numbers are estimates: a split step is a small hop seen in your feet, and movement toward or
  away from the camera isn't seen.
- Match analysis covers up to 10 minutes per video and takes a few minutes on a phone.
- The grading thresholds come from standard tennis coaching and haven't been tuned on real players yet.
- The AI review takes 1–2 minutes on a phone. The first run after a download also prepares the
  model, which takes a little longer.
