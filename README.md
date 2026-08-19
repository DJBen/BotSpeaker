# BotSpeaker

**You can test a multi-party meeting in the same room with distinctive bot speakers.**

<img width="463" height="609" alt="Screenshot 2026-08-11 at 6 26 49 PM" src="https://github.com/user-attachments/assets/dc4b369e-45b9-4c7f-9f81-0f75ef43c896" />

BotSpeaker is a native macOS and Windows utility that turns meeting scripts into ElevenLabs speech and sends it to a virtual microphone. It lets you simulate additional attendees in Microsoft Teams, Zoom, Google Meet, and other meeting applications while retaining control over voice, timing, volume, interruptions, and playback position.

The macOS app uses SwiftUI and [BlackHole](https://existential.audio/blackhole/). The Windows app uses WPF and [VB-Audio Virtual Cable](https://vb-audio.com/Cable/).

## Download

[Download the latest BotSpeaker builds from GitHub Releases](https://github.com/DJBen/BotSpeaker/releases).

- **macOS 14 or later:** [`BotSpeaker-0.1.4-universal.dmg`](https://github.com/DJBen/BotSpeaker/releases/tag/0.1.4), signed with Developer ID and notarized by Apple. Supports Apple Silicon and Intel.
- **Windows 10/11 x64:** `BotSpeaker-Windows-x64-0.1.2.zip`, a self-contained portable exe—unzip and run, with no .NET installation required. It is currently unsigned, so Windows SmartScreen may warn on first launch.

The repository and its release downloads are public.

## Example configurations
| Mac | Windows |
| --- | --- |
| <img width="304" height="300" alt="Screenshot 2026-08-13 at 1 18 01 PM" src="https://github.com/user-attachments/assets/3c9ad85e-ef01-4839-9e5d-017787c66d33" /> | <img width="304" alt="image" src="https://github.com/user-attachments/assets/69365248-974d-42ac-8f32-c263a2e6defa" /> |

## Features

- Native SwiftUI menu-bar app on macOS and native WPF system-tray app on Windows
- Automatic macOS update checks powered by Sparkle, with a manual **Check for Updates…** action
- ElevenLabs API-key setup, validation, and platform-encrypted storage
- ElevenLabs voice selection
- Sequential, sentence-aware speech generation for long scripts
- Persistent audio-chunk caching per script, voice, model, and surrounding context
- Two coordinated meeting scenarios with seven role templates and one-time speaker-name substitution
- Side-by-side script library and playback workspace, plus named custom scripts
- Play, pause, stop, seek, and progress-aware text highlighting
- Persistent output-volume control applied before audio reaches the virtual device
- Optional looping, disabled by default
- Adaptive interruption detection that:
  - learns the selected input's ambient level;
  - detects elevated sound over a 0.4-second window;
  - pauses speech immediately, without waiting for a sentence boundary; and
  - resumes after 0.75 seconds continuously near ambient level.

## Runtime requirements

- An ElevenLabs API key
- **macOS:** macOS 14 or later and [BlackHole 2ch](https://existential.audio/blackhole/) or another virtual audio device
- **Windows:** Windows 10/11 x64 and [VB-Audio Virtual Cable](https://vb-audio.com/Cable/) or another virtual audio device

Virtual audio drivers are not bundled with BotSpeaker. Review their licensing terms before redistributing them with another application.

## Build from source

### macOS

Requires Xcode 16 or later.

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

### Windows

Requires the .NET 10 SDK. See the [Windows build and setup guide](Windows/README.md), or run:

```powershell
dotnet run --project Windows/BotSpeaker
```

The Windows app encrypts the API key with Windows DPAPI for the current user.

## Route speech into a meeting

### macOS

1. Install BlackHole 2ch.
2. Open BotSpeaker settings and select **BlackHole 2ch** as the output device.
3. In Microsoft Teams, Zoom, Google Meet, or another meeting app, select **BlackHole 2ch** as the microphone.
4. Choose a bundled example or click **Add Text** to create a named custom script.
5. Select an ElevenLabs voice and press **Play**.
6. Use the compact volume slider beside the playback gear to control the signal delivered to BlackHole.

BlackHole is silent through local speakers by default. To monitor BotSpeaker locally, create a Multi-Output Device in Audio MIDI Setup containing BlackHole and headphones, select that device in BotSpeaker, and continue using BlackHole as the meeting microphone.

### Windows

1. Install VB-Audio Virtual Cable and reboot if requested.
2. Select **CABLE Input** as BotSpeaker's output device.
3. Select **CABLE Output** as the microphone in Teams, Zoom, Meet, or another meeting app.
4. Select a script and ElevenLabs voice, then press **Play**.

See [Windows/README.md](Windows/README.md) for monitoring and storage details.

## Interruption handling

Enable **Pause for interruptions** from the playback-options menu and choose the input to monitor in Settings. BotSpeaker calibrates against ambient sound, pauses when the rolling 0.4-second input window exceeds its adaptive threshold, and resumes after the input remains near ambient for 0.75 seconds.

Headphones or direct virtual-device routing are recommended so the monitored microphone does not hear BotSpeaker's own output.

## Project structure

```text
BotSpeaker/
├── README.md
├── scripts/                    # Release packaging and publishing
├── macOS/
│   ├── BotSpeaker.xcodeproj/
│   └── BotSpeaker/
└── Windows/
    ├── README.md
    └── BotSpeaker/
```

Generated MP3 and timing files are stored in the platform's user cache. API credentials are stored in macOS Keychain or encrypted with Windows DPAPI and are never written to the repository.

## Publish a release

BotSpeaker is configured for Apple Developer team `52RD2GH5DP`. A public macOS release requires:

- a Developer ID Application certificate for that team in the login keychain;
- an App Store Connect API key authorized to notarize software; and
- [`create-dmg`](https://github.com/sindresorhus/create-dmg), installed with `npm install --global create-dmg`.

Copy `.env.template` to `.env` and enter the API key ID, issuer ID, and base64-encoded `.p8` contents. The release script decodes the key into its temporary build directory with owner-only permissions and removes it when the command exits. The completed `.env` is ignored by Git.

Build, sign, notarize, staple, and validate a universal DMG locally with:

```sh
./scripts/release-macos.sh 0.2.0
```

The DMG and its SHA-256 checksum are written to `dist/`. To additionally create and push the version tag and attach both files to a GitHub Release, run:

```sh
./scripts/release-macos.sh 0.2.0 --publish-github
```

The same versioned GitHub Release is used for every platform. On the Windows release machine, build, package, and upload the self-contained exe and its checksum with:

```powershell
.\scripts\publish-windows-release.ps1 -Version 0.2.0 -AllowUnsigned
```

The script verifies that `BotSpeaker.csproj` declares the same version, publishes a single-file win-x64 build, zips it with a SHA-256 checksum into `dist/`, and uploads both. Pass `-CertificateThumbprint <sha1>` instead of `-AllowUnsigned` to Authenticode-sign the exe with `signtool` before packaging; unsigned publishing always requires the explicit flag. The publisher refuses a dirty working tree, a tag that does not match `HEAD`, and existing asset names. Either platform can create the shared release first; the other adds its artifacts afterward.

The macOS publisher also signs the DMG with BotSpeaker's Sparkle EdDSA key and attaches `appcast.xml` to the GitHub Release. The Sparkle private key is stored in the login Keychain under account `ai.djben.BotSpeaker`; preserve or securely export this key before moving release production to another Mac. Because anonymous GitHub release downloads are required for Sparkle, automatic updates become available once this repository is public. Until then, collaborators can continue installing releases manually from GitHub.

Because this repository is currently private, only collaborators can download its GitHub release assets. Making the repository public later will also make its releases publicly downloadable.
