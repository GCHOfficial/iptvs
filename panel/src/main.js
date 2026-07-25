import { supabase, KIND_FIELDS } from './supabase.js';
import {
  validateSource,
  friendlyError,
  splitFields,
  kindHasSecret,
  deviceProvisionState,
  deviceNeedsKey,
  SOURCE_SECRET_KEYS,
  METADATA_SECRET_KEYS,
} from './validate.js';
import * as secrets from './secrets.js';
import { CloudCryptoError } from './crypto.js';

const MAX_PROFILE_NAME_LENGTH = 256;
const MAX_METADATA_FIELD_LENGTH = 1024;
// Minimum sync-passphrase length. E2EE is only as strong as the passphrase, and
// the passphrase is unrecoverable, so guard against trivially weak entries.
const MIN_PASSPHRASE_LENGTH = 8;

const app = document.getElementById('app');
// Profiles per account are capped server-side (a BEFORE INSERT trigger); mirror
// the limit here to disable the add button and explain why before the round-trip.
const MAX_PROFILES = 20;
let session = null;
let tab = 'sources';
// Profiles: an account holds several; sources/metadata are scoped to the one
// selected here. `profiles === null` means "not loaded yet".
let profiles = null;
let currentProfileId = localStorage.getItem('iptvs_profile') || null;

// The unlocked content key auto-locks after idle or on sign-out; re-render so
// the Security section and any locked secret placeholders update.
secrets.setLockChangeHandler(() => render());
// Any real user interaction defers the idle auto-lock. Capture-phase, passive.
for (const evt of ['click', 'keydown', 'input']) {
  document.addEventListener(evt, () => secrets.touchActivity(), { capture: true, passive: true });
}

