const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const test = require("node:test");

const {
  DigitalRewardError,
  digitalRewardCatalog,
  rewardById,
} = require("../digital_rewards");

test("built-in Digital Reward catalog ships complete working categories", () => {
  assert.equal(digitalRewardCatalog.length, 30);
  assert.equal(
    new Set(digitalRewardCatalog.map((reward) => reward.id)).size,
    digitalRewardCatalog.length,
  );

  const categories = new Set(
    digitalRewardCatalog.map((reward) => reward.category),
  );
  assert.deepEqual(
    categories,
    new Set([
      "profileFrame",
      "profileBadge",
      "profileTheme",
      "celebrationEffect",
      "nameplate",
      "mascotAccessory",
      "mascotOutfit",
      "mascotAura",
    ]),
  );

  for (const reward of digitalRewardCatalog) {
    assert.ok(reward.cost > 0);
    assert.ok(reward.assetKey);
    assert.equal(reward.isActive, true);
  }
});

test("server catalog is canonical and rejects unknown rewards", () => {
  assert.equal(rewardById("frame_gold").cost, 250);
  assert.equal(rewardById("mascot_guardian_crown").cost, 300);
  assert.equal(rewardById("mascot_cosmic_orbit").cost, 420);
  assert.equal(rewardById("mascot_victory_burst").cost, 460);
  assert.throws(
    () => rewardById("client-invented-reward"),
    (error) =>
      error instanceof DigitalRewardError && error.statusCode === 404,
  );
});

test("Firestore purchase rules stay in sync with every catalog item", () => {
  const rules = readFileSync(resolve(__dirname, "../../firestore.rules"), "utf8");
  const costBody = functionBody(rules, "digitalRewardCost");
  const categoryBody = functionBody(rules, "digitalRewardCategory");
  const assetBody = functionBody(rules, "digitalRewardAsset");
  const categoriesById = new Map();

  for (const match of categoryBody.matchAll(
    /rewardId in \[([\s\S]*?)\]\s*\? '([^']+)'/g,
  )) {
    for (const idMatch of match[1].matchAll(/'([^']+)'/g)) {
      categoriesById.set(idMatch[1], match[2]);
    }
  }

  for (const reward of digitalRewardCatalog) {
    assert.match(
      costBody,
      new RegExp(`rewardId == '${reward.id}' \\? ${reward.cost}(?:\\s|$)`),
      `missing canonical rule price for ${reward.id}`,
    );
    assert.match(
      assetBody,
      new RegExp(`rewardId == '${reward.id}' \\? '${reward.assetKey}'`),
      `missing canonical rule asset for ${reward.id}`,
    );
    assert.equal(
      categoriesById.get(reward.id),
      reward.category,
      `wrong canonical rule category for ${reward.id}`,
    );
  }
});

function functionBody(source, name) {
  const match = source.match(
    new RegExp(`function ${name}\\([^)]*\\) \\{([\\s\\S]*?)\\n    \\}`),
  );
  assert.ok(match, `Firestore rule function ${name} must exist`);
  return match[1];
}
