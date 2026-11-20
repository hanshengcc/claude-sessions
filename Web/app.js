'use strict';

// ---------- constants ----------
const POLL_MS = 3000;
const RESIZE_DEBOUNCE_MS = 220;
const ENTER_DELAY_MS = 70;
const KEY_REPEAT_DELAY_MS = 380;
const KEY_REPEAT_MS = 70;
const FONT_MIN = 8;
const FONT_MAX = 18;
const FONT_DEFAULT = 12;
const DUMP_LINES = 400;
const WHEEL_FLUSH_MS = 50;
const WHEEL_MAX_EVENTS = 20;
const LINES_PER_WHEEL = 3;
const TOKEN_KEY = 'cs_token';
const FONT_KEY = 'cs_font';

const KEYS = [
  { label: 'Esc', seq: '\x1b' },
  { label: '⇧Tab', seq: '\x1b[Z', title: '切换模式' },
  { label: '↑', seq: '\x1b[A', repeat: true },
  { label: '↓', seq: '\x1b[B', repeat: true },
  { label: '⏎', seq: '\r' },
  { label: '1', seq: '1' },
  { label: '2', seq: '2' },
  { label: '3', seq: '3' },
  { label: 'Tab', seq: '\t' },
  { label: '←', seq: '\x1b[D', repeat: true },
  { label: '→', seq: '\x1b[C', repeat: true },
  { label: '/', seq: '/' },
  { label: '^C', seq: '\x03', warn: true },
  { label: '^D', seq: '\x04' },
  { label: '^R', seq: '\x12' },
];

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text != null) node.textContent = text;
  return node;
};
const icon = (paths) => {
  const wrap = document.createElement('span');
  wrap.innerHTML = `<svg viewBox="0 0 24 24">${paths}</svg>`;
  return wrap.firstChild;
};
const ICONS = {
  bubble: '<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>',
  bubbleFill: '<path fill="currentColor" d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>',
  bell: '<path d="M6 8a6 6 0 1 1 12 0c0 7 3 8 3 8H3s3-1 3-8"/><path d="M10 20a2 2 0 0 0 4 0"/>',
  terminal: '<path d="m5 8 4 4-4 4M12 17h7"/>',
  chevron: '<path d="m9 5 7 7-7 7"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  text: '<path d="M4 6h16M4 12h16M4 18h10"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"/>',
  close: '<path d="M6 6l12 12M18 6 6 18"/>',
  plug: '<path d="M9 7V3M15 7V3M7 7h10v4a5 5 0 0 1-10 0zM12 16v5"/>',
};

// ---------- auth & api ----------
const token = (() => {
  const params = new URLSearchParams(location.search);
  const fromUrl = params.get('k');
  try {
    if (fromUrl) localStorage.setItem(TOKEN_KEY, fromUrl);
    return fromUrl || localStorage.getItem(TOKEN_KEY) || '';
  } catch {
    return fromUrl || '';
  }
})();

class AuthError extends Error {}

async function api(path, body) {
  const options = { headers: { 'X-CS': '1' }, cache: 'no-store' };
  if (token) options.headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) {
    options.method = 'POST';
    options.headers['Content-Type'] = 'application/json';
    options.body = JSON.stringify(body);
  }
  const response = await fetch(path, options);
  if (response.status === 401) throw new AuthError('unauthorized');
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

// ---------- utilities ----------
function relativeTime(ms) {
  const diff = (Date.now() - ms) / 1000;
  if (diff < 60) return '刚刚';
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  const date = new Date(ms);
  const now = new Date();
  const hm = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
  if (date.toDateString() === now.toDateString()) return `${Math.floor(diff / 3600)} 小时前`;
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (date.toDateString() === yesterday.toDateString()) return `昨天 ${hm}`;
  if (date.getFullYear() === now.getFullYear()) return `${date.getMonth() + 1}月${date.getDate()}日`;
  return `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()}`;
}

let toastTimer;
function toast(message) {
  const node = $('toast');
  node.textContent = message;
  node.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.classList.add('hidden'), 1800);
}

function debounce(fn, ms) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
}