// Re-render whenever auth changes (login, logout, magic-link return).
supabase.auth.onAuthStateChange((_event, s) => {
  session = s;
  profiles = null; // reload per session
  secrets.lock(); // never carry an unlocked CK across an auth change
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
        ${navButton('security', 'Security')}
        ${navButton('profiles', 'Profiles')}
        ${navButton('devices', 'Devices')}
        ${navButton('account', 'Account')}
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
    secrets.lock(); // the unlocked CK is scoped to one profile
    render();
  };
  for (const b of app.querySelectorAll('[data-tab]')) {
    b.onclick = () => { tab = b.dataset.tab; render(); };
  }
  if (tab === 'sources') renderSources();
  else if (tab === 'metadata') renderMetadata();
  else if (tab === 'security') renderSecurity();
  else if (tab === 'profiles') renderProfiles();
  else if (tab === 'devices') renderDevices();
  else renderAccount();
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
      <p class="legal-links">
        <a href="${import.meta.env.BASE_URL}privacy.html">Privacy</a>
        <span aria-hidden="true"> · </span>
        <a href="${import.meta.env.BASE_URL}support.html">Support</a>
      </p>
    </div>`;
  const redirectTo = window.location.origin + import.meta.env.BASE_URL;
  document.getElementById('magic').onsubmit = async (e) => {
    e.preventDefault();
    const email = document.getElementById('email').value.trim();
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: redirectTo },
    });
    if (error) console.error(error);
    document.getElementById('msg').textContent = error
      ? friendlyError(error)
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
  if (error) { console.error(error); return (view().innerHTML = `<p class="error">${esc(friendlyError(error))}</p>`); }

  // Secrets no longer live in sources.fields (a server strip-trigger removes
  // them). Load them from the secret store so the summary and the edit form can
  // still show/prefill credential-bearing fields; a locked E2EE profile yields
  // LOCKED placeholders.
  let decoded = { sources: {}, metadata: null, missing: false };
  try {
    decoded = await secrets.loadDecodedSecrets(currentProfileId);
  } catch (e) {
    console.error(e); // degrade to broad-only display rather than failing the page
  }
  const locked = decoded.sources && Object.values(decoded.sources).includes(secrets.LOCKED);

  const nextPos = data.length ? Math.max(...data.map((s) => s.position ?? 0)) + 1 : 0;
  view().innerHTML = `
    <p class="muted hint">Sources for <strong>${esc(profileName(currentProfileId))}</strong>. Devices show them in this order — use ↑ / ↓ to reorder.</p>
    ${locked ? '<p class="muted hint">This profile is end-to-end encrypted and locked. Credentials are hidden — open <strong>Security</strong> to unlock.</p>' : ''}
    <div class="rows">
      ${data.length ? data.map((s, i) => sourceRow(s, i, data.length, decoded)).join('') : '<p class="muted">No sources yet.</p>'}
    </div>
    <button id="add" class="primary">+ Add source</button>`;
  document.getElementById('add').onclick = () => editSource(null, nextPos, decoded);
  for (const el of view().querySelectorAll('[data-edit]'))
    el.onclick = () => editSource(data.find((s) => s.id === el.dataset.edit), 0, decoded);
  for (const el of view().querySelectorAll('[data-del]'))
    el.onclick = () => deleteSource(el.dataset.del);
  for (const el of view().querySelectorAll('[data-up]'))
    el.onclick = () => reorder(data, data.findIndex((s) => s.id === el.dataset.up), -1);
  for (const el of view().querySelectorAll('[data-down]'))
    el.onclick = () => reorder(data, data.findIndex((s) => s.id === el.dataset.down), 1);
}

// The decoded secret map for a source, falling back to legacy inline fields
// when the secret RPCs are absent (pre-migration backend). Returns a string map,
// or the LOCKED sentinel when the profile is E2EE-locked.
function sourceSecret(s, decoded) {
  const entry = decoded?.sources?.[s.id];
  if (entry !== undefined) return entry;
  if (decoded?.missing) {
    // Pre-migration: credentials may still be inline in the row.
    const map = {};
    for (const k of SOURCE_SECRET_KEYS) if (s.fields?.[k]) map[k] = s.fields[k];
    return map;
  }
  return {};
}

function sourceRow(s, i, n, decoded) {
  const secret = sourceSecret(s, decoded);
  const isLocked = secret === secrets.LOCKED;
  const summary =
    s.kind === 'stalker' ? s.fields.portal
    : s.kind === 'xtream' ? s.fields.host
    : s.kind === 'm3u' ? (isLocked ? 'M3U playlist' : secret.playlistUrl || 'M3U playlist')
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
    if (error) { console.error(error); return toast(friendlyError(error), true); }
  }
  renderSources();
}

function editSource(existing, nextPos = 0, decoded = null) {
  const kinds = Object.keys(KIND_FIELDS);
  let kind = existing?.kind ?? 'stalker';
  const secretMap = existing ? sourceSecret(existing, decoded) : {};
  const isLocked = secretMap === secrets.LOCKED;
  // Secret fields prefill from the secret store (decrypted); broad fields from
  // the row. A locked E2EE profile can't reveal secrets, so those start blank.
  const prefill = (f) => {
    if (SOURCE_SECRET_KEYS.includes(f.key)) return isLocked ? '' : (secretMap[f.key] ?? '');
    return existing?.fields?.[f.key] ?? '';
  };
  const fieldsHtml = () =>
    KIND_FIELDS[kind]
      .map(
        (f) => `
        <label>${esc(f.label)}
          <input name="${f.key}" type="${f.password ? 'password' : 'text'}"
            value="${esc(prefill(f))}" ${f.required ? 'required' : ''} />
        </label>`)
      .join('');

  view().innerHTML = `
    <form id="form" class="form">
      <h2>${existing ? 'Edit source' : 'Add source'}</h2>
      ${isLocked ? '<p class="muted hint">This profile is locked. Credential fields are blank — saving would overwrite the stored ones. Unlock in <strong>Security</strong> first.</p>' : ''}
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
    const label = (fd.get('label') ?? '').trim();
    const validationError = validateSource(kind, label, fields);
    if (validationError) return toast(validationError, true);

    // Determine the profile's E2EE state; block a secret-bearing edit on a
    // locked profile (we can't encrypt without the CK, and a plaintext write
    // would be rejected server-side and could blank the stored secret).
    let cryptoState;
    try {
      cryptoState = await secrets.getCryptoState(currentProfileId);
    } catch (err) {
      console.error(err);
      return toast(friendlyError(err), true);
    }
    const needsSecret = kindHasSecret(kind);
    const locked = cryptoState.enabled && !secrets.unlockedFor(currentProfileId);
    // A locked profile can't encrypt. Creating a NEW secret-bearing source would
    // silently drop the credentials the form collected, so block that. An
    // EXISTING source can still have its broad fields edited — we just skip the
    // secret write, preserving the stored (encrypted) credentials.
    if (locked && needsSecret && !existing) {
      return toast(
        'This profile is end-to-end encrypted. Unlock it in Security before adding this source.',
        true,
      );
    }

    // Broad fields ride the sources row; secret fields go to set_source_secret.
    const { broad, secret } = splitFields(fields, SOURCE_SECRET_KEYS);
    const row = { owner: session.user.id, profile_id: currentProfileId, kind, label, fields: broad };
    let sourceId = existing?.id;
    if (existing) {
      const res = await supabase.from('sources').update(row).eq('id', existing.id);
      if (res.error) { console.error(res.error); return toast(friendlyError(res.error), true); }
    } else {
      row.position = nextPos; // append after the current last source
      const res = await supabase.from('sources').insert(row).select('id').single();
      if (res.error) { console.error(res.error); return toast(friendlyError(res.error), true); }
      sourceId = res.data.id;
    }

    if (needsSecret && !locked) {
      try {
        await secrets.setSourceSecret(currentProfileId, sourceId, secret, cryptoState);
      } catch (err) {
        console.error(err);
        return toast(
          err instanceof CloudCryptoError
            ? 'Could not encrypt the credentials — unlock this profile in Security and try again.'
            : friendlyError(err),
          true,
        );
      }
    }
    toast(locked && needsSecret ? 'Saved. Credentials left unchanged (profile locked).' : 'Saved');
    renderSources();
  };
}

