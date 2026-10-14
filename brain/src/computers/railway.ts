import { randomBytes } from "node:crypto";
import { secrets } from "../secrets.ts";
import { Collection } from "../store.ts";
import { remote } from "./remote.ts";
import type { Computer, ComputerProvider, ComputerState } from "./types.ts";

const API = "https://backboard.railway.com/graphql/v2";
/** The device image (see /device). Override to test a build of your own. */
const IMAGE = process.env.LOCALBOT_DEVICE_IMAGE ?? "ghcr.io/jaocorreia/localbot-device:latest";
const PROJECT = "Local Bot";
const TOKEN_ACCOUNT = "railway";

interface RailwayRecord {
  id: string;
  name: string;
  serviceId: string;
  url: string;
  vncPassword: string;
}

/** The Railway project and environment that hold every device. */
interface ProjectRecord {
  id: "project";
  projectId: string;
  environmentId: string;
}

/**
 * Linux desktops on the user's Railway account: one service per device,
 * running the device image, reached through its public domain. Provisioning
 * goes through Railway's public GraphQL API with an account token kept in the
 * Keychain; driving and watching go through the device agent (see remote.ts).
 */
export class RailwayProvider implements ComputerProvider {
  readonly name = "railway";
  private devices = new Collection<RailwayRecord>("railway-devices.json", 0o600);
  private project = new Collection<ProjectRecord>("railway.json", 0o600);
  /** Deployment status per service, briefly cached: the list is asked for often. */
  private status = new Map<string, { at: number; state: ComputerState; deploymentId?: string }>();

  async load() {
    await secrets.load([TOKEN_ACCOUNT, ...this.devices.all().map((d) => remote.tokenAccount(d.id))]);
  }

  get configured() {
    return !!secrets.get(TOKEN_ACCOUNT);
  }

  async available() {
    return this.configured;
  }

  /** Checks the token against the API, then keeps it in the Keychain. */
  async setToken(token: string) {
    const clean = token.trim();
    if (!clean) throw new Error("Paste a Railway token");
    await gql(clean, "query { projects { edges { node { id } } } }")
      .catch((err) => { throw new Error(`Railway didn’t accept that token: ${err.message}`); });
    await secrets.set(TOKEN_ACCOUNT, clean);
  }

  async list(): Promise<Computer[]> {
    return Promise.all(this.devices.all().map(async (d) => ({
      id: d.id,
      name: d.name,
      provider: this.name,
      os: "linux" as const,
      state: (await this.deployment(d)).state,
      display: remote.display(d.url, remote.token(d.id), d.vncPassword),
    })));
  }

  async create(name: string) {
    const { projectId, environmentId } = await this.ensureProject();
    const token = remote.newToken();
    const vncPassword = randomBytes(6).toString("hex");
    const variables = { LOCALBOT_TOKEN: token, VNC_PW: vncPassword, PORT: "8080" };
    const { serviceCreate } = await this.api(
      `mutation($input: ServiceCreateInput!) { serviceCreate(input: $input) { id } }`,
      { input: { projectId, name: serviceName(name), source: { image: IMAGE }, variables } },
    );
    const serviceId: string = serviceCreate.id;
    try {
      await this.api(`mutation($input: VariableCollectionUpsertInput!) { variableCollectionUpsert(input: $input) }`,
        { input: { projectId, environmentId, serviceId, variables, skipDeploys: true } });
      const { serviceDomainCreate } = await this.api(
        `mutation($input: ServiceDomainCreateInput!) { serviceDomainCreate(input: $input) { domain } }`,
        { input: { serviceId, environmentId, targetPort: 8080 } },
      );
      await this.api(`mutation($s: String!, $e: String!) { serviceInstanceDeployV2(serviceId: $s, environmentId: $e) }`,
        { s: serviceId, e: environmentId });
      const id = `railway:${serviceId}`;
      await secrets.set(remote.tokenAccount(id), token);
      this.devices.upsert({ id, name, serviceId, url: `https://${serviceDomainCreate.domain}`, vncPassword });
      return id;
    } catch (err) {
      // Don't leave a half-made service billing on the account.
      await this.api(`mutation($id: String!) { serviceDelete(id: $id) }`, { id: serviceId }).catch(() => {});
      throw err;
    }
  }

  /** Deletes the Railway service (and its deployments) and forgets the device. */
  async remove(id: string) {
    const d = this.devices.get(id);
    if (d) await this.api(`mutation($id: String!) { serviceDelete(id: $id) }`, { id: d.serviceId });
    this.devices.remove((x) => x.id === id);
    this.status.delete(id);
    await secrets.delete(remote.tokenAccount(id));
  }

