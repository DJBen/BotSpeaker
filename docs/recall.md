# Recall bot control

Use `botspeaker-cli recall` on Windows or `botspeaker recall` on macOS. The CLI
talks to the local app, which owns bot requests and speech schedules. The Recall
Bot sidebar entry appears before Remote Mode; the same controls are available
there without a terminal.

## Configure

```sh
botspeaker recall configure --region us-east-1
```

The app reads `RECALL_API_KEY`, with `RECALL_AI_API_KEY` as a compatibility alias.
Windows checks both the current process and persistent user environment. macOS
reads the app's launch environment; the CLI can import its shell environment
into the app with `recall configure`. Finder-launched apps do not generally inherit
shell exports. Keys entered through the GUI or CLI are saved in Windows DPAPI or
macOS Keychain, and saved keys take precedence over environment values.

Without an environment key, `configure` accepts a hidden interactive prompt or
`--key-stdin` for piped input. Keys never appear in status responses. Choose the
region belonging to your Recall workspace: `us-east-1` (default), `us-west-2`,
`eu-central-1`, or `ap-northeast-1`. A read-only API call validates the key and
region before saving.

Recall is optional during onboarding. With no configured key, the Recall page
shows setup before its control plane. When either environment variable or a saved
key is present, it hides the key/region form and opens the controls directly.
Both fields remain available under **Settings → Recall**.

## Bots and status

```sh
botspeaker recall list --json
botspeaker recall status --json
botspeaker recall add "https://teams.live.com/meet/..." --name "Speaker One"
botspeaker recall remove BOT_ID
```

`list` returns every paginated bot with its latest status and meeting ID.
The GUI starts with a meeting setup screen. Enter a URL or ID and select Continue;
The last confirmed meeting is remembered and prefilled on the next app launch.
Change meeting returns to setup. Add bot opens a name prompt, alongside Refresh
and Remove in the action row.
The GUI uses a compact grid scoped to the selected meeting URL or ID and hides
bots whose status is `done`. Known meeting IDs can also add bots: the app resolves their join URL and passcode
from Recall history, including completed bots. An unknown ID needs its invite link
once; the app does not guess the platform or passcode.
Choose an ElevenLabs voice from the dropdown; selected bots receive an editable
greeting with a random three-paragraph sample. Edited drafts are retained per bot while
the view is open. Use Now or the local date/time selector to dispatch speech, and
the repeat counter or adjacent Loop toggle to repeat it. `status` returns local
configuration and speech jobs. The GUI refreshes bots every 10 seconds while its meeting controls are open,
and supports manual refresh. Overlapping requests are skipped. Bots must be admitted from the
meeting lobby where required. `remove` asks the bot to leave and cancels its local
pending speech jobs. It does not delete recordings or meeting history.

## Speech

```sh
botspeaker recall speak BOT_ID "Hello from Speaker One"
botspeaker recall speak BOT_ID "First turn" --at +30
botspeaker recall speak OTHER_BOT_ID "Second turn" --at +45
botspeaker recall speak BOT_ID "Scheduled announcement" --at "2027-01-01T09:00:00-08:00"
botspeaker recall speak BOT_ID --file script.txt --voice ELEVENLABS_VOICE_ID --repeat 3 --interval 5
botspeaker recall speak BOT_ID "Repeating announcement" --loop --interval 10
botspeaker recall cancel JOB_ID
```

Replace the timestamp example with a future time within 30 days. `--at` accepts
`now` (default), `+SECONDS` relative to submission, or ISO 8601 with a timezone.
`--file -` reads speech text from stdin. Voice IDs override the selected app voice;
generation uses the existing ElevenLabs key, selected model, and audio cache.
Each job generates its MP3 once, before the scheduled dispatch, and reuses it for
repeats. `--interval` adds silence after the estimated clip duration and a two-second
buffer. Use either `--repeat N` (total sends) or `--loop` (until cancelled).

Jobs for one bot dispatch in due-time order, with submission order breaking ties;
other bots can run concurrently. A looping job holds that bot's queue until
cancelled. For multiple bots speaking in turns, give each a distinct timestamp
and leave enough time for the previous clip and Recall's playback latency.

