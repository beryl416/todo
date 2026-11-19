// done for iPhone (and any browser). Same data and sync rules as the Mac app:
// every change stamps updated_at, the newest version of an item wins, and
// changed items stay "dirty" until the server has them.
//
// Each to-do lives in one list: a day's, a week's or a month's ("scope"),
// stored under the first day of that period.

const SUPABASE_URL = 'https://hqyucrsqxvzwtyewxqhi.supabase.co';
const PUBLISHABLE_KEY = 'sb_publishable_ZphNZVulyrdtVsKzK910jA_cZOAlQi4'; // public by design
const K = { state: 'todo.state.v1', key: 'todo.key', theme: 'todo.theme', mode: 'todo.mode' };
const SCOPES = ['day', 'week', 'month'];

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
const localToday = () => { const n = new Date(); return mk(n.getFullYear(), n.getMonth() + 1, n.getDate()); };
const WEEKDAYS = ['월', '화', '수', '목', '금', '토', '일'];
const weekdayName = (s) => WEEKDAYS[isoWeekday(s) - 1];

const scopeOf = (i) => (SCOPES.includes(i.scope) ? i.scope : 'day');
const startOf = (scope, day) => (scope === 'week' ? weekStart(day) : scope === 'month' ? monthStart(day) : day);
const nextStart = (scope, day) => {
  const s = startOf(scope, day);
  return scope === 'week' ? addDays(s, 7) : scope === 'month' ? addMonths(s, 1) : addDays(s, 1);
};
// The list an item belongs to; tolerates a day that is not the period's first day.
const listOf = (i) => ({ scope: scopeOf(i), start: startOf(scopeOf(i), i.day) });
const inList = (i, list) => { const l = listOf(i); return l.scope === list.scope && l.start === list.start; };

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
const openIn = (list) => all().filter((i) => live(i) && !i.parent && !i.done && inList(i, list)).sort(inOrder);
const doneIn = (list) => all().filter((i) => live(i) && !i.parent && i.done && inList(i, list)).sort(inOrder);
// Sub-tasks stay in their own order; checking one off does not move it.
const childrenOf = (id) => all().filter((i) => live(i) && i.parent === id).sort(inOrder);

