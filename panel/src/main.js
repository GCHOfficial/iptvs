import { supabase, KIND_FIELDS } from './supabase.js';

const app = document.getElementById('app');
let session = null;
let tab = 'sources';
// Profiles: an account holds several; sources/metadata are scoped to the one
// selected here. `profiles === null` means "not loaded yet".
let profiles = null;
let currentProfileId = localStorage.getItem('iptvs_profile') || null;

// Re-render whenever auth changes (login, logout, magic-link return).
supabase.auth.onAuthStateChange((_event, s) => {
  session = s;
  profiles = null; // reload per session
  render();
});
supabase.auth.getSession().then(({ data }) => {
  session = data.session;
  render();
});

// Load the account's profiles, creating a Default when there are none (so
// sources have somewhere to attach), and settle on a valid current profile.
async function ensureProfiles() {
  const { data, error } = await supabase.from('profiles').select('*').order('position');
  if (error) { profiles = []; return; }
  profiles = data;
  if (profiles.length === 0) {
    const { data: created } = await supabase
      .from('profiles')
      .insert({ owner: session.user.id, name: 'Default', position: 0 })
      .select()
      .single();
    if (created) profiles = [created];
  }
  if (!currentProfileId || !profiles.some((p) => p.id === currentProfileId)) {
    currentProfileId = profiles[0]?.id ?? null;
  }
  if (currentProfileId) localStorage.setItem('iptvs_profile', currentProfileId);
}

const profileName = (id) =>
  (profiles ?? []).find((p) => p.id === id)?.name || 'Profile';

async function render() {
  if (!session) return renderLogin();
  if (profiles === null) await ensureProfiles();
  app.innerHTML = `
    <header class="bar">
      <span class="brand">
        <img class="logo" src="${import.meta.env.BASE_URL}icon.png" alt="" />
        <strong>iptvs sources</strong>
      </span>
      <nav>
        ${navButton('sources', 'Sources')}
        ${navButton('metadata', 'Metadata')}
        ${navButton('profiles', 'Profiles')}
        ${navButton('devices', 'Devices')}
      </nav>
      <select id="profile" class="profile-select" title="Active profile">
        ${(profiles ?? []).map((p) =>
          `<option value="${p.id}" ${p.id === currentProfileId ? 'selected' : ''}>${esc(p.name || 'Profile')}</option>`).join('')}
      </select>
      <button id="logout" class="ghost">Sign out</button>
    </header>
    <main id="view"></main>`;
  document.getElementById('logout').onclick = () => supabase.auth.signOut();
  document.getElementById('profile').onchange = (e) => {
    currentProfileId = e.target.value;
    localStorage.setItem('iptvs_profile', currentProfileId);
    render();
  };
  for (const b of app.querySelectorAll('[data-tab]')) {
    b.onclick = () => { tab = b.dataset.tab; render(); };
  }
  if (tab === 'sources') renderSources();
  else if (tab === 'metadata') renderMetadata();
  else if (tab === 'profiles') renderProfiles();
  else renderDevices();
}

const navButton = (id, label) =>
  `<button data-tab="${id}" class="${tab === id ? 'active' : ''}">${label}</button>`;

const view = () => document.getElementById('view');
const esc = (s) =>
  String(s ?? '').replace(/[&<>"]/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function toast(msg, isError = false) {
  const t = document.createElement('div');
  t.className = `toast ${isError ? 'error' : ''}`;
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 4000);
}

// ---------------------------------------------------------------- login

function renderLogin() {
  app.innerHTML = `
    <div class="login">
      <div class="brand">
        <img class="logo" src="${import.meta.env.BASE_URL}icon.png" alt="" />
        <h1>iptvs sources</h1>
      </div>
      <p>Sign in to manage your IPTV source list. Your devices pull it down — no login on the TV.</p>
      <form id="magic">
        <input type="email" id="email" placeholder="you@example.com" required />
        <button type="submit">Email me a sign-in link</button>
      </form>
      <p id="msg" class="muted"></p>
    </div>`;
  const redirectTo = window.location.origin + import.meta.env.BASE_URL;
  document.getElementById('magic').onsubmit = async (e) => {
    e.preventDefault();
    const email = document.getElementById('email').value.trim();
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: redirectTo },
    });
    document.getElementById('msg').textContent = error
      ? error.message
      : 'Check your email for the sign-in link.';
  };
}

// -------------------------------------------------------------- sources

