/* twig —— 前端主逻辑。
 *
 * 没有框架也没有构建步骤：改完刷新页面就生效。
 * 代码按功能分块，从上到下依次是：
 *   基础工具 → 全局状态 → 仓库开关 → 侧栏（分支勾选）→ 提交图 →
 *   提交详情 → 工作区暂存 → 各种操作 → 右键菜单 → 启动
 */

'use strict';

/* ==================== 基础工具 ==================== */

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};

// 令牌从 URL 拿一次就存进 localStorage，然后把它从地址栏抹掉，免得被复制粘贴出去。
//
// 用 localStorage 而不是 sessionStorage：这样把 http://127.0.0.1:7890/ 存成书签、
// 或者新开一个标签页，都还认得令牌，不用回终端重新复制一遍带 token 的地址。
const TOKEN = (() => {
  const u = new URL(location.href);
  const t = u.searchParams.get('token');
  if (t) {
    localStorage.setItem('twig-token', t);
    u.searchParams.delete('token');
    history.replaceState(null, '', u.pathname + u.search);
    return t;
  }
  return localStorage.getItem('twig-token') || '';
})();

async function api(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: { 'X-Twig-Token': TOKEN, 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = { error: text }; }
  if (!res.ok) {
    const err = new Error((data && data.error) || res.statusText);
    err.output = data && data.output;
    throw err;
  }
  return data;
}

const apiGet = (path) => api(path);
const apiPost = (path, body) => api(path, { method: 'POST', body: JSON.stringify(body || {}) });

function setStatus(msg, kind = '') {
  const bar = $('statusMsg');
  bar.textContent = msg;
  bar.parentElement.className = 'statusbar' + (kind ? ' ' + kind : '');
}

// multiKey 判断"加选"那个修饰键有没有按下。
//
// macOS 上 Ctrl + 点击等同于右键，所以那里只认 Cmd；其他平台认 Ctrl。
// 两边都认的话，Mac 用户 Ctrl + 点击会同时弹出右键菜单又进比较模式。
const IS_MAC = /Mac/i.test(navigator.platform || navigator.userAgent || '');
const multiKey = (ev) => (IS_MAC ? ev.metaKey : ev.ctrlKey);

// plural: 数量 + 单复数正确的名词，如 1 branch / 3 branches。
const plural = (n, word, plur) => `${n} ${n === 1 ? word : (plur || word + 's')}`;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function fmtDate(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  const now = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (d.toDateString() === now.toDateString()) return `Today ${hm}`;
  const y = new Date(now.getTime() - 86400000);
  if (d.toDateString() === y.toDateString()) return `Yesterday ${hm}`;
  const md = `${MONTHS[d.getMonth()]} ${d.getDate()}`;
  return d.getFullYear() === now.getFullYear() ? `${md}, ${hm}` : `${md}, ${d.getFullYear()}`;
}

/* ==================== 全局状态 ==================== */

const S = {
  repo: null,          // { path, name, head, remotes }
  refs: [],            // 所有 ref
  head: null,          // { branch, hash, detached }
  graph: null,         // { commits, edges, width }
  status: null,        // 工作区状态
  stashes: [],
  // selected 是图上勾选的分支（ref 全名）。空集合表示"画全部"。
  selected: new Set(),
  selCommit: null,     // 当前选中的提交 hash
  detail: null,        // 当前提交详情
  detailFile: null,    // 详情里选中的文件路径
  // 比较模式：按住 Cmd / Ctrl 点第二个提交，看这两个版本之间的差异。
  // cmpB 为空表示不在比较模式；cmpA 是先选中的那条（锚点，换比较对象时不动）。
  cmpA: null,          // { hash, row }
  cmpB: null,          // { hash, row }
  cmpSwap: false,      // 反转比较方向（默认从旧版本看到新版本）
  cmpDetail: null,     // 比较结果
  cmpFile: null,       // 比较结果里选中的文件路径
  wipMode: false,      // 下方面板是否处于"工作区"模式
  wipFile: null,       // { path, staged, untracked }
  lastOutput: null,    // 上一次 git 操作的原始输出，点状态栏可以看
  limit: 500,
  firstParent: false,  // 只沿第一父提交走，把合并进来的分支细节折叠掉
  branchFilter: '',
  loading: false,
};

/* 图形常量 */
const ROW_H = 26;
const LANE_W = 15;
const DOT_R = 4;
const GRAPH_PAD = 10;
const COLORS = ['#2f6feb', '#1a7f37', '#bf3989', '#9a6700', '#6639ba',
                '#0f7c8c', '#cf222e', '#7a6a00', '#0969da', '#8250df'];
const laneColor = (i) => COLORS[((i % COLORS.length) + COLORS.length) % COLORS.length];

/* ==================== 仓库开关 ==================== */

async function bootstrap() {
  const data = await apiGet('/api/bootstrap');
  S.homeDir = data.home;
  S.recent = data.recent || [];
  if (data.repo) {
    applyRepo(data.repo);
    await refreshAll();
    // 下方面板别空着：有未提交的改动就先给工作区，否则给最新那个提交。
    if (S.status && !S.status.clean) showWip();
    else if (S.graph && S.graph.commits.length) selectCommit(S.graph.commits[0].hash);
  } else {
    openRepoModal();
  }
}

function applyRepo(info) {
  S.repo = info;
  S.selected = new Set(info.selectedRefs || []);
  $('repoName').textContent = info.name;
  document.title = `${info.name} — twig`;
}

async function openRepo(path) {
  try {
    setStatus('Opening ' + path, 'busy');
    const info = await apiPost('/api/open', { path });
    applyRepo(info);
    closeModal('repoModal');
    S.selCommit = null;
    S.detail = null;
    S.wipMode = false;
    await refreshAll();
    setStatus('Opened ' + info.path);
  } catch (e) {
    setStatus(e.message, 'err');
  }
}

/* 仓库选择弹层 */
function openRepoModal() {
  $('repoModal').hidden = false;
  renderRecent();
  browseTo(S.repo ? S.repo.path : (S.homeDir || '/'));
}

function renderRecent() {
  const box = $('recentList');
  box.textContent = '';
  if (!S.recent || !S.recent.length) {
    box.append(el('div', 'prompt-desc', 'No recent repositories yet — pick a folder below.'));
    return;
  }
  for (const p of S.recent) {
    const item = el('div', 'recent-item');
    const name = el('span', 'n', p.split('/').pop());
    const full = el('span', 'p', p);
    const rm = el('button', 'mini rm', 'Remove');
    rm.title = 'Remove from the recent list';
    rm.onclick = async (ev) => {
      ev.stopPropagation();
      const r = await apiPost('/api/forget', { path: p });
      S.recent = r.recent || [];
      renderRecent();
    };
    item.append(name, full, rm);
    item.onclick = () => openRepo(p);
    box.append(item);
  }
}