async function deleteSource(id) {
  if (!confirm('Delete this source?')) return;
  const { error } = await supabase.from('sources').delete().eq('id', id);
  if (error) { console.error(error); return toast(friendlyError(error), true); }
  renderSources();
}

// -------------------------------------------------------------- profiles

async function renderProfiles() {
  view().innerHTML = '<p class="muted">Loading…</p>';
  const { data, error } = await supabase.from('profiles').select('*').order('position');
  if (error) { console.error(error); return (view().innerHTML = `<p class="error">${esc(friendlyError(error))}</p>`); }
  profiles = data;
  const nextPos = data.length ? Math.max(...data.map((p) => p.position ?? 0)) + 1 : 0;
  const atCap = data.length >= MAX_PROFILES;
  view().innerHTML = `
    <p class="muted hint">Each profile is its own source list, metadata, and favorites. Devices pick which profile to sync.</p>
    <div class="rows">
      ${data.map((p, i) => profileRow(p, i, data.length)).join('')}
    </div>
    <button id="addp" class="primary" ${atCap ? 'disabled' : ''}>+ Add profile</button>
    ${atCap ? `<p class="muted hint mt">Profile limit reached (${MAX_PROFILES}).</p>` : ''}`;
  if (!atCap) document.getElementById('addp').onclick = () => addProfile(nextPos);
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
  if (name.trim().length > MAX_PROFILE_NAME_LENGTH) {
    return toast(`Profile name is too long (max ${MAX_PROFILE_NAME_LENGTH} characters).`, true);
  }
  const { error } = await supabase
    .from('profiles')
    .insert({ owner: session.user.id, name: name.trim() || 'Profile', position: nextPos });
  if (error) { console.error(error); return toast(friendlyError(error), true); }
  await ensureProfiles();
  render();
}

