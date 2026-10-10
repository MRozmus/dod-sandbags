# DoD Sandbags 2.5.0

A player-controlled sandbag building plugin for **GoldSrc Day of Defeat 1.3**.
Hold a bound key to preview, release to place, and rotate in 90-degree steps.
Bags are elongated (64 x 32 x 16), solid to players and bullet traces, stackable,
and destructible. Side/near-ground snapping builds straight rows. Players must
opt in with `dod_sandbag`; installation never changes their binds or client cvars.

## Gameplay demo

[Watch the gameplay demo (MP4, 30 seconds)](https://github.com/MRozmus/dod-sandbags/blob/main/docs/media/demo.mp4)

See placement previews, stacking, straight rows and destructible cover in-game.

## Features

- Translucent placement preview with 90-degree rotation.
- Ground placement, stacking and snapping for straight rows.
- Destructible cover with configurable health and weapon damage.
- Global and per-player limits, placement cooldown and access controls.
- Optional expiration and cleanup when the owner disconnects.
- English messages with support for AMXX translations.

## Requirements and compatibility

- Original Steam Day of Defeat 1.3 (`dod`).
- Metamod and AMX Mod X **1.9.0 or newer**, including the **DoD addon**.
- Engine, Ham Sandwich, DoDX and Fakemeta modules.
- Python 3.8+ to generate the model during installation. Python is not needed
  by the running game server.

Tested with Linux 32-bit HLDS build 10211, Metamod 1.21.1-am and AMXX
1.9.0.5303, using a Windows game client. Windows servers, ReHLDS and other AMXX
builds have not been verified. This plugin does not support DoD: Source or
SourceMod.

## Installation

### 1. Get the source package

Download or clone this repository. From its root directory, run:

```sh
python3 scripts/package-sandbag.py
```

Extract `build/releases/dod_sandbag-2.5.0-source.zip` into your server's `dod`
folder. The archive uses the installation paths expected by AMXX. It contains
source files, an example config, language messages and the model generator;
it does not include a compiled `.amxx` or game models.

The following commands run from the server's `dod` folder unless noted otherwise.
On Windows, use `py -3` in place of `python3`.

### 2. Generate the model

Create `models/dod_modding`, then run:

```sh
python3 tools/generate-sandbag-model.py models/mapmodels/sandbag_gib.mdl models/dod_modding/sandbag_v6.mdl
```

Use the stock model from your own installed Day of Defeat game. Generation may
also run on a workstation; copy the result to the same relative path on the
server. The stock model is left unchanged. See [License and assets](LICENSE.md).

### 3. Compile the plugin

Install AMXX base and its DoD addon first. From `addons/amxmodx/scripting`, compile
with the AMXX 1.9.0+ compiler and installed base/DoD includes:

```sh
./amxxpc dod_sandbag.sma -iinclude -o../plugins/dod_sandbag.amxx
```

On Windows, use AMXX's bundled compiler or compile script. The resulting file
must be installed at `addons/amxmodx/plugins/dod_sandbag.amxx`.

### 4. Configure and enable

The source package installs messages at `addons/amxmodx/data/lang/dod_sandbag.txt`.
For a new installation, copy
`addons/amxmodx/configs/plugins/dod_sandbag.cfg.example` to
`addons/amxmodx/configs/plugins/dod_sandbag.cfg`. Alternatively, AMXX creates the
config automatically when the plugin loads. Keep your existing config when
updating.

Add this line once to `addons/amxmodx/configs/plugins.ini`:

```text
dod_sandbag.amxx
```

Restart the server or change map. Check `amxx plugins` for a running
`DoD Sandbags` entry and run `dod_sandbag_status` in the server console.
A missing model or language file stops the plugin with an explicit error.

### 5. Enable client downloads

Allow model downloads with `sv_allowdownload 1`. Players must also allow server
asset downloads in their client settings. If using HTTP/FastDL, upload the model
at exactly `models/dod_modding/sandbag_v6.mdl` on the download host.

## Quick start

In the game console:

```text
dod_sandbag
bind mouse3 +dod_sandbag
bind v dod_sandbag_rotate
```

Aim at level ground, hold the middle mouse button to preview a bag, and release
to place it. Press **V** while previewing to rotate. Aim at a bag's top to stack
another bag, or its side to extend a row. You can choose different keys.
Run `dod_sandbag` again to turn your building ability off.

## Player commands

```text
dod_sandbag                 // toggle your building ability
bind mouse3 +dod_sandbag    // hold preview, release to place
bind v dod_sandbag_rotate   // rotate the active preview by 90 degrees
dod_sandbag_remove          // remove your aimed bag within reach
dod_sandbag_help            // print help in your console
```

The player must be alive to place/remove bags. Preview initially follows the
view's quarter-turn yaw; directly aiming at an existing bag adopts its yaw until
you manually rotate. Placement requires a level surface, support at the center
and four inset corners, and clearance from walls, other bags and alive players.
Unsupported crosswise stacks are rejected. Preview uses the same transform as
the final bag. The translucent preview is visible to other clients.

## Server configuration

All variables are prefixed `dod_sandbag_`. Numeric values are bounded by AMXX.
The config is loaded once per map via `AutoExecConfig`; standard AMXX per-map
configs may override it. Live server-console changes apply immediately except
where noted. To persist them, edit the config. For a live reload, run
`exec addons/amxmodx/configs/plugins/dod_sandbag.cfg` in the server console.
Do not assume changes to the file are hot-reloaded automatically.

| Cvar | Default | Range / behavior |
| --- | --- | --- |
| `dod_sandbag_enabled` | `1` | 0/1. Disabling cancels previews; existing bags remain. |
| `dod_sandbag_max_bags` | `64` | 1-128 total bags. Never exceeds hard cap 128. |
| `dod_sandbag_max_per_player` | `16` | 0-128; 0 removes the personal quota, not global safety limits. |
| `dod_sandbag_cooldown` | `0.5` | 0.1-10 seconds between successful placements. |
| `dod_sandbag_reach` | `256` | 64-512 game units. |
| `dod_sandbag_health` | `400` | 1-10000 HP for newly created bags. |
| `dod_sandbag_pistol_damage` | `40` | 0-1000; 0 uses stock game damage. |
| `dod_sandbag_lifetime` | `0` | 0-3600 seconds; 0 means no timed expiry. New bags only. |
| `dod_sandbag_remove_on_disconnect` | `1` | 0/1. Clean up the departing session's bags. |
| `dod_sandbag_access_flags` | `""` | All listed AMXX flags required; empty allows everyone. `h` = ADMIN_CFG. Invalid strings deny building. |
| `dod_sandbag_entity_reserve` | `64` | 32-256 free engine entities reserved for map/other plugins. |
| `dod_sandbag_preview_alpha` | `125` | 20-200 opacity. Preview updates capped at 20 Hz. |

`dod_sandbag_version` is server-visible release metadata, not a gameplay setting.
With defaults, ten Colt/Luger/Webley hits destroy a fresh bag. Other weapons and
explosions keep their damage. Reduced limits stop further placement, without
silently deleting existing bags. Raising the limit cannot bypass the engine
entity reserve. Start with conservative quotas on busy maps and measure capacity.
Ownership uses the connection's user ID rather than a recycled player slot;
there is no persistent SteamID database. If disconnect cleanup is disabled,
reconnecting gives a new personal quota while old bags still count globally.

## Administration

- `dod_sandbag_clear`: remove all sandbags and placement previews. Server console or AMXX
  **ADMIN_CFG (`h`)**, subject to normal AMXX command access configuration.
  Never removes unrelated map entities.
- `dod_sandbag_status`: server-console diagnostic with version, quotas and engine
  entity usage. No credentials or player identifiers are printed.
- `dod_sandbag_selftest`: temporary live-engine fixtures, automatic cleanup;
  run **only on an empty development server**. The plugin refuses it when any
  player is connected. Server-only; clients cannot invoke it.

English is the baseline language. Other translations can add normal AMXX language
sections to `data/lang/dod_sandbag.txt`; no recompilation is required. Keep message
keys intact and avoid oversized chat text. No forced key binds/client commands.

## Updates and removal

Back up this plugin's binary, config, language file and model before updating.
Preserve administrator-edited settings and custom language sections. Add new
cvars using the updated example. Do not replace global `plugins.ini` or `modules.ini` wholesale.
Restart/change map after installing a matching source/binary pair. A geometry
change must ship a new model filename, also updated on FastDL.

To uninstall, comment/remove only `dod_sandbag.amxx` from `plugins.ini`, then
restart/change map. Afterwards remove its binary, dictionary, config and owned
model if no other plugin needs them. No database/global configuration entries are
created. Model downloads cached by clients need not be deleted for uninstall.

## Known limitations

- The model has an open/untextured underside, visible when viewed from below.
- Bags are static. Destroying/removing/expiring a supporting bag does not simulate
  falling or recursively collapse bags above it. Support is checked at placement.
- All weapons may damage bags; no teammate damage protection is implemented.
- Bags can obstruct routes/objectives. Quotas, lifetime/access controls and admin
  clear are provided; map-specific no-build zones are not implemented.

## Support and contributions

Report problems through [GitHub Issues](https://github.com/MRozmus/dod-sandbags/issues).
Include the plugin and server versions, map, reproduction steps and relevant
sandbag settings. Attach only sanitized error excerpts; do not share passwords,
private server details or unfiltered logs.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks and translation
contributions, [CHANGELOG.md](CHANGELOG.md) for releases, and
[LICENSE.md](LICENSE.md) for the code license and asset terms.
