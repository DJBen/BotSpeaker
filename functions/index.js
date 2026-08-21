"use strict";

/**
 * Scheduled maintenance for the meeting-orchestration collections.
 *
 * Nothing in the macOS or Windows clients deletes an orchestration room once a
 * meeting ends, so rooms, their `participants`, `turns`, and `turns/*\/events`
 * subcollections, and the `orchestrationPairings` entries that point at them
 * accumulate indefinitely. Rooms also hold the host's resolved script text, so
 * stale rooms are both a cost and a data-retention concern. This job sweeps
 * them on a schedule.
 */

const { onSchedule } = require("firebase-functions/v2/scheduler");
const { logger } = require("firebase-functions");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");

initializeApp();

/** Hours a finished meeting (completed or stopped) is kept for transcript export. */
const FINISHED_ROOM_RETENTION_HOURS = numberFromEnv("FINISHED_ROOM_RETENTION_HOURS", 24);

/**
 * Hours any room may sit untouched before it is removed regardless of status.
 * Catches abandoned lobbies and rooms whose host crashed mid-meeting, which
 * keep a non-terminal status forever.
 */
const IDLE_ROOM_RETENTION_HOURS = numberFromEnv("IDLE_ROOM_RETENTION_HOURS", 72);

/** Grace period after a pairing code's own four-hour expiry before deletion. */
const PAIRING_GRACE_HOURS = numberFromEnv("PAIRING_GRACE_HOURS", 1);

/** Upper bound on documents handled per run, so one sweep cannot run away. */
const ROOM_LIMIT_PER_RUN = numberFromEnv("ROOM_LIMIT_PER_RUN", 200);
const PAIRING_LIMIT_PER_RUN = numberFromEnv("PAIRING_LIMIT_PER_RUN", 500);

const FINISHED_STATUSES = ["completed", "stopped"];

function numberFromEnv(name, fallback) {
  const parsed = Number(process.env[name]);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function hoursBefore(now, hours) {
  return Timestamp.fromMillis(now.toMillis() - hours * 60 * 60 * 1000);
}

/**
 * Deletes stale orchestration data.
 *
 * Exported separately from the scheduled wrapper so it can be driven against
 * the Firestore emulator with an injected clock.
 *
 * @param {FirebaseFirestore.Firestore} firestore
 * @param {FirebaseFirestore.Timestamp} now
 * @param {{dryRun?: boolean}} [options]
 */
async function cleanUpOrchestrationData(firestore, now, options = {}) {
  const dryRun = options.dryRun === true;
  const roomIDs = await staleRoomIDs(firestore, now);
  const pairingRefs = await stalePairingReferences(firestore, now, roomIDs);

  if (dryRun) {
    return { roomsDeleted: roomIDs.length, pairingsDeleted: pairingRefs.length, dryRun: true };
  }

  // recursiveDelete removes the room document along with its participants,
  // turns, and per-turn events subcollections; deleting the room document
  // alone would orphan them.
  for (const roomID of roomIDs) {
    await firestore.recursiveDelete(firestore.collection("orchestrationRooms").doc(roomID));
  }

  if (pairingRefs.length > 0) {
    const writer = firestore.bulkWriter();
    for (const ref of pairingRefs) {
      writer.delete(ref);
    }
    await writer.close();
  }

  return { roomsDeleted: roomIDs.length, pairingsDeleted: pairingRefs.length, dryRun: false };
}

/**
 * Rooms that are finished and past their retention window, plus rooms of any
 * status that have seen no activity at all for the idle window.
 *
 * Both queries key off `activityAt`, the server-timestamp marker every
 * state-changing commit on either platform touches, so a long meeting that is
 * still under way is never collected mid-session.
 *
 * Rooms written before `activityAt` existed, or by a client that failed to set
 * it, are invisible to those queries — Firestore cannot match a missing field —
 * and would leak forever. A third pass sweeps by `createdAt` and keeps only the
 * documents that genuinely lack a usable `activityAt`, so an old room that is
 * still active is left alone.
 */
async function staleRoomIDs(firestore, now) {
  const rooms = firestore.collection("orchestrationRooms");
  const idleCutoff = hoursBefore(now, IDLE_ROOM_RETENTION_HOURS);
  const [finished, idle, aged] = await Promise.all([
    rooms
      .where("status", "in", FINISHED_STATUSES)
      .where("activityAt", "<", hoursBefore(now, FINISHED_ROOM_RETENTION_HOURS))
      .limit(ROOM_LIMIT_PER_RUN)
      .get(),
    rooms
      .where("activityAt", "<", idleCutoff)
      .limit(ROOM_LIMIT_PER_RUN)
      .get(),
    rooms
      .where("createdAt", "<", idleCutoff)
      .limit(ROOM_LIMIT_PER_RUN)
      .get(),
  ]);

  // The `createdAt` pass exists only to reach rooms the `activityAt` queries
  // cannot see. A room that carries a fresh `activityAt` is still in use and is
  // dropped here however old its creation timestamp is.
  const staleByAge = aged.docs.filter((doc) => {
    const activityAt = doc.get("activityAt");
    return !activityAt || activityAt.toMillis() < idleCutoff.toMillis();
  });

  const ids = new Set();
  for (const doc of [...finished.docs, ...idle.docs, ...staleByAge]) {
    if (ids.size >= ROOM_LIMIT_PER_RUN) break;
    ids.add(doc.id);
  }
  return [...ids];
}

/**
 * Pairing codes whose own expiry has passed by more than the grace period, and
 * any pairing pointing at a room this run is about to delete. The second case
 * keeps a still-unexpired code from surviving its room and letting a client
 * join a session that no longer exists.
 */
async function stalePairingReferences(firestore, now, deletedRoomIDs) {
  const pairings = firestore.collection("orchestrationPairings");
  const expired = await pairings
    .where("expiresAt", "<", hoursBefore(now, PAIRING_GRACE_HOURS))
    .limit(PAIRING_LIMIT_PER_RUN)
    .get();

  const byPath = new Map(expired.docs.map((doc) => [doc.ref.path, doc.ref]));

  // `in` accepts at most 30 values per query, so the room IDs are chunked.
  for (let index = 0; index < deletedRoomIDs.length; index += 30) {
    const chunk = deletedRoomIDs.slice(index, index + 30);
    const orphaned = await pairings.where("roomID", "in", chunk).get();
    for (const doc of orphaned.docs) {
      byPath.set(doc.ref.path, doc.ref);
    }
  }

  return [...byPath.values()];
}

exports.cleanUpOrchestrationData = cleanUpOrchestrationData;

exports.orchestrationCleanup = onSchedule(
  {
    // Day-of-month step: the 1st, 4th, 7th ... of each month. The step resets
    // at the month boundary, so one gap per month is 1-2 days rather than 3.
    schedule: "0 4 */3 * *",
    timeZone: "America/Los_Angeles",
    region: "us-west1",
    // The job streams deletes rather than holding result sets, so the smallest
    // instance is enough.
    memory: "256MiB",
    timeoutSeconds: 540,
    retryCount: 1,
  },
  async () => {
    const result = await cleanUpOrchestrationData(getFirestore(), Timestamp.now());
    logger.info("Orchestration cleanup finished", result);
  }
);
