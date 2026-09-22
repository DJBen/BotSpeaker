# BotSpeaker for Windows

Native Windows (WPF) port of BotSpeaker: turns meeting scripts into ElevenLabs speech and routes the result to a virtual audio device such as [VB-Audio Virtual Cable](https://vb-audio.com/Cable/). Meeting applications select the cable's capture side (**CABLE Output**) as their microphone and receive BotSpeaker's generated voice as live input — the Windows equivalent of BlackHole on macOS.

## Features

Feature parity with the macOS app:

- ElevenLabs API-key setup, validation, and encrypted storage (Windows DPAPI, current-user scope)
- ElevenLabs voice selection
- Speech-model selection in Settings or `botspeaker-cli models --select ID`: Flash v2 (`eleven_flash_v2`, default) or Eleven v3 (`eleven_v3`). Flash v2 is English-only; select v3 for expressive audio tags.
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
- A **Speak** page for ad hoc text: play it on this PC at any time, or, while
  hosting, on any paired attendee; attendees get the same box in Remote Mode.
  Script templates stay available while hosting
- Optional looping, disabled by default
- System-tray icon with Play/Pause, Stop, and Quit. Closing the main window fully quits; active playback or meetings require confirmation, then pending speech is cancelled and sessions are closed before exit.
- Installed builds check for updates on launch and every six hours, download in the background, and offer **Restart to update** in the tray menu

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

Only one app instance can run from a given executable path. Additional launches
from that path exit immediately, including when the first instance is in the tray.
Copies in different folders can still run concurrently. Quitting or a crash releases
the guard so the app can be launched again.

## Route speech into a meeting

1. Install VB-Audio Virtual Cable and reboot if the installer asks.
2. Open BotSpeaker settings and select **CABLE Input (VB-Audio Virtual Cable)** as the output device (it is auto-selected when detected).
3. In Microsoft Teams, Zoom, Google Meet, or another meeting app, select **CABLE Output (VB-Audio Virtual Cable)** as the microphone.
4. Choose a bundled example or click **Add Text** to create a named custom script.
5. Select an ElevenLabs voice and press **Play**.
6. Use the volume slider to control the signal delivered to the cable.

The cable is silent through local speakers by default. To monitor locally, enable "Listen to this device" on **CABLE Output** in the Windows Sound control panel (Recording tab → CABLE Output → Properties → Listen), routed to your headphones.

## Install and update

Starting with the first release containing Velopack assets, download
`BotSpeaker.Windows-win-Setup.exe` from [GitHub Releases](https://github.com/DJBen/BotSpeaker/releases).
It installs the app and matching CLI for the current user under
`%LOCALAPPDATA%\BotSpeaker.Windows`, without requiring a separate .NET installation.
Existing portable users must run this installer once, then use its shortcut.
Settings, credentials, scripts, and the audio cache retain their existing locations.
The separate install directory keeps uninstalling the app from deleting the audio cache.

The app checks stable GitHub releases on launch and every six hours. Downloads
run in the background; use the tray menu's **Check for Updates…** for a manual
check. A downloaded update enables **Restart to update**, which waits until you
stop playback/generation and leave hosted or joined meetings. Other running
BotSpeaker instances must also be closed. Restart is always explicit, including
after quitting and reopening the app; it never interrupts a meeting automatically.
Failed background checks stay quiet and retry at the next interval.

Portable ZIPs and builds started with `dotnet run` remain manual-update builds.
VB-CABLE remains a separate installation and is not changed by app updates.

The CLI installer command below detects a Velopack installation and puts its
bundled CLI directory first in the user PATH, so the app and CLI update together.
Run it once after installing the app, then open a new terminal. Explicit
`-Version`, `-Source`, or `-Destination` options still install a standalone CLI.

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

## Build and verify update packages

The release script restores the pinned `vpk` tool from `.config/dotnet-tools.json`.
Keep that version aligned with the Velopack package references in the app and
update test project. Build without publishing or changing Git tags:

```powershell
.\scripts\publish-windows-release.ps1 -Version 0.4.5 -AllowUnsigned -BuildOnly
dotnet run --project Windows/BotSpeaker.UpdateTests -- <printed-output-directory>\velopack
```

Each build uses a new directory under `dist`. Outputs include the Windows
installer, full update package, `releases.win.json`, and the existing portable
app/standalone CLI ZIPs and checksums. Full packages are used; delta generation
is not seeded with earlier releases. The tests use an isolated local feed and
package directory to verify downloading, version selection, retry behavior,
and corruption rejection without installing or restarting the app.

For a public release, increment both app and CLI project versions, commit, and
run the same script without `-BuildOnly`. Use `-CertificateThumbprint <sha1>`
instead of `-AllowUnsigned` to sign the app, CLI, installer, and updater binaries.
The feed uploads last, after its package. The public repository is the update
source; no GitHub credentials are bundled in the app. Installer/restart behavior
should also be smoke-tested with two successive versions in a disposable Windows
account or VM before the first public updater release.
