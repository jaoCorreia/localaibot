import { secrets } from "../secrets.ts";
import { Collection } from "../store.ts";

/**
 * The local brain's link to a brain in the cloud (server.ts). Bots hosted
 * there keep working while the Mac is off; while the app is open, the local
 * brain forwards their methods and relays their events, so the shell sees one
 * team. Device ids differ between the two brains (the cloud knows a Railway
 * device as a remote one), so the link keeps a map.
 */
interface LinkRecord {
  id: "brain";
  url: string;
  /** Set when Local Bot created the brain on Railway (and may delete it). */
  railwayServiceId?: string;
}

const TOKEN_ACCOUNT = "cloud-brain";

export class CloudLink {
  private record = new Collection<LinkRecord>("cloud.json", 0o600);
  /** Bots that live in the cloud brain. */
  private hosted = new Collection<{ id: string }>("cloud-bots.json");
  /** Local device id ↔ the same device's id in the cloud brain. */
  private devices = new Collection<{ id: string; cloudId: string }>("cloud-devices.json");
  /** Last bot list from the cloud, served while it's unreachable. */
  private cachedBots: any[] = [];
  private stream?: AbortController;

  constructor(private relay: (event: string, data: unknown) => void, private log: (...a: unknown[]) => void) {}

  async load() {
    await secrets.load([TOKEN_ACCOUNT]);
    if (this.connected) this.listen();
  }

  get connected() {
    return !!this.record.get("brain") && !!secrets.get(TOKEN_ACCOUNT);
  }

  get url() {
    return this.record.get("brain")?.url;
  }

  get railwayServiceId() {
    return this.record.get("brain")?.railwayServiceId;
  }

  isHosted(botId: string) {
    return !!this.hosted.get(botId);
  }

  hostedCount() {
    return this.hosted.all().length;
  }

  markHosted(botId: string, hosted: boolean) {
    if (hosted) this.hosted.upsert({ id: botId });
    else this.hosted.remove((b) => b.id === botId);
  }

  /** Checks the brain answers with this token, then keeps both. */
  async connect(url: string, token: string, railwayServiceId?: string) {
    const clean = url.trim().replace(/\/+$/, "");
    await call(clean, token, "ping", {}).catch((err) => { throw new Error(`Couldn’t reach the cloud brain: ${err.message}`); });
    await secrets.set(TOKEN_ACCOUNT, token);
    this.record.upsert({ id: "brain", url: clean, railwayServiceId });
    this.listen();
  }

  /** Forgets the link. Hosted bots stay in the cloud and come back on reconnect. */
  async disconnect() {
    this.stream?.abort();
    this.record.remove(() => true);
    this.devices.remove(() => true);
    this.cachedBots = [];
    await secrets.delete(TOKEN_ACCOUNT);
  }

  async health() {
    const url = this.url;
    if (!url) return false;
    try {
      return (await fetch(`${url}/health`, { signal: AbortSignal.timeout(5000) })).ok;
    } catch {
      return false;
    }
  }

  call(method: string, params: unknown = {}) {
    const url = this.url, token = secrets.get(TOKEN_ACCOUNT);
    if (!url || !token) throw new Error("No cloud brain is connected");
    return call(url, token, method, params);
  }

  // ---- device ids

  cloudDevice(localId: string) {
    return this.devices.get(localId)?.cloudId;
  }

  localDevice(cloudId: string) {
    return this.devices.where((d) => d.cloudId === cloudId)[0]?.id;
  }

  mapDevice(localId: string, cloudId: string) {
    this.devices.upsert({ id: localId, cloudId });
  }

  unmapDevice(localId: string) {
    this.devices.remove((d) => d.id === localId);
  }

  /** Bot views from the cloud with device ids translated to local ones. */
  async bots(): Promise<any[]> {
    if (!this.connected || !this.hostedCount()) return [];
    try {
      const list = (await this.call("bots.list")) as any[];
      this.cachedBots = list
        .filter((b) => this.isHosted(b.id))
        .map((b) => ({ ...b, host: "cloud", computers: (b.computers ?? []).map((a: any) => this.toLocalAccess(a)) }));
    } catch (err) {
      this.log("cloud bots unavailable:", err instanceof Error ? err.message : err);
      this.cachedBots = this.cachedBots.map((b) => ({ ...b, status: "offline" }));
    }
    return this.cachedBots;
  }

  toLocalAccess(a: any) {
    return { ...a, computerId: this.localDevice(a.computerId) ?? a.computerId };
  }

  // ---- events

  /** Follows the cloud brain's events and relays them; reconnects with backoff. */
  private listen() {
    this.stream?.abort();
    const ctrl = new AbortController();
    this.stream = ctrl;
    void (async () => {
      let delay = 1000;
      while (!ctrl.signal.aborted && this.connected) {
        try {
          const res = await fetch(`${this.url}/events`, {
            headers: { authorization: `Bearer ${secrets.get(TOKEN_ACCOUNT)}` },
            signal: ctrl.signal,
          });
          if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
          delay = 1000;
          // Anything may have changed while we weren't listening.
          this.relay("bots", null);
          let buffer = "";
          for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
            buffer += Buffer.from(chunk).toString("utf8");
            let end: number;
            while ((end = buffer.indexOf("\n\n")) >= 0) {
              const block = buffer.slice(0, end);
              buffer = buffer.slice(end + 2);
              const data = block.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).join("\n");
              if (!data) continue;
              try {
                const { event, data: payload } = JSON.parse(data);
                this.relay(event, payload);
              } catch {}
            }
          }
        } catch (err) {
          if (ctrl.signal.aborted) return;
          this.log("cloud events dropped:", err instanceof Error ? err.message : err);
        }
        await new Promise((r) => setTimeout(r, delay));
        delay = Math.min(delay * 2, 30_000);
      }
    })();
  }
}

async function call(url: string, token: string, method: string, params: unknown) {
  const res = await fetch(`${url}/rpc`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ method, params }),
    signal: AbortSignal.timeout(60_000),
  });
  if (res.status === 401) throw new Error("The cloud brain refused the token");
  if (!res.ok) throw new Error(`Cloud brain answered HTTP ${res.status}`);
  const body: any = await res.json();
  if (body.error) throw new Error(body.error);
  return body.result;
}
