# Meeting orchestration

BotSpeaker's meeting orchestrator coordinates multiple laptops so their
virtual microphones speak one at a time without someone pressing Space on every
machine. The first machine is the host and the remaining machines join as remote
speakers with a short-lived six-character code. macOS and Windows clients speak
the same protocol and interoperate freely in one session — either platform can
host.

## Run a coordinated meeting

Every machine needs BotSpeaker, an ElevenLabs API key, a playable custom script,
and a virtual output device (BlackHole 2ch on macOS, VB-Audio Virtual Cable on
Windows).

1. On each machine, choose or replicate the script for that participant and
   select its ElevenLabs voice.
2. Open **Meeting Orchestrator** from the people icon in BotSpeaker's header.
3. On the host machine, enter its speaker name and choose **Host Meeting**.
4. On every other machine, choose **Remote Client**, enter its speaker name and
   the host's pairing code, then choose **Join Meeting**.
5. On the host, arrange the speakers in the desired order and choose
   **Start Meeting**.

As soon as a machine pairs, it generates and caches its first paragraph without
loading the audio player. Prefetch-capable clients report this readiness to the
host, and the Start button unlocks after their first turns are ready. Older
clients can still join, but the host labels them as not supporting prefetch and
does not wait on a readiness field they cannot provide.

BotSpeaker splits each script at paragraph boundaries. Turns are scheduled in a
round-robin sequence: each connected speaker delivers its next paragraph, then
control passes to the next speaker. A very long paragraph is split at sentence
boundaries. Local play, script-selection, and Space-key controls are locked
while a machine is paired.

During the meeting, every client keeps one local paragraph ahead of its most
recently finished turn. The lookahead uses the exact same cache key, chunking,
voice, model, and context as playback. When that paragraph is assigned, playback
loads the prepared MP3 and timing data from disk rather than waiting on an
ElevenLabs request. Prefetching never calls the audio player, so prepared speech
cannot start before the host assigns its turn. Preparation failures appear in
the speaker list and retry after a short delay; assigned playback still performs
a final cache check before reporting failure.

The host can pause or resume all clients, skip the current turn, stop the
session, and close pairing after the expected speakers have joined. A client
reports completion only after its local audio player reaches the end of the
assigned audio, so slow ElevenLabs generation does not advance the next speaker
early.

## Timestamped transcript

After a meeting completes or is stopped, choose **Export Timestamped JSON…** on
the host. The schema includes:

- the session ID, pairing code, status, and session start/end time;
- every speaker's anonymous session ID, name, script title, and voice name;
- every turn's speaker, paragraph index, spoken text, and outcome;
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
heartbeat freshness visible. Heartbeats deliberately do not move the marker. Audio, ElevenLabs keys, and complete scripts are never
uploaded as session setup data; only the active paragraph is attached to its
turn when that speaker begins preparing it.

The host is authoritative for room state and turn advancement. Security rules
limit room reads to paired participants, prohibit pairing-code enumeration, let
only the host change the queue, and let a client update only the turn assigned
to its anonymous identity. Pairing expires after four hours and is closed when
the meeting starts.

Relevant deployment files are:

- `firebase.json` — Firebase/Firestore project configuration;
- `.firebaserc` — default project alias; and
- `firestore.rules` — access-control rules.

To deploy a changed ruleset from an authenticated development machine:

```sh
firebase deploy --only firestore:rules --project bot-speaker-1
```

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