async function browseTo(path) {
  try {
    const data = await apiGet('/api/browse?path=' + encodeURIComponent(path) + '&token=' + TOKEN);
    S.browsePath = data.path;
    S.browseParent = data.parent;
    $('pathInput').value = data.path;
    $('openHereBtn').disabled = !data.selfIsGit;
    $('openHereBtn').textContent = data.selfIsGit ? 'Open This Folder' : 'Not a repository';

    const list = $('browseList');
    list.textContent = '';
    for (const e of data.entries) {
      const item = el('div', 'browse-item');
      item.append(el('span', 'ico', e.isGit ? '📁' : '📂'), el('span', 'n', e.name));
      if (e.isGit) item.append(el('span', 'git-mark', 'git repo'));
      item.onclick = () => (e.isGit ? openRepo(e.path) : browseTo(e.path));
      list.append(item);
    }
    if (!data.entries.length) list.append(el('div', 'diff-note', '(no subfolders)'));
  } catch (e) {
    setStatus(e.message, 'err');
  }
}

/* ==================== 刷新 ==================== */

// graphURL 拼出取图的接口地址：勾了哪些分支、要多少条、要不要只看主线。
function graphURL() {
  const params = new URLSearchParams({
    limit: String(S.limit),
    refs: [...S.selected].join(','),
    firstParent: S.firstParent ? '1' : '0',
  });
  return '/api/graph?' + params.toString();
}

async function refreshAll() {
  if (!S.repo) return;
  if (S.loading) return;
  S.loading = true;
  try {
    setStatus('Loading repository…', 'busy');
    const refsData = await apiGet('/api/refs');
    S.refs = refsData.refs || [];
    S.head = refsData.head;

    // 服务端记住的勾选可能引用了已删除的分支，清理掉。
    const valid = new Set(S.refs.map((r) => r.fullName));
    S.selected = new Set([...S.selected].filter((f) => valid.has(f)));

    const [graphData, status, stashData] = await Promise.all([
      apiGet(graphURL()),
      apiGet('/api/status'),
      apiGet('/api/stashes'),
    ]);
    S.graph = graphData.graph;
    S.status = status;
    S.stashes = stashData.stashes || [];

    renderSidebar();
    renderGraph();
    renderToolbar();

    if (S.wipMode) renderWip();
    else if (S.cmpB) await loadCompare();
    else if (S.selCommit) await selectCommit(S.selCommit, true);

    setStatus(plural(S.graph.commits.length, 'commit') +
      (S.selected.size ? ` (filtered to ${plural(S.selected.size, 'branch', 'branches')})` : ''));
  } catch (e) {
    setStatus(e.message, 'err');
  } finally {
    S.loading = false;
  }
}

// 只重画图，不重读 refs（勾选分支时用，快一点）。
async function refreshGraph() {
  if (!S.repo) return;
  try {
    setStatus('Redrawing graph…', 'busy');
    const data = await apiGet(graphURL());
    S.graph = data.graph;
    renderGraph();
    setStatus(plural(S.graph.commits.length, 'commit') +
      (S.selected.size ? ` (filtered to ${plural(S.selected.size, 'branch', 'branches')})` : ''));
  } catch (e) {
    setStatus(e.message, 'err');
  }
}

function renderToolbar() {
  const head = S.head || {};
  $('repoBranch').textContent = head.detached
    ? `detached HEAD @ ${(head.hash || '').slice(0, 8)}`
    : (head.branch || '');

  // 当前分支相对上游的领先 / 落后数，标在拉取和推送按钮上。
  const cur = S.refs.find((r) => r.kind === 'head' && r.isHead);
  const ahead = $('badgeAhead'), behind = $('badgeBehind');
  ahead.className = 'badge' + (cur && cur.ahead ? ' on' : '');
  ahead.textContent = cur ? cur.ahead || '' : '';
  behind.className = 'badge' + (cur && cur.behind ? ' on' : '');
  behind.textContent = cur ? cur.behind || '' : '';

  // merge / rebase 中途状态提示。
  const st = $('repoState');
  const state = S.status && S.status.state;
  if (state) {
    st.hidden = false;
    st.textContent = '';
    const label = { merge: 'Merging', rebase: 'Rebasing', 'cherry-pick': 'Cherry-picking', revert: 'Reverting' }[state] || state;
    st.append(el('span', '', label + ' — resolve conflicts to continue'));
    const cont = el('button', 'mini', 'Continue');
    cont.onclick = () => runOp({ action: 'continue', state }, 'Continue ' + label);
    const abort = el('button', 'mini', 'Abort');
    abort.onclick = () => runOp({ action: 'abort', state }, 'Abort ' + label);
    if (state !== 'merge') st.append(cont);
    st.append(abort);
  } else {
    st.hidden = true;
  }
}

/* ==================== 侧栏：分支勾选 ==================== */

function renderSidebar() {
  const filter = S.branchFilter.toLowerCase();
  const match = (r) => !filter || r.name.toLowerCase().includes(filter);

  // 工作区条目
  const wip = $('wipItem');
  const changes = S.status ? S.status.staged.length + S.status.unstaged.length + S.status.conflicts.length : 0;
  const cnt = $('wipCount');
  cnt.textContent = changes || '';
  cnt.className = 'count' + (changes ? ' on' : '');
  wip.classList.toggle('active', S.wipMode);

  const groups = {
    localList: S.refs.filter((r) => r.kind === 'head' && match(r)),
    remoteList: S.refs.filter((r) => r.kind === 'remote' && match(r)),
    tagList: S.refs.filter((r) => r.kind === 'tag' && match(r)),
  };

  for (const [boxId, refs] of Object.entries(groups)) {
    const box = $(boxId);
    box.textContent = '';
    if (!refs.length) {
      box.append(el('div', 'side-item', filter ? '(no match)' : '(none)'));
      box.firstChild.style.color = 'var(--text-faint)';
      continue;
    }
    for (const ref of refs) {
      box.append(refItem(ref));
    }
  }

  // 正在过滤时把分组都展开，否则匹配到折叠分组里的分支会看不见。
  if (filter) {
    for (const h of document.querySelectorAll('.side-head.collapsible')) {
      h.classList.remove('collapsed');
      $(h.dataset.collapse).classList.remove('hidden');
    }
  }

  // 折叠起来的分组在标题上标个数量，不用展开也知道有多少
  $('remoteCount').textContent = S.refs.filter((r) => r.kind === 'remote').length || '';
  $('tagCount').textContent = S.refs.filter((r) => r.kind === 'tag').length || '';
  $('stashCount').textContent = S.stashes.length || '';

  // 提示当前图上画的是哪些分支
  const hint = $('filterHint');
  hint.textContent = S.selected.size
    ? `Graph limited to ${plural(S.selected.size, 'branch', 'branches')}`
    : '';

  renderStashList();
}

