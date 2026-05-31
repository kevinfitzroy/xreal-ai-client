/**
 * 热词 —— 对齐 Android `Hotwords`(SPEC §7)。
 * 内置通用词(Claude Code 控制命令,所有 project 继承)+ project 级 manifest hotwords,合并后喂 ASR。
 * 克制:token 预算上限,通用词优先。
 */
export class Hotwords {
  /** 内置通用词:Claude Code 控制命令 + 高频易错专名。 */
  static readonly BASE: string[] = [
    'compact', 'context', 'agent', 'resume', 'model', 'continue',
    'Claude', 'Maestro', 'tmux', 'commit', 'kubectl', 'Grafana'
  ];

  /** 合并通用词 + project 热词,去重,按预算截断(通用词优先)。 */
  static merge(projectWords: string[] | undefined, budget: number = 32): string[] {
    const seen = new Set<string>();
    const out: string[] = [];
    const push = (w: string): void => { if (w && !seen.has(w) && out.length < budget) { seen.add(w); out.push(w); } };
    for (const w of Hotwords.BASE) { push(w); }
    for (const w of (projectWords ?? [])) { push(w); }
    return out;
  }
}