const STATUS_TEXT = { working: '运行中', idle: '空闲', exited: '已结束', attention: '等你回复' };
const tabState = (tab) => (tab.attention ? 'attention' : tab.status);

// ---------- viewport (keyboard-aware height) ----------
function syncViewport() {
  const vv = window.visualViewport;
  const height = vv ? vv.height : window.innerHeight;
  document.documentElement.style.setProperty('--app-h', `${height}px`);
  // While the keyboard is up, the home indicator inset would leave a gap above it.
  const keyboardUp = vv && window.innerHeight - vv.height > 120;
  document.documentElement.style.setProperty('--dock-pad', keyboardUp ? '0px' : 'var(--safe-bottom)');
  if (vv && vv.offsetTop) window.scrollTo(0, 0);
}
window.visualViewport?.addEventListener('resize', syncViewport);
window.visualViewport?.addEventListener('scroll', syncViewport);
window.addEventListener('resize', syncViewport);
syncViewport();

// ---------- sheet ----------
function openSheet(build) {
  const content = $('sheet-content');
  content.replaceChildren();
  build(content);
  $('sheet').classList.remove('hidden');
  $('sheet-backdrop').classList.remove('hidden');
}
function closeSheet() {
  $('sheet').classList.add('hidden');
  $('sheet-backdrop').classList.add('hidden');
}
$('sheet-backdrop').addEventListener('click', closeSheet);

function actionButton(label, iconPaths, onClick, { danger = false, trail = '' } = {}) {
  const button = el('button', `action${danger ? ' danger' : ''}`);
  button.append(icon(iconPaths), el('span', null, label));
  if (trail) button.append(el('span', 'trail', trail));
  button.addEventListener('click', onClick);
  return button;
}

// ---------- list view ----------
const list = { state: null, timer: null, query: '' };

function showPlaceholder(title, text, spinner = false) {
  const body = $('list-body');
  const box = el('div', 'placeholder');
  if (spinner) box.append(el('div', 'spinner'));
  if (title) box.append(el('h3', null, title));
  if (text) box.append(el('p', null, text));
  body.replaceChildren(box);
}

async function refreshList() {
  try {
    list.state = await api('/api/state');
    $('host-name').textContent = list.state.host;
    $('list-conn').classList.add('on');
    renderList();
  } catch (error) {
    $('list-conn').classList.remove('on');
    if (error instanceof AuthError) {
      $('host-name').textContent = '未配对';
      showPlaceholder('需要配对', '在 Mac 上的 Claude Sessions 里点工具栏的手机图标，用相机扫码打开。');
      return;
    }
    $('host-name').textContent = '连接中断，正在重试…';
    if (!list.state) showPlaceholder('连不上 Mac', '确认 Mac 没有睡眠、App 正在运行，并且手机和 Mac 在同一网络（或都开着 Tailscale）。');
  }
}

function matches(item, query) {
  if (!query) return true;
  const haystack = [item.title, item.preview, item.project, item.cwd].join(' ').toLowerCase();
  return query.split(/\s+/).every((term) => haystack.includes(term));
}

function renderList() {
  const state = list.state;
  if (!state) return;
  const query = list.query.trim().toLowerCase();
  const tabs = state.tabs.filter((tab) => matches(tab, query));
  const sessions = state.sessions.filter((session) => !session.tabId && matches(session, query));
  const body = $('list-body');
  const fragment = document.createDocumentFragment();

  if (tabs.length) {
    fragment.append(el('div', 'section-title', `在 Mac 上打开 · ${tabs.length}`));
    const group = el('div', 'group');
    tabs.forEach((tab) => group.append(tabRow(tab)));
    fragment.append(group);
  }
  fragment.append(el('div', 'section-title', query ? `搜索结果 · ${sessions.length}` : '最近会话'));
  if (sessions.length) {
    const group = el('div', 'group');
    sessions.forEach((session) => group.append(sessionRow(session)));
    fragment.append(group);
  } else {
    const empty = el('div', 'placeholder');
    empty.append(el('p', null, query ? '没有匹配的会话' : '还没有会话，点右上角 + 新建'));
    fragment.append(empty);
  }
  const scroll = body.scrollTop;
  body.replaceChildren(fragment);
  body.scrollTop = scroll;
}

