const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const test = require("node:test");

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  increment,
  runTransaction,
  serverTimestamp,
  setDoc,
  writeBatch,
} = require("firebase/firestore");

// Separate namespace: the existing rules suite clears its own project in
// beforeEach, and Node may run the two test files concurrently.
const projectId = "demo-kinquest-competition-tokens";
const familyId = "FAMILY_A";
const competitionId = "monthly_2026-09";
const ledgerId = `${familyId}_${competitionId}`;
const competitionPath = `families/${familyId}/officialCompetitions/${competitionId}`;
const trophyPath = `families/${familyId}/trophies/${competitionId}`;
const participants = ["alice", "bob", "carol", "dave"];
const initialTokens = { alice: 7, bob: 11, carol: 13, dave: 17 };
let testEnvironment;

const userPath = (userId) => `users/${userId}`;
const ledgerPath = (userId) => `${userPath(userId)}/tokenTransactions/${ledgerId}`;
const databaseFor = (userId) => testEnvironment.authenticatedContext(userId).firestore();

function tokenEntry(userId, amount, reason) {
  return {
    userId,
    familyId,
    amount,
    type: "earned",
    reason,
    relatedRewardId: null,
    relatedRequestId: null,
    relatedCompetitionId: competitionId,
    createdAt: serverTimestamp(),
  };
}

// Reproduces the application's guarded, atomic Monthly Cup settlement write
// shape. These are rules/transaction regressions, not a replacement for Dart
// tests of the game's bracket and placement calculations.
function settleMonthlyCup(database, semifinalists = ["carol", "dave"]) {
  return runTransaction(database, async (transaction) => {
    const competitionRef = doc(database, competitionPath);
    const existing = await transaction.get(competitionRef);
    if (existing.data()?.completed === true) return false;

    transaction.set(competitionRef, {
      completed: true,
      rewardGranted: true,
      rewardCurrency: "tokens",
      winnerId: "alice",
      winnerName: "Alice",
      runnerUpId: "bob",
      runnerUpName: "Bob",
      semifinalistIds: semifinalists,
      semifinalistNames: semifinalists,
      tokenReward: 100,
      runnerUpTokenReward: 50,
      semifinalistTokenReward: 20,
      completedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }, { merge: true });

    const awards = [
      ["alice", 100, "Monthly Cup Champion"],
      ["bob", 50, "Monthly Cup Runner-up"],
      ...semifinalists.map((id) => [id, 20, "Monthly Cup Semifinalist"]),
    ];
    for (const [userId, amount, reason] of awards) {
      transaction.set(doc(database, userPath(userId)), {
        gamesPlayed: increment(semifinalists.length && ["alice", "bob"].includes(userId) ? 2 : 1),
        updatedAt: serverTimestamp(),
      }, { merge: true });
      transaction.set(doc(database, userPath(userId)), {
        tokens: increment(amount),
        ...(userId === "alice" ? {
          officialWins: increment(1),
          monthlyWins: increment(1),
          trophies: increment(1),
        } : {}),
        updatedAt: serverTimestamp(),
      }, { merge: true });
      transaction.set(doc(database, ledgerPath(userId)), tokenEntry(userId, amount, reason));
    }

    transaction.set(doc(database, trophyPath), {
      id: competitionId,
      type: "monthlyCup",
      monthKey: "2026-09",
      title: "Monthly Cup Champion",
      winnerId: "alice",
      winnerName: "Alice",
      familyId,
      earnedAt: serverTimestamp(),
    });
    return true;
  });
}

test.before(async () => {
  const [host, port] = (process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:9090").split(":");
  testEnvironment = await initializeTestEnvironment({
    projectId,
    firestore: {
      host,
      port: Number(port),
      rules: readFileSync(resolve(__dirname, "../../firestore.rules"), "utf8"),
    },
  });
});

test.after(async () => {
  if (testEnvironment) await testEnvironment.cleanup();
});

test.beforeEach(async () => {
  await testEnvironment.clearFirestore();
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const database = context.firestore();
    await Promise.all([
      ...participants.map((userId) => setDoc(doc(database, userPath(userId)), {
        familyId,
        name: userId,
        tokens: initialTokens[userId],
        rankingPoints: 91,
        gamesPlayed: 0,
        officialWins: 0,
        monthlyWins: 0,
        trophies: 0,
      })),
      setDoc(doc(database, "users/mallory"), { familyId: "FAMILY_B", tokens: 0 }),
      setDoc(doc(database, `families/${familyId}`), { ownerId: "alice", members: participants }),
      setDoc(doc(database, "families/FAMILY_B"), { ownerId: "mallory", members: ["mallory"] }),
      setDoc(doc(database, competitionPath), { completed: false, participantIds: participants }),
    ]);
  });
});