async function renderSources() {
  view().innerHTML = '<p class="muted">Loading…</p>';
  if (!currentProfileId) {
    return (view().innerHTML =
      '<p class="muted">Create a profile first (Profiles tab).</p>');
  }
  const { data, error } = await supabase
    .from('sources')
    .select('*')
    .eq('profile_id', currentProfileId)
    .order('position');
  if (error) return (view().innerHTML = `<p class="error">${esc(error.message)}</p>`);

  const nextPos = data.length ? Math.max(...data.map((s) => s.position ?? 0)) + 1 : 0;
  view().innerHTML = `
    <p class="muted hint">Sources for <strong>${esc(profileName(currentProfileId))}</strong>. Devices show them in this order — use ↑ / ↓ to reorder.</p>
    <div class="rows">
      ${data.length ? data.map((s, i) => sourceRow(s, i, data.length)).join('') : '<p class="muted">No sources yet.</p>'}
    </div>
    <button id="add" class="primary">+ Add source</button>`;
  document.getElementById('add').onclick = () => editSource(null, nextPos);
  for (const el of view().querySelectorAll('[data-edit]'))
    el.onclick = () => editSource(data.find((s) => s.id === el.dataset.edit));
  for (const el of view().querySelectorAll('[data-del]'))
    el.onclick = () => deleteSource(el.dataset.del);
  for (const el of view().querySelectorAll('[data-up]'))
    el.onclick = () => reorder(data, data.findIndex((s) => s.id === el.dataset.up), -1);
  for (const el of view().querySelectorAll('[data-down]'))
    el.onclick = () => reorder(data, data.findIndex((s) => s.id === el.dataset.down), 1);
}

function sourceRow(s, i, n) {
  const summary =
    s.kind === 'stalker' ? s.fields.portal
    : s.kind === 'xtream' ? s.fields.host
    : s.kind === 'm3u' ? s.fields.playlistUrl
    : 'Demo streams';
  return `
    <div class="row">
      <div>
        <div class="title">${esc(s.label || '(unnamed)')}</div>
        <div class="muted">${esc(s.kind)} · ${esc(summary || '')}</div>
      </div>
      <div class="actions">
        <button data-up="${s.id}" class="ghost icon" title="Move up" ${i === 0 ? 'disabled' : ''}>↑</button>
        <button data-down="${s.id}" class="ghost icon" title="Move down" ${i === n - 1 ? 'disabled' : ''}>↓</button>
        <button data-edit="${s.id}" class="ghost">Edit</button>
        <button data-del="${s.id}" class="ghost danger">Delete</button>
      </div>
    </div>`;
}

// Swap a source with its neighbour, then persist normalized 0..n-1 positions for
// any row whose index changed (self-heals the legacy timestamp-based positions).
async function reorder(data, index, dir) {
  const j = index + dir;
  if (index < 0 || j < 0 || j >= data.length) return;
  const arr = data.slice();
  [arr[index], arr[j]] = [arr[j], arr[index]];
  for (let i = 0; i < arr.length; i++) {
    if (arr[i].position === i) continue;
    const { error } = await supabase.from('sources').update({ position: i }).eq('id', arr[i].id);
    if (error) return toast(error.message, true);
  }
  renderSources();
}

function editSource(existing, nextPos = 0) {
  const kinds = Object.keys(KIND_FIELDS);
  let kind = existing?.kind ?? 'stalker';
  const fieldsHtml = () =>
    KIND_FIELDS[kind]
      .map(
        (f) => `
        <label>${esc(f.label)}
          <input name="${f.key}" type="${f.password ? 'password' : 'text'}"
            value="${esc(existing?.fields?.[f.key] ?? '')}" ${f.required ? 'required' : ''} />
        </label>`)
      .join('');

  view().innerHTML = `
    <form id="form" class="form">
      <h2>${existing ? 'Edit source' : 'Add source'}</h2>
      <label>Label
        <input name="label" value="${esc(existing?.label ?? '')}" />
      </label>
      <label>Kind
        <select name="kind">
          ${kinds.map((k) => `<option value="${k}" ${k === kind ? 'selected' : ''}>${k}</option>`).join('')}
        </select>
      </label>
      <div id="fields">${fieldsHtml()}</div>
      <div class="form-actions">
        <button type="submit" class="primary">Save</button>
        <button type="button" id="cancel" class="ghost">Cancel</button>
      </div>
    </form>`;

  view().querySelector('[name=kind]').onchange = (e) => {
    kind = e.target.value;
    document.getElementById('fields').innerHTML = fieldsHtml();
  };
  document.getElementById('cancel').onclick = renderSources;
  document.getElementById('form').onsubmit = async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    const fields = {};
    for (const f of KIND_FIELDS[kind]) {
      const v = (fd.get(f.key) ?? '').trim();
      if (v) fields[f.key] = v;
    }
    const row = {
      owner: session.user.id,
      profile_id: currentProfileId,
      kind,
      label: (fd.get('label') ?? '').trim(),
      fields,
    };
    let res;
    if (existing) {
      res = await supabase.from('sources').update(row).eq('id', existing.id);
    } else {
      row.position = nextPos; // append after the current last source
      res = await supabase.from('sources').insert(row);
    }
    if (res.error) return toast(res.error.message, true);
    toast('Saved');
    renderSources();
  };
}

