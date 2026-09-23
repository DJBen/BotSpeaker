# BotSpeaker CLI and control API

The `botspeaker` command lets a person or an LLM agent drive the running
BotSpeaker app from a shell: play arbitrary text on this machine, play it on
any Mac or Windows PC paired to a meeting this machine hosts, pick voices and
outputs, and start or join meetings. Everything is also reachable with plain
`curl`. The CLI exists for both platforms with the same commands, flags, JSON
output, and exit codes; this guide is written from the Mac, and the
[Windows section](#windows) lists what differs there.

Ad hoc speech is independent of the orchestrated meeting script. It uses the
same ElevenLabs synthesis, cache, and virtual-audio output as the composer, so
once a machine is configured for meetings it needs nothing extra.

## Install and update

Each GitHub release ships a signed, notarized universal `botspeaker` binary.
One line installs it, or replaces whatever version is already there:

```sh
curl -fsSL https://raw.githubusercontent.com/DJBen/BotSpeaker/main/scripts/install-cli.sh | bash
```

It goes to `/usr/local/bin` when that is writable, otherwise `~/.local/bin`.
Options: `--dest DIR`, `--version 0.4.0`, and `--source` (build `cli/` from a
checkout; also the automatic fallback when a release has no CLI asset).

The app keeps itself current through Sparkle, but the CLI is a separate file.
Whenever the running app is newer than the CLI, every command prints
`note: BotSpeaker app is X but this CLI is Y. Run \`botspeaker upgrade\`.` on
stderr (silence it with `BOTSPEAKER_NO_UPGRADE_HINT=1`). `botspeaker upgrade`
downloads the matching release, verifies its SHA-256, and swaps the binary in
place; `botspeaker upgrade --check` only reports, and `--version` prints the
installed version.

```sh
botspeaker --help
```

The CLI is a thin client: synthesis, playback, and the Firestore session all
live in the BotSpeaker app, so the app must be installed on every machine that
plays audio. When the app is not running, the CLI launches it in the
background (without stealing focus) and waits up to 20 seconds for it to come
up. Set `BOTSPEAKER_NO_LAUNCH=1` to fail with exit code 2 instead, or
`BOTSPEAKER_APP=/path/to/BotSpeaker.app` to launch a specific copy. It finds
the running app through a discovery file the app writes at launch:

```
~/Library/Containers/ai.DJBen.2.BotSpeaker/Data/Library/Application Support/BotSpeaker/control.json
```

The file holds the loopback URL, the per-launch bearer token, the app's pid,
and version. Override discovery with `BOTSPEAKER_CONTROL_URL` plus
`BOTSPEAKER_TOKEN`, or point `BOTSPEAKER_CONTROL_FILE` at another file. Set
the `controlPort` user default to change the preferred port (`47311`); when
that port is busy the app falls back to an ephemeral port and the discovery
file reflects it.

## Everyday commands

```sh
botspeaker status                          # app, output, voice, session, active speech
botspeaker speak "Hello from this Mac"     # play locally, return immediately with a request ID
botspeaker speak --wait "Hello"            # block until playback finishes; exit 0 only on success
botspeaker speak --voice "Rachel" "Hi"     # voice by name or ElevenLabs voice ID
botspeaker models                         # list models; * marks the saved selection
botspeaker models --select eleven_flash_v2 # save Flash v2 (the default)
botspeaker models --select eleven_v3       # save Eleven v3 for expressive audio tags
botspeaker speak --loop "On a cycle"        # repeat until `botspeaker stop`
botspeaker speak --repeat 3 --wait "Thrice" # play a fixed number of times
echo "long text" | botspeaker speak        # text from stdin (or --file path, --file -)
botspeaker play-audio --wait clip.mp3      # play a recorded file (mp3, wav, m4a, aiff, caf, flac, ...) on this Mac
botspeaker play-audio --loop jingle.wav    # same --loop / --repeat N as speak; stop with `botspeaker stop`
botspeaker targets                         # "local" plus attendees paired to the meeting this Mac hosts
botspeaker speak --target "Sihao's Mac" --wait "Hello from the host"
botspeaker requests                        # recent requests with status
botspeaker wait <request-id>               # follow a request started without --wait
botspeaker stop [<request-id>]             # cancel one request, or all queued/playing speech
botspeaker voices [--refresh] [--select NAME]
botspeaker outputs [--select "BlackHole 2ch"]
botspeaker host [--name NAME]              # start hosting; prints the pairing code
botspeaker join ABC123 [--name NAME]       # pair this Mac to a host
botspeaker leave
```

Add `--json` after the subcommand for machine-readable output (for example
`botspeaker speak --json "text"`, which returns `{"ok": true, "request": {"id":
"...", "status": "...", ...}}`). Exit codes: `0` success, `1` the app rejected
or failed the request, `2` the app could not be launched or reached, or the
token was rejected.

### Voices and models on macOS

`eleven_flash_v2` is Flash v2 (English-only), not Multilingual v2 or Flash v2.5.
Flash v2 and Eleven v3 use the same account voice catalog and voice IDs. Changing
the model preserves your selected voice; delivery and clone fidelity can differ.
ElevenLabs notes that professional voice clones may be less faithful with v3.
The `/v2/voices` URL is the voice-list API version, not a filter for v2 speech.
See [ElevenLabs voices](https://elevenlabs.io/docs/overview/capabilities/voices)
and [v3 guidance](https://elevenlabs.io/docs/overview/capabilities/text-to-speech/best-practices).

In **Settings → ElevenLabs**, select the default model and voice together.
The **Speak** page's voice picker overrides the voice for that request; its
Default option follows Settings. `botspeaker voices --select NAME_OR_ID` changes
the same saved default, while `botspeaker speak --voice NAME_OR_ID "text"` changes
only that request. `botspeaker status` and `botspeaker voices` show the local
model. Exact voice IDs are safest in scripts: an ambiguous name returns
`ambiguous_voice` rather than picking the first match. Combine `--refresh --select`
to refresh first; a failed refresh prevents selection.

Remote attendees use their own saved model, API key, and default voice. A host's
voice list belongs to the host's account, so an override may not be available to
the attendee. Omitting `--voice` uses the attendee's own default.

Run `./scripts/test-macos-voices.sh` for voice resolution, catalog pagination,
and CLI regression tests without using an ElevenLabs account.

### Remote playback

The CLI and the app share one session. `botspeaker host` runs the same code
path as **Host Meeting**, so the pairing code shows up in the app's menu bar
window, and a Mac that joins through **Remote Mode** appears in `botspeaker
targets`. Any mix works: host from the CLI and join from the app, or the other
way round.

1. On the host Mac: `botspeaker host` (or click **Host Meeting** in the app).
2. On each remote Mac: `botspeaker join CODE` (or use **Remote Mode**).
3. On the host: `botspeaker targets` lists the attendees; `botspeaker speak
   --target NAME --wait "text"` plays on that attendee and reports
   `completed`, `failed` (with the attendee's error), or `cancelled`.

Remote requests are written to Firestore under the meeting room, claimed by the
targeted attendee, played with the attendee's own ElevenLabs key and output,
and their status is mirrored back to the host. Only the host can target other
machines; an attendee can still play locally with `botspeaker speak`. Windows
attendees are targeted the same way; they pick requests up on their next poll
(about 1.5 seconds) and use the same `--loop` and `--repeat` semantics.

### Playing audio files

`botspeaker play-audio FILE` plays a recording instead of synthesizing text.
The CLI uploads the file to the app (the app is sandboxed and cannot open
arbitrary paths), the app stages it in its container, and the request joins
the same queue as spoken text: `--wait`, `--loop`, `--repeat N`,
`botspeaker requests`, `botspeaker wait ID`, and `botspeaker stop` all apply,
and a scripted meeting turn preempts it. No ElevenLabs key is needed. Files up
to 48 MB in any format Core Audio decodes (mp3, wav, m4a, aac, aiff, caf,
flac, ogg, opus) are accepted. Audio files play on this Mac only; `--target`
is not available because the recording is never sent through Firestore.

### The same queue in the app

The **Speak** entry at the top of the script sidebar is the GUI for this
queue, on macOS and Windows alike. It offers the same text box, target (this
machine or a paired attendee while hosting), voice choice, and a **Loop until
stopped** checkbox (`--loop`), and lists recent requests from both the app and
the CLI with their pass count and a cancel control. A paired attendee sees the
same box inside Remote Mode for local playback. While hosting, pressing Play on
a script in the composer also goes through the queue, so scripted meeting turns
keep priority.

### Interaction with orchestrated meetings

Ad hoc speech shares the output with the meeting script. A scripted turn
assigned to a machine always wins: it cancels any ad hoc request playing there
(status `cancelled`, error notes the turn). While a scripted turn is playing,
new ad hoc requests wait in the queue and start when the turn ends. Stopping
playback in the app or pressing Play on a script also cancels the active ad hoc
request.

## HTTP API

Base URL and token come from `control.json`. Send
`Authorization: Bearer <token>` (or `X-BotSpeaker-Token`). Every response is
JSON with an `ok` boolean; errors carry `error.code` and `error.message`.

| Method and path | Purpose |
| --- | --- |
| `GET /health` | Liveness; no token required. |
| `GET /v1/status` | App, output, voice, player, session, active speech. |
| `GET /v1/targets` | `local` plus attendees (host only lists attendees). |
| `GET /v1/outputs`, `POST /v1/outputs/select {uid\|name}` | Audio outputs on this Mac. |
| `GET /v1/voices?refresh=1`, `POST /v1/voices/select {id\|name}` | ElevenLabs voices. |
| `GET /v1/models`, `POST /v1/models/select {model}` | List model IDs or save `eleven_flash_v2` / `eleven_v3` as the local app's model. |
| `POST /v1/speak {text, target?, voice?, loop?, repeat?, wait?, timeout?}` | Queue speech. `loop: true` repeats until cancelled; `repeat: n` plays `n` times. `202` with the request when not waiting, `200` with the final request when waiting. |
| `POST /v1/play-audio {audio, filename, loop?, repeat?, wait?, timeout?}` | Play a recorded file on this Mac. `audio` is the file's bytes as base64, `filename` supplies the extension. Same response shape as `/v1/speak`; the request carries `"kind": "audio"` and `audioFile`. |
| `GET /v1/speech` | Recent requests. |
| `GET /v1/speech/{id}?wait=1&timeout=600` | One request; long-polls until terminal when `wait=1`. |
| `POST /v1/speech/{id}/cancel`, `POST /v1/speech/cancel-all` (alias `POST /v1/stop`) | Cancel. |
| `GET /v1/session`, `POST /v1/session/host {speakerName?}`, `POST /v1/session/join {code, speakerName?}`, `POST /v1/session/leave` | Meeting membership. |

Example:

```sh
cfg=~/Library/Containers/ai.DJBen.2.BotSpeaker/Data/Library/Application\ Support/BotSpeaker/control.json
url=$(python3 -c "import json;print(json.load(open('$cfg'))['url'])")
tok=$(python3 -c "import json;print(json.load(open('$cfg'))['token'])")
curl -s -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
  -d '{"text":"Hello","target":"local","wait":true}' "$url/v1/speak"
```

A speech request looks like:

```json
{
  "id": "local-3f0e…",
  "target": "local",
  "targetName": "This Mac",
  "remote": false,
  "text": "Hello",
  "voiceID": null,
  "voiceName": "Rachel",
  "status": "completed",
  "createdAt": "2026-09-08T18:20:11Z",
  "startedAt": "2026-09-08T18:20:12Z",
  "endedAt": "2026-09-08T18:20:14Z",
  "error": null,
  "loop": false,
  "cycles": 1,
  "completedCycles": 1
}
```

Statuses move `queued → preparing → speaking → completed`, or end in `failed`
or `cancelled`. A looping request (`loop: true`, `cycles: null`) stays
`speaking` and replays the same audio until it is cancelled, so `--wait` on it
only returns when it is stopped or the timeout passes; a counted repeat
(`cycles: n`) completes after `n` passes. `completedCycles` counts passes on
the Mac doing the playing, so the host sees `0` for a remote request.

## Windows

The Windows app (0.4.1 Windows builds published from September 9, 2026, and later) runs the same loopback control API, and
`botspeaker-cli.exe` is the same CLI built for Windows
(`Windows/BotSpeakerCli`, plain .NET, no dependencies). Install or update it
from PowerShell:

```powershell
irm https://raw.githubusercontent.com/DJBen/BotSpeaker/main/scripts/install-cli.ps1 | iex
```

The Windows app installer adds its bundled CLI directory to the front of your
user PATH, keeps it there during updates, and removes that entry on uninstall.
Open a new terminal after installation. The PowerShell CLI installer also
updates the current terminal's PATH and prefers the installed app's bundled
CLI, so app updates keep both versions together. Older copies are left in
place; `Get-Command botspeaker-cli -All` lists them. A machine-level PATH entry
can still take precedence over user PATH in a new terminal.

```powershell
botspeaker-cli --version
botspeaker-cli upgrade --check --json  # latest release, running version, executable path
botspeaker-cli upgrade                # self-update a standalone published CLI
```

Standalone upgrades verify the release ZIP's SHA-256 checksum and launch a
hidden worker that replaces the invoked executable after the command exits.
They retain a `.previous` backup and write success or failure to
`botspeaker-cli.exe.update.log` beside the CLI; `--version` verifies the result.
Installer-managed CLIs
update with the app: `upgrade` explains how to use **Check for Updates** and
**Restart to update** from the tray menu. Checks require access to GitHub;
normal playback commands do not query GitHub. A newer running app also produces
an upgrade hint on stderr, including the CLI's path to help find stale copies.

If the running Windows app's discovery file is deleted, it recreates it within
two seconds, keeping the same port and token. The CLI briefly waits for this
repair before attempting to launch the app. Discovery failures include the
searched paths and recovery steps.

Differences from the Mac:

- The command is `botspeaker-cli`, not `botspeaker`: on Windows the app is
  `BotSpeaker.exe`, and file names are case-insensitive, so the two could not
  share a folder or a name on PATH. Every subcommand and flag in this guide
  works the same after that substitution.
- The discovery file is `%APPDATA%\BotSpeaker\control.json`; the preferred
  port comes from `ControlPort` in `settings.json`. The same
  `BOTSPEAKER_CONTROL_URL`, `BOTSPEAKER_TOKEN`, `BOTSPEAKER_CONTROL_FILE`,
  `BOTSPEAKER_NO_LAUNCH`, and `BOTSPEAKER_APP` overrides apply.
- When the app is not running, the CLI starts `BotSpeaker.exe --background`
  (tray only, no focus) from `BOTSPEAKER_APP`, the app it last talked to
  (remembered in `%APPDATA%\BotSpeaker\cli.json`), a `BotSpeaker.exe` beside
  the CLI, `%LOCALAPPDATA%\Programs\BotSpeaker`, or the Desktop, in that
  order.
- `upgrade` (also `self-update`) supports `--check` and `--json`; it updates
  standalone release binaries, while installer-managed CLIs update with the app.
- `play-audio` also accepts `.wma`; `.caf` is Mac-only. Local targets are
  reported as "This PC".
- A Windows attendee sees host requests on its next poll, about 1.5 seconds
  after they are queued.

## Agent usage

`cli/skills/botspeaker/SKILL.md` is a drop-in skill for Claude Code and similar
agents. Copy or symlink it into the agent's skills directory
(for Claude Code: `~/.claude/skills/botspeaker/SKILL.md`).

## Recall meeting bots

Use `botspeaker recall` (`botspeaker-cli recall` on Windows) to configure Recall,
list/add/remove bots, schedule ElevenLabs speech, repeat/loop, and cancel jobs.
Both platforms support invitation/passcode input, meeting-scoped removal,
`prepare`/`dispatch`, job waits, and JSON meeting plans with start/status/skip/stop
controls. These extended controls require the current macOS source or Windows
0.5.5 and matching CLI builds.
See [Recall control](recall.md) for setup, commands, scheduling semantics, and limits.