async function renameProfile(id, data) {
  const cur = data.find((p) => p.id === id);
  const name = prompt('Profile name', cur?.name ?? '');
  if (name === null) return;
  if (name.trim().length > MAX_PROFILE_NAME_LENGTH) {
    return toast(`Profile name is too long (max ${MAX_PROFILE_NAME_LENGTH} characters).`, true);
  }
  const { error } = await supabase
    .from('profiles')
    .update({ name: name.trim() || 'Profile' })
    .eq('id', id);
  if (error) { console.error(error); return toast(friendlyError(error), true); }
  await ensureProfiles();
  render();
}

async function deleteProfile(id, count) {
  if (count <= 1) return toast('Keep at least one profile.', true);
  if (!confirm('Delete this profile? Its sources, metadata, and favorites are removed.')) return;
  const { error } = await supabase.from('profiles').delete().eq('id', id);
  if (error) { console.error(error); return toast(friendlyError(error), true); }
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
    if (error) { console.error(error); return toast(friendlyError(error), true); }
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

  // API keys/PIN are secrets now — loaded from the secret store, not `config`.
  let metaSecret = {};
  let isLocked = false;
  try {
    const decoded = await secrets.loadDecodedSecrets(currentProfileId);
    if (decoded.metadata === secrets.LOCKED) isLocked = true;
    else if (decoded.metadata) metaSecret = decoded.metadata;
    else if (decoded.missing) {
      // Pre-migration: keys may still be inline in the config.
      for (const k of METADATA_SECRET_KEYS) if (c[k]) metaSecret[k] = c[k];
    }
  } catch (e) {
    console.error(e);
  }
  const sv = (k) => (isLocked ? '' : (metaSecret[k] ?? ''));

  view().innerHTML = `
    <form id="meta" class="form">
      <h2>Metadata enrichment</h2>
      ${isLocked ? '<p class="muted hint">This profile is locked. API keys are hidden — unlock in <strong>Security</strong> before editing them.</p>' : ''}
      <label>Preferred provider
        <select name="provider">
          <option value="tmdb" ${c.provider !== 'tvdb' ? 'selected' : ''}>TMDB</option>
          <option value="tvdb" ${c.provider === 'tvdb' ? 'selected' : ''}>TVDB</option>
        </select>
      </label>
      <label>TMDB API key<input name="tmdbApiKey" value="${esc(sv('tmdbApiKey'))}" /></label>
      <label>TVDB API key<input name="tvdbApiKey" value="${esc(sv('tvdbApiKey'))}" /></label>
      <label>TVDB PIN<input name="tvdbPin" value="${esc(sv('tvdbPin'))}" /></label>
      <label>MDBList API key<input name="mdblistApiKey" value="${esc(sv('mdblistApiKey'))}" /></label>
      <label class="check"><input type="checkbox" name="autoEnrich" ${c.autoEnrich !== false ? 'checked' : ''} /> Auto-enrich</label>
      <div class="form-actions"><button class="primary">Save</button></div>
    </form>`;
  document.getElementById('meta').onsubmit = async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    // Broad config: provider choice + auto-enrich flag only.
    const config = {
      provider: fd.get('provider'),
      autoEnrich: fd.get('autoEnrich') === 'on',
    };
    // Secret keys travel separately through set_metadata_secret.
    const secret = {};
    for (const k of METADATA_SECRET_KEYS) {
      const v = (fd.get(k) ?? '').trim();
      if (v) secret[k] = v;
    }
    for (const [key, value] of Object.entries(secret)) {
      if (value.length > MAX_METADATA_FIELD_LENGTH) {
        return toast(`${key} is too long (max ${MAX_METADATA_FIELD_LENGTH} characters).`, true);
      }
    }

    let cryptoState;
    try {
      cryptoState = await secrets.getCryptoState(currentProfileId);
    } catch (err) {
      console.error(err);
      return toast(friendlyError(err), true);
    }
    const locked = cryptoState.enabled && !secrets.unlockedFor(currentProfileId);

    const upsert = await supabase
      .from('metadata_configs')
      .upsert({ owner: session.user.id, profile_id: currentProfileId, config });
    if (upsert.error) { console.error(upsert.error); return toast(friendlyError(upsert.error), true); }

    if (!locked) {
      try {
        await secrets.setMetadataSecret(currentProfileId, secret, cryptoState);
      } catch (err) {
        console.error(err);
        return toast(
          err instanceof CloudCryptoError
            ? 'Could not encrypt the API keys — unlock this profile in Security and try again.'
            : friendlyError(err),
          true,
        );
      }
    }
    toast(locked ? 'Saved. API keys left unchanged (profile locked).' : 'Saved');
  };
}