function tabRow(tab) {
  const state = tabState(tab);
  const row = el('button', 'row live-card');
  const iconBox = el('div', `row-icon ${state === 'working' ? 'icon-working' : state === 'attention' ? 'icon-attention' : ''}`);
  iconBox.append(icon(tab.kind === 'shell' ? ICONS.terminal : state === 'attention' ? ICONS.bell : ICONS.bubbleFill));
  const main = el('div', 'row-main');
  const top = el('div', 'row-top');
  if (tab.kind === 'agy') top.append(el('span', 'agent-tag', 'agy'));
  top.append(el('div', 'row-title', tab.title));
  const status = el('span', `state ${state}`, STATUS_TEXT[state]);
  if (state === 'working') {
    const dots = el('span', 'typing');
    dots.append(el('i'), el('i'), el('i'));
    status.append(dots);
  }
  top.append(status);
  const meta = el('div', 'row-meta');
  meta.append(el('span', null, tab.cwd));
  if (tab.owner === 'remote') meta.append(el('span', null, '· 手机控制中'));
  main.append(top, meta);
  const chev = el('div', 'chev');
  chev.append(icon(ICONS.chevron));
  row.append(iconBox, main, chev);
  row.addEventListener('click', () => go(`#/t/${tab.id}`));
  return row;
}

function sessionRow(session) {
  const row = el('button', 'row');
  const iconBox = el('div', 'row-icon');
  iconBox.append(icon(ICONS.bubble));
  const main = el('div', 'row-main');
  const top = el('div', 'row-top');
  if (session.agent === 'agy') top.append(el('span', 'agent-tag', 'agy'));
  top.append(el('div', 'row-title', session.title));
  if (session.pinned) top.append(el('span', 'pin', '置顶'));
  top.append(el('span', 'row-time', relativeTime(session.updatedAt)));
  main.append(top);
  if (session.preview && session.preview !== session.title) main.append(el('div', 'row-preview', session.preview));
  const meta = el('div', 'row-meta');
  meta.append(el('span', null, session.project));
  if (session.branch) meta.append(el('span', null, `⎇ ${session.branch}`));
  main.append(meta);
  row.append(iconBox, main);
  row.addEventListener('click', () => openSession(session));
  return row;
}

async function openSession(session) {
  try {
    const { tabId } = await api('/api/open', { sessionId: session.id });
    go(`#/t/${tabId}`);
  } catch (error) {
    toast(`打开失败：${error.message}`);
  }
}

async function createTab(cwd, kind) {
  closeSheet();
  try {
    const { tabId } = await api('/api/new', { cwd, kind });
    go(`#/t/${tabId}`);
  } catch (error) {
    toast(`新建失败：${error.message}`);
  }
}

function openNewSheet() {
  openSheet((content) => {
    content.append(el('h2', null, '新建'));
    content.append(el('p', 'hint', '在 Mac 上的这个目录里启动'));
    const custom = el('div', 'path-input');
    const input = el('input');
    input.placeholder = '其他路径，如 ~/code/app';
    input.autocapitalize = 'off';
    input.spellcheck = false;
    const go = el('button', 'pill', '新会话');
    go.addEventListener('click', () => input.value.trim() && createTab(input.value.trim(), 'claude'));
    custom.append(input, go);
    content.append(custom);
    const group = el('div', 'group');
    (list.state?.projects || []).forEach((project) => {
      const row = el('div', 'project');
      const main = el('div', 'project-main');
      main.append(el('div', 'project-name', project.name), el('div', 'project-path', project.display));
      const claude = el('button', 'pill', 'Claude');
      claude.addEventListener('click', () => createTab(project.path, 'claude'));
      const agy = el('button', 'pill agy', 'agy');
      agy.addEventListener('click', () => createTab(project.path, 'agy'));
      const shell = el('button', 'pill secondary', '终端');
      shell.addEventListener('click', () => createTab(project.path, 'shell'));
      row.append(main, claude, agy, shell);
      group.append(row);
    });
    content.append(group);
  });
}

