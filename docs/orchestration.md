# Meeting orchestration

BotSpeaker's meeting orchestrator coordinates multiple laptops so their
virtual microphones speak one at a time without someone pressing Space on every
machine. The first machine is the host and the remaining machines join as remote
speakers with a short-lived six-character code. macOS and Windows clients speak
the same protocol and interoperate freely in one session — either platform can
host.

## Run a coordinated meeting

Every machine needs BotSpeaker, an ElevenLabs API key, and a virtual output
device (BlackHole 2ch on macOS, VB-Audio Virtual Cable on Windows). The host
selects the shared meeting script and the ElevenLabs voice for every speaker.

1. On the host, choose an entry under **Orchestrated meeting** in the script
   sidebar. Templates may require different numbers of paired clients.
2. Fill in every speaker name, review the distinct default voices (the
   three-person incident review starts male, female, male), and review the
   resolved script preview.
3. Choose **Prepare Meeting**. BotSpeaker creates the room immediately. On
   macOS, the lobby pushes into the main detail pane and temporarily disables
   the script sidebar.
4. On every other machine, select the same orchestrated template and choose
   **Join Meeting** beside **Prepare Meeting**. Enter the host's pairing code in
   the compact prompt and confirm **Join**.
5. On the host, arrange the devices. Their order maps to `{{speaker_1}}`,
   `{{speaker_2}}`, and so on.
6. Choose **Prepare Speakers** to distribute the resolved script and the host's
   per-speaker voice assignments.
7. Wait for every assigned client to report all paragraphs ready, then choose
   **Start Meeting**.

Preparing the meeting writes the ordered, resolved turn plan to the room. Each
client downloads the turns assigned to its anonymous participant ID, generates
and caches every paragraph without loading the audio player, and reports
readiness to the host. The Start button unlocks only after every assigned
speaker is fully prepared.

The host script is an explicit timeline: every non-empty paragraph must start
with `{{speaker_N}}:`. The prefix selects the client in that numbered host
order; placeholder references inside the paragraph are replaced with paired
speaker names before distribution. This allows natural short replies,
agreement, and longer statements without forcing a round-robin order. Local
play, script-selection, and Space-key controls are locked while paired.

Before the meeting starts, every client prepares all of its assigned paragraphs.
Preparation uses the exact same cache key, chunking, voice, model, and context as
playback, so an unchanged assignment is reused across meetings without another
ElevenLabs request. Preparation never calls the audio player, so cached speech
cannot start before the host assigns its turn. Failures appear in the speaker
list and retry after a short delay.

The host can pause or resume all clients with the Play/Pause control or Space,
skip the current turn, and stop the session. A client
reports completion only after its local audio player reaches the end of the
assigned audio, so slow ElevenLabs generation does not advance the next speaker
early.

On macOS, **Leave**, **Disconnect**, or **Done** returns to the selected
orchestrated-meeting configuration in the main detail pane and unlocks the
sidebar. Closing the main window performs the same session cleanup first.

## Timestamped transcript

After a meeting completes or is stopped, choose **Export Timestamped JSON…** on
the host. The schema includes:

- the session ID, pairing code, status, and session start/end time;
- every speaker's anonymous session ID, name, script title, and voice name;
- every turn's speaker, `speakerSlot`, per-speaker paragraph index, spoken text,
  and outcome;
- playback start/end timestamps reported by the speaker's machine; and
- corresponding server-received timestamps for clock-independent auditing.

Dates use ISO 8601. `durationMilliseconds` is measured from the effective
playback start and end and therefore includes a host-initiated pause. Failed,
skipped, and stopped turns retain their terminal status and error when present.

## Cloud design

Coordination uses Firebase Authentication and Cloud Firestore in Google Cloud
project `bot-speaker-1` (`516080606747`). Clients authenticate anonymously and
observe the room, participant, and turn documents — the macOS app through the
Firebase SDK's real-time snapshot listeners, and the Windows app by polling the
same documents over the Firestore REST API on a short interval. Both clients
issue identical writes (including `REQUEST_TIME` server-timestamp transforms),
so one ruleset governs both.