function refItem(ref) {
  const item = el('div', 'side-item');
  if (ref.isHead) item.classList.add('is-head');

  // 勾选框：决定这条分支画不画进图里 —— 这是 twig 的核心特性。
  const chk = el('input');
  chk.type = 'checkbox';
  chk.checked = S.selected.has(ref.fullName);
  chk.title = 'When anything is checked, the graph draws only checked branches';
  chk.onclick = (ev) => ev.stopPropagation();
  chk.onchange = () => {
    if (chk.checked) S.selected.add(ref.fullName);
    else S.selected.delete(ref.fullName);
    $('filterHint').textContent = S.selected.size
      ? `Graph limited to ${plural(S.selected.size, 'branch', 'branches')}` : '';
    refreshGraph();
  };

  const dot = el('span', 'dot');
  dot.style.background = ref.kind === 'tag' ? '#9a6700' : (ref.kind === 'remote' ? 'var(--text-faint)' : 'var(--accent)');

  const label = el('span', 'side-label', ref.name);
  label.title = ref.name + (ref.upstream ? `  →  ${ref.upstream}` : '');

  item.append(chk, dot, label);

  if (ref.ahead || ref.behind) {
    const t = [];
    if (ref.ahead) t.push('↑' + ref.ahead);
    if (ref.behind) t.push('↓' + ref.behind);
    item.append(el('span', 'track', t.join(' ')));
  }

  // 双击 = 切换到这条分支；单击 = 跳到它在图上的位置。
  item.ondblclick = () => checkoutRef(ref);
  item.onclick = () => jumpToRef(ref);
  item.oncontextmenu = (ev) => showRefMenu(ev, ref);
  return item;
}

function renderStashList() {
  const box = $('stashList');
  box.textContent = '';
  if (!S.stashes.length) {
    const n = el('div', 'side-item', '(none)');
    n.style.color = 'var(--text-faint)';
    box.append(n);
    return;
  }
  for (const st of S.stashes) {
    const item = el('div', 'side-item');
    item.append(el('span', 'side-label', st.subject));
    item.title = `${st.ref} · ${fmtDate(st.time)}`;
    item.oncontextmenu = (ev) => showStashMenu(ev, st);
    item.ondblclick = () => runOp({ action: 'stashApply', ref: st.ref, drop: true }, 'Pop stash');
    box.append(item);
  }
}

function jumpToRef(ref) {
  if (!S.graph) return;
  const c = S.graph.commits.find((c) => c.hash === ref.hash);
  if (!c) {
    setStatus(`${ref.name} is not on the graph (not checked, or beyond the shown commit count)`);
    return;
  }
  selectCommit(c.hash);
  const row = document.querySelector(`.row[data-hash="${c.hash}"]`);
  if (row) row.scrollIntoView({ block: 'center', behavior: 'smooth' });
}

/* ==================== 提交图 ==================== */

function renderGraph() {
  const rows = $('rows');
  const svg = $('graphSvg');
  rows.textContent = '';
  svg.textContent = '';

  const g = S.graph;
  const empty = $('graphEmpty');
  const hasWip = S.status && !S.status.clean;

  if (!g || !g.commits.length) {
    empty.hidden = false;
    empty.textContent = S.selected.size
      ? 'No commits on the checked branches — try checking different ones.'
      : 'This repository has no commits yet.';
    $('graphInner').style.height = '0px';
    return;
  }
  empty.hidden = true;

  const graphW = Math.max(60, GRAPH_PAD * 2 + g.width * LANE_W);
  document.documentElement.style.setProperty('--graph-w', graphW + 'px');

  const wipOffset = hasWip ? ROW_H : 0;
  const totalH = wipOffset + g.commits.length * ROW_H;

  svg.setAttribute('width', graphW);
  svg.setAttribute('height', totalH);
  svg.style.width = graphW + 'px';
  svg.style.height = totalH + 'px';
  $('graphInner').style.height = totalH + 'px';

  const laneX = (lane) => GRAPH_PAD + lane * LANE_W + LANE_W / 2;
  const rowY = (row) => wipOffset + row * ROW_H + ROW_H / 2;

  // 先画连线，再画节点，节点才不会被线盖住。
  const frag = document.createDocumentFragment();
  for (const e of g.edges) {
    const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    p.setAttribute('d', edgePath(e, laneX, rowY));
    p.setAttribute('fill', 'none');
    p.setAttribute('stroke', laneColor(e.color));
    p.setAttribute('stroke-width', e.merge ? 1.5 : 2);
    p.setAttribute('stroke-linecap', 'round');
    if (e.merge) p.setAttribute('opacity', '.85');
    frag.append(p);
  }

  // 工作区那一行：一个空心圈，用虚线连到 HEAD 所在的提交。
  if (hasWip) {
    const headCommit = S.head && g.commits.find((c) => c.hash === S.head.hash);
    const lane = headCommit ? headCommit.lane : 0;
    const x = laneX(lane);
    if (headCommit) {
      const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      p.setAttribute('d', `M ${x} ${ROW_H / 2} L ${x} ${rowY(headCommit.row)}`);
      p.setAttribute('stroke', 'var(--text-faint)');
      p.setAttribute('stroke-width', '1.5');
      p.setAttribute('stroke-dasharray', '3 3');
      p.setAttribute('fill', 'none');
      frag.append(p);
    }
    const c = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    c.setAttribute('cx', x); c.setAttribute('cy', ROW_H / 2); c.setAttribute('r', DOT_R);
    c.setAttribute('fill', 'var(--bg)');
    c.setAttribute('stroke', 'var(--text-faint)');
    c.setAttribute('stroke-width', '2');
    c.setAttribute('stroke-dasharray', '2 2');
    frag.append(c);
  }

  for (const c of g.commits) {
    const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    dot.setAttribute('cx', laneX(c.lane));
    dot.setAttribute('cy', rowY(c.row));
    const isMerge = (c.parents || []).length > 1;
    dot.setAttribute('r', isMerge ? DOT_R - 0.5 : DOT_R);
    const isHead = S.head && c.hash === S.head.hash;
    dot.setAttribute('fill', isHead ? 'var(--bg)' : laneColor(colorOfCommit(c)));
    dot.setAttribute('stroke', laneColor(colorOfCommit(c)));
    dot.setAttribute('stroke-width', isHead ? 3 : 1);
    frag.append(dot);
  }
  svg.append(frag);

  // 行内容
  const rowsFrag = document.createDocumentFragment();
  if (hasWip) rowsFrag.append(wipRow());
  for (const c of g.commits) rowsFrag.append(commitRow(c));
  rows.append(rowsFrag);
  markRows();

  $('graphStat').textContent =
    `${plural(g.commits.length, 'commit')} · ${plural(g.width, 'lane')}` +
    (S.selected.size ? ` · ${plural(S.selected.size, 'branch', 'branches')}` : ' · all branches') +
    (S.firstParent ? ' · first parent only' : '');
}

// colorOfCommit：节点颜色跟着它下面那条主干线走。
function colorOfCommit(c) {
  const g = S.graph;
  const out = g.edges.find((e) => e.fromRow === c.row && !e.merge);
  if (out) return out.color;
  const inc = g.edges.find((e) => e.toRow === c.row);
  return inc ? inc.color : c.lane;
}