test("a non-owner family member atomically pays all four Monthly Cup placements in Tokens", async () => {
  const database = databaseFor("bob");
  assert.equal(await assertSucceeds(settleMonthlyCup(database)), true);

  for (const [userId, amount] of [["alice", 100], ["bob", 50], ["carol", 20], ["dave", 20]]) {
    const user = (await getDoc(doc(database, userPath(userId)))).data();
    const ledger = await getDoc(doc(database, ledgerPath(userId)));
    assert.equal(user.tokens, initialTokens[userId] + amount);
    assert.equal(user.rankingPoints, 91, "settlement must not grant permanent RP");
    assert.equal(ledger.id, `${familyId}_${competitionId}`);
    assert.equal(ledger.data().amount, amount);
    assert.equal(ledger.data().userId, userId);
    assert.equal(ledger.data().familyId, familyId);
    assert.equal(ledger.data().relatedCompetitionId, competitionId);
    assert.equal(ledger.data().type, "earned");
  }

  const champion = (await getDoc(doc(database, "users/alice"))).data();
  assert.equal(champion.officialWins, 1);
  assert.equal(champion.monthlyWins, 1);
  assert.equal(champion.trophies, 1);
  assert.equal(champion.gamesPlayed, 2);
  const completed = (await getDoc(doc(database, competitionPath))).data();
  assert.equal(completed.completed, true);
  assert.equal(completed.rewardGranted, true);
  assert.equal(completed.rewardCurrency, "tokens");
  assert.equal((await getDoc(doc(database, trophyPath))).data().winnerId, "alice");

  // A retry is a read-only no-op, not another balance or ledger write.
  assert.equal(await assertSucceeds(settleMonthlyCup(database)), false);
  assert.equal((await getDoc(doc(database, "users/alice"))).data().tokens, 107);
  assert.equal((await getDoc(doc(database, "users/bob"))).data().tokens, 61);
});

test("a two-player cup pays no nonexistent semifinalist awards", async () => {
  const database = databaseFor("bob");
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), competitionPath), {
      completed: false,
      participantIds: ["alice", "bob"],
    });
  });
  await assertSucceeds(settleMonthlyCup(database, []));
  for (const userId of ["carol", "dave"]) {
    assert.equal((await getDoc(doc(database, userPath(userId)))).data().tokens, initialTokens[userId]);
    assert.equal((await getDoc(doc(database, ledgerPath(userId)))).exists(), false);
  }
});

test("an unrelated family cannot settle the cup or credit its participants", async () => {
  const unrelated = databaseFor("mallory");
  await assertFails(settleMonthlyCup(unrelated));
  const batch = writeBatch(unrelated);
  batch.update(doc(unrelated, "users/alice"), { tokens: increment(100) });
  batch.set(doc(unrelated, ledgerPath("alice")), tokenEntry("alice", 100, "Monthly Cup Champion"));
  await assertFails(batch.commit());
  await assertUnsettled();
});

test("a duplicate recipient ledger rejects the whole settlement without partial payouts", async () => {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), ledgerPath("bob")), tokenEntry("bob", 50, "Existing prize"));
  });
  await assertFails(settleMonthlyCup(databaseFor("bob")));
  await assertUnsettled("bob");
  const existing = (await getDoc(doc(databaseFor("bob"), ledgerPath("bob")))).data();
  assert.equal(existing.reason, "Existing prize");
});

test("an earned ledger cannot be overwritten, even together with a new balance increment", async () => {
  const database = databaseFor("bob");
  await assertSucceeds(settleMonthlyCup(database));
  const batch = writeBatch(database);
  batch.update(doc(database, "users/alice"), { tokens: increment(100) });
  batch.set(doc(database, ledgerPath("alice")), tokenEntry("alice", 200, "Forged replacement"));
  await assertFails(batch.commit());
  assert.equal((await getDoc(doc(database, "users/alice"))).data().tokens, 107);
  assert.equal((await getDoc(doc(database, ledgerPath("alice")))).data().amount, 100);
});

async function assertUnsettled(existingLedgerUser = null) {
  const database = databaseFor("alice");
  assert.equal((await getDoc(doc(database, competitionPath))).data().completed, false);
  assert.equal((await getDoc(doc(database, trophyPath))).exists(), false);
  for (const userId of participants) {
    const user = (await getDoc(doc(database, userPath(userId)))).data();
    assert.equal(user.tokens, initialTokens[userId]);
    assert.equal(user.rankingPoints, 91);
    assert.equal(user.gamesPlayed, 0);
    assert.equal(user.officialWins, 0);
    assert.equal(user.monthlyWins, 0);
    assert.equal(user.trophies, 0);
    assert.equal((await getDoc(doc(database, ledgerPath(userId)))).exists(), userId === existingLedgerUser);
  }
}
