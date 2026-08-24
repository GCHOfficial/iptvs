// Profile PINs — the panel half of `lib/data/profile_pin.dart`.
//
// The format is a contract shared by three implementations: this one, the app's
// (which is what actually *checks* a PIN), and Postgres, which validates only
// the shape (`profiles_validate`). A verifier written here must be readable by
// an app build that has never seen this panel, so the parameters below are
// fixed, not negotiated: any change is a new algorithm label and a migration,
// never a quietly different iteration count.
//
// The PIN is a gate on a shared television, not a secret. Four digits is ten
// thousand values, so whoever holds the verifier can recover the PIN regardless
// of the KDF cost — which is why `profiles.pin` is a broad column and why the
// iteration count is chosen for the slowest device that must verify one (a
// set-top box), not for an attacker.

export const PIN_LENGTH = 4;
export const PIN_ALGORITHM = 'pbkdf2-sha256';
export const PIN_ITERATIONS = 10000;
const SALT_BYTES = 16;
const HASH_BYTES = 32;

/** Exactly four ASCII digits. */
export function isValidPin(pin) {
  return typeof pin === 'string' && /^[0-9]{4}$/.test(pin);
}

/** The shape Postgres and the app both expect. */
export function isPinVerifier(value) {
  return (
    typeof value === 'string' &&
    // Six digits, not seven: the app's parser rejects anything above 1,000,000
    // iterations, and a verifier this side calls valid but the device cannot
    // read is a profile nobody can open.
    /^pbkdf2-sha256\$[0-9]{1,6}\$[A-Za-z0-9+/]{8,88}={0,2}\$[A-Za-z0-9+/]{43}=$/.test(
      value,
    )
  );
}

function toBase64(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

/**
 * Derive a storable verifier for `pin`.
 *
 * `salt` is injectable so the tests can pin a known vector; callers pass only
 * the PIN and get a fresh random salt.
 */
export async function hashPin(pin, salt = null, iterations = PIN_ITERATIONS) {
  if (!isValidPin(pin)) throw new Error(`pin must be ${PIN_LENGTH} digits`);
  const saltBytes =
    salt ?? crypto.getRandomValues(new Uint8Array(SALT_BYTES));
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(pin),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: saltBytes, iterations },
    key,
    HASH_BYTES * 8,
  );
  return `${PIN_ALGORITHM}$${iterations}$${toBase64(saltBytes)}$${toBase64(
    new Uint8Array(bits),
  )}`;
}
