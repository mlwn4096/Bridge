# Security

Bridge handles pairing credentials, files, clipboard text and notification content.
Version 1.0 is an early release candidate; fixes target the current source branch.
No independent security audit has been completed.

## Report a vulnerability privately

Use GitHub's **Security → Report a vulnerability** when available:
https://github.com/mlwn4096/Bridge/security/advisories/new

If private reporting is unavailable, contact the maintainer through the public
contact route on https://mlwn.in and ask for a private reporting channel. Do not
post exploit details, pairing credentials or personal data in a public issue.

Include affected versions/platforms, reproduction steps, impact, and a minimal
redacted example. Never send signing keys, clipboard contents, private files or
unredacted notification logs. There is no guaranteed response deadline; please
allow the maintainer time to investigate before public disclosure.

## Security boundaries

Pairing requires explicit Mac approval and certificate pinning. Never disable TLS
validation to fix connectivity. Notification/clipboard sharing and automation are
permission-dependent; review settings before enabling them. Keep release signing
keys outside Git, and rotate exposed secrets rather than merely deleting files.