Because Firestore bills one read per document returned, a poller that re-listed
every participant and turn each tick would burn through the project's read
quota in minutes on a long meeting. Instead, every state-changing commit on
either platform also touches an `activityAt` server-timestamp marker on the
room document — the one room field the rules allow a non-host participant to
update. Each poll tick then costs a single room read, and the collections are
re-listed only when the marker moves, plus a 30-second full resync that keeps
heartbeat freshness visible. Heartbeats deliberately do not move the marker.
Audio and ElevenLabs keys never leave the local client. The host's shared script
and resolved turn text are stored in the Firestore session room so remote
clients can prepare before their turn; do not place secrets in an orchestrated
script.

The host is authoritative for room state and turn advancement. Security rules
limit room reads to paired participants, prohibit pairing-code enumeration, let
only the host change the queue, and let a client update only the turn assigned
to its anonymous identity. Pairing expires after four hours and is closed when
the meeting starts.

Relevant deployment files are:

- `firebase.json` — Firebase/Firestore project configuration;
- `.firebaserc` — default project alias; and
- `firestore.rules` — access-control rules;
- `firestore.indexes.json` — composite indexes the cleanup job queries; and
- `functions/` — the scheduled data-retention job.

To deploy a changed ruleset from an authenticated development machine:

```sh
firebase deploy --only firestore:rules --project bot-speaker-1
```

## Data retention

Neither client deletes an orchestration room when a meeting ends, so rooms —
including the host's resolved script text — and their `participants`, `turns`,
and per-turn `events` subcollections would otherwise live forever. The
`orchestrationCleanup` Cloud Function in `functions/index.js` runs every third
day at 04:00 America/Los_Angeles (`0 4 */3 * *`, so the 1st, 4th, 7th and so on
of each month) and removes:

- rooms whose status is `completed` or `stopped` and whose `activityAt` is more
  than 24 hours old;
- rooms of any status untouched for more than 72 hours, which covers abandoned
  lobbies and sessions whose host crashed mid-meeting and left a non-terminal
  status behind; and
- pairing codes more than an hour past their four-hour expiry, plus any pairing
  still pointing at a room the same run deletes.

Rooms are removed with the Admin SDK's `recursiveDelete`, so subcollections go
with them rather than being orphaned. The status and idle queries key off
`activityAt`, the marker every state-changing commit already touches, so an
in-progress meeting is never collected mid-session. Because Firestore cannot
match a missing field, a third pass sweeps by `createdAt` to reach rooms written
before `activityAt` existed and keeps only those that still lack a fresh marker
— an old room that is genuinely still in use survives it.

Deletion happens on the first run after a record crosses its window, not the
moment it crosses. On a three-day cadence a finished room lives up to four days
and an idle room up to six, so export a transcript within a day or two of the
meeting rather than relying on the room still being there. Each run handles at
most 200 rooms and 500 pairings and logs the counts; a larger backlog drains
over successive runs, which at this cadence is 200 rooms every three days.

The retention windows and per-run limits read from environment variables
(`FINISHED_ROOM_RETENTION_HOURS`, `IDLE_ROOM_RETENTION_HOURS`,
`PAIRING_GRACE_HOURS`, `ROOM_LIMIT_PER_RUN`, `PAIRING_LIMIT_PER_RUN`) and fall
back to the values above. Deploy the job and the index it needs with:

```sh
firebase deploy --only functions,firestore:indexes --project bot-speaker-1
```

The job runs with Admin SDK credentials and so bypasses `firestore.rules`.

Run the live two-client security and timestamp smoke test with:

```sh
./scripts/test-orchestration-backend.sh
```

The script creates temporary anonymous clients and Firestore documents, verifies
the expected allow/deny behavior, and removes the test data and identities when
it exits.

`GoogleService-Info.plist` (macOS) and the `FirebaseConfig` constants in
`Windows/BotSpeaker/FirestoreClient.cs` contain Firebase's public app
configuration. They do not grant database access; anonymous authentication plus
`firestore.rules` enforce access.

## Operational notes

- A pairing code is convenient discovery, not a password. Share it only with
  meeting participants and close pairing once everyone has joined.
- The green speaker indicator means a heartbeat arrived in the last 90 seconds.
- Client wall clocks may differ. Use the server-received fields when comparing
  activity across machines where clock synchronization is uncertain.
- The Windows client polls rather than listens, so remote state changes (start,
  pause, skip, stop) can take a couple of seconds to reflect there.
- Participant presence (heartbeats) reaches polling clients on the 30-second
  resync rather than immediately; the 90-second green-indicator window absorbs
  that delay.