$('new-btn').addEventListener('click', openNewSheet);
$('search').addEventListener('input', (event) => {
  list.query = event.target.value;
  renderList();
});

function startPolling() {
  stopPolling();
  refreshList();
  list.timer = setInterval(() => document.visibilityState === 'visible' && refreshList(), POLL_MS);
}
function stopPolling() {
  clearInterval(list.timer);
  list.timer = null;
}

// ---------- terminal view ----------
const TERM_THEME = {
  background: '#161619', foreground: '#e6e6e6', cursor: '#e3754d', cursorAccent: '#161619',
  selectionBackground: 'rgba(227, 117, 77, 0.35)',
  black: '#1c1c1f', red: '#ff6b6b', green: '#5cc778', yellow: '#faa83d', blue: '#6aa7ff',
  magenta: '#c49bff', cyan: '#5fd1d1', white: '#d8d8d8',
  brightBlack: '#6e6e76', brightRed: '#ff8787', brightGreen: '#7ad992', brightYellow: '#ffc266',
  brightBlue: '#8fbcff', brightMagenta: '#d6b6ff', brightCyan: '#86e0e0', brightWhite: '#ffffff',
};
const FONT_FAMILY = 'ui-monospace, "SF Mono", Menlo, monospace';

const session = {
  id: null, term: null, fit: null, source: null, lastId: null,
  meta: null, owner: null, exited: false, gone: false, synced: false,
  prefersPhone: true, claimedAt: 0,
};
const CLAIM_GRACE_MS = 2000;

function readFont() {
  try {
    const value = Number(localStorage.getItem(FONT_KEY));
    return value >= FONT_MIN && value <= FONT_MAX ? value : FONT_DEFAULT;
  } catch {
    return FONT_DEFAULT;
  }
}
let userFont = readFont();

function decodeBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Width of one monospace cell relative to font size, measured once. */
const cellRatio = (() => {
  const canvas = document.createElement('canvas').getContext('2d');
  canvas.font = `100px ${FONT_FAMILY}`;
  return canvas.measureText('W'.repeat(10)).width / 1000;
})();

function terminalBox() {
  const node = $('terminal');
  return { width: node.clientWidth, height: node.clientHeight };
}

/** Phone owns the pty: size the pty to what fits the screen at the user's font. */
const claimSize = debounce(() => {
  if (!session.term || session.exited || session.gone) return;
  if (session.term.options.fontSize !== userFont) session.term.options.fontSize = userFont;
  const dims = session.fit.proposeDimensions();
  if (!dims || !dims.cols || !dims.rows) return;
  const cols = Math.max(20, dims.cols);
  const rows = Math.max(6, dims.rows);
  if (cols !== session.term.cols || rows !== session.term.rows) session.term.resize(cols, rows);
  api(`/api/tab/${session.id}/resize`, { cols, rows }).catch(() => {});
}, RESIZE_DEBOUNCE_MS);

/** Desktop owns the pty: shrink the font so its full width still fits. */
function fitDesktopWidth() {
  const term = session.term;
  if (!term) return;
  const { width } = terminalBox();
  const fitting = Math.floor((width / (term.cols * cellRatio)) * 10) / 10;
  const size = Math.max(5, Math.min(userFont, fitting));
  if (term.options.fontSize !== size) term.options.fontSize = size;
}

function takeOver() {
  session.owner = 'remote';
  session.prefersPhone = true;
  session.claimedAt = Date.now();
  renderBanner();
  claimSize();
}

function renderHeader() {
  const meta = session.meta;
  if (!meta) return;
  $('term-title').textContent = meta.title;
  document.title = meta.title;
  const state = session.gone ? 'exited' : session.exited ? 'exited' : tabState(meta);
  $('term-dot').className = `status-dot ${state}`;
  const connected = session.source && session.source.readyState === EventSource.OPEN;
  $('term-status').textContent = !connected && !session.gone && !session.exited
    ? '重新连接中…'
    : `${STATUS_TEXT[state]} · ${meta.project}`;
  const agentName = meta.kind === 'agy' ? 'agy' : 'Claude';
  $('input').placeholder = meta.kind === 'shell' ? '输入命令…' : `给 ${agentName} 发消息…`;
}

