// Sync-passphrase generation and strength policy.
//
// Why this exists: the wrapped content key, its salt and its iteration count all
// live in one `profile_crypto` row. The stated threat model includes a Supabase
// operator reading that table, so an attacker gets an *offline* attack with no
// rate limit and no lockout — the passphrase's own entropy is the entire margin.
//
// PBKDF2 at 600k iterations costs roughly 1.8e4 guesses/sec on one consumer GPU.
// A median human-chosen 8-character password carries ~22 bits of real entropy,
// which falls in minutes. Raising the KDF cost does not fix this: Argon2id at
// 64 MiB buys about 4 bits, 1 GiB about 8-9, against a ~28-bit shortfall. The
// deficit has to be closed with entropy, not cost — hence a generator.
//
// The passphrase is typed only at panel unlock, never on a TV remote, so a long
// generated phrase costs the user nothing at the point of use.

import { WORDS } from './wordlist.js';

// 1024 words = exactly 10 bits per word. `assertWordlistSane` enforces the
// power-of-two count, because a list of any other size would make the masking
// below non-uniform and silently overstate the entropy.
const BITS_PER_WORD = Math.log2(WORDS.length);

export const GENERATED_WORD_COUNT = 6;
export const GENERATED_BITS = Math.round(GENERATED_WORD_COUNT * BITS_PER_WORD);

// Floor for a hand-typed passphrase. Not a claim that 16 characters is as good
// as a generated phrase — it is the point below which we refuse outright.
export const MIN_PASSPHRASE_LENGTH = 16;

export const SEPARATOR = '-';

// Throws if the wordlist could not deliver uniform selection. Called at module
// load so a bad list fails immediately and loudly rather than quietly halving
// the entropy of every passphrase generated afterwards.
function assertWordlistSane() {
  if (!Number.isInteger(BITS_PER_WORD)) {
    throw new Error(
      `wordlist length ${WORDS.length} is not a power of two — masked selection ` +
        'would be biased',
    );
  }
  if (WORDS.length < 256) {
    throw new Error(`wordlist is too small (${WORDS.length})`);
  }
}
assertWordlistSane();

// Uniform index in [0, WORDS.length). WORDS.length is a power of two and
// divides 2**16 exactly, so masking a 16-bit CSPRNG value is unbiased and needs
// no rejection loop.
function randomIndex() {
  const buf = new Uint16Array(1);
  globalThis.crypto.getRandomValues(buf);
  return buf[0] & (WORDS.length - 1);
}

// A fresh diceware-style passphrase, e.g. "bramble-outfox-yearly-cavalier-dusk-plate".
export function generatePassphrase(wordCount = GENERATED_WORD_COUNT) {
  const out = [];
  for (let i = 0; i < wordCount; i++) out.push(WORDS[randomIndex()]);
  return out.join(SEPARATOR);
}

// A deliberately coarse strength read for hand-typed input. It is NOT an
// entropy estimate — human passwords do not have one that a few lines of code
// can compute honestly. It drives a meter and nothing security-critical; the
// hard gate is `validatePassphrase` below.
//
// Returns { score: 0..4, label }.
export function passphraseStrength(p) {
  const s = p ?? '';
  if (!s) return { score: 0, label: 'empty' };

  // Treat a multi-word phrase on its own terms — length matters far more than
  // character classes once someone is stringing words together.
  const words = s.split(/[\s\-_.]+/).filter(Boolean);
  if (words.length >= 5 && s.length >= 20) return { score: 4, label: 'strong' };
  if (words.length >= 4 && s.length >= 16) return { score: 3, label: 'good' };

  let classes = 0;
  if (/[a-z]/.test(s)) classes++;
  if (/[A-Z]/.test(s)) classes++;
  if (/[0-9]/.test(s)) classes++;
  if (/[^A-Za-z0-9]/.test(s)) classes++;

  if (s.length >= 24) return { score: 3, label: 'good' };
  if (s.length >= MIN_PASSPHRASE_LENGTH && classes >= 2) return { score: 2, label: 'fair' };
  if (s.length >= MIN_PASSPHRASE_LENGTH) return { score: 1, label: 'weak' };
  return { score: 0, label: 'too short' };
}

// The hard gate. Returns an error string, or null when acceptable.
export function validatePassphrase(p1, p2) {
  const a = p1 ?? '';
  const b = p2 ?? '';
  if (a.length < MIN_PASSPHRASE_LENGTH) {
    return `Passphrase must be at least ${MIN_PASSPHRASE_LENGTH} characters — or use Generate.`;
  }
  if (a !== b) return 'Passphrases do not match.';
  return null;
}