async function deleteSource(id) {
  if (!confirm('Delete this source?')) return;
  const { error } = await supabase.from('sources').delete().eq('id', id);
  if (error) return toast(error.message, true);
  renderSources();
}

// -------------------------------------------------------------- profiles

async function renderProfiles() {
  view().innerHTML = '<p class="muted">Loading…</p>';
  const { data, error } = await supabase.from('profiles').select('*').order('position');
  if (error) return (view().innerHTML = `<p class="error">${esc(error.message)}</p>`);
  profiles = data;
  const nextPos = data.length ? Math.max(...data.map((p) => p.position ?? 0)) + 1 : 0;
  view().innerHTML = `
    <p class="muted hint">Each profile is its own source list, metadata, and favorites. Devices pick which profile to sync.</p>
    <div class="rows">
      ${data.map((p, i) => profileRow(p, i, data.length)).join('')}
    </div>
    <button id="addp" class="primary">+ Add profile</button>`;
  document.getElementById('addp').onclick = () => addProfile(nextPos);
  for (const el of view().querySelectorAll('[data-rename]'))
    el.onclick = () => renameProfile(el.dataset.rename, data);
  for (const el of view().querySelectorAll('[data-del]'))
    el.onclick = () => deleteProfile(el.dataset.del, data.length);
  for (const el of view().querySelectorAll('[data-up]'))
    el.onclick = () => reorderProfiles(data, data.findIndex((p) => p.id === el.dataset.up), -1);
  for (const el of view().querySelectorAll('[data-down]'))
    el.onclick = () => reorderProfiles(data, data.findIndex((p) => p.id === el.dataset.down), 1);
}

function profileRow(p, i, n) {
  const active = p.id === currentProfileId;
  return `
    <div class="row">
      <div>
        <div class="title">${esc(p.name || 'Profile')}${active ? ' · selected' : ''}</div>
        <div class="muted">profile</div>
      </div>
      <div class="actions">
        <button data-up="${p.id}" class="ghost icon" title="Move up" ${i === 0 ? 'disabled' : ''}>↑</button>
        <button data-down="${p.id}" class="ghost icon" title="Move down" ${i === n - 1 ? 'disabled' : ''}>↓</button>
        <button data-rename="${p.id}" class="ghost">Rename</button>
        <button data-del="${p.id}" class="ghost danger" ${n === 1 ? 'disabled' : ''}>Delete</button>
      </div>
    </div>`;
}

async function addProfile(nextPos) {
  const name = prompt('Profile name', '');
  if (name === null) return;
  const { error } = await supabase
    .from('profiles')
    .insert({ owner: session.user.id, name: name.trim() || 'Profile', position: nextPos });
  if (error) return toast(error.message, true);
  await ensureProfiles();
  render();
}

async function renameProfile(id, data) {
  const cur = data.find((p) => p.id === id);
  const name = prompt('Profile name', cur?.name ?? '');
  if (name === null) return;
  const { error } = await supabase
    .from('profiles')
    .update({ name: name.trim() || 'Profile' })
    .eq('id', id);
  if (error) return toast(error.message, true);
  await ensureProfiles();
  render();
}

async function deleteProfile(id, count) {
  if (count <= 1) return toast('Keep at least one profile.', true);
  if (!confirm('Delete this profile? Its sources, metadata, and favorites are removed.')) return;
  const { error } = await supabase.from('profiles').delete().eq('id', id);
  if (error) return toast(error.message, true);
  if (currentProfileId === id) currentProfileId = null; // re-settled by ensureProfiles
  await ensureProfiles();
  render();
}

// Swap a profile with its neighbour and persist normalized 0..n-1 positions.
async function reorderProfiles(data, index, dir) {
  const j = index + dir;
  if (index < 0 || j < 0 || j >= data.length) return;
  const arr = data.slice();
  [arr[index], arr[j]] = [arr[j], arr[index]];
  for (let i = 0; i < arr.length; i++) {
    if (arr[i].position === i) continue;
    const { error } = await supabase.from('profiles').update({ position: i }).eq('id', arr[i].id);
    if (error) return toast(error.message, true);
  }
  renderProfiles();
}

// ------------------------------------------------------------- metadata

