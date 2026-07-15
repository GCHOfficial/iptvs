# Source and content identities

Persisted identities must remain stable when a provider credential, endpoint,
or display label changes, and must not expose secrets in SQLite or cloud keys.

## Source namespace

`SourceConfig.id` is the sole source namespace used by repositories, SQLite,
favorites, playback positions, metadata, EPG, and cloud records. New configs use
a random UUID that round-trips through the cloud `sources.id` column. Provider
implementations receive that ID when built; they never derive `Source.id` from a
URL, username, password, or MAC address.

On first startup after this change, all configured sources are migrated in an
SQLite transaction from their legacy derived namespace to `SourceConfig.id`.
The active-source path repeats the idempotent migration so restored local/cloud
profiles are covered too. Any destination-key collision rolls the whole source
namespace migration back rather than partially moving favorites or caches.

## Content identities

Xtream and Stalker retain provider-issued stream/media IDs. Those IDs are opaque,
provider-owned, and used consistently for channels, EPG, favorites, positions,
metadata, and cloud favorites.

M3U has no provider-issued channel ID, so it uses:

`m3u-channel:<SHA-256(normalized locator)>`

Normalization performs only transformations that do not change an HTTP request:

- trim surrounding whitespace;
- lowercase scheme and host;
- remove default HTTP/HTTPS ports;
- resolve path dot-segments;
- discard fragments.

User-info, path casing, and query text/order remain significant because provider
servers may distinguish them. Equal normalized locators intentionally share one
identity. Distinct locators use the full SHA-256 digest; a theoretical digest
collision is treated as the same identity without falling back to a raw locator.

Legacy M3U URL keys are atomically rewritten across channel cache, EPG references,
and live favorites. Existing cloud M3U favorites are normalized on pull; future
pushes therefore contain only the opaque ID.