// edgePath：连线的形状是"出发拐一下 → 沿中间轨道直下 → 到达前拐一下"。
function edgePath(e, laneX, rowY) {
  const x0 = laneX(e.fromLane), y0 = rowY(e.fromRow);
  const xm = laneX(e.lane);
  const x1 = laneX(e.toLane), y1 = rowY(e.toRow);

  if (x0 === xm && xm === x1) return `M ${x0} ${y0} L ${x1} ${y1}`;

  // 只隔一行还要拐两次：直接一条曲线连过去，免得挤成折线。
  if (x0 !== xm && xm !== x1 && e.toRow - e.fromRow <= 1) {
    return `M ${x0} ${y0} C ${x0} ${y0 + ROW_H / 2}, ${x1} ${y1 - ROW_H / 2}, ${x1} ${y1}`;
  }

  const parts = [`M ${x0} ${y0}`];
  let y = y0;
  if (x0 !== xm) {
    const yb = Math.min(y0 + ROW_H, y1);
    parts.push(`C ${x0} ${y0 + ROW_H / 2}, ${xm} ${yb - ROW_H / 2}, ${xm} ${yb}`);
    y = yb;
  }
  if (xm !== x1) {
    const ya = Math.max(y1 - ROW_H, y);
    if (ya > y) parts.push(`L ${xm} ${ya}`);
    parts.push(`C ${xm} ${ya + ROW_H / 2}, ${x1} ${y1 - ROW_H / 2}, ${x1} ${y1}`);
  } else if (y1 > y) {
    parts.push(`L ${xm} ${y1}`);
  }
  return parts.join(' ');
}

function wipRow() {
  const row = el('div', 'row wip-row');
  row.append(el('div', 'row-graph'));
  const msg = el('div', 'row-msg');
  const n = S.status.staged.length + S.status.unstaged.length + S.status.conflicts.length;
  msg.append(el('span', 'txt', `Uncommitted changes (${plural(n, 'file')})`));
  row.append(msg, el('div', 'row-author'), el('div', 'row-date'), el('div', 'row-hash'));
  row.classList.toggle('sel', S.wipMode);
  row.onclick = () => showWip();
  return row;
}

function commitRow(c) {
  const row = el('div', 'row');
  row.dataset.hash = c.hash;
  row.style.height = ROW_H + 'px';
  row.append(el('div', 'row-graph'));

  const msg = el('div', 'row-msg');
  for (const ref of c.refs || []) {
    const isCurrent = ref.kind === 'head' && S.head && !S.head.detached && ref.name === S.head.branch;
    const tag = el('span', 'reftag ' + ref.kind + (isCurrent ? ' current' : ''), ref.name);
    tag.title = ref.fullName;
    tag.oncontextmenu = (ev) => { ev.stopPropagation(); showRefMenu(ev, ref); };
    msg.append(tag);
  }
  msg.append(el('span', 'txt', c.subject));
  row.append(msg);

  row.append(el('div', 'row-author', c.authorName));
  row.append(el('div', 'row-date', fmtDate(c.timestamp)));
  row.append(el('div', 'row-hash', c.short));

  row.onclick = (ev) => {
    // 按住 Cmd（macOS）/ Ctrl（其他平台）：把这一条和当前选中的那条放在一起比较。
    if (multiKey(ev)) toggleCompare(c);
    else selectCommit(c.hash);
  };
  row.oncontextmenu = (ev) => showCommitMenu(ev, c);
  return row;
}

/* ==================== 提交详情 ==================== */

async function selectCommit(hash, keepScroll = false) {
  S.selCommit = hash;
  S.wipMode = false;
  S.cmpA = S.cmpB = S.cmpDetail = S.cmpFile = null;
  S.cmpSwap = false;
  $('wipItem').classList.remove('active');
  markRows();

  $('detailEmpty').hidden = true;
  $('wipDetail').hidden = true;
  $('commitDetail').hidden = false;

  try {
    const d = await apiGet('/api/commit?hash=' + encodeURIComponent(hash));
    S.detail = d;
    if (!keepScroll || !S.detailFile || !d.files.some((f) => f.path === S.detailFile)) {
      S.detailFile = d.files.length ? d.files[0].path : null;
    }
    renderCommitDetail();
  } catch (e) {
    setStatus(e.message, 'err');
  }
}

function renderCommitDetail() {
  const d = S.detail;
  if (!d) return;

  $('dSubject').textContent = d.subject;

  const meta = $('dMeta');
  meta.textContent = '';
  const add = (label, value, mono) => {
    const s = el('span');
    s.append(el('span', '', label + ' '));
    const v = mono ? el('code', '', value) : el('span', '', value);
    s.append(v);
    meta.append(s);
  };
  add('Author', `${d.authorName} <${d.authorMail}>`);
  add('Date', new Date(d.timestamp * 1000).toLocaleString('en-US'));
  add('Commit', d.hash, true);
  const parents = d.parents || [];
  if (parents.length) add(parents.length > 1 ? 'Parents (merge)' : 'Parent', parents.map((p) => p.slice(0, 8)).join('  '), true);

  $('dBody').textContent = d.body || '';

  renderFileList(d.files, S.detailFile, '(this commit changes no files)',
    (path) => { S.detailFile = path; renderCommitDetail(); });
  const file = d.files.find((f) => f.path === S.detailFile);
  renderDiff($('dDiff'), file ? [file] : []);
}

// renderFileList 画详情面板左边那一列文件。
//
// 只负责列表，不负责右边的 diff——两种模式取 diff 的方式不一样：
// 看单个提交时内容已经跟着详情一起来了，比较两个版本时要按文件单独去取。
function renderFileList(files, current, emptyText, onPick) {
  const list = $('dFiles');
  list.textContent = '';
  if (!files.length) list.append(el('div', 'diff-note', emptyText));
  for (const f of files) {
    const item = el('div', 'file-item');
    if (f.path === current) item.classList.add('sel');
    item.append(el('span', 'st ' + f.status, f.status));
    const p = el('span', 'fp', f.path);
    p.title = f.origPath ? `${f.origPath} → ${f.path}` : f.path;
    item.append(p);
    const stat = el('span', 'stat');
    if (f.additions) stat.append(el('span', 'a', '+' + f.additions));
    if (f.deletions) stat.append(el('span', 'd', ' -' + f.deletions));
    item.append(stat);
    item.onclick = () => onPick(f.path);
    list.append(item);
  }
}

/* ==================== 比较两个提交 ==================== */

// markRows 刷新提交列表上的选中高亮。
// 普通模式只亮一行；比较模式亮两行，并用行首的色条标出谁是起点、谁是终点。
function markRows() {
  const cmp = !!S.cmpB;
  const [from, to] = cmp ? compareEnds() : [null, null];
  for (const r of document.querySelectorAll('.row')) {
    const h = r.dataset.hash;
    // 工作区那一行没有 hash，它的高亮只跟着 wipMode 走。
    // 这里必须显式处理：漏掉的话它的高亮会一直留着，跟提交行同时亮。
    if (!h) { r.classList.toggle('sel', S.wipMode); continue; }
    r.classList.toggle('sel', cmp ? (h === from || h === to) : (!S.wipMode && h === S.selCommit));
    r.classList.toggle('cmp-from', cmp && h === from);
    r.classList.toggle('cmp-to', cmp && h === to);
  }
}

// compareEnds 定出比较的方向：图上靠下的那条（row 更大）是更早的版本，
// 拿它当起点，看到的就是"从旧版本到新版本发生了什么"。Swap 按钮可以反过来。
function compareEnds() {
  const a = S.cmpA, b = S.cmpB;
  const older = a.row >= b.row ? a : b;
  const newer = older === a ? b : a;
  return S.cmpSwap ? [newer.hash, older.hash] : [older.hash, newer.hash];
}