// -------------------------------------------------------------- security

// The passphrase-loss warning shown wherever a passphrase is first set.
const PASSPHRASE_LOSS_WARNING =
  'Choose a passphrase you will remember. It never leaves this browser and the ' +
  'server can never recover it — if you lose this passphrase you will re-enter ' +
  'your credentials.';

async function renderSecurity() {
  view().innerHTML = '<p class="muted">Loading…</p>';
  if (!currentProfileId) {
    return (view().innerHTML =
      '<p class="muted">Create a profile first (Profiles tab).</p>');
  }
  let state;
  try {
    state = await secrets.getCryptoState(currentProfileId);
  } catch (err) {
    console.error(err);
    return (view().innerHTML = `<p class="error">${esc(friendlyError(err))}</p>`);
  }

  if (state.missing) {
    return (view().innerHTML = `
      <h2>Security</h2>
      <p class="muted">End-to-end encryption isn't available on this backend yet.
      Credentials are stored server-side, protected by row-level security and TLS.</p>`);
  }

  const name = esc(profileName(currentProfileId));
  if (!state.enabled) return renderSecurityDisabled(name);
  if (!secrets.unlockedFor(currentProfileId)) return renderSecurityLocked(name);
  return renderSecurityUnlocked(name);
}

function renderSecurityDisabled(name) {
  view().innerHTML = `
    <h2>Security · ${name}</h2>
    <p class="muted hint">This profile's credentials are stored server-side, protected by
    row-level security and TLS. Turn on end-to-end encryption to protect them with a
    passphrase only you know — the server then stores only ciphertext it cannot read.</p>
    <form id="enable" class="form">
      <h3>Enable end-to-end encryption</h3>
      <p class="warn">${esc(PASSPHRASE_LOSS_WARNING)}</p>
      <label>Sync passphrase<input type="password" name="p1" autocomplete="new-password" /></label>
      <label>Confirm passphrase<input type="password" name="p2" autocomplete="new-password" /></label>
      <div class="form-actions"><button class="primary">Enable encryption</button></div>
    </form>`;
  document.getElementById('enable').onsubmit = async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    const p1 = fd.get('p1') ?? '';
    const p2 = fd.get('p2') ?? '';
    const err = validatePassphrasePair(p1, p2);
    if (err) return toast(err, true);
    await runCryptoOp(e.submitter, 'Enabling…', async () => {
      await secrets.enableE2ee(currentProfileId, p1);
      toast('End-to-end encryption enabled and unlocked.');
      render();
    });
  };
}

