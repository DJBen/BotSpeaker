# macOS functional parity review

Release: macOS app and CLI **0.5.6** (September 24, 2026).
Baseline: `origin/main` at `f9e904b`, including Windows 0.5.5, voice-derived
speaker names, and the prior macOS parity implementation. The upstream main
branch was re-fetched before release; no newer Windows source was present.

| Capability | macOS result |
| --- | --- |
| Local scripts, chunked speech, caching, voice/model selection, playback and volume | Existing macOS implementation; retained local voice improvements |
| Cross-machine hosting, pairing, preparation, turn control, transcripts and ad hoc requests | Existing shared protocol and macOS implementation |
| Speaker names default to selected voices | Included from the latest upstream baseline |
| Single instance per executable path | Included from upstream; separate installed copies may run independently |
| Recall full Teams invitation and explicit ID/passcode input | Added to GUI, CLI and API |
| Recall meeting-scoped list and bulk removal | Added; removal rejects empty scopes and reports per-bot failures |
| Recall prepared speech and explicit dispatch | Added; held clips do not block runnable speech |
| Prepare all meeting turns before starting | GUI and CLI use the same runner; failure prevents partial playback |
| Recall dispatch timing | Duration, dispatch-start, acceptance and estimated-end fields; prepared turns omit the standalone two-second guard |
| Recall CLI JSON plans | Create, start, status, skip, stop and wait; overlapping CLI plans cannot share a bot |
| Job waits and errors | Added completion/preparation waits, deadlines, failure exits and JSON output |
| Retained sidebar meetings | One plan per template for the app session; navigation does not stop playback |
| Direct speaker cleanup | Remove all bots is available from turn arrangement as well as bot setup |
| Explicit quit | Confirms active work, cancels speech, closes/leaves remote sessions and removes sidebar speaker bots; failures keep the app open for retry |

## Platform differences retained

- Closing a macOS window leaves the menu-bar app running. Windows closes the
  application from its main window. On macOS use Quit or Cmd-Q for cleanup.
- macOS uses Sparkle, Keychain and Core Audio/BlackHole; Windows uses Velopack,
  DPAPI and WASAPI/VB-CABLE. Installer/update workflows remain platform-specific.
- Standalone Recall bots and bots referenced by CLI plans remain joined after
  quitting; their pending local jobs are cancelled. Sidebar speaker bots are
  removed. This follows Windows ownership behavior.
- Recall timing estimates are not confirmations of audible playback. Stop/Skip
  cannot retract audio already accepted by Recall. Jobs/plans do not survive an
  application restart.

## Verification

- Debug app built with Xcode, signing disabled.
- `scripts/test-macos-recall.sh`: production controller and turn runner with
  substituted credentials/synthesis/HTTP, plus the real CLI against loopback HTTP.
  Covers invitations, held jobs, dispatch timing, scoped removal, preparation
  failure, stop/skip cleanup, JSON plans, waits, validation and exit codes.
- `scripts/test-macos-voices.sh`: existing voice catalog/selection and CLI tests.
- The September 23 Teams run exercised four admitted Recall bots plus self,
  repeated speech and waits, and meeting-scoped removal with no reported failures.
  This validates BotSpeaker transport/orchestration, not Wispr AX reliability.
- Interactive quit confirmation and real cross-machine Firestore shutdown were
  not re-tested in that run. Platform-specific update mechanisms remain distinct.
- Release verification reruns the Recall controller/CLI, voice selection/CLI,
  and ground-truth/template suites. Recall `-l` and `-r` aliases now match Windows.