// toggleCompare 处理 Cmd / Ctrl + 点击一条提交。
function toggleCompare(c) {
  if (!S.cmpB) {
    // 还没进比较模式：拿当前选中的那条当另一端。没有选中的话就当普通点击。
    const anchor = ((S.graph && S.graph.commits) || []).find((x) => x.hash === S.selCommit);
    if (!anchor || anchor.hash === c.hash) { selectCommit(c.hash); return; }
    S.cmpA = { hash: anchor.hash, row: anchor.row };
    S.cmpB = { hash: c.hash, row: c.row };
  } else if (c.hash === S.cmpA.hash || c.hash === S.cmpB.hash) {
    exitCompare();                       // 再点已经选中的任一端就退出比较
    return;
  } else {
    S.cmpB = { hash: c.hash, row: c.row }; // 换一个比较对象，锚点不动
  }
  S.cmpSwap = false;
  S.cmpFile = null;
  loadCompare();
}

// exitCompare 回到"只看一个提交"的普通模式，选中留在锚点那条上。
function exitCompare() {
  const back = S.cmpA ? S.cmpA.hash : S.selCommit;
  S.cmpA = S.cmpB = S.cmpDetail = S.cmpFile = null;
  S.cmpSwap = false;
  if (back) selectCommit(back);
  else markRows();
}

async function loadCompare() {
  if (!S.cmpB) return;
  const [from, to] = compareEnds();
  S.wipMode = false;
  $('wipItem').classList.remove('active');
  $('detailEmpty').hidden = true;
  $('wipDetail').hidden = true;
  $('commitDetail').hidden = false;
  markRows();

  try {
    const d = await apiGet('/api/rangediff?from=' + encodeURIComponent(from) +
                           '&to=' + encodeURIComponent(to));
    S.cmpDetail = d;
    if (!S.cmpFile || !d.files.some((f) => f.path === S.cmpFile)) {
      S.cmpFile = d.files.length ? d.files[0].path : null;
    }
    renderCompareDetail();
    loadCompareFile();
  } catch (e) {
    setStatus(e.message, 'err');
  }
}

// cmpFileSeq 给每次取文件内容编号：连着点几个文件时，只认最后一次的结果，
// 免得先发出的请求后返回、把已经换掉的文件内容画上去。
let cmpFileSeq = 0;

// loadCompareFile 取比较模式下当前选中那个文件的逐行差异。
//
// 文件清单是一次性拿到的，内容按需单独取，原因见后端 parseDiffStats 的注释。
async function loadCompareFile() {
  const box = $('dDiff');
  const f = ((S.cmpDetail && S.cmpDetail.files) || []).find((x) => x.path === S.cmpFile);
  if (!f) { renderDiff(box, []); return; }

  const seq = ++cmpFileSeq;
  const [from, to] = compareEnds();
  box.textContent = '';
  box.append(el('div', 'diff-note', 'Loading…'));
  try {
    const d = await apiGet('/api/rangefilediff' +
      '?from=' + encodeURIComponent(from) +
      '&to=' + encodeURIComponent(to) +
      '&path=' + encodeURIComponent(f.path) +
      (f.origPath ? '&orig=' + encodeURIComponent(f.origPath) : ''));
    if (seq !== cmpFileSeq) return;
    renderDiff(box, d.files || []);
  } catch (e) {
    if (seq !== cmpFileSeq) return;
    box.textContent = '';
    box.append(el('div', 'diff-note', e.message));
  }
}

function renderCompareDetail() {
  const d = S.cmpDetail;
  if (!d) return;

  $('dSubject').textContent = `Comparing ${d.from.short} … ${d.to.short}`;

  const meta = $('dMeta');
  meta.textContent = '';
  const end = (label, c, cls) => {
    const s = el('span', 'cmp-end ' + cls);
    s.append(el('span', '', label + ' '));
    s.append(el('code', '', c.short));
    s.append(el('span', '', ' ' + c.subject));
    s.title = `${c.authorName} · ${new Date(c.timestamp * 1000).toLocaleString('en-US')}`;
    meta.append(s);
  };
  end('From', d.from, 'from');
  end('To', d.to, 'to');

  // 这两个版本是一前一后，还是从某处分叉、各自走了一段。
  let rel;
  if (d.ahead && d.behind) rel = `diverged · ${d.ahead} ahead, ${d.behind} behind`;
  else if (d.ahead) rel = `${plural(d.ahead, 'commit')} ahead`;
  else if (d.behind) rel = `${plural(d.behind, 'commit')} behind`;
  else rel = 'same commit';
  meta.append(el('span', '', rel));
  meta.append(el('span', '', plural(d.files.length, 'file') + ' changed'));

  meta.append(mkMini('⇄ Swap', () => { S.cmpSwap = !S.cmpSwap; S.cmpFile = null; loadCompare(); }));
  meta.append(mkMini('Exit compare', exitCompare));

  $('dBody').textContent = '';
  renderFileList(d.files, S.cmpFile, '(these two versions are identical)',
    (path) => { S.cmpFile = path; renderCompareDetail(); loadCompareFile(); });
}

/* diff 渲染 */
function renderDiff(box, files) {
  box.textContent = '';
  if (!files.length) {
    box.append(el('div', 'diff-note', 'Select a file to see the changes'));
    return;
  }
  for (const f of files) {
    const head = el('div', 'diff-file-head');
    head.append(el('span', '', f.origPath ? `${f.origPath} → ${f.path}` : f.path));
    if (f.additions || f.deletions) {
      const s = el('span', 'stat');
      if (f.additions) s.append(el('span', 'a', '+' + f.additions + ' '));
      if (f.deletions) s.append(el('span', 'd', '-' + f.deletions));
      head.append(s);
    }
    box.append(head);

    if (f.binary) {
      box.append(el('div', 'diff-note', 'Binary file — no text diff shown.'));
      continue;
    }
    if (!f.hunks || !f.hunks.length) {
      box.append(el('div', 'diff-note', 'No text differences (mode-only change, or identical content).'));
      continue;
    }

    const table = el('table', 'diff-table');
    const tbody = el('tbody');
    for (const h of f.hunks) {
      const hr = el('tr', 'hunk');
      const hc = el('td');
      hc.colSpan = 3;
      hc.textContent = h.header ? `@@ ${h.header}` : '@@';
      hr.append(hc);
      tbody.append(hr);

      for (const l of h.lines) {
        const tr = el('tr', l.kind);
        tr.append(el('td', 'ln', l.oldLine || ''));
        tr.append(el('td', 'ln', l.newLine || ''));
        const sign = l.kind === 'add' ? '+' : l.kind === 'del' ? '-' : ' ';
        tr.append(el('td', 'tx', sign + l.text));
        tbody.append(tr);
      }
    }
    table.append(tbody);
    box.append(table);

    if (f.truncated) {
      box.append(el('div', 'diff-note', 'Diff is very large — only the first part is shown.'));
    }
  }
}

/* ==================== 工作区暂存 ==================== */

function showWip() {
  S.wipMode = true;
  S.selCommit = null;
  for (const r of document.querySelectorAll('.row')) r.classList.remove('sel');
  const wipRowEl = document.querySelector('.row.wip-row');
  if (wipRowEl) wipRowEl.classList.add('sel');
  $('wipItem').classList.add('active');
  $('detailEmpty').hidden = true;
  $('commitDetail').hidden = true;
  $('wipDetail').hidden = false;
  renderWip();
}

