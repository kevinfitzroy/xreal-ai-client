import { HostConfig, ProjectInfo, SessionStatus, AgentState, RenderHost, RenderProject } from '../model/Models';
import { SshConnection } from '../ssh/SshConnection';
import { Log } from '../util/Logger';

/**
 * 列表数据源 —— 对齐 Android `ManifestFetcher` + `StatusPoller`(SPEC §2/§3)。
 *   1. 每 host 经 SSH exec `cat <base>/.xreal/projects.json`(manifest)+ `cat status.json`(hooks 状态)
 *   2. 合并:host 不可达→全 disconnected;有上报→用;无→unknown(SPEC §3 合并规则)
 *   3. 产出 RenderHost[] JSON 推 window.setHosts
 * 事件驱动零空轮询:列表首显 / back-to-list / onForeground 各拉一次(对齐 iOS Phase 3 + Android)。
 */
const TAG = 'ManifestFetcher';

export class ManifestFetcher {
  constructor(private hosts: HostConfig[]) {}

  /** 拉全部 host,返回可直接喂 window.setHosts 的 JSON 字符串。死 host 不拖累活 host(各自 try)。 */
  async fetchAll(): Promise<string> {
    const byName = new Map<string, HostConfig>();
    for (const h of this.hosts) { byName.set(h.name, h); }
    const out: RenderHost[] = [];
    // 并发拉(对齐 iOS withTaskGroup);单 host 失败→disconnected,不抛。
    const results = await Promise.all(this.hosts.map((h) => this.fetchHost(h, byName)));
    for (const r of results) { out.push(r); }
    return JSON.stringify(out);
  }

  private async fetchHost(h: HostConfig, byName: Map<string, HostConfig>): Promise<RenderHost> {
    if (!h.basePath) {
      // 无 basePath:不 live-fetch,只用 seed(SPEC §8)
      return this.renderFromSeed(h, true);
    }
    const conn = new SshConnection();
    try {
      await conn.connect(h, byName);
      const projJson = await conn.exec(`cat ${h.basePath}/.xreal/projects.json 2>/dev/null`);
      const statJson = await conn.exec(`cat ${h.basePath}/.xreal/status.json 2>/dev/null`);
      const projects = this.parseProjects(projJson);
      const status = this.parseStatus(statJson);
      return this.merge(h, projects, status);
    } catch (e) {
      Log.w(TAG, `${h.name} 不可达: ${e}`);
      return this.renderFromSeed(h, false);   // host 不可达 → 全 disconnected
    } finally {
      conn.close();
    }
  }

  private parseProjects(raw: string): ProjectInfo[] {
    try { const j = JSON.parse(raw) as Record<string, Object>; return (j.projects as ProjectInfo[]) ?? []; }
    catch (e) { return []; }
  }

  private parseStatus(raw: string): Map<string, SessionStatus> {
    const m = new Map<string, SessionStatus>();
    try {
      const j = JSON.parse(raw) as Record<string, Object>;
      for (const s of (j.sessions as SessionStatus[]) ?? []) { m.set(s.session, s); }
    } catch (e) {}
    return m;
  }

  /** SPEC §3 合并规则:host 可达 + 有上报→用;有 manifest 无上报→unknown。 */
  private merge(h: HostConfig, projects: ProjectInfo[], status: Map<string, SessionStatus>): RenderHost {
    const rp: RenderProject[] = projects.map((p) => {
      const st = status.get(p.session);
      const state: AgentState = st ? st.state : 'unknown';
      return { name: p.name, session: p.session, type: p.type, state: state, since: st?.since, preview: null } as RenderProject;
    });
    return { name: h.name, addr: h.addr ?? h.name, up: true, proxy: this.effectiveProxy(h), projects: rp };
  }

  private renderFromSeed(h: HostConfig, up: boolean): RenderHost {
    const rp: RenderProject[] = (h.projects ?? []).map((p) =>
      ({ name: p.name, session: p.session, type: p.type, state: (up ? 'unknown' : 'disconnected') as AgentState, preview: null } as RenderProject));
    return { name: h.name, addr: h.addr ?? h.name, up: up, proxy: this.effectiveProxy(h), projects: rp };
  }

  /** 🔒 徽章:生效 proxy 名(SPEC §5.1 归属规则:直连用自己的,多跳用跳板的)。 */
  private effectiveProxy(h: HostConfig): string | undefined {
    if (h.via) {
      const jump = this.hosts.find((x) => x.name === h.via);
      return jump?.proxy;   // 经 via 的内网 host → 跳板的 proxy
    }
    return h.proxy;
  }
}