function renderSecurityLocked(name) {
  view().innerHTML = `
    <h2>Security · ${name}</h2>
    <p class="muted hint">This profile is end-to-end encrypted. Enter its passphrase to
    unlock it for this browser session so you can view and edit credentials. The
    passphrase is never sent to the server.</p>
    <form id="unlock" class="form">
      <label>Sync passphrase<input type="password" name="p" autocomplete="current-password" /></label>
      <div class="form-actions"><button class="primary">Unlock</button></div>
    </form>`;
  document.getElementById('unlock').onsubmit = async (e) => {
    e.preventDefault();
    const p = new FormData(e.target).get('p') ?? '';
    if (!p) return toast('Enter your passphrase.', true);
    await runCryptoOp(e.submitter, 'Unlocking…', async () => {
      try {
        await secrets.unlock(currentProfileId, p);
      } catch (err) {
        if (err instanceof CloudCryptoError) return toast('Incorrect passphrase.', true);
        throw err;
      }
      toast('Unlocked for this session.');
      render();
    });
  };
}

function renderSecurityUnlocked(name) {
  view().innerHTML = `
    <h2>Security · ${name}</h2>
    <p class="muted hint">End-to-end encryption is <strong>on</strong> and unlocked for this
    session. Credentials are encrypted with your passphrase before they reach the server, which
    stores only ciphertext it cannot read. This session locks automatically after 15 minutes idle.</p>
    <div class="form-actions">
      <button id="lock" class="ghost">Lock now</button>
    </div>

    <form id="rotpass" class="form section">
      <h3>Change passphrase</h3>
      <p class="warn">${esc(PASSPHRASE_LOSS_WARNING)}</p>
      <label>New passphrase<input type="password" name="p1" autocomplete="new-password" /></label>
      <label>Confirm new passphrase<input type="password" name="p2" autocomplete="new-password" /></label>
      <div class="form-actions"><button class="primary">Change passphrase</button></div>
    </form>

    <form id="rotck" class="form section">
      <h3>Rotate content key</h3>
      <p class="muted">Mint a fresh content key and re-encrypt every credential under it. Use this
      after a device is revoked or a passphrase may have leaked — old ciphertext and old device keys
      stop working. Re-enter your current passphrase to re-wrap the new key.</p>
      <label>Current passphrase<input type="password" name="p" autocomplete="current-password" /></label>
      <div class="form-actions"><button class="primary">Rotate content key</button></div>
    </form>

    <div class="danger-zone section">
      <h3>Turn off end-to-end encryption</h3>
      <p>Credentials return to server-side storage protected only by row-level security and TLS —
      the operator can technically read them again. This rewrites every secret back to plaintext.</p>
      <button id="disable" class="danger-solid">Disable encryption</button>
    </div>`;

  document.getElementById('lock').onclick = () => {
    secrets.lock();
    toast('Locked.');
  };

  document.getElementById('rotpass').onsubmit = async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    const err = validatePassphrasePair(fd.get('p1') ?? '', fd.get('p2') ?? '');
    if (err) return toast(err, true);
    await runCryptoOp(e.submitter, 'Changing…', async () => {
      await secrets.rotatePassphrase(currentProfileId, fd.get('p1'));
      toast('Passphrase changed.');
      render();
    });
  };

  document.getElementById('rotck').onsubmit = async (e) => {
    e.preventDefault();
    const p = new FormData(e.target).get('p') ?? '';
    if (!p) return toast('Enter your current passphrase.', true);
    await runCryptoOp(e.submitter, 'Rotating…', async () => {
      await secrets.rotateContentKey(currentProfileId, p);
      toast('Content key rotated. Reprovision any devices that need it (Devices tab).');
      render();
    });
  };

  document.getElementById('disable').onclick = async () => {
    if (!confirm('Turn off end-to-end encryption? Credentials return to server-side storage the operator can read.')) return;
    await runCryptoOp(document.getElementById('disable'), 'Disabling…', async () => {
      await secrets.disableE2ee(currentProfileId);
      toast('End-to-end encryption disabled.');
      render();
    });
  };
}

function validatePassphrasePair(p1, p2) {
  if (p1.length < MIN_PASSPHRASE_LENGTH) {
    return `Passphrase must be at least ${MIN_PASSPHRASE_LENGTH} characters.`;
  }
  if (p1 !== p2) return 'Passphrases do not match.';
  return null;
}