function write(item) {
  state.items[item.id] = item;
  state.dirty.add(item.id);
  save();
}
function update(id, change) {
  const cur = state.items[id];
  if (!live(cur)) return;
  const next = { ...cur, scope: scopeOf(cur) };
  change(next);
  next.updated_at = Math.max(Date.now(), cur.updated_at + 1);
  write(next);
}
// The add button: an empty to-do at the end of the unfinished ones, for its title to be
// typed in. It is not sent while empty, and commitTitle deletes it if left that way.
function addBlank(list) {
  const last = openIn(list).at(-1);
  const id = crypto.randomUUID();
  write({
    id, title: '', scope: list.scope, day: list.start, done: false, starred: false,
    position: (last ? last.position : 0) + 1, deleted: false, updated_at: Date.now(),
  });
  return id;
}
// Sub-tasks belong to a top-level to-do and go wherever it goes. No sub-tasks of sub-tasks.
function addChild(title, parentId) {
  const t = title.trim();
  const parent = state.items[parentId];
  if (!t || !live(parent) || parent.parent) return;
  const last = childrenOf(parentId).at(-1);
  write({
    id: crypto.randomUUID(), title: t, scope: scopeOf(parent), day: parent.day, done: false, starred: false,
    position: (last ? last.position : 0) + 1, deleted: false, parent: parentId, updated_at: Date.now(),
  });
}
// Deletes a to-do, and its sub-tasks with it.
function removeItem(id) {
  for (const c of childrenOf(id)) update(c.id, (i) => { i.deleted = true; });
  update(id, (i) => { i.deleted = true; });
}
// Moves a to-do between the day, week and month lists. A week or month takes the one
// around its date; a day takes today if today is in its current period, else that period's first day.
function changeScope(id, scope) {
  const cur = state.items[id];
  if (!live(cur) || cur.parent || scopeOf(cur) === scope) return;
  const own = listOf(cur);
  const around = scope === 'day' && startOf(own.scope, view.today) === own.start ? view.today : own.start;
  const target = { scope, start: startOf(scope, around) };
  const others = cur.done ? doneIn(target) : openIn(target);
  const position = (others.length ? others.at(-1).position : 0) + 1;
  update(id, (i) => { i.scope = scope; i.day = target.start; i.position = position; });
}
// Starring a to-do also moves it to the top of its list (unfinished or finished);
// un-starring leaves it where it is.
// Checking a to-do's last open sub-task checks the to-do too; unchecking a sub-task
// of a checked to-do opens the to-do again.
function toggleDone(id) {
  const cur = state.items[id];
  if (!live(cur)) return;
  update(id, (i) => { i.done = !i.done; });
  const parent = cur.parent && state.items[cur.parent];
  if (!live(parent)) return;
  const checked = !cur.done;
  if (checked && !parent.done && childrenOf(parent.id).every((c) => c.done)) update(parent.id, (i) => { i.done = true; });
  else if (!checked && parent.done) update(parent.id, (i) => { i.done = false; });
}
function toggleStar(id) {
  const cur = state.items[id];
  if (!live(cur)) return;
  if (cur.starred || cur.parent) { update(id, (i) => { i.starred = !i.starred; }); return; }
  const list = listOf(cur);
  const first = (cur.done ? doneIn(list) : openIn(list)).find((i) => i.id !== id);
  update(id, (i) => {
    i.starred = true;
    if (first && first.position <= i.position) i.position = first.position - 1;
  });
}
// At launch: deletes to-dos left empty when the app last closed mid-edit.
function dropBlanks() {
  for (const i of all()) if (live(i) && !i.title.trim()) removeItem(i.id);
}
function commitTitle(id) {
  const cur = state.items[id];
  if (!live(cur)) return;
  const t = cur.title.trim();
  if (!t) removeItem(id);
  else if (t !== cur.title) update(id, (i) => { i.title = t; });
}
// "Later": the next day, week or month after whichever is later, its own or the current one.
function postpone(id) {
  const cur = state.items[id];
  if (!live(cur) || cur.parent) return;
  const scope = scopeOf(cur);
  const own = listOf(cur).start;
  const current = startOf(scope, view.today);
  const target = { scope, start: nextStart(scope, own > current ? own : current) };
  const others = cur.done ? doneIn(target) : openIn(target);
  const position = (others.length ? others.at(-1).position : 0) + 1;
  update(id, (i) => { i.day = target.start; i.position = position; });
}
// Unfinished to-dos from earlier days, weeks and months move to the top of the current ones.
function rollOver(today) {
  let moved = 0;
  for (const scope of SCOPES) {
    const current = { scope, start: startOf(scope, today) };
    const stale = all()
      .filter((i) => live(i) && !i.done && !i.parent && scopeOf(i) === scope && listOf(i).start < current.start)
      .sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : inOrder(a, b)));
    if (!stale.length) continue;
    const top = openIn(current)[0]?.position ?? 1;
    stale.forEach((it, k) => update(it.id, (i) => { i.day = current.start; i.position = top - (stale.length - k); }));
    moved += stale.length;
  }
  return moved;
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
  .slice(0, 500)
  .map((i) => (i.scope ? i : { ...i, scope: 'day' }));

function markPushed(batch) {
  for (const sent of batch) {
    const cur = state.items[sent.id];
    // Edited again while sending? Then it stays dirty.
    if (!cur || cur.updated_at !== sent.updated_at || cur.title !== sent.title) continue;
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
  mode: SCOPES.includes(store.get(K.mode)) ? store.get(K.mode) : 'day',
  today: localToday(),
  anchor: localToday(),
};
const currentList = () => ({ scope: view.mode, start: startOf(view.mode, view.anchor) });
let activeId = null;      // the to-do being edited, with its tools showing
let editingId = null;     // the sub-task being edited
let addingChildTo = null; // the to-do showing an "add sub-task" line
let renderPending = false;
let rendering = false;    // a redraw removes text boxes; their blur is not the user leaving
let focusAfter = null;    // { edit: id } | { childAdd: parentId }

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
    // A week belongs to the month that holds its Thursday (Korean calendars, ISO 8601).
    const thursday = addDays(weekStart(view.anchor), 3);
    const [, tm, td] = nums(thursday);
    const ordinal = ['첫째', '둘째', '셋째', '넷째', '다섯째'][Math.floor((td - 1) / 7)];
    return `${yp(thursday)}${tm}월 ${ordinal} 주`;
  }
  return `${nums(view.anchor)[0]}년 ${m}월`;
}

