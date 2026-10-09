# Contributing

Bridge welcomes focused fixes, documentation and tests. Before larger changes,
open an issue explaining the user problem and proposed scope. See
[the build guide](docs/BUILDING.md) and [architecture](docs/ARCHITECTURE.md).

Use a feature branch and submit a pull request describing the behavior before and
after, tests run and any device checks still pending. Keep changes focused. Run
Mac and Android tests for the parts changed; protocol changes need both peers.
Use the release acceptance checklist for permission, reconnect and transfer changes.
Never include signing keys, pairing credentials, clipboard contents, private files
or identifying notification logs. Supply minimal, redacted reproduction steps.

Do not reintroduce screen mirroring or accessibility-control experiments as an
incidental change. Keep generated installers out of source commits.

Only contribute code/assets you have the right to license. Preserve third-party
notices. Contributions are submitted under the [MIT License](LICENSE), unless explicitly
agreed otherwise. Be respectful, provide reproducible reports, and avoid personal
attacks. Security reports should follow [SECURITY.md](SECURITY.md).
