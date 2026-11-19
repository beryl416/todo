// Todo for iPhone (and any browser). Same data and sync rules as the Mac app:
// every change stamps updated_at, the newest version of an item wins, and
// changed items stay "dirty" until the server has them.

const SUPABASE_URL = 'https://hqyucrsqxvzwtyewxqhi.supabase.co';
const PUBLISHABLE_KEY = 'sb_publishable_ZphNZVulyrdtVsKzK910jA_cZOAlQi4'; // public by design
const K = { state: 'todo.state.v1', key: 'todo.key', theme: 'todo.theme', mode: 'todo.mode' };

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode: keep going in memory */ } },
};

// ---------- days ("YYYY-MM-DD"; arithmetic in UTC so DST never shifts a day) ----------
const pad = (n) => String(n).padStart(2, '0');
const mk = (y, m, d) => `${y}-${pad(m)}-${pad(d)}`;
const nums = (s) => s.split('-').map(Number);
const noon = (s) => { const [y, m, d] = nums(s); return new Date(Date.UTC(y, m - 1, d, 12)); };
const fromNoon = (t) => mk(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
const addDays = (s, n) => { const t = noon(s); t.setUTCDate(t.getUTCDate() + n); return fromNoon(t); };
const monthStart = (s) => s.slice(0, 8) + '01';
const addMonths = (s, n) => { const [y, m] = nums(s); return fromNoon(new Date(Date.UTC(y, m - 1 + n, 1, 12))); };
const isoWeekday = (s) => { const w = noon(s).getUTCDay(); return w === 0 ? 7 : w; };
const weekStart = (s) => addDays(s, 1 - isoWeekday(s));
const weekOf = (s) => Array.from({ length: 7 }, (_, i) => addDays(weekStart(s), i));
const daysInMonth = (s) => { const [y, m] = nums(s); return new Date(Date.UTC(y, m, 0)).getUTCDate(); };
const monthGrid = (s) => {
  const first = weekStart(monthStart(s));
  const last = s.slice(0, 8) + pad(daysInMonth(s));
  const end = addDays(last, 7 - isoWeekday(last));
  const out = [];
  for (let d = first; d <= end; d = addDays(d, 1)) out.push(d);
  return out;
};
const localToday = () => { const n = new Date(); return mk(n.getFullYear(), n.getMonth() + 1, n.getDate()); };
const WEEKDAYS = ['월', '화', '수', '목', '금', '토', '일'];
const weekdayName = (s) => WEEKDAYS[isoWeekday(s) - 1];

// ---------- state ----------
function loadState() {
  try {
    const s = JSON.parse(store.get(K.state));
    if (s && s.items) return { items: s.items, dirty: new Set(s.dirty || []), lastRev: s.lastRev || 0 };
  } catch { /* fall through */ }
  return { items: {}, dirty: new Set(), lastRev: 0 };
}
let state = loadState();
let saveTimer = 0;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    store.set(K.state, JSON.stringify({ items: state.items, dirty: [...state.dirty], lastRev: state.lastRev }));
  }, 200);
}

const live = (i) => i && !i.deleted;
const inOrder = (a, b) => a.position - b.position || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const all = () => Object.values(state.items);
const openOn = (d) => all().filter((i) => live(i) && !i.done && i.day === d).sort(inOrder);
const doneOn = (d) => all().filter((i) => live(i) && i.done && i.day === d).sort(inOrder);
const openCounts = () => {
  const c = {};
  for (const i of all()) if (live(i) && !i.done) c[i.day] = (c[i.day] || 0) + 1;
  return c;
};

