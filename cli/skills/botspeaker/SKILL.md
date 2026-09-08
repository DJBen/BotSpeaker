---
name: botspeaker
description: Play spoken text through BotSpeaker on this Mac or on a paired remote Mac using the `botspeaker` CLI. Use when asked to say, speak, announce, or play audio into a meeting or virtual audio device.
---

# BotSpeaker CLI

`botspeaker` talks to the running BotSpeaker app. It synthesizes text with
ElevenLabs and plays it through the app's configured output (usually a virtual
audio device that feeds a meeting).

## Check first

```bash
botspeaker status --json
```

- The CLI launches BotSpeaker in the background if it is not running. Exit code 2 means the app is not installed or did not come up; ask the user to install or open BotSpeaker.
- If `botspeaker` is missing, install it with `curl -fsSL https://raw.githubusercontent.com/DJBen/BotSpeaker/main/scripts/install-cli.sh | bash`. If a command prints a `note:` that the app is newer than the CLI, run `botspeaker upgrade`.
- `apiKeyConfigured` must be true and `output` non-null, otherwise ask the user to finish Settings.
- `session` shows whether this Mac hosts (`"mode": "host"`) or joined a meeting; `attendees` lists paired Macs.

## Speak on this Mac

```bash
botspeaker speak --wait "Text to say"
printf '%s' "$LONG_TEXT" | botspeaker speak --wait --file -
```

`--wait` blocks until playback ends and exits 0 only when the status is `completed`.
Without `--wait` the command returns immediately with a request ID; follow it with `botspeaker wait ID`.

## Speak on a paired remote Mac (host only)

```bash
botspeaker targets                     # names and IDs of paired attendees
botspeaker speak --target "Attendee name" --wait "Text to say"
```

If `targets` only lists `local`, this Mac is not hosting or nobody has paired:
`botspeaker host` prints a pairing code; the other Mac runs `botspeaker join CODE`
or enters the code in the app's Remote Mode. CLI and app share the same session,
so a meeting hosted from the CLI is visible in the app and vice versa.

## Other controls

```bash
botspeaker voices                      # list; pick with --voice NAME on speak, or --select NAME to change the default
botspeaker outputs --select "BlackHole 2ch"
botspeaker requests                    # status of recent requests
botspeaker stop                        # cancel everything queued or playing
```

## Rules of thumb

- Keep each request to what one person would say in one go; queue several requests for a dialogue.
- A scripted meeting turn preempts ad hoc speech; if a request ends `cancelled` with a "meeting turn" error, wait and retry.
- Add `--json` after the subcommand when you need to parse the output. `speak --json` returns `{"ok": true, "request": {"id": ..., "status": ...}}`; `requests --json` returns `{"ok": true, "requests": [...]}`.
