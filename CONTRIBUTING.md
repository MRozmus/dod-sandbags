# Contributing

Bug reports, translations and focused improvements are welcome. Open an issue to
coordinate larger changes. Describe the behavior changed and the environments
used to verify it in your pull request.

## Source layout

- `plugins/dod_sandbag.sma`: AMXX Pawn plugin.
- `configs/dod_sandbag.cfg`: example server configuration.
- `configs/lang/dod_sandbag.txt`: AMXX language dictionary.
- `scripts/generate-sandbag-model.py`: model-generation tool.
- `scripts/package-sandbag.py`: source-archive builder.
- `tests/test_sandbag_release.py`: config, dictionary and packaging checks.

## Development checks

Run the standard-library checks from the repository root:

```sh
python3 tests/test_sandbag_release.py
```

Compile the Pawn source without warnings using AMXX base plus the DoD addon
includes. Follow the compilation command in [README.md](README.md).
The plugin also provides `dod_sandbag_selftest` in the server console. It creates
temporary entities and runs collision, placement, configuration and damage checks.
Use an empty development server; the command refuses connected players.

Engine checks complement in-game testing. For gameplay changes, check downloads,
preview/release placement, rotation, rows, stacking, movement and weapon damage
with a real client. For ownership/config changes, also check multiple players,
permissions, quotas, cooldown, reconnects, expiration and disconnect cleanup.

## Translations

Add an AMXX language section to `configs/lang/dod_sandbag.txt`. Keep all `SB_`
keys, preserve format placeholders and keep messages within chat/console limits.
Verify the translation using the corresponding client language setting.

## Source archives and versioning

```sh
python3 scripts/package-sandbag.py
```

The source ZIP and SHA-256 checksum are written to `build/releases/`. The archive
contains an explicit list of installable source files and documentation, plus a
manifest of file hashes. It excludes compiled plugins, models, logs and local
configuration. The example config is named `.cfg.example` in the archive so
extracting an update does not overwrite server-owner settings.

Keep the version consistent in the Pawn source, README, example-config header
and changelog. Version 2.5.0 is the initial release in this repository.
Keep existing model filenames when geometry is unchanged. When geometry changes,
use a new filename consistently in the plugin, generator and installation docs,
so clients download the matching asset instead of using a cached model.

## License

Contributions must be compatible with GPL-3.0-or-later. Do not commit game assets,
generated models, vendor includes, credentials or private server configuration.
See [LICENSE.md](LICENSE.md) for the separate terms governing game assets.
