import { createClient } from '@supabase/supabase-js';

// The anon/publishable key is safe in client code: access is gated by the
// row-level security in supabase/migrations. Never put the service_role key here.
const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !key) {
  document.getElementById('app').innerHTML =
    '<p style="padding:2rem">Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (see panel/.env.example).</p>';
  throw new Error('Missing Supabase config');
}

export const supabase = createClient(url, key);

// Field shapes mirror lib/sources/source_config.dart so the panel and app agree.
export const KIND_FIELDS = {
  stalker: [
    { key: 'portal', label: 'Portal URL', required: true },
    { key: 'mac', label: 'MAC address', required: true },
  ],
  xtream: [
    { key: 'host', label: 'Host', required: true },
    { key: 'username', label: 'Username', required: true },
    { key: 'password', label: 'Password', required: true, password: true },
  ],
  m3u: [
    { key: 'playlistUrl', label: 'Playlist URL', required: true },
    { key: 'epgUrl', label: 'EPG URL (optional)', required: false },
    { key: 'userAgent', label: 'User-Agent (optional)', required: false },
  ],
  demo: [],
};