function renderWip() {
  const st = S.status;
  if (!st) return;

  const fill = (box, files, staged) => {
    box.textContent = '';
    if (!files.length) {
      box.append(el('div', 'diff-note', '(empty)'));
      return;
    }
    for (const f of files) {
      const item = el('div', 'file-item');
      if (S.wipFile && S.wipFile.path === f.path && S.wipFile.staged === staged) item.classList.add('sel');

      const code = f.conflict ? 'U' : (f.untracked ? 'A' : (staged ? f.index : f.work));
      item.append(el('span', 'st ' + code, code));
      const p = el('span', 'fp', f.path);
      p.title = f.origPath ? `${f.origPath} → ${f.path}` : f.path;
      item.append(p);

      const act = el('span', 'act');
      if (staged) {
        act.append(mkMini('Unstage', (ev) => {
          ev.stopPropagation();
          runOp({ action: 'unstage', paths: [f.path] }, 'Unstage');
        }));
      } else {
        act.append(mkMini('Stage', (ev) => {
          ev.stopPropagation();
          runOp({ action: 'stage', paths: [f.path] }, 'Stage');
        }));
        act.append(mkMini('Discard', (ev) => {
          ev.stopPropagation();
          if (!confirm(`Discard changes to ${f.path}?\nThis cannot be undone.`)) return;
          runOp(f.untracked
            ? { action: 'discard', untracked: [f.path] }
            : { action: 'discard', paths: [f.path] }, 'Discard changes');
        }));
      }
      item.append(act);

      // renderWip 末尾会自己拉 diff，这里不用再拉一次。
      item.onclick = () => {
        S.wipFile = { path: f.path, staged, untracked: !!f.untracked };
        renderWip();
      };
      box.append(item);
    }
  };

  const unstaged = [...st.conflicts, ...st.unstaged];
  fill($('unstagedList'), unstaged, false);
  fill($('stagedList'), st.staged, true);

  // 选中的文件可能已经被暂存/丢弃了，回落到第一个可选文件。
  const stillThere = S.wipFile &&
    (S.wipFile.staged ? st.staged : unstaged).some((f) => f.path === S.wipFile.path);
  if (!stillThere) {
    const first = unstaged[0] || st.staged[0];
    S.wipFile = first
      ? { path: first.path, staged: !unstaged.length, untracked: !!first.untracked }
      : null;
  }
  loadWipDiff();

  const canCommit = st.staged.length > 0 || $('amendChk').checked;
  $('commitBtn').disabled = !canCommit;
  $('commitHint').textContent = st.staged.length
    ? `${plural(st.staged.length, 'file')} to commit`
    : ($('amendChk').checked ? 'Will amend the last commit' : 'Stage something to commit');
}

function mkMini(text, onclick) {
  const b = el('button', 'mini', text);
  b.onclick = onclick;
  return b;
}

async function loadWipDiff() {
  const box = $('wipDiff');
  if (!S.wipFile) {
    box.textContent = '';
    box.append(el('div', 'diff-note', 'No changes in the working copy'));
    return;
  }
  const { path, staged, untracked } = S.wipFile;
  try {
    const q = `/api/filediff?path=${encodeURIComponent(path)}&staged=${staged ? 1 : 0}&untracked=${untracked ? 1 : 0}`;
    const data = await apiGet(q);
    renderDiff(box, data.files || []);
  } catch (e) {
    box.textContent = '';
    box.append(el('div', 'diff-note', e.message));
  }
}

/* ==================== 操作 ==================== */

// runOp 是所有写操作的统一出口：调接口 → 出错就弹原始输出 → 成功就刷新。
//
// 成功时不弹窗打断：git 的原始输出存起来，状态栏给一句摘要，
// 想看全文点状态栏。失败时才弹出来，因为那种时候一定要看清报错。
async function runOp(payload, label, opts = {}) {
  try {
    setStatus(label + '…', 'busy');
    const res = await apiPost('/api/op', payload);
    await refreshAll();

    const out = (res.output || '').trim();
    S.lastOutput = out ? { title: label, text: out } : null;
    const tail = out ? out.split('\n').filter((l) => l.trim()).pop() : '';
    setStatus(label + ' done' + (tail ? ' · ' + tail : '') + (out ? '  (click for full output)' : ''));
    return true;
  } catch (e) {
    const text = ((e.output || '') + '\n' + e.message).trim();
    S.lastOutput = { title: label + ' failed', text };
    setStatus(label + ' failed: ' + e.message, 'err');
    showOutput(label + ' failed', text);
    await refreshAll();
    return false;
  }
}

function showOutput(title, text) {
  $('outputTitle').textContent = '';
  $('outputTitle').append(document.createTextNode(title));
  const x = el('button', 'x', '×');
  x.onclick = () => closeModal('outputModal');
  $('outputTitle').append(x);
  $('outputText').textContent = (text || '').trim() || '(no output)';
  $('outputModal').hidden = false;
}

function closeModal(id) { $(id).hidden = true; }

// prompt 弹层：比浏览器自带的 prompt 好看，还能带一个复选框。
function askInput({ title, desc, value, placeholder, checkbox }) {
  return new Promise((resolve) => {
    $('promptTitle').textContent = '';
    $('promptTitle').append(document.createTextNode(title));
    const x = el('button', 'x', '×');
    x.onclick = () => { closeModal('promptModal'); resolve(null); };
    $('promptTitle').append(x);

    $('promptDesc').textContent = desc || '';
    const input = $('promptInput');
    input.value = value || '';
    input.placeholder = placeholder || '';

    const wrap = $('promptChkWrap');
    const chk = $('promptChk');
    if (checkbox) {
      wrap.hidden = false;
      $('promptChkLabel').textContent = checkbox.label;
      chk.checked = !!checkbox.checked;
    } else {
      wrap.hidden = true;
      chk.checked = false;
    }

    const done = (ok) => {
      closeModal('promptModal');
      $('promptOk').onclick = null;
      input.onkeydown = null;
      resolve(ok ? { value: input.value.trim(), checked: chk.checked } : null);
    };
    $('promptOk').onclick = () => done(true);
    input.onkeydown = (ev) => {
      if (ev.key === 'Enter') done(true);
      if (ev.key === 'Escape') done(false);
    };
    for (const b of $('promptModal').querySelectorAll('[data-close]')) {
      b.onclick = () => done(false);
    }

    $('promptModal').hidden = false;
    input.focus();
    input.select();
  });
}

async function checkoutRef(ref) {
  if (ref.kind === 'remote') {
    await runOp({ action: 'checkoutRemote', target: ref.name }, `Create local branch from ${ref.name}`);
  } else if (ref.kind === 'tag') {
    if (!confirm(`Checking out tag ${ref.name} will leave you on a detached HEAD.\nContinue?`)) return;
    await runOp({ action: 'checkout', target: ref.name }, `Checkout ${ref.name}`);
  } else {
    await runOp({ action: 'checkout', target: ref.name }, `Checkout ${ref.name}`);
  }
  await ensureCurrentBranchVisible();
}