// Re-rendering replaces the list, so wait while someone is typing, and while a
// finger or mouse is down (redrawing mid-tap would swallow the tap).
let pointerDown = false;
function typing() {
  const a = document.activeElement; // a list picker counts: redrawing would close it
  return a && (a.tagName === 'TEXTAREA' || a.tagName === 'SELECT');
}
function requestRender() {
  if (typing() || pointerDown) { renderPending = true; return; }
  render();
}
document.addEventListener('pointerdown', (e) => {
  pointerDown = true;
  const t = e.target;
  // A tap outside the to-do being edited puts its tools away.
  if (activeId && !t.closest(`[data-row="${activeId}"]`)) {
    const id = activeId;
    activeId = null;
    commitTitle(id);
    scheduleSync();
    renderPending = true;
  }
  // A tap outside the "add sub-task" line closes it, keeping what was typed.
  if (addingChildTo && !t.closest(`[data-child-add-row="${addingChildTo}"]`)) {
    finishAddingChild();
    renderPending = true;
  }
  // A tap on empty space removes the cursor.
  if (!t.closest('textarea, button, select, label, .text')) {
    const a = document.activeElement;
    if (a && a.tagName === 'TEXTAREA') a.blur();
  }
}, true);
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  const line = addingChildTo && $('main').querySelector(`textarea[data-child-add="${addingChildTo}"]`);
  if (line) line.value = ''; // Escape drops what was typed there
  finishEdits();
  const a = document.activeElement;
  if (a && a.tagName === 'TEXTAREA') a.blur();
  render();
});
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
      h('b', { text: 'done' }), h('br'),
      keyRejected ? '연결 코드가 맞지 않습니다.' : '아직 연결되지 않았습니다.', h('br'),
      '맥 앱 메뉴 [파일 → 아이폰 연결…]의', h('br'),
      'QR 코드를 카메라로 찍어서 여세요.'));
    $('status').textContent = '';
    return;
  }
  document.querySelector('.top').hidden = false;
  $('title').textContent = titleText();
  for (const b of document.querySelectorAll('.modes button')) b.classList.toggle('on', b.dataset.mode === view.mode);
  const dark = document.documentElement.dataset.theme === 'dark';
  $('theme').innerHTML = dark ? ICON_SUN : ICON_MOON;
  document.querySelector('meta[name="theme-color"]').setAttribute('content', dark ? '#1e1e1e' : '#ffffff');

  // Unfinished, then finished, then the add button.
  // A redraw puts the cursor back where it was, so the iPhone keyboard stays up.
  const keepFocus = focusAfter || focusKey(document.activeElement);
  const caret = !focusAfter && document.activeElement?.tagName === 'TEXTAREA' ? document.activeElement.selectionStart : null;
  focusAfter = null;
  const list = currentList();
  const wrap = h('div', { class: 'list' });
  for (const item of openIn(list)) wrap.append(row(item));
  for (const item of doneIn(list)) wrap.append(row(item));
  wrap.append(addButton(list));
  rendering = true;
  try { main.replaceChildren(wrap); } finally { rendering = false; }
  for (const ta of main.querySelectorAll('textarea')) fit(ta);
  $('status').textContent = online ? '' : '오프라인 · 연결되면 맞춰집니다';

  if (keepFocus) {
    const el = main.querySelector(selectorFor(keepFocus));
    if (el) {
      el.focus({ preventScroll: true });
      const pos = caret ?? el.value.length;
      el.setSelectionRange(pos, pos);
    }
  }
}

function focusKey(el) {
  if (!el || el.tagName !== 'TEXTAREA') return null;
  if (el.dataset.edit) return { edit: el.dataset.edit };
  if (el.dataset.childAdd) return { childAdd: el.dataset.childAdd };
  return null;
}
function selectorFor(key) {
  if (key.edit) return `textarea[data-edit="${key.edit}"]`;
  return `textarea[data-child-add="${key.childAdd}"]`;
}

