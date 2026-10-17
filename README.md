# Serve Coach 🎾

An iPhone app that watches your tennis serve, checks your posture at the two key moments (the
**trophy position** and **contact**), and uses on-device AI to tell you how to improve.

Everything runs on the phone: no accounts, no API keys, no servers, and no video is uploaded.

## Features

- **Live coaching**: point the camera at yourself and serve. The app spots each serve
  automatically, grades it, reads a tip aloud, and lets you open a full review.
- **Hold-pose mode**: freeze in the trophy position and get real-time feedback while you adjust.
- **Video analysis**: pick a serve clip from Photos. The app finds the trophy and contact frames and
  draws your skeleton on them.
- **AI coach**: Apple's on-device language model double-checks each measurement against the pose
  tracker's confidence, then gives you strengths, up to three prioritised fixes with cues and
  drills, and a focus for your next session.
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

Distances are measured relative to your torso length, so the results don't depend on how far you
stand from the camera.

## Tech stack

| Layer | Choice | Why |
| --- | --- | --- |
| Language | **Swift** | Native performance for real-time camera processing |
| UI | **SwiftUI** (+ Observation) | Modern declarative UI. `Canvas` draws the skeleton overlay |
| Camera | **AVFoundation** | `AVCaptureSession` for live frames, `AVAssetImageGenerator` for videos |
| Pose detection | **Apple Vision**, `VNDetectHumanBodyPoseRequest` | On-device body tracking, free, no model download |
| AI coaching | **Apple Foundation Models** (iOS 26, Apple Intelligence) | On-device LLM with structured `@Generable` output. No API key, works offline |
| Fallback coaching | Rule-based tips and drills | Used on devices without Apple Intelligence |
| Voice cues | **AVSpeechSynthesizer** | Hands-free feedback between serves |
| Analysis core | Swift package `ServeAnalysis` | Pure Swift, platform-independent, unit-tested |
| Tests | **XCTest** via `swift test` | Also runs on Linux/CI without a simulator |
| Project | Plain Xcode project with folder-synced groups | Open and run, no extra tools. New files in `App/ServeCoach/` show up automatically |

## Project layout

```
Package.swift                  # ServeAnalysis Swift package
Sources/ServeAnalysis/         # Geometry, posture checks, serve tracking (no Apple frameworks)
Tests/ServeAnalysisTests/      # Unit tests for the analysis
App/ServeCoach.xcodeproj       # Xcode project for the iOS app (open this)
App/ServeCoach/                # iOS app: camera, Vision, AI coach, SwiftUI screens
```

## Getting started

Requirements: a Mac with **Xcode 26** and an iPhone running iOS 17 or later. The AI coach needs
iOS 26 on an Apple Intelligence device (iPhone 15 Pro or newer). Other devices get the built-in coach.

1. Open `App/ServeCoach.xcodeproj` in Xcode.
2. Choose the **ServeCoach** target, then *Signing & Capabilities*, and pick your team. You can
   change the bundle ID `com.example.ServeCoach` to something unique.
3. Plug in your iPhone, select it as the run destination, and press **Run** (⌘R).

Use a real iPhone, because the camera doesn't work in the simulator.

Run the analysis tests (macOS or Linux):

```bash
swift test
```

## Filming tips

- Stand **side-on** to the camera, about 4 m away, with your **whole body** in frame.
- Use good light. Prop the phone at about hip height on a tripod or against your bag.
- For videos, trim the clip to a single serve.
