# BotSpeaker

**You can test a multi-party meeting in the same room with distinctive bot speakers.**

<img width="463" height="609" alt="Screenshot 2026-08-11 at 6 26 49 PM" src="https://github.com/user-attachments/assets/dc4b369e-45b9-4c7f-9f81-0f75ef43c896" />

BotSpeaker is a native macOS and Windows utility that turns meeting scripts into ElevenLabs speech and sends it to a virtual microphone. It lets you simulate additional attendees in Microsoft Teams, Zoom, Google Meet, and other meeting applications while retaining control over voice, timing, volume, and playback position.

The macOS app uses SwiftUI and [BlackHole](https://existential.audio/blackhole/). The Windows app uses WPF and [VB-Audio Virtual Cable](https://vb-audio.com/Cable/).

## Download

[Download the latest BotSpeaker builds from GitHub Releases](https://github.com/DJBen/BotSpeaker/releases).

- **macOS 14 or later:** [`BotSpeaker-0.4.5-universal.dmg`](https://github.com/DJBen/BotSpeaker/releases/tag/0.4.5), signed with Developer ID and notarized by Apple. Supports Apple Silicon and Intel.
- **macOS command line tool** (optional, for scripts and LLM agents): install or update it with one line. It downloads the signed `botspeaker` binary attached to the latest release.

  ```sh
  curl -fsSL https://raw.githubusercontent.com/DJBen/BotSpeaker/main/scripts/install-cli.sh | bash
  ```
- **Windows 10/11 x64:** [BotSpeaker 0.5.5 installer](https://github.com/DJBen/BotSpeaker/releases/download/0.5.5/BotSpeaker.Windows-win-Setup.exe), with automatic update downloads and Desktop/Start menu shortcuts. Existing portable users should install once. A [portable ZIP](https://github.com/DJBen/BotSpeaker/releases/download/0.5.5/BotSpeaker-Windows-x64-0.5.5.zip) is also available for manual updates. Both are self-contained and currently unsigned, so Windows SmartScreen may warn on first launch.
- **Windows command line tool** `botspeaker-cli` (optional, for scripts and LLM agents; needs the Windows app from 0.4.1 or later): install or update it with one line in PowerShell.

  ```powershell
  irm https://raw.githubusercontent.com/DJBen/BotSpeaker/main/scripts/install-cli.ps1 | iex
  ```

The repository and its release downloads are public.

## Example configurations
| Mac | Windows |
| --- | --- |
| <img width="304" height="300" alt="Screenshot 2026-08-13 at 1 18 01 PM" src="https://github.com/user-attachments/assets/3c9ad85e-ef01-4839-9e5d-017787c66d33" /> | <img width="304" alt="image" src="https://github.com/user-attachments/assets/69365248-974d-42ac-8f32-c263a2e6defa" /> |

## Features

- Native SwiftUI menu-bar app on macOS and native WPF app with tray controls on Windows
- Closing the Windows window fully quits; active playback or meetings require confirmation and cleanup before exit
- One running instance per executable path; duplicate launches exit, while copies in different folders can run concurrently (macOS guard applies within the current user account)
- Automatic macOS update checks powered by Sparkle, with a manual **Check for Updates…** action
- Windows installer builds use Velopack for background downloads and an explicit **Restart to update** tray action; portable ZIPs remain manual-update builds
- ElevenLabs API-key setup, validation, and platform-encrypted storage
- ElevenLabs voice selection
- Saved speech-model selection in Settings or `botspeaker models --select ID`: Flash v2 (`eleven_flash_v2`) by default, or Eleven v3 (`eleven_v3`). Flash v2 is English-only; use v3 for the bundled templates' expressive audio tags. Each machine uses its own saved model for local and remote-requested speech.
- Speech generated at a 1.1× default speed for a more natural meeting pace
- Sequential, sentence-aware speech generation for long scripts
- Persistent audio-chunk caching per script, voice, and model
- Three launch-retrospective role templates written for Eleven v3 audio tags, with one-time speaker-name substitution
- One host-controlled, four-speaker **AI meeting assistant launch readiness** conversation
- Side-by-side script library and playback workspace, plus named custom scripts
- Play, pause, stop, seek, and progress-aware text highlighting
- Persistent output-volume control applied before audio reaches the virtual device
- Multi-machine meeting orchestration across macOS and Windows: the host owns a
  shared `{{speaker_1}}`-style script, assigns roles by client order, and controls
  automatic handoff, pause, resume, skip, and stop
- Ahead-of-time orchestration preparation that caches every assigned paragraph
  before playback and reuses unchanged text and voice results across meetings
- A **Speak** page for ad hoc text: play it on this machine at any time, or, while
  hosting, on any paired attendee; attendees get the same box in Remote Mode.
  Recent requests from the app and the CLI are listed with their pass count and a
  cancel control, and script templates stay available while hosting
- Loop-until-stopped and repeat-N playback for ad hoc speech and recorded audio
- A `botspeaker` command-line tool for macOS and Windows that speaks text,
  plays audio files, picks voices and outputs, hosts or joins meetings, and
  targets paired attendees, with `--json` output for scripts
- A loopback HTTP control API with a per-launch bearer token behind the CLI,
  usable from `curl` or any language
- A ready-made agent skill (`cli/skills/botspeaker/SKILL.md`) so Claude Code and
  similar LLM agents can speak into a meeting
- Self-updating CLI on macOS (`botspeaker upgrade`) with a reminder whenever the
  Sparkle-updated app gets ahead of it
- Timestamped JSON transcript export with both playback-device and
  server-received start/end times for every speaker turn
- Optional looping, disabled by default
- Recall.ai meeting bots with individual voices, scheduled speech, and orchestrated turns
- Recall CLI controls (Windows 0.5.5 and current macOS source) for Teams invitation input, meeting-scoped bot cleanup, prepared speech, job waits, and JSON meeting plans

## Runtime requirements

- An ElevenLabs API key
- **macOS:** macOS 14 or later; [BlackHole 2ch](https://existential.audio/blackhole/) or another virtual audio device for local microphone routing
- **Windows:** Windows 10/11 x64; [VB-Audio Virtual Cable](https://vb-audio.com/Cable/) or another virtual audio device for local microphone routing
- **Recall.ai bots:** a Recall API key; speech goes directly to the bot without a local virtual audio driver

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

## Orchestrate multiple machines

Choose a template under **Orchestrated meeting** in the script sidebar. The
built-in scenarios include a four-person AI assistant launch review and a
three-person API latency incident review, plus a two-person performance-review
1:1. The main window first shows the shared
script preview plus a name and ElevenLabs voice picker for each speaker. Each
template starts with distinct gender-matched voices when the ElevenLabs catalog
provides them; the three-person incident review defaults to male, female, male.
Choose **Host Meeting** in the main app title bar first. BotSpeaker creates one
remote group and replaces that button with its stable six-character code. Remote
participants choose **Remote Mode** at the top of the sidebar and enter that code
once; they do not need to select the same transcript. The host then opens any
entry under **Orchestrated meeting** and chooses **Use This Script**.
Macs and Windows PCs interoperate freely in the same group — either platform can
host. The host orders the paired devices and chooses **Prepare Speakers** to
distribute the resolved script and voice assignments. Each client generates and
caches all assigned paragraphs asynchronously; once every client is fully ready,
the host starts the session and BotSpeaker hands turns between laptops
automatically. The code is owned by the title bar, not a script, and is not shown
inside individual meeting runs. When a run completes, clients remain paired while
the host selects another orchestrated script; transient disconnects and app
restarts restore the same membership. The host can export a JSON transcript with exact per-speaker
playback and server-received timestamps, while **Leave** or **Disconnect** ends
the durable group explicitly.

Each participating machine needs its own ElevenLabs API key and virtual-audio
output configuration. The host chooses every voice and the meeting script. See the
[meeting orchestration guide](docs/orchestration.md) for setup, privacy, protocol,
and transcript details.

## Use Recall.ai meeting bots

Open **Recall.ai Bots** in the sidebar to configure your Recall key and join a
meeting. Paste the full Teams invitation, including its meeting ID
and passcode, or enter a join URL. An existing key appears masked during
onboarding; choose **Change** to replace it.

For a scripted conversation, choose **Host in Recall.ai** on an orchestrated
script, assign speaker names and voices, and choose **Arrange turns**. Admit
the bots from the meeting lobby before starting. Both platforms prepare every turn’s
audio before playback in the current source. Returning to the same sidebar item preserves progress
for the current app session. After stopping or finishing, use **Remove all bots**
to make the speaker bots leave.

See the [Recall guide](docs/recall.md) for setup, timing, and lifecycle details.

## Drive it from the command line or an agent

The `botspeaker` CLI (macOS) and `botspeaker-cli` (Windows) drive the running
app from a shell: speak arbitrary text on this machine or on any Mac or Windows
PC paired to the meeting this machine hosts, play recorded audio files, choose
voices and outputs, and host or join meetings. Ad hoc speech is independent of
the orchestrated script but shares its ElevenLabs synthesis, cache, and
virtual-audio output, so a machine set up for meetings needs nothing extra.

### Install

Install or update with the one-liners under [Download](#download). On macOS the
binary goes to `/usr/local/bin` (or `~/.local/bin`); pass `--dest DIR`,
`--version 0.4.3`, or `--source` to build from a checkout. The CLI is a thin
client: if the app is not running, it launches it in the background and waits
up to 20 seconds. Set `BOTSPEAKER_NO_LAUNCH=1` to fail instead, or
`BOTSPEAKER_APP=/path/to/BotSpeaker.app` to launch a specific copy.

The app updates itself through Sparkle, and when it gets ahead of the CLI every
command prints a `note:` reminder. On macOS run `botspeaker upgrade`
(`--check` only reports); Windows standalone builds also support `upgrade`.

### Commands

Replace `botspeaker` with `botspeaker-cli` on Windows; every subcommand and flag
is otherwise identical.

```sh
botspeaker status                            # app, output, voice, session, active speech
botspeaker speak "Hello from this Mac"       # play locally, return immediately with a request ID
botspeaker speak --wait "Hello"              # block until playback finishes; exit 0 only on success
botspeaker speak --voice "Rachel" "Hi"       # voice by name or ElevenLabs voice ID
botspeaker speak --loop "On a cycle"         # repeat until `botspeaker stop`
botspeaker speak --repeat 3 --wait "Thrice"  # play a fixed number of times
echo "long text" | botspeaker speak          # text from stdin (or --file path, --file -)
botspeaker play-audio --wait clip.mp3        # play a recorded file (mp3, wav, m4a, aiff, flac, ...) locally
botspeaker play-audio --loop jingle.wav      # same --loop / --repeat N as speak
botspeaker targets                           # "local" plus attendees paired to the meeting this machine hosts
botspeaker speak --target "Sihao's Mac" --wait "Hello from the host"
botspeaker requests                          # recent requests with status
botspeaker wait <request-id>                 # follow a request started without --wait
botspeaker stop [<request-id>]               # cancel one request, or all queued/playing speech
botspeaker voices [--refresh] [--select NAME]
botspeaker models                           # show available models and the saved selection
botspeaker models --select eleven_flash_v2  # Flash v2 (English-only, default)
botspeaker models --select eleven_v3        # Eleven v3, with expressive audio tags
botspeaker outputs [--select "BlackHole 2ch"]
botspeaker host [--name NAME]                # start hosting; prints the pairing code
botspeaker join ABC123 [--name NAME]         # pair this machine to a host
botspeaker leave
botspeaker upgrade [--check]                 # upgrade the standalone CLI
botspeaker --version
```

Add `--json` after the subcommand for machine-readable output. Exit codes:
`0` success, `1` the app rejected or failed the request, `2` the app could not
be launched or reached, or the token was rejected.

On macOS, **Settings → ElevenLabs** puts the saved model and default voice
together. The **Speak** page shows the active model and lets you override the
voice for one request. Both models use the same account voice list; changing
models keeps your selected voice, although its delivery can differ. For scripts,
prefer exact voice IDs; ambiguous names are rejected. See the
[voice and model guide](docs/cli.md#voices-and-models-on-macos).

### Remote playback

The CLI and the app share one session, so `botspeaker host` shows the pairing
code in the app and a machine that joins through **Remote Mode** appears in
`botspeaker targets`. Only the host can target other machines. Remote requests
travel through Firestore, play with the attendee's own ElevenLabs key and
output, and report `completed`, `failed`, or `cancelled` back to the host.
Audio files play locally only. A scripted meeting turn always preempts ad hoc
speech on the machine it is assigned to.

### HTTP API and agents

The app exposes the same functions over a loopback HTTP API. The URL and
per-launch bearer token are in `control.json` under the app's Application
Support folder on macOS or `%APPDATA%\BotSpeaker` on Windows. Endpoints
include `/v1/status`, `/v1/speak`, `/v1/play-audio`, `/v1/speech`, `/v1/targets`,
`/v1/voices`, `/v1/outputs`, and `/v1/session`.

`cli/skills/botspeaker/SKILL.md` is a drop-in skill for Claude Code and similar
agents; copy or symlink it to `~/.claude/skills/botspeaker/SKILL.md`. The
[CLI guide](docs/cli.md) has the full flag list, environment overrides, the
request JSON shape, every endpoint, and the Windows differences.


### Recall CLI

These commands are available in Windows 0.5.5 and the current macOS source.
Use `botspeaker` in place of `botspeaker-cli` on macOS. All Recall
commands return JSON. Replace the example IDs with values returned by `add`,
`prepare`, or `meeting-create`.

```powershell
botspeaker-cli recall configure --region us-east-1
Get-Clipboard -Raw | botspeaker-cli recall add --file - --name "Speaker One"
botspeaker-cli recall add "123 456 789 012 3" --passcode CODE --name "Speaker Two"
botspeaker-cli recall list --meeting "123 456 789 012 3"
botspeaker-cli recall speak BOT_ID "Hello" --voice VOICE_ID --wait
botspeaker-cli recall prepare BOT_ID "Next turn" --voice VOICE_ID --wait
botspeaker-cli recall dispatch JOB_ID --wait
botspeaker-cli recall remove-all --meeting "123 456 789 012 3"
```

For multi-speaker playback, create a JSON plan with a `turns` array containing
`botId`, `voice`, and `text` for each turn:

```powershell
botspeaker-cli recall meeting-create --file plan.json
botspeaker-cli recall meeting-start PLAN_ID
botspeaker-cli recall meeting-status PLAN_ID
botspeaker-cli recall meeting-skip PLAN_ID
botspeaker-cli recall meeting-stop PLAN_ID
botspeaker-cli recall meeting-wait PLAN_ID --timeout 600
```

CLI plans are separate from sidebar orchestration sessions. They survive CLI
exit but reset when the app quits. Stop leaves bots joined; `remove-all` requires
a meeting scope and makes its unfinished bots leave. Wait timeouts leave work
running in the app, and cancellation cannot retract audio already sent.
See the [Recall CLI reference](docs/recall.md#recall-cli-controls)
for the plan format, status fields, and failure handling.

## Project structure

```text
BotSpeaker/
├── README.md
├── cli/                        # `botspeaker` command-line tool (macOS) and the agent skill
├── docs/                       # CLI, orchestration guides
├── scripts/                    # Release packaging, publishing, CLI install
├── macOS/
│   ├── BotSpeaker.xcodeproj/
│   └── BotSpeaker/
└── Windows/
    ├── README.md
    ├── BotSpeaker/             # WPF app
    └── BotSpeakerCli/          # `botspeaker-cli.exe` command-line tool (Windows)
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

The script verifies matching app and CLI versions, publishes self-contained win-x64 builds, and creates portable ZIPs/checksums plus a Velopack installer, full update package, and feed under a fresh `dist/windows-<version>-<id>/` directory. The installer bundles the matching CLI. Pass `-BuildOnly` to build locally without publishing or changing tags; this also permits a dirty working tree. Pass `-CertificateThumbprint <sha1>` instead of `-AllowUnsigned` to sign the app, CLI, and Velopack installer/updater binaries; unsigned builds require the explicit flag. Publishing refuses a dirty working tree, a tag that does not match `HEAD`, and existing asset names. The update feed uploads after its packages. Either platform can create the shared release first; the other adds its artifacts afterward. See [Windows installation and update verification](Windows/README.md#install-and-update) for migration and testing.

The macOS publisher also builds, signs, and attaches the `botspeaker` CLI binary with its checksum, signs the DMG with BotSpeaker's Sparkle EdDSA key, and attaches `appcast.xml` to the GitHub Release. The Sparkle private key is stored in the login Keychain under Sparkle's default account (`ed25519`); the key was rotated for 0.2.0, so 0.1.x installs must update manually; preserve or securely export this key before moving release production to another Mac. Sparkle fetches updates anonymously from GitHub Releases, which works because the repository and its release assets are public.
