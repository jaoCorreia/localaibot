/**
 * Bot avatars: a flat solid-color circle with a white face, assembled from a
 * small catalog of parts. A bot stores its avatar as a string:
 *   - "v1:<color>:<eyes>:<mouth>:<accessory>"  chosen from the catalog
 *   - anything else                             a seed; parts are derived from it
 * Same string, same face. Flat on purpose: no gradients, highlights or glows.
 */

export const COLORS = {
  ember: { label: "Ember", fill: "#ef6b47", deep: "#7a1500" },
  sky: { label: "Sky", fill: "#4f9cf9", deep: "#08245c" },
  mint: { label: "Mint", fill: "#3fc380", deep: "#004d2b" },
  sun: { label: "Sun", fill: "#f4ae3d", deep: "#6b3a00" },
  violet: { label: "Violet", fill: "#9b5cff", deep: "#2b0a5c" },
  rose: { label: "Rose", fill: "#ec5a8b", deep: "#5c0a2a" },
  steel: { label: "Steel", fill: "#7b8794", deep: "#1f2933" },
  aqua: { label: "Aqua", fill: "#2cc4b3", deep: "#003d38" },
  indigo: { label: "Indigo", fill: "#5f6bf5", deep: "#141a5c" },
  lime: { label: "Lime", fill: "#a6db2f", deep: "#2a4d00" },
} as const;

export const EYES = ["dot", "pill", "visor", "ring", "happy", "spark"] as const;
export const MOUTHS = ["smile", "line", "dot", "o", "grin", "none"] as const;
export const ACCESSORIES = ["none", "antenna", "antennae", "orbit", "cheeks"] as const;

type Color = keyof typeof COLORS;
export interface AvatarSpec {
  color: Color;
  eyes: (typeof EYES)[number];
  mouth: (typeof MOUTHS)[number];
  accessory: (typeof ACCESSORIES)[number];
}

const PART_LABELS: Record<string, string> = {
  dot: "Dots", pill: "Pills", visor: "Visor", ring: "Rings", happy: "Happy", spark: "Sparks",
  smile: "Smile", line: "Line", o: "Oh", grin: "Grin", none: "None",
  antenna: "Antenna", antennae: "Alien", orbit: "Orbit", cheeks: "Cheeks",
};

/** mulberry32 seeded by an FNV-1a hash of the seed string. */
function rng(seed: string) {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) h = Math.imul(h ^ seed.charCodeAt(i), 16777619);
  let a = h >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pick = <T>(r: () => number, list: readonly T[]) => list[Math.floor(r() * list.length)];

export function parseAvatar(value: string): AvatarSpec {
  const [v, color, eyes, mouth, accessory] = value.split(":");
  if (v === "v1" && color in COLORS && (EYES as readonly string[]).includes(eyes)
      && (MOUTHS as readonly string[]).includes(mouth) && (ACCESSORIES as readonly string[]).includes(accessory)) {
    return { color, eyes, mouth, accessory } as AvatarSpec;
  }
  const r = rng(value);
  return {
    color: pick(r, Object.keys(COLORS) as Color[]),
    eyes: pick(r, EYES),
    mouth: pick(r, MOUTHS),
    // Most random faces stay plain; accessories are a choice.
    accessory: r() < 0.6 ? "none" : pick(r, ACCESSORIES),
  };
}

export const formatAvatar = (s: AvatarSpec) => `v1:${s.color}:${s.eyes}:${s.mouth}:${s.accessory}`;

const INK = "#fff";
const EYE_Y = 31;
const [L, R] = [22, 42];

function eyes(kind: AvatarSpec["eyes"]) {
  switch (kind) {
    case "dot":
      return `<circle cx="${L}" cy="${EYE_Y}" r="3.6" fill="${INK}"/><circle cx="${R}" cy="${EYE_Y}" r="3.6" fill="${INK}"/>`;
    case "pill":
      return [L, R].map((x) => `<rect x="${x - 2.6}" y="${EYE_Y - 5.5}" width="5.2" height="11" rx="2.6" fill="${INK}"/>`).join("");
    case "visor":
      return `<rect x="${L - 5}" y="${EYE_Y - 2.5}" width="${R - L + 10}" height="5" rx="2.5" fill="${INK}"/>`;
    case "ring":
      return [L, R].map((x) => `<circle cx="${x}" cy="${EYE_Y}" r="3.8" fill="none" stroke="${INK}" stroke-width="2.4"/>`).join("");
    case "happy":
      return [L, R].map((x) =>
        `<path d="M${x - 4} ${EYE_Y + 1.5} Q${x} ${EYE_Y - 4.5} ${x + 4} ${EYE_Y + 1.5}" fill="none" stroke="${INK}" stroke-width="2.6" stroke-linecap="round"/>`).join("");
    case "spark":
      return [L, R].map((x) => {
        const y = EYE_Y;
        return `<path d="M${x} ${y - 5} L${x + 1.4} ${y - 1.4} L${x + 5} ${y} L${x + 1.4} ${y + 1.4} L${x} ${y + 5} L${x - 1.4} ${y + 1.4} L${x - 5} ${y} L${x - 1.4} ${y - 1.4} Z" fill="${INK}"/>`;
      }).join("");
  }
}