// Run a crypto/RPC op with a busy button and safe error surfacing. `btn` may be
// undefined (some browsers omit submitter); the op still runs.
async function runCryptoOp(btn, busyLabel, op) {
  const label = btn?.textContent;
  if (btn) { btn.disabled = true; btn.textContent = busyLabel; }
  try {
    await op();
  } catch (err) {
    console.error(err);
    toast(friendlyError(err), true);
  } finally {
    if (btn) { btn.disabled = false; if (label != null) btn.textContent = label; }
  }
}

// -------------------------------------------------------------- devices

async function renderDevices() {
  view().innerHTML = '<p class="muted">Loading…</p>';
  const { data, error } = await supabase
    .from('devices')
    .select('*')
    .order('created_at');
  if (error) { console.error(error); return (view().innerHTML = `<p class="error">${esc(friendlyError(error))}</p>`); }

  // Crypto context for the CURRENTLY SELECTED profile — provisioning wraps that
  // profile's content key to a device's public key.
  let cryptoCtx = { enabled: false };
  if (currentProfileId) {
    try {
      cryptoCtx = await secrets.deviceCryptoContext(currentProfileId);
    } catch (e) {
      console.error(e);
    }
  }
  const unlocked = cryptoCtx.enabled && !!secrets.unlockedFor(currentProfileId);
  // Authoritative per-device provisioning state (list_device_ck). `missing` on a
  // pre-migration backend → fall back to the public_key heuristic in deviceRow.
  let provisioning = { missing: true, byDevice: {} };
  if (cryptoCtx.enabled && currentProfileId) {
    try {
      provisioning = await secrets.listDeviceProvisioning(currentProfileId);
    } catch (e) {
      console.error(e);
    }
  }

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
    ${cryptoCtx.enabled
      ? `<p class="muted hint">Profile <strong>${esc(profileName(currentProfileId))}</strong> is end-to-end encrypted.
         A device must hold this profile's content key before it can read credentials.
         ${unlocked ? 'Provision a device to send it the key.' : 'Unlock this profile in <strong>Security</strong> to provision devices.'}</p>`
      : ''}
    <div class="rows">
      ${data.length ? data.map((d) => deviceRow(d, cryptoCtx, unlocked, provisioning)).join('') : '<p class="muted">None yet.</p>'}
    </div>`;

  document.getElementById('claim').onsubmit = async (e) => {
    e.preventDefault();
    const code = new FormData(e.target).get('code').trim().toUpperCase();
    const { error } = await supabase.rpc('claim_pairing', { p_code: code });
    if (error) { console.error(error); return toast(friendlyError(error), true); }
    toast('Device paired');
    renderDevices();
  };
  for (const el of view().querySelectorAll('[data-revoke]'))
    el.onclick = () => revokeDevice(el.dataset.revoke);
  for (const el of view().querySelectorAll('[data-rename]'))
    el.onclick = () => renameDevice(el.dataset.rename, data);
  for (const el of view().querySelectorAll('[data-provision]'))
    el.onclick = () => provisionDevice(el.dataset.provision, data);
}

function deviceRow(d, cryptoCtx = { enabled: false }, unlocked = false, provisioning = { missing: true, byDevice: {} }) {
  const profile = d.active_profile_id ? profileName(d.active_profile_id) : '—';
  // Provisioning UI only when the selected profile is E2EE-on. Prefer the
  // authoritative list_device_ck entry; fall back to a public_key heuristic on
  // a pre-migration backend (missing accessor).
  let provisionNote = '';
  let provisionBtn = '';
  if (cryptoCtx.enabled) {
    const entry = provisioning.byDevice[d.device_uid];
    const state =
      !provisioning.missing && entry
        ? deviceProvisionState(entry)
        : d.public_key
          ? 'needs-key'
          : 'no-key';
    const canSend = unlocked && deviceNeedsKey(state);
    if (canSend) {
      provisionBtn = `<button data-provision="${d.device_uid}" class="ghost">Send key</button>`;
    }
    const note = {
      'no-key': 'encryption: waiting for this device to come online',
      'needs-key': unlocked ? '' : 'encryption: unlock to send key',
      'stale': unlocked ? 'encryption: old key — resend' : 'encryption: unlock to update key',
      'provisioned': 'encryption: key provisioned',
    }[state];
    if (note) provisionNote = `<div class="muted">${note}</div>`;
  }
  return `
    <div class="row">
      <div>
        <div class="title">${esc(d.label || 'Device')}</div>
        <div class="muted">paired ${esc((d.created_at || '').slice(0, 10))} · syncing ${esc(profile)}</div>
        ${provisionNote}
      </div>
      <div class="actions">
        ${provisionBtn}
        <button data-rename="${d.device_uid}" class="ghost">Rename</button>
        <button data-revoke="${d.device_uid}" class="ghost danger">Revoke</button>
      </div>
    </div>`;
}

async function provisionDevice(deviceUid, data) {
  const d = data.find((x) => x.device_uid === deviceUid);
  if (!d?.public_key) return toast('This device has no encryption key yet.', true);
  try {
    await secrets.provisionDevice(currentProfileId, deviceUid, d.public_key);
    toast('Content key sent to the device.');
  } catch (err) {
    console.error(err);
    toast(
      err instanceof CloudCryptoError
        ? 'Unlock this profile in Security before provisioning.'
        : friendlyError(err),
      true,
    );
  }
}

async function renameDevice(id, data) {
  const cur = data.find((d) => d.device_uid === id);
  const label = prompt('Device name', cur?.label ?? '');
  if (label === null) return;
  const { error } = await supabase
    .from('devices')
    .update({ label: label.trim() })
    .eq('device_uid', id);
  if (error) { console.error(error); return toast(friendlyError(error), true); }
  renderDevices();
}

async function revokeDevice(id) {
  if (!confirm('Revoke this device? It will stop syncing.')) return;
  const { error } = await supabase.from('devices').delete().eq('device_uid', id);
  if (error) { console.error(error); return toast(friendlyError(error), true); }
  renderDevices();
}

// --------------------------------------------------------------- account

function renderAccount() {
  view().innerHTML = `
    <section class="account-section">
      <h2>Account</h2>
      <p class="muted">Signed in as ${esc(session.user.email || 'this account')}.</p>
      <p>
        <a href="${import.meta.env.BASE_URL}privacy.html">Privacy policy</a>
        <span aria-hidden="true"> · </span>
        <a href="${import.meta.env.BASE_URL}support.html">Support</a>
      </p>
      <div class="danger-zone">
        <h3>Delete cloud account</h3>
        <p>
          Permanently deletes this account, its profiles, source configurations,
          metadata settings, favorites, and device pairings. Local data already
          stored on a device is not deleted.
        </p>
        <button id="delete-account" class="danger-solid">Delete cloud account</button>
      </div>
    </section>`;
  document.getElementById('delete-account').onclick = deleteAccount;
}

async function deleteAccount() {
  const confirmation = prompt(
    'This cannot be undone. Type DELETE to permanently delete your cloud account.',
    '',
  );
  if (confirmation !== 'DELETE') {
    if (confirmation !== null) toast('Account deletion cancelled.', true);
    return;
  }

  const button = document.getElementById('delete-account');
  button.disabled = true;
  button.textContent = 'Deleting…';
  const { error } = await supabase.rpc('delete_account');
  if (error) {
    console.error(error);
    button.disabled = false;
    button.textContent = 'Delete cloud account';
    return toast(friendlyError(error), true);
  }

  localStorage.removeItem('iptvs_profile');
  currentProfileId = null;
  profiles = null;
  await supabase.auth.signOut({ scope: 'local' });
  session = null;
  renderLogin();
  toast('Cloud account deleted.');
}
