import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { avatarOptions, avatarSVG, parseAvatar, randomAvatar } from "../src/bots/avatar.ts";

test("catalog specs round-trip; retired extras keep the rest of the face", () => {
  assert.deepEqual(parseAvatar("v1:mint:dot:smile:cheeks"), { color: "mint", eyes: "dot", mouth: "smile", accessory: "cheeks" });
  assert.deepEqual(parseAvatar("v1:sky:ring:grin:antenna"), { color: "sky", eyes: "ring", mouth: "grin", accessory: "none" });
});

test("legacy seeds are deterministic", () => {
  assert.deepEqual(parseAvatar("some-old-seed"), parseAvatar("some-old-seed"));
  assert.equal(avatarSVG("some-old-seed"), avatarSVG("some-old-seed"));
});

test("random faces are valid specs and render", () => {
  const v = randomAvatar();
  assert.match(v, /^v1:\w+:\w+:\w+:\w+$/);
  assert.match(avatarSVG(v), /^<svg[\s\S]*<\/svg>$/);
  const opts = avatarOptions(v);
  assert.equal(opts.colors.length, 10);
  assert.ok(opts.eyes.every((o) => o.svg.startsWith("<svg")));
});