function mouth(kind: AvatarSpec["mouth"]) {
  switch (kind) {
    case "smile":
      return `<path d="M25 42 Q32 48 39 42" fill="none" stroke="${INK}" stroke-width="2.4" stroke-linecap="round"/>`;
    case "line":
      return `<rect x="26" y="42" width="12" height="2.4" rx="1.2" fill="${INK}"/>`;
    case "dot":
      return `<circle cx="32" cy="43.5" r="1.9" fill="${INK}"/>`;
    case "o":
      return `<ellipse cx="32" cy="43.5" rx="2.6" ry="3.2" fill="none" stroke="${INK}" stroke-width="2"/>`;
    case "grin":
      return `<path d="M25 41 Q32 49 39 41 Z" fill="${INK}"/>`;
    case "none":
      return "";
  }
}

function accessory(kind: AvatarSpec["accessory"], deep: string) {
  switch (kind) {
    case "antenna":
    case "antennae":
      return ""; // drawn outside the head in renderAvatar
    case "orbit":
      return ""; // drawn around the planet in renderAvatar
    case "cheeks":
      return `<circle cx="17" cy="40" r="3" fill="${deep}" opacity="0.3"/><circle cx="47" cy="40" r="3" fill="${deep}" opacity="0.3"/>`;
    case "none":
      return "";
  }
}

export function renderAvatar(spec: AvatarSpec): string {
  const c = COLORS[spec.color];
  const face =
    `<circle cx="32" cy="32" r="32" fill="${c.fill}"/>` +
    accessory(spec.accessory, c.deep) +
    eyes(spec.eyes) +
    mouth(spec.mouth);
  if (spec.accessory === "antennae") {
    // Two curved stalks leaning outward, like an alien.
    const stalk = (side: 1 | -1) => {
      const bx = 32 + side * 8, tx = 32 + side * 16;
      return `<path d="M${bx} 16 Q${bx - side * 1} 8 ${tx} 6" fill="none" stroke="${c.fill}" stroke-width="2.6" stroke-linecap="round"/>` +
        `<circle cx="${tx}" cy="6" r="3.6" fill="${c.fill}"/>`;
    };
    return (
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">` +
      stalk(-1) + stalk(1) +
      `<g transform="translate(32 37.4) scale(0.8) translate(-32 -32)">${face}</g>` +
      `</svg>`
    );
  }
  if (spec.accessory === "antenna") {
    // Head shrinks and drops so a springy antenna can stick out of the top.
    return (
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">` +
      `<path d="M32 15 L32 6.5" stroke="${c.fill}" stroke-width="2.6" stroke-linecap="round"/>` +
      `<circle cx="32" cy="5" r="4" fill="${c.fill}"/>` +
      `<g transform="translate(32 37.4) scale(0.8) translate(-32 -32)">${face}</g>` +
      `</svg>`
    );
  }
  if (spec.accessory !== "orbit") {
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">${face}</svg>`;
  }
  // Planet with a ring outside it: the far half of the ring is drawn before
  // the (shrunk) body so the body hides it; the near half is drawn on top.
  // The ring sits low (below the mouth) so its near half never crosses the face.
  const ring = (sweep: 0 | 1) =>
    `<g transform="translate(32 40) rotate(-14)"><path d="M-30 0 A30 7 0 0 ${sweep} 30 0" fill="none" stroke="${c.fill}" stroke-width="3" stroke-linecap="round"/></g>`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">` +
    ring(1) +
    `<g transform="translate(32 29) scale(0.68) translate(-32 -32)">${face}</g>` +
    ring(0) +
    `</svg>`
  );
}

/** SVG for a stored avatar string (catalog spec or legacy seed). */
export const avatarSVG = (value: string) => renderAvatar(parseAvatar(value));

/**
 * The catalog for a picker: every option of every part, each rendered on top
 * of the current face so the user sees exactly what they'd get.
 */
export function avatarOptions(value: string) {
  const base = parseAvatar(value);
  const option = (patch: Partial<AvatarSpec>, id: string, label: string) => {
    const spec = { ...base, ...patch };
    return { id, label, value: formatAvatar(spec), svg: renderAvatar(spec) };
  };
  return {
    value: formatAvatar(base),
    svg: renderAvatar(base),
    face: { ...base, fill: COLORS[base.color].fill, deep: COLORS[base.color].deep },
    colors: (Object.keys(COLORS) as Color[]).map((id) => ({ ...option({ color: id }, id, COLORS[id].label), fill: COLORS[id].fill })),
    eyes: EYES.map((id) => option({ eyes: id }, id, PART_LABELS[id])),
    mouths: MOUTHS.map((id) => option({ mouth: id }, id, PART_LABELS[id])),
    accessories: ACCESSORIES.map((id) => option({ accessory: id }, id, PART_LABELS[id])),
  };
}

/** A random face, as a catalog spec (so it can be tweaked afterwards). */
export function randomAvatar(): string {
  return formatAvatar(parseAvatar(Math.random().toString(36)));
}