  async start(id: string) {
    const d = this.record(id);
    const { environmentId } = await this.ensureProject();
    await this.api(`mutation($s: String!, $e: String!) { serviceInstanceDeployV2(serviceId: $s, environmentId: $e) }`,
      { s: d.serviceId, e: environmentId });
    this.status.delete(id);
  }

  /** Stops the running deployment: Railway stops billing for it until started again. */
  async stop(id: string) {
    const deployment = await this.deployment(this.record(id), true);
    if (deployment.deploymentId) {
      await this.api(`mutation($id: String!) { deploymentStop(id: $id) }`, { id: deployment.deploymentId });
    }
    this.status.delete(id);
  }

  async hands(id: string, session: string) {
    const d = this.devices.get(id);
    if (!d || (await this.deployment(d, true)).state !== "running") return null;
    return remote.hands(d, d.id, session);
  }

  private record(id: string) {
    const d = this.devices.get(id);
    if (!d) throw new Error(`Unknown device: ${id}`);
    return d;
  }

  /** The device's state from its latest deployment, plus a health check once it's up. */
  private async deployment(d: RailwayRecord, fresh = false) {
    const cached = this.status.get(d.id);
    if (!fresh && cached && Date.now() - cached.at < 5000) return cached;
    let state: ComputerState = "error";
    let deploymentId: string | undefined;
    try {
      const { environmentId } = await this.ensureProject();
      const { serviceInstance } = await this.api(
        `query($s: String!, $e: String!) { serviceInstance(serviceId: $s, environmentId: $e) { latestDeployment { id status } } }`,
        { s: d.serviceId, e: environmentId },
      );
      const latest = serviceInstance?.latestDeployment;
      deploymentId = latest?.id;
      state = stateOf(latest?.status, cached?.state);
      // Railway says SUCCESS once the container runs; the desktop takes a few more seconds.
      if (state === "running" && !(await remote.healthy(d.url))) state = cached?.state === "running" ? "running" : "starting";
    } catch (err) {
      console.error("[brain] railway status failed:", err instanceof Error ? err.message : err);
      state = cached?.state ?? "error";
    }
    const entry = { at: Date.now(), state, deploymentId };
    this.status.set(d.id, entry);
    return entry;
  }

  /** One "Local Bot" project for all devices, created on first use. */
  private async ensureProject(): Promise<ProjectRecord> {
    const saved = this.project.get("project");
    if (saved) return saved;
    const create = (workspaceId?: string) => this.api(
      `mutation($input: ProjectCreateInput!) { projectCreate(input: $input) { id environments { edges { node { id name } } } } }`,
      { input: { name: PROJECT, description: "Devices for Local Bot", ...(workspaceId ? { workspaceId } : {}) } },
    );
    // Accounts in several workspaces must say which one; use the first.
    const { projectCreate } = await create().catch(async (err) => {
      const { me } = await this.api(`query { me { workspaces { id } } }`).catch(() => { throw err; });
      const workspace = me?.workspaces?.[0]?.id;
      if (!workspace) throw err;
      return create(workspace);
    });
    const environmentId = projectCreate.environments?.edges?.[0]?.node?.id;
    if (!environmentId) throw new Error("Railway created the project without an environment");
    return this.project.upsert({ id: "project", projectId: projectCreate.id, environmentId });
  }

  private api(query: string, variables: Record<string, unknown> = {}) {
    const token = secrets.get(TOKEN_ACCOUNT);
    if (!token) throw new Error("Connect Railway first (paste an account token)");
    return gql(token, query, variables);
  }
}

async function gql(token: string, query: string, variables: Record<string, unknown> = {}): Promise<any> {
  const res = await fetch(API, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ query, variables }),
    signal: AbortSignal.timeout(30_000),
  });
  const body: any = await res.json().catch(() => ({}));
  if (body.errors?.length) throw new Error(body.errors.map((e: any) => e.message).join("; "));
  if (!res.ok) throw new Error(`Railway answered HTTP ${res.status}`);
  return body.data;
}

function stateOf(status: string | undefined, previous?: ComputerState): ComputerState {
  switch (status) {
    case "SUCCESS":
      return "running";
    case "BUILDING": case "DEPLOYING": case "INITIALIZING": case "QUEUED": case "WAITING":
      // First boot shows as being created; later ones as starting.
      return previous === "stopped" || previous === "running" || previous === "starting" ? "starting" : "creating";
    case "FAILED": case "CRASHED":
      return "error";
    default: // REMOVED, SLEEPING, SKIPPED, or never deployed
      return "stopped";
  }
}

function serviceName(label: string) {
  const slug = label.toLowerCase().normalize("NFD").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 24) || "device";
  return `${slug}-${randomBytes(2).toString("hex")}`;
}