function renderBanner() {
  const banner = $('banner');
  banner.replaceChildren();
  let message = null;
  let button = null;
  if (session.gone) {
    message = '这个标签已在 Mac 上关闭';
    button = ['返回列表', () => go('#/')];
  } else if (session.exited) {
    message = '会话已结束';
    button = ['重新打开', restartSession];
  } else if (session.synced && session.owner === 'desktop') {
    message = '电脑正在使用，按电脑宽度显示';
    button = ['在手机上排版', takeOver];
  }
  banner.classList.toggle('hidden', !message);
  if (!message) return;
  banner.append(el('span', 'grow', message));
  const action = el('button', null, button[0]);
  action.addEventListener('click', button[1]);
  banner.append(action);
}

function handleMeta(meta) {
  const ownerChanged = session.owner !== meta.owner;
  session.meta = meta;
  if (meta.status !== 'exited') session.exited = false;
  // Ignore a stale "desktop" report that raced our own resize request.
  const racing = meta.owner === 'desktop' && Date.now() - session.claimedAt < CLAIM_GRACE_MS;
  if (ownerChanged && !racing) {
    session.owner = meta.owner;
    if (meta.owner === 'desktop' && session.synced) session.prefersPhone = false;
    if (meta.owner === 'desktop') fitDesktopWidth();
  }
  renderHeader();
  renderBanner();
}

function connectStream() {
  session.source?.close();
  const params = new URLSearchParams();
  if (token) params.set('k', token);
  if (session.lastId) params.set('since', session.lastId);
  const source = new EventSource(`/api/tab/${session.id}/stream?${params}`);
  session.source = source;
  const term = session.term;

  source.addEventListener('open', renderHeader);
  source.addEventListener('reset', () => {
    term.reset();
    session.synced = false;
  });
  source.addEventListener('resize', (event) => {
    const { cols, rows } = JSON.parse(event.data);
    if (cols !== term.cols || rows !== term.rows) term.resize(cols, rows);
    if (session.owner === 'desktop') fitDesktopWidth();
  });
  source.addEventListener('data', (event) => {
    term.write(decodeBase64(event.data));
    if (event.lastEventId) session.lastId = event.lastEventId;
  });
  source.addEventListener('sync', (event) => {
    session.lastId = event.lastEventId;
    session.synced = true;
    // Using a session on the phone means laying it out for this screen,
    // also after a reconnect, unless the desktop took it back meanwhile.
    if (session.prefersPhone) takeOver();
    else fitDesktopWidth();
    renderBanner();
    term.scrollToBottom();
  });
  source.addEventListener('meta', (event) => handleMeta(JSON.parse(event.data)));
  source.addEventListener('exit', () => {
    session.exited = true;
    renderHeader();
    renderBanner();
  });
  source.addEventListener('gone', () => {
    session.gone = true;
    source.close();
    renderHeader();
    renderBanner();
  });
  source.addEventListener('error', () => {
    renderHeader();
    if (source.readyState === EventSource.CLOSED && !session.gone) checkTabStillExists();
  });
}

async function checkTabStillExists() {
  try {
    const state = await api('/api/state');
    if (!state.tabs.some((tab) => tab.id === session.id)) {
      session.gone = true;
      renderHeader();
      renderBanner();
      return;
    }
  } catch (error) {
    if (error instanceof AuthError) return go('#/');
  }
  setTimeout(() => session.id && !session.gone && connectStream(), 1500);
}