// ensureCurrentBranchVisible：切完分支总该在图上看得见它。
// 只在"正在筛选"时才动手，没筛选时图上本来就有全部分支。
async function ensureCurrentBranchVisible() {
  if (!S.selected.size || !S.head || S.head.detached) return;
  const cur = S.refs.find((r) => r.kind === 'head' && r.name === S.head.branch);
  if (cur && !S.selected.has(cur.fullName)) {
    S.selected.add(cur.fullName);
    renderSidebar();
    await refreshGraph();
  }
}

async function doCommit() {
  const msg = $('commitMsg').value;
  const amend = $('amendChk').checked;
  if (!msg.trim() && !amend) {
    setStatus('Commit message cannot be empty', 'err');
    $('commitMsg').focus();
    return;
  }
  const ok = await runOp({ action: 'commit', message: msg, amend }, 'Commit');
  if (ok) {
    $('commitMsg').value = '';
    $('amendChk').checked = false;
  }
}

async function doNewBranch(startPoint) {
  const r = await askInput({
    title: 'New Branch',
    desc: startPoint ? `Starting from ${startPoint}` : 'Starting from the current HEAD',
    placeholder: 'feature/my-branch',
    checkbox: { label: 'Check out after creating', checked: true },
  });
  if (!r || !r.value) return;
  await runOp({ action: 'createBranch', name: r.value, startPoint: startPoint || 'HEAD', checkout: r.checked },
    `Create branch ${r.value}`);
}

async function doStash() {
  if (S.status && S.status.clean) {
    setStatus('Working copy is clean — nothing to stash');
    return;
  }
  const r = await askInput({
    title: 'Stash Changes',
    desc: 'Put the current uncommitted changes aside; you can bring them back later.',
    placeholder: 'Message (optional)',
    checkbox: { label: 'Include untracked files', checked: true },
  });
  if (!r) return;
  await runOp({ action: 'stashPush', message: r.value, includeUntracked: r.checked }, 'Stash');
}

/* ==================== 右键菜单 ==================== */

function showMenu(ev, items) {
  ev.preventDefault();
  ev.stopPropagation();
  const menu = $('ctxMenu');
  menu.textContent = '';
  for (const it of items) {
    if (it.sep) { menu.append(el('div', 'ctx-sep')); continue; }
    if (it.title) { menu.append(el('div', 'ctx-title', it.title)); continue; }
    const n = el('div', 'ctx-item' + (it.danger ? ' danger' : ''), it.label);
    n.onclick = () => { hideMenu(); it.run(); };
    menu.append(n);
  }
  menu.hidden = false;
  // 先显示再量尺寸，免得菜单跑到屏幕外面。
  const w = menu.offsetWidth, h = menu.offsetHeight;
  menu.style.left = Math.min(ev.clientX, innerWidth - w - 8) + 'px';
  menu.style.top = Math.min(ev.clientY, innerHeight - h - 8) + 'px';
}
function hideMenu() { $('ctxMenu').hidden = true; }

function showCommitMenu(ev, c) {
  // Cmd / Ctrl + 点击是同一件事，这里再给一个看得见的入口，免得功能藏起来没人知道。
  const anchor = S.cmpB ? null : ((S.graph && S.graph.commits) || []).find((x) => x.hash === S.selCommit);
  const items = [
    { title: `${c.short}  ${c.subject}` },
    ...(anchor && anchor.hash !== c.hash
      ? [{ label: `Compare with ${anchor.short}`, run: () => toggleCompare(c) }, { sep: true }]
      : []),
    { label: 'Checkout this commit (detached HEAD)', run: () => runOp({ action: 'checkout', target: c.hash }, 'Checkout ' + c.short) },
    { label: 'Create branch here…', run: () => doNewBranch(c.hash) },
    { sep: true },
    { label: 'Merge into current branch', run: () => runOp({ action: 'merge', target: c.hash }, 'Merge ' + c.short) },
    { label: 'Rebase current branch onto this', run: () => runOp({ action: 'rebase', target: c.hash }, 'Rebase onto ' + c.short) },
    { sep: true },
    { label: 'Copy full SHA', run: () => copy(c.hash) },
    { label: 'Copy commit message', run: () => copy(c.subject) },
    { sep: true },
    {
      label: 'Reset current branch here (keep changes)', run: () =>
        runOp({ action: 'reset', target: c.hash, mode: 'mixed' }, 'Reset to ' + c.short),
    },
    {
      label: 'Reset current branch here (discard changes)', danger: true, run: () => {
        if (!confirm(`Hard-reset the current branch to ${c.short}?\nAll uncommitted changes will be lost. This cannot be undone.`)) return;
        runOp({ action: 'reset', target: c.hash, mode: 'hard' }, 'Hard reset to ' + c.short);
      },
    },
  ];
  showMenu(ev, items);
}

function showRefMenu(ev, ref) {
  const isCurrent = ref.kind === 'head' && S.head && !S.head.detached && ref.name === S.head.branch;
  const items = [{ title: ref.name }];

  if (!isCurrent) {
    items.push({ label: 'Checkout', run: () => checkoutRef(ref) });
  }
  items.push({ label: 'Locate in graph', run: () => jumpToRef(ref) });

  const onlyThis = () => {
    S.selected = new Set([ref.fullName]);
    renderSidebar();
    refreshGraph();
  };
  items.push({ label: 'Show only this in graph', run: onlyThis });

  if (S.selected.has(ref.fullName)) {
    items.push({ label: 'Uncheck (remove from graph)', run: () => { S.selected.delete(ref.fullName); renderSidebar(); refreshGraph(); } });
  } else {
    items.push({ label: 'Check (add to graph)', run: () => { S.selected.add(ref.fullName); renderSidebar(); refreshGraph(); } });
  }

  if (!isCurrent && ref.kind !== 'tag') {
    items.push({ sep: true });
    items.push({ label: `Merge ${ref.name} into current branch`, run: () => runOp({ action: 'merge', target: ref.name }, 'Merge ' + ref.name) });
    items.push({ label: `Rebase current branch onto ${ref.name}`, run: () => runOp({ action: 'rebase', target: ref.name }, 'Rebase onto ' + ref.name) });
  }

  items.push({ sep: true }, { label: 'Copy branch name', run: () => copy(ref.name) });

  if (ref.kind === 'head' && !isCurrent) {
    items.push({
      label: 'Delete local branch', danger: true, run: async () => {
        if (!confirm(`Delete local branch ${ref.name}?`)) return;
        const ok = await runOp({ action: 'deleteBranch', name: ref.name }, 'Delete ' + ref.name);
        if (!ok && confirm(`${ref.name} is not fully merged. Force delete?`)) {
          runOp({ action: 'deleteBranch', name: ref.name, force: true }, 'Force delete ' + ref.name);
        }
      },
    });
  }
  if (ref.kind === 'remote') {
    items.push({
      label: 'Delete remote branch', danger: true, run: () => {
        if (!confirm(`Delete remote branch ${ref.name}?\nThis affects everyone on the remote.`)) return;
        runOp({ action: 'deleteRemoteBranch', name: ref.name }, 'Delete remote branch ' + ref.name);
      },
    });
  }
  showMenu(ev, items);
}