function write(item) {
  state.items[item.id] = item;
  state.dirty.add(item.id);
  save();
}
function update(id, change) {
  const cur = state.items[id];
  if (!live(cur)) return;
  const next = { ...cur };
  change(next);
  next.updated_at = Math.max(Date.now(), cur.updated_at + 1);
  write(next);
}
function addItem(title, day) {
  const t = title.trim();
  if (!t) return;
  const last = openOn(day).at(-1);
  write({
    id: crypto.randomUUID(), title: t, day, done: false, starred: false,
    position: (last ? last.position : 0) + 1, deleted: false, updated_at: Date.now(),
  });
}
function commitTitle(id) {
  const cur = state.items[id];
  if (!live(cur)) return;
  const t = cur.title.trim();
  if (!t) update(id, (i) => { i.deleted = true; });
  else if (t !== cur.title) update(id, (i) => { i.title = t; });
}
function moveToDay(id, day) {
  const cur = state.items[id];
  if (!live(cur) || cur.day === day) return;
  const list = cur.done ? doneOn(day) : openOn(day);
  const position = (list.length ? list.at(-1).position : 0) + 1;
  update(id, (i) => { i.day = day; i.position = position; });
}
function rollOver(today) {
  const stale = all()
    .filter((i) => live(i) && !i.done && i.day < today)
    .sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : inOrder(a, b)));
  if (!stale.length) return 0;
  const top = openOn(today)[0]?.position ?? 1;
  stale.forEach((it, k) => update(it.id, (i) => { i.day = today; i.position = top - (stale.length - k); }));
  return stale.length;
}

// ---------- sync ----------
const syncKey = (() => {
  const m = location.hash.match(/[#&]k=([A-Za-z0-9_-]{32,})/);
  if (m) store.set(K.key, m[1]); // keep it in the URL too, so "Add to Home Screen" carries it
  return m ? m[1] : store.get(K.key);
})();

let online = true;
let keyRejected = false;
let syncing = false;
let syncAgain = false;
let needFull = true;
let syncTimer = 0;

const pendingPush = () => [...state.dirty]
  .map((id) => state.items[id])
  .filter((i) => i && (i.deleted || i.title.trim()))
  .sort((a, b) => a.updated_at - b.updated_at)
  .slice(0, 500);

function markPushed(batch) {
  for (const sent of batch) {
    if (state.items[sent.id] !== sent) continue; // edited again while sending
    state.dirty.delete(sent.id);
    if (sent.deleted) delete state.items[sent.id];
  }
}
function applyFull(server, rev) {
  const next = {};
  for (const s of server) if (!s.deleted) next[s.id] = s;
  for (const id of [...state.dirty]) {
    const local = state.items[id];
    if (!local) { state.dirty.delete(id); continue; }
    const remote = next[id];
    if (remote && remote.updated_at > local.updated_at) state.dirty.delete(id);
    else next[id] = local;
  }
  state.items = next;
  state.lastRev = rev;
}
function applyChanges(server, rev) {
  for (const remote of server) {
    if (state.dirty.has(remote.id)) {
      const local = state.items[remote.id];
      if (!local || remote.updated_at <= local.updated_at) continue;
      state.dirty.delete(remote.id);
    }
    if (remote.deleted) delete state.items[remote.id];
    else state.items[remote.id] = remote;
  }
  state.lastRev = Math.max(state.lastRev, rev);
}
const pullCursor = () => (state.lastRev === 0 ? 0 : Math.max(1, state.lastRev - 20));

async function rpc(fn, body) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: PUBLISHABLE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const err = new Error(`HTTP ${res.status}`);
    err.status = res.status;
    throw err;
  }
  return res.json();
}

function scheduleSync(delay = 600) {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(sync, delay);
}

async function sync() {
  if (!syncKey || keyRejected) return;
  if (syncing) { syncAgain = true; return; }
  syncing = true;
  let rounds = 0;
  try {
    do {
      syncAgain = false;
      rounds += 1;
      const batch = pendingPush();
      if (batch.length) {
        await rpc('todo_push', { p_key: syncKey, p_items: batch });
        markPushed(batch);
      }
      const full = needFull || pullCursor() === 0;
      const res = await rpc('todo_pull', { p_key: syncKey, p_since: full ? 0 : pullCursor() });
      if (full) { applyFull(res.items, res.rev); needFull = false; } else applyChanges(res.items, res.rev);
      if (rollOver(view.today) > 0 || pendingPush().length) syncAgain = true;
      online = true;
      save();
      requestRender();
    } while (syncAgain && rounds < 5);
  } catch (err) {
    if (err.status === 401 || err.status === 403) keyRejected = true;
    online = false;
    requestRender();
  } finally {
    syncing = false;
  }
}