// SGR mouse wheel: button 64 = up, 65 = down, reported at the screen centre.
let wheelPending = 0;
let wheelTimer = 0;
function queueWheel(term, lines) {
  if (term.modes.mouseTrackingMode === 'none') return;
  wheelPending += lines;
  if (wheelTimer) return;
  wheelTimer = setTimeout(() => {
    wheelTimer = 0;
    const steps = Math.trunc(wheelPending / LINES_PER_WHEEL);
    wheelPending -= steps * LINES_PER_WHEEL;
    const count = Math.min(Math.abs(steps), WHEEL_MAX_EVENTS);
    if (!count || !session.id || session.gone) return;
    const button = steps < 0 ? 64 : 65;
    const col = Math.max(1, Math.ceil(term.cols / 2));
    const row = Math.max(1, Math.ceil(term.rows / 2));
    const data = `\x1b[<${button};${col};${row}M`.repeat(count);
    // Scrolling only reads history, so it must not take the size over from the Mac.
    api(`/api/tab/${session.id}/input`, { data }).catch((error) => toast(`滚动失败：${error.message}`));
  }, WHEEL_FLUSH_MS);
}

function installTouchScroll(wrap, term) {
  let lastY = 0;
  let startY = 0;
  let velocity = 0;
  let lastTime = 0;
  let residue = 0;
  let frame = 0;
  const lineHeight = () => (term.options.fontSize || userFont) * 1.2;
  const scrollBy = (pixels) => {
    residue += pixels / lineHeight();
    const lines = Math.trunc(residue);
    if (!lines) return;
    residue -= lines;
    // Full-screen TUIs (e.g. Claude Code with "tui": "fullscreen") live in the
    // alternate buffer, which has no scrollback: forward the swipe as mouse
    // wheel events so the app scrolls its own history.
    if (term.buffer.active.type === 'alternate') queueWheel(term, lines);
    else term.scrollLines(lines);
  };
  wrap.addEventListener('touchstart', (event) => {
    cancelAnimationFrame(frame);
    lastY = startY = event.touches[0].clientY;
    lastTime = performance.now();
    velocity = 0;
    residue = 0;
  }, { passive: true, capture: true });
  wrap.addEventListener('touchmove', (event) => {
    const y = event.touches[0].clientY;
    const now = performance.now();
    const dy = lastY - y;
    velocity = dy / Math.max(1, now - lastTime);
    lastY = y;
    lastTime = now;
    scrollBy(dy);
    event.preventDefault();
    event.stopPropagation();
  }, { passive: false, capture: true });
  wrap.addEventListener('touchend', (event) => {
    if (Math.abs(lastY - startY) < 6) {
      // A tap on the terminal dismisses the keyboard.
      $('input').blur();
      return;
    }
    event.stopPropagation();
    let v = velocity * 16;
    const step = () => {
      if (Math.abs(v) < 0.5) return;
      scrollBy(v);
      v *= 0.95;
      frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
  }, { capture: true });
}

function createTerminal() {
  const term = new Terminal({
    fontFamily: FONT_FAMILY,
    fontSize: userFont,
    lineHeight: 1.12,
    theme: TERM_THEME,
    scrollback: 5000,
    disableStdin: true,
    cursorBlink: false,
    allowProposedApi: true,
    macOptionIsMeta: true,
    smoothScrollDuration: 0,
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.loadAddon(new Unicode11Addon.Unicode11Addon());
  term.unicode.activeVersion = '11';
  term.open($('terminal'));
  const helper = $('terminal').querySelector('textarea');
  if (helper) {
    helper.readOnly = true;
    helper.inputMode = 'none';
    helper.tabIndex = -1;
  }
  const toBottom = $('to-bottom');
  term.onScroll(() => {
    const buffer = term.buffer.active;
    toBottom.classList.toggle('hidden', buffer.viewportY >= buffer.baseY);
  });
  toBottom.addEventListener('click', () => term.scrollToBottom());
  installTouchScroll($('term-wrap'), term);
  return { term, fit };
}

function openTerminal(id) {
  if (session.id === id && session.term) return;
  closeTerminal();
  stopPolling();
  Object.assign(session, {
    id, lastId: null, meta: null, owner: null, exited: false, gone: false, synced: false,
    prefersPhone: true, claimedAt: Date.now(),
  });
  const cached = list.state?.tabs.find((tab) => tab.id === id);
  if (cached) handleMeta(cached);
  else $('term-title').textContent = '…';
  const { term, fit } = createTerminal();
  session.term = term;
  session.fit = fit;
  renderBanner();
  connectStream();
}

function closeTerminal() {
  session.source?.close();
  session.source = null;
  session.term?.dispose();
  session.term = null;
  session.id = null;
  $('terminal').replaceChildren();
  $('to-bottom').classList.add('hidden');
  $('banner').classList.add('hidden');
  document.title = 'Claude Sessions';
}

function sendRaw(data) {
  if (!session.id || session.gone) return Promise.resolve();
  if (session.owner === 'desktop') takeOver();
  return api(`/api/tab/${session.id}/input`, { data }).catch((error) => toast(`发送失败：${error.message}`));
}

async function restartSession() {
  if (!session.id) return;
  closeSheet();
  try {
    await api(`/api/tab/${session.id}/restart`, {});
    session.exited = false;
    renderBanner();
    claimSize();
  } catch (error) {
    toast(`重启失败：${error.message}`);
  }
}

// ---------- composer & keys ----------
const input = $('input');
const sendButton = $('send-btn');

function autosize() {
  input.style.height = 'auto';
  input.style.height = `${Math.min(input.scrollHeight, 132)}px`;
  sendButton.classList.toggle('enter', input.value.length === 0);
}
input.addEventListener('input', autosize);

async function submit() {
  const text = input.value;
  input.value = '';
  autosize();
  if (!text) return sendRaw('\r');
  const body = text.replace(/\r\n?/g, '\n');
  const payload = body.includes('\n') ? `\x1b[200~${body}\x1b[201~` : body;
  await sendRaw(payload);
  await new Promise((resolve) => setTimeout(resolve, ENTER_DELAY_MS));
  await sendRaw('\r');
  session.term?.scrollToBottom();
}

// pointerdown + preventDefault keeps the keyboard up while tapping send/keys.
sendButton.addEventListener('pointerdown', (event) => event.preventDefault());
sendButton.addEventListener('click', submit);

function buildKeys() {
  const container = $('keys');
  KEYS.forEach((key) => {
    const button = el('button', `key${key.warn ? ' warn' : ''}`, key.label);
    if (key.title) button.title = key.title;
    let delay;
    let repeat;
    const stop = () => {
      clearTimeout(delay);
      clearInterval(repeat);
      button.classList.remove('pressed');
    };
    button.addEventListener('pointerdown', (event) => {
      event.preventDefault();
      button.classList.add('pressed');
      navigator.vibrate?.(8);
      sendRaw(key.seq);
      if (key.repeat) {
        delay = setTimeout(() => { repeat = setInterval(() => sendRaw(key.seq), KEY_REPEAT_MS); }, KEY_REPEAT_DELAY_MS);
      }
    });
    ['pointerup', 'pointercancel', 'pointerleave'].forEach((name) => button.addEventListener(name, stop));
    container.append(button);
  });
}
buildKeys();

// ---------- menu sheet ----------
function bufferText(maxLines) {
  const buffer = session.term?.buffer.active;
  if (!buffer) return '';
  const lines = [];
  for (let i = 0; i < buffer.length; i += 1) {
    const line = buffer.getLine(i);
    if (!line) continue;
    const text = line.translateToString(true);
    if (line.isWrapped && lines.length) lines[lines.length - 1] += text;
    else lines.push(text);
  }
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  return lines.slice(-maxLines).join('\n');
}

function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text).then(() => true, () => false);
  }
  const area = el('textarea');
  area.value = text;
  area.setAttribute('readonly', '');
  area.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
  document.body.append(area);
  area.select();
  area.setSelectionRange(0, text.length);
  let ok = false;
  try { ok = document.execCommand('copy'); } catch { ok = false; }
  area.remove();
  return Promise.resolve(ok);
}