function fit(el) {
  el.style.height = '0px';
  el.style.height = `${el.scrollHeight}px`;
}

function act(change) {
  change();
  scheduleSync();
  render();
}

// ---------- to-dos and sub-tasks ----------
// Sub-tasks always show under their to-do. Tapping a to-do's title edits it in place
// and shows its tools: star, postpone, list, add sub-task, delete.
const POSTPONE_LABEL = { day: '내일로', week: '다음 주로', month: '다음 달로' };
const SCOPE_LABEL = { day: '일', week: '주', month: '월' };
const keep = (e) => e.preventDefault(); // tapping this must not take the cursor away

// Finishes every edit (a blank title deletes) and closes the "add sub-task" line.
function finishEdits() {
  if (editingId) { const id = editingId; editingId = null; commitTitle(id); }
  if (activeId) { const id = activeId; activeId = null; commitTitle(id); }
  finishAddingChild();
  scheduleSync();
}

function activate(id) {
  finishEdits();
  activeId = id;
  focusAfter = { edit: id };
  render();
}

function editChild(id) {
  finishEdits();
  editingId = id;
  focusAfter = { edit: id };
  render();
}

function startAddingChild(id) {
  finishEdits();
  addingChildTo = id;
  focusAfter = { childAdd: id };
  render();
}

// Closes the "add sub-task" line, adding what was typed in it.
function finishAddingChild() {
  if (!addingChildTo) return;
  const parent = addingChildTo;
  addingChildTo = null;
  const ta = $('main').querySelector(`textarea[data-child-add="${parent}"]`);
  if (ta && ta.value.trim()) {
    addChild(ta.value, parent);
    ta.value = '';
    scheduleSync();
  }
}

// Typing into a title. Return calls onReturn instead of adding a line break.
function titleArea(item, onReturn, onBlur) {
  const ta = h('textarea', {
    rows: 1,
    'data-edit': item.id,
    enterkeyhint: 'done',
    oninput: (e) => {
      const t = e.target;
      const value = t.value.replace(/\n/g, ' ');
      if (value !== t.value) t.value = value;
      update(item.id, (i) => { i.title = value; });
      fit(t);
      if (e.inputType === 'insertLineBreak' || e.inputType === 'insertParagraph' || /\n/.test(e.data || '')) onReturn(t);
      else scheduleSync(1200);
    },
    onblur: onBlur,
  });
  ta.value = item.title;
  return ta;
}

function row(item) {
  const active = activeId === item.id;
  const block = h('div', { class: 'block' });
  const el = h('div', { class: `row${item.done ? ' done' : ''}`, 'data-row': item.id });
  el.append(h('button', {
    class: 'check',
    'aria-label': item.done ? '완료 취소' : '완료',
    onpointerdown: active ? keep : null,
    onmousedown: active ? keep : null,
    onclick: () => act(() => toggleDone(item.id)),
  }, h('span')));

  if (active) {
    el.append(titleArea(item,
      () => { finishEdits(); document.activeElement?.blur(); render(); },
      () => { // the keyboard went away: keep the edit, leave the tools up
        if (rendering || activeId !== item.id) return;
        commitTitle(item.id);
        scheduleSync();
        if (!live(state.items[item.id])) { activeId = null; setTimeout(requestRender, 0); }
      }));
    el.append(h('div', { class: 'tools' },
      h('button', {
        class: item.starred ? 'starred' : '',
        'aria-label': item.starred ? '중요 표시 빼기' : '중요 표시 (맨 위로)',
        onpointerdown: keep, onmousedown: keep,
        onclick: () => act(() => toggleStar(item.id)),
      }, item.starred ? '★' : '☆'),
      item.done ? null : h('button', {
        'aria-label': POSTPONE_LABEL[scopeOf(item)], onpointerdown: keep, onmousedown: keep,
        onclick: () => { finishEdits(); act(() => postpone(item.id)); },
      }, '→'),
      moveButton(item),
      h('button', {
        'aria-label': '하위 할 일 추가', onpointerdown: keep, onmousedown: keep,
        onclick: () => startAddingChild(item.id),
      }, '↳'),
      h('button', {
        'aria-label': '삭제', onpointerdown: keep, onmousedown: keep,
        onclick: () => { activeId = null; act(() => removeItem(item.id)); },
      }, '×')));
  } else {
    el.append(h('div', { class: 'text', text: item.title, onclick: () => activate(item.id) }));
    if (item.starred) el.append(h('span', { class: 'star', text: '★' }));
  }
  block.append(el);
  for (const child of childrenOf(item.id)) block.append(childRow(child));
  if (addingChildTo === item.id) block.append(childAddRow(item.id));
  return block;
}