function showStashMenu(ev, st) {
  showMenu(ev, [
    { title: st.subject },
    { label: 'Pop (apply and drop)', run: () => runOp({ action: 'stashApply', ref: st.ref, drop: true }, 'Pop stash') },
    { label: 'Apply (keep the stash)', run: () => runOp({ action: 'stashApply', ref: st.ref, drop: false }, 'Apply stash') },
    { sep: true },
    {
      label: 'Drop this stash', danger: true, run: () => {
        if (!confirm(`Drop stash "${st.subject}"?\nThis cannot be undone.`)) return;
        runOp({ action: 'stashDrop', ref: st.ref }, 'Drop stash');
      },
    },
  ]);
}

function copy(text) {
  navigator.clipboard.writeText(text).then(
    () => setStatus('Copied: ' + text.slice(0, 60)),
    () => setStatus('Copy failed (blocked by the browser)', 'err'),
  );
}

/* ==================== 面板拖动 ==================== */

function makeResizer(handle, target, dir, min = 120, max = 900) {
  handle.addEventListener('mousedown', (ev) => {
    ev.preventDefault();
    const startPos = dir === 'x' ? ev.clientX : ev.clientY;
    const startSize = dir === 'x' ? target.offsetWidth : target.offsetHeight;
    const move = (e) => {
      const delta = (dir === 'x' ? e.clientX : e.clientY) - startPos;
      const size = Math.max(min, Math.min(max, startSize + delta));
      if (dir === 'x') { target.style.width = size + 'px'; target.style.flex = '0 0 auto'; }
      else { target.style.height = size + 'px'; target.style.flex = '0 0 auto'; }
    };
    const up = () => {
      document.removeEventListener('mousemove', move);
      document.removeEventListener('mouseup', up);
      document.body.style.cursor = '';
    };
    document.body.style.cursor = dir === 'x' ? 'col-resize' : 'row-resize';
    document.addEventListener('mousemove', move);
    document.addEventListener('mouseup', up);
  });
}

/* ==================== 事件绑定与启动 ==================== */

function bindEvents() {
  // 工具栏
  $('repoBtn').onclick = openRepoModal;
  $('refreshBtn').onclick = refreshAll;

  for (const b of document.querySelectorAll('.tb[data-act]')) {
    b.onclick = () => {
      switch (b.dataset.act) {
        case 'fetch': runOp({ action: 'fetch' }, 'Fetch'); break;
        case 'pull': runOp({ action: 'pull' }, 'Pull'); break;
        case 'push': runOp({ action: 'push' }, 'Push'); break;
        case 'newBranch': doNewBranch(); break;
        case 'stash': doStash(); break;
      }
    };
  }

  // 侧栏
  $('wipItem').onclick = showWip;
  $('branchFilter').oninput = (ev) => { S.branchFilter = ev.target.value; renderSidebar(); };

  for (const b of document.querySelectorAll('[data-select]')) {
    b.onclick = () => {
      const mode = b.dataset.select;
      if (mode === 'all') S.selected = new Set(S.refs.filter((r) => r.kind === 'head').map((r) => r.fullName));
      else if (mode === 'none') S.selected = new Set();
      else if (mode === 'current') {
        const cur = S.refs.find((r) => r.kind === 'head' && r.isHead);
        S.selected = cur ? new Set([cur.fullName]) : new Set();
      }
      renderSidebar();
      refreshGraph();
    };
  }

  for (const h of document.querySelectorAll('.side-head.collapsible')) {
    h.onclick = () => {
      h.classList.toggle('collapsed');
      $(h.dataset.collapse).classList.toggle('hidden');
    };
  }

  // 提交条数 / 只看主线
  $('limitSel').onchange = (ev) => { S.limit = parseInt(ev.target.value, 10); refreshGraph(); };
  $('firstParentChk').onchange = (ev) => { S.firstParent = ev.target.checked; refreshGraph(); };

  // 工作区
  $('stageAllBtn').onclick = () => runOp({ action: 'stage' }, 'Stage all');
  $('unstageAllBtn').onclick = () => runOp({ action: 'unstage' }, 'Unstage all');
  $('commitBtn').onclick = doCommit;
  $('amendChk').onchange = async () => {
    if ($('amendChk').checked && !$('commitMsg').value.trim()) {
      // 勾上"修补"时，把上一个提交的信息填进去，方便改。
      try {
        const head = S.head && S.head.hash;
        if (head) {
          const d = await apiGet('/api/commit?hash=' + head);
          $('commitMsg').value = d.body ? `${d.subject}\n\n${d.body}` : d.subject;
        }
      } catch { /* 拿不到就算了 */ }
    }
    renderWip();
  };
  $('commitMsg').onkeydown = (ev) => {
    if ((ev.metaKey || ev.ctrlKey) && ev.key === 'Enter') doCommit();
  };

  // 仓库弹层
  $('upBtn').onclick = () => S.browseParent && browseTo(S.browseParent);
  $('openHereBtn').onclick = () => openRepo(S.browsePath);
  $('pathInput').onkeydown = (ev) => { if (ev.key === 'Enter') browseTo(ev.target.value); };

  for (const b of document.querySelectorAll('[data-close]')) {
    b.onclick = (ev) => {
      const modal = ev.target.closest('.modal');
      if (modal && modal.id !== 'promptModal') closeModal(modal.id);
    };
  }
  for (const m of document.querySelectorAll('.modal')) {
    m.addEventListener('mousedown', (ev) => {
      // 点遮罩关闭；仓库弹层在没有仓库时不许关。
      if (ev.target !== m) return;
      if (m.id === 'repoModal' && !S.repo) return;
      closeModal(m.id);
    });
  }

  // 点状态栏看上一条 git 命令的完整输出
  $('statusMsg').parentElement.onclick = () => {
    if (S.lastOutput) showOutput(S.lastOutput.title, S.lastOutput.text);
  };

  // 全局
  document.addEventListener('click', hideMenu);
  document.addEventListener('contextmenu', (ev) => {
    if (!ev.target.closest('.row, .side-item, .reftag')) hideMenu();
  });
  document.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') {
      hideMenu();
      let closed = false;
      for (const m of document.querySelectorAll('.modal:not([hidden])')) {
        if (m.id === 'repoModal' && !S.repo) continue;
        closeModal(m.id);
        closed = true;
      }
      // 没有弹窗要关，Esc 就用来退出比较模式。
      if (!closed && S.cmpB) exitCompare();
    }
    const typing = /input|textarea/i.test(document.activeElement.tagName);
    if (typing) return;
    if (ev.key === 'r' || ev.key === 'R') { refreshAll(); }
    if (ev.key === 'o' || ev.key === 'O') { openRepoModal(); }
  });

  makeResizer($('sidebarResizer'), $('sidebar'), 'x', 150, 500);
  makeResizer($('detailResizer'), $('graphPane'), 'y', 100, 2000);
  makeResizer($('detailFileResizer'), $('dFiles'), 'x', 150, 700);
  makeResizer($('wipResizer'), document.querySelector('.wip-cols'), 'x', 200, 700);
}

bindEvents();
bootstrap().catch((e) => setStatus(e.message, 'err'));