function openTextSheet() {
  const text = bufferText(DUMP_LINES);
  openSheet((content) => {
    const head = el('div', 'path-input');
    head.append(el('h2', null, '终端文本'));
    head.firstChild.style.flex = '1';
    const copy = el('button', 'pill', '全部复制');
    copy.addEventListener('click', async () => toast((await copyText(text)) ? '已复制' : '复制失败，请长按文本手动选择'));
    head.append(copy);
    content.append(head, el('pre', 'text-dump', text || '（空）'));
  });
}

function fontRow() {
  const row = el('div', 'font-row');
  const value = el('span', 'value', String(userFont));
  const step = (delta) => {
    userFont = Math.max(FONT_MIN, Math.min(FONT_MAX, userFont + delta));
    value.textContent = String(userFont);
    try { localStorage.setItem(FONT_KEY, String(userFont)); } catch { /* per-device convenience only */ }
    if (session.owner === 'desktop') fitDesktopWidth();
    else claimSize();
  };
  const minus = el('button', 'stepper', '−');
  minus.addEventListener('click', () => step(-1));
  const plus = el('button', 'stepper', '+');
  plus.addEventListener('click', () => step(1));
  row.append(el('span', 'label', '字号'), minus, value, plus);
  return row;
}

function confirmClose(content) {
  content.replaceChildren(el('h2', null, '关闭这个会话？'));
  content.append(el('p', 'hint', 'Mac 上对应的标签也会关闭。对话记录会保留，之后可以从列表重新打开。'));
  const group = el('div', 'group');
  group.append(actionButton('关闭会话', ICONS.close, async () => {
    closeSheet();
    try {
      await api(`/api/tab/${session.id}/close`, {});
      go('#/');
    } catch (error) {
      toast(`关闭失败：${error.message}`);
    }
  }, { danger: true }));
  group.append(actionButton('取消', ICONS.chevron, closeSheet));
  content.append(group);
}

