/**
 * A device share code: everything needed to connect to a remote device (URL,
 * token, screen password, suggested name) in one string, so another Local Bot
 * can add it by pasting. `localbot-device:` + base64url(JSON). Links that carry
 * the code after `d=` work too. The code grants control of the machine.
 */
const PREFIX = "localbot-device:";

export interface SharedDevice {
  url: string;
  token: string;
  vncPassword?: string;
  name?: string;
}

export function encodeShare(d: SharedDevice) {
  const payload = { v: 1, url: d.url, token: d.token, ...(d.vncPassword ? { vnc: d.vncPassword } : {}), ...(d.name ? { name: d.name } : {}) };
  return PREFIX + Buffer.from(JSON.stringify(payload)).toString("base64url");
}

export function decodeShare(text: string): SharedDevice {
  const raw = text.trim();
  const fromLink = /[?&#]d=([\w-]+)/.exec(raw)?.[1];
  const body = fromLink ?? (raw.startsWith(PREFIX) ? raw.slice(PREFIX.length) : raw);
  let data: any;
  try {
    data = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  } catch {
    throw new Error("That isn’t a device share code");
  }
  if (data?.v !== 1 || typeof data.url !== "string" || typeof data.token !== "string") {
    throw new Error("That share code is incomplete or from a newer Local Bot");
  }
  return { url: data.url, token: data.token, vncPassword: data.vnc, name: data.name };
}
