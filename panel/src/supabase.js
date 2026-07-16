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

// Field shapes mirror lib/sources/source_config.dart so the panel and app
// agree. The canonical definition (plus validation limits) lives in
// validate.js — a dependency-free module so it's testable without
// supabase-js — and is re-exported here for callers importing from this file.
export { KIND_FIELDS } from './validate.js';
