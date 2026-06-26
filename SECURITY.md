# Security Policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub's
[private vulnerability reporting](https://github.com/GCHOfficial/iptvs/security/advisories/new)
("Report a vulnerability" under the repo's **Security** tab). Do **not** open a
public issue for security problems.

Please include a description, reproduction steps, and impact. We'll acknowledge the
report and keep you updated on the fix.

## Scope & handling of secrets

iptvs has no backend — it talks directly to user-supplied provider panels and public
metadata APIs. Provider URLs, MAC addresses, and tokens are **credentials**, and the
app is built to keep them out of logs, on-screen errors, and exported diagnostics
(see the redaction helpers in `lib/data/net.dart` and the Stalker source).

When reporting, **do not include real credentials** — redact provider URLs and
tokens in any logs you attach.

## Supported versions

This is a single actively-developed application; fixes land on `main` and ship in
the next release. There is no long-term support for older releases.
