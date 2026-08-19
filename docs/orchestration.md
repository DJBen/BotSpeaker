# Meeting orchestration

BotSpeaker's macOS meeting orchestrator coordinates multiple laptops so their
virtual microphones speak one at a time without someone pressing Space on every
machine. The first Mac is the host and the remaining Macs join as remote
speakers with a short-lived six-character code.

## Run a coordinated meeting

Every Mac needs BotSpeaker, an ElevenLabs API key, a playable custom script, and
an output device such as BlackHole 2ch.

1. On each Mac, choose or replicate the script for that participant and select
   its ElevenLabs voice.
2. Open **Meeting Orchestrator** from the people icon in BotSpeaker's header.
3. On the host Mac, enter its speaker name and choose **Host Meeting**.
4. On every other Mac, choose **Remote Client**, enter its speaker name and the
   host's pairing code, then choose **Join Meeting**.
5. On the host, arrange the speakers in the desired order and choose
   **Start Meeting**.

BotSpeaker splits each script at paragraph boundaries. Turns are scheduled in a
round-robin sequence: each connected speaker delivers its next paragraph, then
control passes to the next speaker. A very long paragraph is split at sentence
boundaries. Local play, script-selection, and Space-key controls are locked
while a Mac is paired.

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
- playback start/end timestamps reported by the speaker Mac; and
- corresponding server-received timestamps for clock-independent auditing.

Dates use ISO 8601. `durationMilliseconds` is measured from the effective
playback start and end and therefore includes a host-initiated pause. Failed,
skipped, and stopped turns retain their terminal status and error when present.

## Cloud design

Coordination uses Firebase Authentication and Cloud Firestore in Google Cloud
project `bot-speaker-1` (`516080606747`). Clients authenticate anonymously and
subscribe to the room, participant, and turn documents through Firestore's
real-time listeners. Audio, ElevenLabs keys, and complete scripts are never
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

`GoogleService-Info.plist` contains Firebase's public app configuration. It does
not grant database access; anonymous authentication plus `firestore.rules`
enforce access.

## Operational notes

- A pairing code is convenient discovery, not a password. Share it only with
  meeting participants and close pairing once everyone has joined.
- The green speaker indicator means a heartbeat arrived in the last 90 seconds.
- Client wall clocks may differ. Use the server-received fields when comparing
  activity across machines where clock synchronization is uncertain.
- A future Windows client can use the same Firestore protocol and JSON schema;
  this initial implementation is macOS-only.