async function renderMetadata() {
  view().innerHTML = '<p class="muted">Loading…</p>';
  if (!currentProfileId) {
    return (view().innerHTML =
      '<p class="muted">Create a profile first (Profiles tab).</p>');
  }
  const { data } = await supabase
    .from('metadata_configs')
    .select('config')
    .eq('profile_id', currentProfileId)
    .maybeSingle();
  const c = data?.config ?? { provider: 'tmdb', autoEnrich: true };
  view().innerHTML = `
    <form id="meta" class="form">
      <h2>Metadata enrichment</h2>
      <label>Preferred provider
        <select name="provider">
          <option value="tmdb" ${c.provider !== 'tvdb' ? 'selected' : ''}>TMDB</option>
          <option value="tvdb" ${c.provider === 'tvdb' ? 'selected' : ''}>TVDB</option>
        </select>
      </label>
      <label>TMDB API key<input name="tmdbApiKey" value="${esc(c.tmdbApiKey ?? '')}" /></label>
      <label>TVDB API key<input name="tvdbApiKey" value="${esc(c.tvdbApiKey ?? '')}" /></label>
      <label>TVDB PIN<input name="tvdbPin" value="${esc(c.tvdbPin ?? '')}" /></label>
      <label>MDBList API key<input name="mdblistApiKey" value="${esc(c.mdblistApiKey ?? '')}" /></label>
      <label class="check"><input type="checkbox" name="autoEnrich" ${c.autoEnrich !== false ? 'checked' : ''} /> Auto-enrich</label>
      <div class="form-actions"><button class="primary">Save</button></div>
    </form>`;
  document.getElementById('meta').onsubmit = async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    const config = {
      provider: fd.get('provider'),
      tmdbApiKey: (fd.get('tmdbApiKey') ?? '').trim(),
      tvdbApiKey: (fd.get('tvdbApiKey') ?? '').trim(),
      tvdbPin: (fd.get('tvdbPin') ?? '').trim(),
      mdblistApiKey: (fd.get('mdblistApiKey') ?? '').trim(),
      autoEnrich: fd.get('autoEnrich') === 'on',
    };
    const { error } = await supabase
      .from('metadata_configs')
      .upsert({ owner: session.user.id, profile_id: currentProfileId, config });
    toast(error ? error.message : 'Saved', !!error);
  };
}

// -------------------------------------------------------------- devices

async function renderDevices() {
  view().innerHTML = '<p class="muted">Loading…</p>';
  const { data, error } = await supabase
    .from('devices')
    .select('*')
    .order('created_at');
  if (error) return (view().innerHTML = `<p class="error">${esc(error.message)}</p>`);

  view().innerHTML = `
    <form id="claim" class="form claim">
      <h2>Pair a device</h2>
      <p class="muted">Enter the code shown on the device's Cloud sync screen.</p>
      <div class="claim-row">
        <input name="code" placeholder="ABCD2345" autocomplete="off" />
        <button class="primary">Pair</button>
      </div>
    </form>
    <h2>Paired devices</h2>
    <div class="rows">
      ${data.length ? data.map(deviceRow).join('') : '<p class="muted">None yet.</p>'}
    </div>`;

  document.getElementById('claim').onsubmit = async (e) => {
    e.preventDefault();
    const code = new FormData(e.target).get('code').trim().toUpperCase();
    const { error } = await supabase.rpc('claim_pairing', { p_code: code });
    if (error) return toast(error.message, true);
    toast('Device paired');
    renderDevices();
  };
  for (const el of view().querySelectorAll('[data-revoke]'))
    el.onclick = () => revokeDevice(el.dataset.revoke);
  for (const el of view().querySelectorAll('[data-rename]'))
    el.onclick = () => renameDevice(el.dataset.rename, data);
}

function deviceRow(d) {
  const profile = d.active_profile_id ? profileName(d.active_profile_id) : '—';
  return `
    <div class="row">
      <div>
        <div class="title">${esc(d.label || 'Device')}</div>
        <div class="muted">paired ${esc((d.created_at || '').slice(0, 10))} · syncing ${esc(profile)}</div>
      </div>
      <div class="actions">
        <button data-rename="${d.device_uid}" class="ghost">Rename</button>
        <button data-revoke="${d.device_uid}" class="ghost danger">Revoke</button>
      </div>
    </div>`;
}

async function renameDevice(id, data) {
  const cur = data.find((d) => d.device_uid === id);
  const label = prompt('Device name', cur?.label ?? '');
  if (label === null) return;
  const { error } = await supabase
    .from('devices')
    .update({ label: label.trim() })
    .eq('device_uid', id);
  if (error) return toast(error.message, true);
  renderDevices();
}

async function revokeDevice(id) {
  if (!confirm('Revoke this device? It will stop syncing.')) return;
  const { error } = await supabase.from('devices').delete().eq('device_uid', id);
  if (error) return toast(error.message, true);
  renderDevices();
}
