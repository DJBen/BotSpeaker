# Reusable meeting plans on macOS

In the sidebar, choose **Orchestrated meeting → Import Meeting Plan…** and select a JSON file. The app validates the complete file before saving it to your local library. Imported plans remain available after restarting the app. Select a plan to preview its transcript and choose names and ElevenLabs voices. **Export Plan…** saves a portable copy of the script, roles, and overlap settings; runtime voice selections, names, meeting links, and bot IDs are not included.

The three longer bundled scripts are also editable JSON examples in `macOS/BotSpeaker/MeetingPlans`:

| Plan | Speakers | Words | Turns | Turn length |
| --- | ---: | ---: | ---: | --- |
| Five-person release deep dive | 5 | 1,367 | 17 | 6–122 words |
| Five-person incident recovery workshop | 5 | 2,236 | 26 | 5–123 words |
| Five-person customer research planning | 5 | 1,372 | 16 | 4–116 words |

The release and research scripts are at least 1,000 words longer than the short five-person release check; the incident script is at least 2,000 words longer. All include simultaneous groups with distinct speakers.

## File format

```json
{
  "version": 1,
  "title": "Release discussion",
  "speakers": [
    { "role": "Product Lead", "gender": "female" },
    { "role": "Engineer", "gender": "male" }
  ],
  "turns": [
    { "speaker": 1, "text": "Let's discuss the rollout, {{speaker_2}}." },
    { "speaker": 2, "text": "I have an update.", "overlapWithPrevious": true },
    { "speaker": 1, "text": "Thanks. What is the next step?" }
  ]
}
```

Speaker numbers are **one-based** and refer to the order of `speakers`. A plan requires a nonempty title, 2–12 speakers with nonempty roles, and 1–450 turns with nonempty text. `gender` is an optional preference for default voice selection. `{{speaker_1}}` and similar placeholders inside speech resolve to the names selected in the app. Line breaks inside one turn are normalized to spaces.

`overlapWithPrevious` defaults to false. When true, the turn starts in the same group as the previous turn. Consecutive true values extend that group. The first turn cannot overlap, and a speaker cannot appear twice in a group. After dispatching every speaker in a group, playback waits for all of them before beginning the next group. This creates simultaneous speech rather than a precisely timed interruption midway through another turn; remote network timing may vary.

Choose **Host in Recall.ai** for plans containing overlap. In **Arrange turns**, each turn has an overlap toggle. Speaker changes, reordering, and toggles must still produce valid groups; invalid groups fail before speech preparation. **Skip turn / overlap group** skips the whole active group. **Stop meeting** cancels active and prepared jobs. Audio already delivered to a remote bot may finish playing. All speech is prepared before the first group starts, so longer scripts can take longer to prepare.

Paired-machine hosting remains sequential and is disabled for a template with overlap, rather than silently ignoring its timing. Sequential imported plans can use either hosting mode. Existing Recall clip-duration limits still apply to individual turns; split exceptionally long turns if preparation reports that a clip is too large.

## Existing CLI plans

CLI `recall meeting-create --file` plans use `botId`, `voice`, and `text` per turn and refer to bots already in a call. They are a separate runtime format, not portable library files. The macOS runner now also accepts optional `overlapWithPrevious` on CLI turns. Use the portable format above for sidebar import; choose live speakers through the UI afterward. Windows is unchanged by this macOS UI feature.
