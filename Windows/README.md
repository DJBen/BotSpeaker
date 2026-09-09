# BotSpeaker for Windows

Native Windows (WPF) port of BotSpeaker: turns meeting scripts into ElevenLabs speech and routes the result to a virtual audio device such as [VB-Audio Virtual Cable](https://vb-audio.com/Cable/). Meeting applications select the cable's capture side (**CABLE Output**) as their microphone and receive BotSpeaker's generated voice as live input — the Windows equivalent of BlackHole on macOS.

## Features

Feature parity with the macOS app:

- ElevenLabs API-key setup, validation, and encrypted storage (Windows DPAPI, current-user scope)
- ElevenLabs voice selection
- Sequential, sentence-aware speech generation for long scripts (identical chunking to macOS)
- Persistent audio-chunk caching per script, voice, and model
- Three read-only launch-retrospective templates written for Eleven v3 audio tags, plus named custom scripts with a separate editor window
- Play, pause, stop, seek, and progress-aware text highlighting driven by ElevenLabs character timestamps
- Persistent output-volume control applied before audio reaches the virtual cable
- Cross-platform meeting orchestration where the host distributes one
  placeholder-driven script and every client prepares and persistently caches
  all assigned turns before playback
- The `botspeaker` command line tool and a loopback control API (see
  [Command line](#command-line) below): speak text or play an audio file on
  this PC, or speak text on any Mac or PC paired to a meeting this PC hosts,
  with the same commands as the macOS CLI.
- Ad hoc speech from the host: while paired in Remote Mode, the PC plays text
  the host sends (`botspeaker speak --target "This PC" --wait "Hello"`,
  including `--loop` and `--repeat N`) and reports completion, failure, or
  cancellation back.
- Optional looping, disabled by default
- System-tray icon with Play/Pause, Stop, and Quit; closing the window keeps the app running in the tray

## Requirements

- Windows 10/11
- [.NET SDK 10](https://dotnet.microsoft.com/download) (to build)
- An ElevenLabs API key
- [VB-Audio Virtual Cable](https://vb-audio.com/Cable/) or another virtual audio device

VB-CABLE is not bundled with BotSpeaker. Review VB-Audio's licensing terms before redistributing it with another application.

## Build and run

```powershell
dotnet run --project Windows/BotSpeaker
```

Or produce a self-contained build:

```powershell
dotnet publish Windows/BotSpeaker -c Release -r win-x64 --self-contained
```

On first launch, enter an ElevenLabs API key. BotSpeaker validates the key and stores it encrypted with DPAPI under `%APPDATA%\BotSpeaker`.

## Route speech into a meeting

1. Install VB-Audio Virtual Cable and reboot if the installer asks.
2. Open BotSpeaker settings and select **CABLE Input (VB-Audio Virtual Cable)** as the output device (it is auto-selected when detected).
3. In Microsoft Teams, Zoom, Google Meet, or another meeting app, select **CABLE Output (VB-Audio Virtual Cable)** as the microphone.
4. Choose a bundled example or click **Add Text** to create a named custom script.
5. Select an ElevenLabs voice and press **Play**.
6. Use the volume slider to control the signal delivered to the cable.

The cable is silent through local speakers by default. To monitor locally, enable "Listen to this device" on **CABLE Output** in the Windows Sound control panel (Recording tab → CABLE Output → Properties → Listen), routed to your headphones.

## Command line

`botspeaker-cli.exe` drives the running app from a terminal or an LLM agent.
(It is `botspeaker-cli` rather than `botspeaker` because `BotSpeaker.exe`,
the app, would be the same file name on Windows.) It is a self-contained
single-file exe; install or update it with one line in PowerShell (it lands in
`%LOCALAPPDATA%\Programs\BotSpeaker` and that folder is added to your user
PATH):

```powershell
irm https://raw.githubusercontent.com/DJBen/BotSpeaker/main/scripts/install-cli.ps1 | iex
```

From a checkout, `.\scripts\install-cli.ps1 -Source` builds it instead, and
`-Source -IncludeApp` also builds and installs `BotSpeaker.exe` beside it.
When the app is not running, the CLI launches the copy it last talked to (so
starting the app by hand once is enough), a `BotSpeaker.exe` beside itself,
`BOTSPEAKER_APP`, or a Desktop copy.

```powershell
botspeaker-cli status
botspeaker-cli speak --wait "Hello from this PC"
botspeaker-cli play-audio --wait C:\clips\intro.mp3     # mp3, wav, m4a, aac, aiff, wma, flac, ogg, opus
botspeaker-cli speak --loop "On a cycle"                 # until `botspeaker-cli stop`
botspeaker-cli host                                      # prints the pairing code
botspeaker-cli targets                                   # attendees paired to this host
botspeaker-cli speak --target "Sihao's Mac" --wait "Hi"  # plays on that attendee
```

Commands, flags, JSON output, and exit codes match the macOS CLI; see the
[CLI guide](../docs/cli.md). The app publishes its loopback URL and per-launch
token in `%APPDATA%\BotSpeaker\control.json`, so `curl` or any HTTP client can
use the same API. Set `ControlPort` in `settings.json` to change the preferred
port (`47311`).

## Storage locations

- API key: `%APPDATA%\BotSpeaker\credentials.bin` (DPAPI encrypted)
- Settings and custom scripts: `%APPDATA%\BotSpeaker\settings.json`
- Generated MP3 and timing files: `%LOCALAPPDATA%\BotSpeaker\Audio\`