function childRow(child) {
  const el = h('div', { class: `row child${child.done ? ' done' : ''}` });
  el.append(h('button', {
    class: 'check',
    'aria-label': child.done ? '완료 취소' : '완료',
    onpointerdown: keep, onmousedown: keep,
    onclick: () => act(() => toggleDone(child.id)),
  }, h('span')));
  if (editingId === child.id) {
    el.append(titleArea(child, (t) => t.blur(), () => {
      if (rendering || editingId !== child.id) return;
      editingId = null;
      commitTitle(child.id);
      scheduleSync();
      setTimeout(requestRender, 0);
    }));
    el.append(h('div', { class: 'tools' }, h('button', {
      'aria-label': '삭제', onpointerdown: keep, onmousedown: keep,
      onclick: () => { editingId = null; act(() => removeItem(child.id)); },
    }, '×')));
  } else {
    el.append(h('div', { class: 'text', text: child.title, onclick: () => editChild(child.id) }));
  }
  return el;
}

// Return adds the sub-task and stays for the next one; Return on an empty line,
// tapping elsewhere or closing the keyboard closes the line (keeping what was typed).
function childAddRow(parentId) {
  const ta = h('textarea', {
    rows: 1,
    'data-child-add': parentId,
    placeholder: '하위 할 일 추가',
    enterkeyhint: 'next',
    'aria-label': '하위 할 일 추가',
    oninput: (e) => {
      const t = e.target;
      if (!t.value.includes('\n')) { fit(t); return; }
      const text = t.value.replace(/\n/g, '');
      t.value = '';
      if (text.trim()) {
        addChild(text, parentId);
        scheduleSync();
        focusAfter = { childAdd: parentId };
      } else {
        addingChildTo = null;
        t.blur();
      }
      render();
    },
    onblur: () => {
      if (rendering || addingChildTo !== parentId) return;
      finishAddingChild();
      renderPending = true;
      setTimeout(() => { if (renderPending) requestRender(); }, 0);
    },
  });
  return h('div', { class: 'row child-add', 'data-child-add-row': parentId }, ta);
}

// The list a to-do lives in ("일", "주" or "월"). Tapping it opens the system picker
// to move the whole to-do, sub-tasks included, to another list.
function moveButton(item) {
  const current = scopeOf(item);
  const select = h('select', {
    'aria-label': '다른 목록으로 옮기기',
    onchange: (e) => {
      const scope = e.target.value;
      if (scope === current) return;
      finishEdits();
      act(() => changeScope(item.id, scope));
    },
  }, ...SCOPES.map((s) => h('option', { value: s, selected: s === current }, `${SCOPE_LABEL[s]}간 목록`)));
  return h('label', { class: 'move' }, SCOPE_LABEL[current], select);
}

// "+ 할 일 추가" as one button, a little apart from the list; its + sits where the
// checkboxes sit. Tapping it adds an empty to-do at the end of the unfinished ones,
// opened for typing; left empty, that to-do goes away again.
function addButton(list) {
  return h('button', {
    class: 'add',
    onpointerdown: keep, onmousedown: keep, // keeps the iPhone keyboard up while moving on
    onclick: () => {
      finishEdits();
      activeId = addBlank(list);
      focusAfter = { edit: activeId };
      render();
    },
  }, h('span', { class: 'plus' }), '할 일 추가');
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
  if (startOf(view.mode, view.anchor) === startOf(view.mode, view.today)) view.anchor = t;
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

dropBlanks();
rollOver(view.today);
render();
sync();
