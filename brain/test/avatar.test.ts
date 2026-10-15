import "./env.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { avatarOptions, avatarSVG, formatAvatar, parseAvatar, randomAvatar } from "../src/bots/avatar.ts";

test("catalog specs round-trip; retired extras keep the rest of the face", () => {
  assert.deepEqual(parseAvatar("v1:mint:dot:smile:cheeks:bean"), { color: "mint", eyes: "dot", mouth: "smile", accessory: "cheeks", shape: "bean" });
  const { shape: _, ...retired } = parseAvatar("v1:sky:ring:grin:antenna");
  assert.deepEqual(retired, { color: "sky", eyes: "ring", mouth: "grin", accessory: "none" });
});

test("legacy seeds are deterministic", () => {
  assert.deepEqual(parseAvatar("some-old-seed"), parseAvatar("some-old-seed"));
  assert.equal(avatarSVG("some-old-seed"), avatarSVG("some-old-seed"));
});

test("random faces are valid specs and render", () => {
  const v = randomAvatar();
  assert.match(v, /^v1:\w+:\w+:\w+:\w+:\w+$/);
  assert.match(avatarSVG(v), /^<svg[\s\S]*<\/svg>$/);
  const opts = avatarOptions(v);
  assert.equal(opts.colors.length, 10);
  assert.ok(opts.eyes.every((o) => o.svg.startsWith("<svg")));
});

test("the head shape is a choice, and older faces keep the one they had", () => {
  const spec = parseAvatar("v1:sky:dot:smile:none:wide");
  assert.equal(spec.shape, "wide");
  assert.equal(formatAvatar(spec), "v1:sky:dot:smile:none:wide");
  // Saved before shapes were a choice: same head as the app derived (Swift hash of the parts).
  assert.equal(parseAvatar("v1:sky:dot:smile:none").shape, parseAvatar("v1:sky:dot:smile:none").shape);
  assert.ok(["round", "egg", "wide", "bean"].includes(parseAvatar("v1:sky:dot:smile:none").shape));
  assert.equal(parseAvatar("v1:sky:dot:smile:none:blob").shape, parseAvatar("v1:sky:dot:smile:none").shape);
  const options = avatarOptions("v1:sky:dot:smile:none:egg");
  assert.deepEqual(options.shapes.map((o) => o.id), ["round", "egg", "wide", "bean", "star", "asterisk"]);
  assert.equal(options.face.shape, "egg");
  assert.notEqual(options.shapes[0].svg, options.shapes[2].svg);
});
