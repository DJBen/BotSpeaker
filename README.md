# BotSpeaker

BotSpeaker is a native macOS menu-bar application that turns meeting scripts into ElevenLabs speech and routes the result to a virtual audio device such as [BlackHole](https://existential.audio/blackhole/). Meeting applications can select BlackHole as their microphone and receive BotSpeaker's generated voice as live input.

The macOS application and Xcode project live in [`macOS/`](macOS/).

## Features

- Native SwiftUI app with a normal window and a menu-bar control surface
- ElevenLabs API-key setup, validation, and Keychain storage
- ElevenLabs voice selection
- Sequential, sentence-aware speech generation for long scripts
- Persistent audio-chunk caching per script, voice, model, and surrounding context
- Three read-only example meeting scripts plus named custom scripts
- Separate custom-script editor window
- Play, pause, stop, seek, and progress-aware text highlighting
- Persistent output-volume control applied before audio reaches BlackHole
- Optional looping, disabled by default
- Adaptive interruption detection that:
  - learns the selected input's ambient level;
  - detects elevated sound over a 0.4-second window;
  - pauses speech immediately, without waiting for a sentence boundary; and
  - resumes after 0.75 seconds continuously near ambient level.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- An ElevenLabs API key
- [BlackHole 2ch](https://existential.audio/blackhole/) or another virtual audio device

BlackHole is not bundled with BotSpeaker. Review BlackHole's licensing terms before redistributing it with another application.

## Build and run

Open [`macOS/BotSpeaker.xcodeproj`](macOS/BotSpeaker.xcodeproj) in Xcode, select the **BotSpeaker** scheme, and press Run.

To build from the repository root:

```sh
xcodebuild \
  -project macOS/BotSpeaker.xcodeproj \
  -scheme BotSpeaker \
  -configuration Debug \
  build
```

On first launch, enter an ElevenLabs API key. BotSpeaker validates the key and stores it in the macOS Keychain.

## Route speech into a meeting

1. Install BlackHole 2ch.
2. Open BotSpeaker settings and select **BlackHole 2ch** as the output device.
3. In Microsoft Teams, Zoom, Google Meet, or another meeting app, select **BlackHole 2ch** as the microphone.
4. Choose a bundled example or click **Add Text** to create a named custom script.
5. Select an ElevenLabs voice and press **Play**.
6. Use the compact volume slider beside the playback gear to control the signal delivered to BlackHole.

BlackHole is silent through local speakers by default. To monitor BotSpeaker locally, create a Multi-Output Device in Audio MIDI Setup containing BlackHole and headphones, select that device in BotSpeaker, and continue using BlackHole as the meeting microphone.

## Interruption handling

Enable **Pause for interruptions** from the playback gear menu and choose the input to monitor in Settings. BotSpeaker calibrates against ambient sound, pauses when the rolling 0.4-second input window exceeds its adaptive threshold, and resumes after the input remains near ambient for 0.75 seconds.

Headphones or direct BlackHole routing are recommended so the monitored microphone does not hear BotSpeaker's own output.

## Project structure

```text
BotSpeaker/
├── README.md
└── macOS/
    ├── BotSpeaker.xcodeproj/
    └── BotSpeaker/
```

Generated MP3 and timing files are stored in the user's caches directory. API credentials are stored in Keychain and are never written to the repository.
