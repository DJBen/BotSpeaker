"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { Timestamp } = require("firebase-admin/firestore");
const { cleanUpOrchestrationData } = require("./index");

const NOW = Timestamp.fromMillis(Date.UTC(2026, 7, 21, 12, 0, 0));

function hoursAgo(hours) {
  return Timestamp.fromMillis(NOW.toMillis() - hours * 60 * 60 * 1000);
}

/** Minimal in-memory stand-in for the query surface the job uses. */
function fakeFirestore(rooms, pairings) {
  const recursivelyDeleted = [];
  const deleted = [];

  const matches = (data, [field, op, value]) => {
    const actual = data[field];
    if (op === "in") return value.includes(actual);
    if (op === "<") return actual !== undefined && actual.toMillis() < value.toMillis();
    throw new Error(`unsupported operator ${op}`);
  };

  const makeQuery = (name, docs, filters = [], limit = Infinity) => ({
    where: (...filter) => makeQuery(name, docs, [...filters, filter], limit),
    limit: (count) => makeQuery(name, docs, filters, count),
    get: async () => ({
      docs: docs
        .filter((doc) => filters.every((filter) => matches(doc.data, filter)))
        .slice(0, limit)
        .map((doc) => ({ id: doc.id, ref: { path: `${name}/${doc.id}` } })),
    }),
  });

  return {
    recursivelyDeleted,
    deleted,
    collection(name) {
      const docs = name === "orchestrationRooms" ? rooms : pairings;
      return {
        ...makeQuery(name, docs),
        doc: (id) => ({ path: `${name}/${id}` }),
      };
    },
    async recursiveDelete(ref) {
      recursivelyDeleted.push(ref.path);
    },
    bulkWriter() {
      return { delete: (ref) => deleted.push(ref.path), close: async () => {} };
    },
  };
}

const ROOMS = [
  { id: "finishedOld", data: { status: "completed", activityAt: hoursAgo(30) } },
  { id: "finishedRecent", data: { status: "stopped", activityAt: hoursAgo(2) } },
  { id: "runningNow", data: { status: "running", activityAt: hoursAgo(1) } },
  { id: "runningLong", data: { status: "running", activityAt: hoursAgo(20) } },
  { id: "abandonedLobby", data: { status: "lobby", activityAt: hoursAgo(100) } },
];

const PAIRINGS = [
  { id: "AAAAAA", data: { roomID: "finishedOld", expiresAt: hoursAgo(26) } },
  { id: "BBBBBB", data: { roomID: "abandonedLobby", expiresAt: NOW } },
  { id: "CCCCCC", data: { roomID: "runningNow", expiresAt: Timestamp.fromMillis(NOW.toMillis() + 3.6e6) } },
  { id: "DDDDDD", data: { roomID: "runningLong", expiresAt: hoursAgo(19) } },
];

test("collects finished and abandoned rooms, keeps live ones", async () => {
  const firestore = fakeFirestore(ROOMS, PAIRINGS);
  const result = await cleanUpOrchestrationData(firestore, NOW);

  assert.deepStrictEqual(firestore.recursivelyDeleted.sort(), [
    "orchestrationRooms/abandonedLobby",
    "orchestrationRooms/finishedOld",
  ]);
  assert.strictEqual(result.roomsDeleted, 2);
});

test("deletes expired pairings and pairings orphaned by this run", async () => {
  const firestore = fakeFirestore(ROOMS, PAIRINGS);
  await cleanUpOrchestrationData(firestore, NOW);

  // AAAAAA and DDDDDD are past expiry plus grace; BBBBBB is unexpired but its
  // room is going away. CCCCCC belongs to a live room and survives.
  assert.deepStrictEqual(firestore.deleted.sort(), [
    "orchestrationPairings/AAAAAA",
    "orchestrationPairings/BBBBBB",
    "orchestrationPairings/DDDDDD",
  ]);
});

test("a mid-meeting room that keeps committing is never collected", async () => {
  const firestore = fakeFirestore(
    [{ id: "live", data: { status: "paused", activityAt: hoursAgo(0.1) } }],
    []
  );
  const result = await cleanUpOrchestrationData(firestore, NOW);
  assert.strictEqual(result.roomsDeleted, 0);
  assert.deepStrictEqual(firestore.recursivelyDeleted, []);
});

test("dry run reports counts without deleting", async () => {
  const firestore = fakeFirestore(ROOMS, PAIRINGS);
  const result = await cleanUpOrchestrationData(firestore, NOW, { dryRun: true });

  assert.deepStrictEqual(result, { roomsDeleted: 2, pairingsDeleted: 3, dryRun: true });
  assert.deepStrictEqual(firestore.recursivelyDeleted, []);
  assert.deepStrictEqual(firestore.deleted, []);
});