// ---------- view ----------
const view = {
  mode: ['day', 'week', 'month'].includes(store.get(K.mode)) ? store.get(K.mode) : 'day',
  today: localToday(),
  anchor: localToday(),
};
let editingId = null;
let renderPending = false;
let focusAfter = null; // { add: day } | { edit: id }

const $ = (id) => document.getElementById(id);
const svg = (body) => `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const ICON_MOON = svg('<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>');
const ICON_SUN = svg('<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4L6 18M18 6l1.4-1.4"/>');
function h(tag, props = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids) if (kid != null) el.append(kid);
  return el;
}

function titleText() {
  const yp = (d) => (d.slice(0, 4) === view.today.slice(0, 4) ? '' : `${Number(d.slice(0, 4))}년 `);
  const [, m, d] = nums(view.anchor);
  if (view.mode === 'day') return `${yp(view.anchor)}${m}월 ${d}일 ${weekdayName(view.anchor)}요일`;
  if (view.mode === 'week') {
    const s = weekStart(view.anchor), e = addDays(s, 6);
    const [, sm, sd] = nums(s), [, em, ed] = nums(e);
    return `${yp(s)}${sm}월 ${sd}일 – ${sm === em ? '' : `${em}월 `}${ed}일`;
  }
  return `${nums(view.anchor)[0]}년 ${m}월`;
}

// Re-rendering replaces the list, so wait while someone is typing, and while a
// finger or mouse is down (redrawing mid-tap would swallow the tap).
let pointerDown = false;
function typing() {
  const a = document.activeElement;
  return a && a.tagName === 'TEXTAREA';
}
function requestRender() {
  if (typing() || pointerDown) { renderPending = true; return; }
  render();
}
document.addEventListener('pointerdown', () => { pointerDown = true; }, true);
for (const type of ['pointerup', 'pointercancel']) {
  document.addEventListener(type, () => {
    pointerDown = false;
    // Runs after the click that follows this pointerup.
    setTimeout(() => { if (renderPending) requestRender(); }, 0);
  }, true);
}

function render() {
  renderPending = false;
  const main = $('main');
  if (!syncKey || keyRejected) {
    document.querySelector('.top').hidden = true;
    main.replaceChildren(h('div', { class: 'connect' },
      h('b', { text: 'Todo' }), h('br'),
      keyRejected ? '연결 코드가 맞지 않습니다.' : '아직 연결되지 않았습니다.', h('br'),
      '맥 앱 메뉴 [파일 → 아이폰 연결…]의', h('br'),
      'QR 코드를 카메라로 찍어서 여세요.'));
    $('status').textContent = '';
    return;
  }
  document.querySelector('.top').hidden = false;
  $('title').textContent = titleText();
  $('today-tag').textContent = view.mode === 'day' && view.anchor === view.today ? '오늘' : '';
  for (const b of document.querySelectorAll('.modes button')) b.classList.toggle('on', b.dataset.mode === view.mode);
  const dark = document.documentElement.dataset.theme === 'dark';
  $('theme').innerHTML = dark ? ICON_SUN : ICON_MOON;
  document.querySelector('meta[name="theme-color"]').setAttribute('content', dark ? '#1e1e1e' : '#ffffff');

  let body;
  if (view.mode === 'day') body = dayList(view.anchor, true);
  else if (view.mode === 'week') body = weekView();
  else body = monthView();
  main.replaceChildren(body);
  $('status').textContent = online ? '' : '오프라인 · 연결되면 맞춰집니다';

  if (focusAfter) {
    const sel = focusAfter.add ? `textarea[data-add="${focusAfter.add}"]` : `textarea[data-edit="${focusAfter.edit}"]`;
    const el = main.querySelector(sel);
    focusAfter = null;
    if (el) {
      el.focus();
      const end = el.value.length;
      el.setSelectionRange(end, end);
      fit(el);
    }
  }
}

function fit(el) {
  el.style.height = '0px';
  el.style.height = `${el.scrollHeight}px`;
}

function dayList(day, showPlaceholder) {
  const wrap = h('div', { class: 'list' });
  for (const item of openOn(day)) wrap.append(row(item));
  wrap.append(addRow(day, showPlaceholder));
  for (const item of doneOn(day)) wrap.append(row(item));
  return wrap;
}

function act(change) {
  change();
  scheduleSync();
  render();
}

function row(item) {
  const el = h('div', { class: `row${item.done ? ' done' : ''}` });
  el.append(h('button', {
    class: 'check',
    'aria-label': item.done ? '완료 취소' : '완료',
    onclick: () => act(() => update(item.id, (i) => { i.done = !i.done; })),
  }, h('span')));

  if (editingId === item.id) {
    const ta = h('textarea', {
      rows: 1,
      'data-edit': item.id,
      enterkeyhint: 'done',
      oninput: (e) => {
        const t = e.target;
        if (t.value.includes('\n')) {
          t.value = t.value.replace(/\n/g, ' ');
          update(item.id, (i) => { i.title = t.value; });
          t.blur();
          return;
        }
        update(item.id, (i) => { i.title = t.value; });
        fit(t);
        scheduleSync(1200);
      },
      onblur: () => finishEditing(item.id),
    });
    ta.value = item.title;
    const keep = (e) => e.preventDefault(); // keep the keyboard open when tapping a tool
    const tools = h('div', { class: 'tools' },
      h('button', {
        'aria-label': '중요', onpointerdown: keep, onmousedown: keep,
        onclick: (e) => {
          update(item.id, (i) => { i.starred = !i.starred; });
          e.currentTarget.textContent = state.items[item.id].starred ? '★' : '☆';
          scheduleSync();
        },
      }, item.starred ? '★' : '☆'),
      item.done ? null : h('button', {
        'aria-label': '내일로', onpointerdown: keep, onmousedown: keep,
        onclick: () => {
          endEdit();
          const cur = state.items[item.id];
          if (cur && !cur.deleted) act(() => moveToDay(item.id, addDays(cur.day > view.today ? cur.day : view.today, 1)));
          else render();
        },
      }, '→'),
      h('button', {
        'aria-label': '삭제', onpointerdown: keep, onmousedown: keep,
        onclick: () => { endEdit(); act(() => update(item.id, (i) => { i.deleted = true; })); },
      }, '×'));
    el.append(ta, tools);
  } else {
    el.append(h('div', {
      class: 'text',
      text: item.title,
      onclick: () => { editingId = item.id; focusAfter = { edit: item.id }; render(); },
    }));
    if (item.starred) el.append(h('span', { class: 'star', text: '★' }));
  }
  return el;
}

function endEdit() {
  const id = editingId;
  editingId = null;
  if (id) commitTitle(id);
}

function finishEditing(id) {
  if (editingId !== id) return;
  endEdit();
  scheduleSync();
  setTimeout(requestRender, 0);
}

function addRow(day, showPlaceholder) {
  const ta = h('textarea', {
    rows: 1,
    'data-add': day,
    placeholder: showPlaceholder ? '할 일 추가' : '+',
    enterkeyhint: 'done',
    'aria-label': '할 일 추가',
    oninput: (e) => {
      const t = e.target;
      if (t.value.includes('\n')) {
        const text = t.value.replace(/\n/g, '');
        t.value = '';
        if (text.trim()) {
          addItem(text, day);
          scheduleSync();
          focusAfter = { add: day };
          render();
        } else {
          t.blur();
        }
        return;
      }
      fit(t);
    },
    onblur: (e) => {
      const t = e.target;
      if (t.value.trim()) {
        addItem(t.value, day);
        t.value = '';
        scheduleSync();
        renderPending = true;
      }
      setTimeout(() => { if (renderPending) requestRender(); }, 0);
    },
  });
  return h('div', { class: 'row add' }, ta);
}

function weekView() {
  const wrap = h('div', { class: 'week' });
  for (const day of weekOf(view.anchor)) {
    const isToday = day === view.today;
    wrap.append(h('div', {
      class: `day-head${isToday ? ' today' : ''}`,
      onclick: () => { view.anchor = day; setMode('day'); },
    }, `${nums(day)[2]}일 ${weekdayName(day)}요일${isToday ? ' · 오늘' : ''}`));
    wrap.append(dayList(day, false));
  }
  return wrap;
}

function monthView() {
  const counts = openCounts();
  const month = view.anchor.slice(0, 7);
  const grid = h('div', { class: 'month' });
  for (const w of WEEKDAYS) grid.append(h('div', { class: 'dow', text: w }));
  for (const day of monthGrid(view.anchor)) {
    const n = Math.min(counts[day] || 0, 3);
    const dots = h('span', { class: 'dots' });
    for (let i = 0; i < n; i += 1) dots.append(h('i'));
    grid.append(h('button', {
      class: `cell${day.slice(0, 7) === month ? '' : ' other'}${day === view.today ? ' today' : ''}`,
      'aria-label': `${nums(day)[1]}월 ${nums(day)[2]}일, 할 일 ${counts[day] || 0}개`,
      onclick: () => { view.anchor = day; setMode('day'); },
    }, h('b', { text: String(nums(day)[2]) }), dots));
  }
  return grid;
}

// ---------- navigation ----------
function setMode(mode) {
  view.mode = mode;
  store.set(K.mode, mode);
  render();
}
function step(n) {
  if (view.mode === 'day') view.anchor = addDays(view.anchor, n);
  else if (view.mode === 'week') view.anchor = addDays(view.anchor, 7 * n);
  else view.anchor = addMonths(monthStart(view.anchor), n);
  render();
}
function checkDay() {
  const t = localToday();
  if (t === view.today) return;
  if (view.anchor === view.today) view.anchor = t;
  view.today = t;
  if (rollOver(t)) scheduleSync();
  requestRender();
}

$('prev').addEventListener('click', () => step(-1));
$('next').addEventListener('click', () => step(1));
$('title').addEventListener('click', () => { view.anchor = view.today; render(); });
for (const b of document.querySelectorAll('.modes button')) b.addEventListener('click', () => setMode(b.dataset.mode));
$('theme').addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  store.set(K.theme, next);
  render();
});

// Swipe left/right to move between days, weeks, or months.
let touch = null;
$('main').addEventListener('touchstart', (e) => {
  if (e.touches.length !== 1 || typing()) { touch = null; return; }
  touch = { x: e.touches[0].clientX, y: e.touches[0].clientY };
}, { passive: true });
$('main').addEventListener('touchend', (e) => {
  if (!touch) return;
  const dx = e.changedTouches[0].clientX - touch.x;
  const dy = e.changedTouches[0].clientY - touch.y;
  touch = null;
  if (Math.abs(dx) > 70 && Math.abs(dy) < 45) step(dx < 0 ? 1 : -1);
}, { passive: true });

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') { checkDay(); sync(); }
});
window.addEventListener('online', () => sync());
document.addEventListener('focusout', () => setTimeout(() => { if (renderPending) requestRender(); }, 0));
setInterval(() => { if (document.visibilityState === 'visible') sync(); }, 10000);
setInterval(checkDay, 30000);

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

rollOver(view.today);
render();
sync();