### Timing and lifecycle

- Keep the app running and the computer awake. CLI exit is safe, but schedules
  are in memory and do not survive app quit/restart. Sleep, slow synthesis, or an
  occupied bot queue can delay dispatch; overdue pending jobs run when available.
- Times control **API dispatch**, not exact audible playback. Recall's clip API
  has no playback-ended acknowledgement. `finished_dispatching` means all API
  sends succeeded and estimated playback time elapsed, not verified meeting audio.
- Cancellation prevents future sends. It cannot retract an accepted clip; an
  interrupted HTTP request may already have reached Recall. Mutating requests
  are not automatically retried to avoid duplicate bots or duplicate speech.
- Bots created here enable automatic audio output with a short silent MP3.
  Existing bots need compatible `automatic_audio_output` configuration and must
  be in a state that permits audio output.
- Clips are limited to 1,835,008 base64 characters (about 85 seconds at the current
  ElevenLabs output bitrate). Split longer speech into shorter jobs.

This feature is a controller for prerecorded meeting announcements/tests. For
continuous conversational agents or precise playback feedback, use Recall's
[Output Media](https://docs.recall.ai/docs/stream-media) with a hosted player and
completion callbacks. The short-clip implementation uses
[Output Audio](https://docs.recall.ai/reference/bot_output_audio_create).

## Local control API

All routes use the existing authenticated loopback control server:
`POST /v1/recall/{configure|status|list|add|remove|speak|cancel}`.

`speak` takes `{botId, text, at?, voice?, loop?, repeat?, interval?}` and returns
`{ok, job}`. `cancel` takes `{id}`; `remove` takes `{botId}`; `add` takes
`{meetingUrl, name?}`; `configure` takes `{apiKey?, region?}`. Status includes
`configured`, `region`, and `jobs`. CLI output is JSON for all Recall actions.

## Validation

```powershell
dotnet build Windows/BotSpeaker/BotSpeaker.csproj
dotnet build Windows/BotSpeakerCli/BotSpeakerCli.csproj
dotnet run --project Windows/BotSpeaker.RecallTests/BotSpeaker.RecallTests.csproj
```

The tests replace paid speech generation, credential storage, and remote HTTP.
They exercise the production Windows controller's pagination, validation,
ordering, repeats, cancellation, removal, and error handling.

## Orchestrated meetings

Choose **Host in Recall.ai** beside **Host this transcript** on an orchestrated script. The flow remembers the meeting link, then offers one bot per configured speaker. Set names and voices before adding bots; each bot joins with that speaker's name. Remove and re-add a bot to change its meeting display name. Bot status refreshes every ten seconds while the setup is visible.

Choose **Arrange turns** to add any missing speaker bots automatically and open the turn preview. Existing bots are reused; if an addition fails, successful additions are retained for retry. The preview shows each bot status and lets you edit speech, assign speakers, reorder, add, or remove turns. **Start meeting** requires all bots to be in `in_call_recording`. Turns dispatch sequentially, advancing after the previous clip's measured duration plus a two-second pause. This is estimated playback pacing, not a remote playback acknowledgment. There is no schedule/repeat UI in this flow. A failed turn stops subsequent turns. **Stop meeting** cancels the current local speech job and remaining turns; audio already sent may finish. Bots stay in the call until removed from **Back to bots**.

Navigation preserves the current plan and active run for this app session. Return via **Host in Recall.ai** on an orchestrated script. To choose a different script or meeting, remove the speaker bots, choose **Change meeting**, then **Back to scripts** (Back on macOS). Plans and active speech do not survive app shutdown.

During a Recall meeting, **Skip turn** cancels the current local job and advances to the next turn. It does not stop the run. Audio already accepted by Recall cannot be retracted and may finish over the next speaker. Individual Add bot buttons are omitted from orchestration setup; **Arrange turns** adds all missing bots, while Remove bot remains available for bots already added.

Step 2 also offers **Remove all bots** for all speaker bots in the current orchestration. Successful removals clear their mappings; failures remain available for retry. Names, voices, and turns are retained, and **Arrange turns** can add the bots again.