$('menu-btn').addEventListener('click', () => {
  openSheet((content) => {
    if (session.meta) content.append(el('h2', null, session.meta.title), el('p', 'hint', session.meta.cwd));
    const display = el('div', 'group');
    display.append(fontRow());
    display.append(actionButton('查看与复制文本', ICONS.text, openTextSheet));
    content.append(display);
    const actions = el('div', 'group');
    actions.append(actionButton('重新连接', ICONS.plug, () => {
      closeSheet();
      session.gone = false;
      connectStream();
    }));
    if (session.owner === 'desktop') actions.append(actionButton('按手机屏幕排版', ICONS.terminal, () => { closeSheet(); takeOver(); }));
    actions.append(actionButton('重启会话', ICONS.refresh, restartSession));
    actions.append(actionButton('关闭会话', ICONS.close, () => confirmClose(content), { danger: true }));
    content.append(actions);
  });
});

// ---------- routing ----------
let cameFromList = false;

function go(hash) {
  if (location.hash === hash) route();
  else location.hash = hash;
}

$('back-btn').addEventListener('click', () => {
  if (cameFromList) history.back();
  else go('#/');
});

function show(viewId) {
  ['list-view', 'term-view'].forEach((id) => {
    const node = $(id);
    const visible = id === viewId;
    if (visible && node.classList.contains('hidden')) {
      node.classList.remove('view-enter');
      void node.offsetWidth;
      node.classList.add('view-enter');
    }
    node.classList.toggle('hidden', !visible);
  });
}

function route() {
  closeSheet();
  const match = location.hash.match(/^#\/t\/([0-9A-Fa-f-]{36})$/);
  if (match) {
    show('term-view');
    openTerminal(match[1].toUpperCase());
    return;
  }
  input.blur();
  closeTerminal();
  show('list-view');
  startPolling();
}

window.addEventListener('hashchange', (event) => {
  cameFromList = !/#\/t\//.test(event.oldURL);
  route();
});

const refit = debounce(() => {
  if (!session.term) return;
  if (session.owner === 'desktop') fitDesktopWidth();
  else if (session.synced) claimSize();
}, RESIZE_DEBOUNCE_MS);
window.addEventListener('resize', refit);
window.visualViewport?.addEventListener('resize', refit);

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return;
  if (session.id && !session.gone && session.source?.readyState !== EventSource.OPEN) connectStream();
  if (!session.id) refreshList();
});

// The token stays in the URL on purpose: iOS home-screen apps get their own
// storage, so "Add to Home Screen" must capture a URL that still carries it.
route();
