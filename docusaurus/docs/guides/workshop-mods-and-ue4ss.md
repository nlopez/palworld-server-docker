---
sidebar_position: 3
---

# Workshop Mods and UE4SS Setup

This guide provides a safe and repeatable workflow for running Workshop mods and UE4SS on the Windows server path.

## Scope and prerequisites

This mod flow is intended for Wine-based Windows server mode.

Required settings:

* `SERVER_PLATFORM=Windows`
* A persistent game data volume mounted to `/palworld`
* A persistent Steam session volume mounted to `/home/steam/Steam` when account authentication is required

By default, Windows mode uses `WINEPREFIX=/palworld/.wine`, so winetricks-installed runtime dependencies persist with the `/palworld` volume.

## About `-nosteam` / `NOSTEAM`

This image can add `-nosteam` by setting `NOSTEAM=true`.

Current official Palworld server docs list startup arguments such as `-port`, `-players`, `-publiclobby`, and `-logformat`, but do not explicitly document `-nosteam`.

Because of that, treat `NOSTEAM` as an operational compatibility option and validate behavior in your own environment when you enable it.

## Recommended base example

Start from the included example:

* [examples/mods/compose.yaml](https://github.com/thijsvanloef/palworld-server-docker/blob/main/examples/mods/compose.yaml)

The example includes all mod-related environment variables and mount points.

## Choose mod source(s)

You can combine these methods:

1. Workshop IDs via environment variable
2. Workshop IDs via `workshop-mods.txt`
3. NativeMods folders under `/palworld/Mods/NativeMods`

### Method A: Workshop IDs in environment variable

Set a comma-separated list:

```yaml
environment:
  WORKSHOP_MOD_IDS: "3625280368,3625287786"
```

### Method B: Workshop IDs in file

Create `/palworld/workshop-mods.txt` and place one ID per line.

Example:

```text
3625280368
3625287786
```

If you manage IDs in file, leave `WORKSHOP_MOD_IDS` empty.

### Method C: NativeMods folders

Place extracted native mod folders under:

```text
/palworld/Mods/NativeMods/<mod_name>/...
```

At startup and periodic sync, mod files are deployed to the active runtime path.

## Enable UE4SS helper (optional)

To auto-download and deploy the experimental UE4SS package:

```yaml
environment:
  INSTALL_UE4SS_EXPERIMENTAL: true
  UE4SS_EXPERIMENTAL_URL: "https://github.com/Okaetsu/RE-UE4SS/releases/download/experimental-palworld/UE4SS-Palworld.zip"
  UE4SS_MODS_LAYOUT: ue4ss_dir
  UE4SS_CLEANUP_LEGACY: true
```

`UE4SS_MODS_LAYOUT` values:

* `legacy`: deploy to `Pal/Binaries/Win64/Mods`
* `ue4ss_dir`: deploy to `Pal/Binaries/Win64/ue4ss/Mods`

## Secure Workshop authentication (no password env)

For paid/private Workshop items, do not put Steam password in compose or dotenv.

Use this flow:

1. Set `STEAM_USERNAME` and `STEAM_SESSION_VOLUME` in `examples/mods/.env`
2. Run one-time login helper from `examples/mods`
3. Start the server with the same Steam session volume mounted at `/home/steam/Steam`

Example:

```bash
cd examples/mods
./steam-login.sh
docker compose up -d  # --build ... if you need.
```

The helper stores account metadata in `.steam-login-user` under the Steam session volume.
This file is managed automatically by the helper script and usually does not require manual edits.

## Automatic update checks

Configure periodic Workshop sync:

```yaml
environment:
  WORKSHOP_MOD_UPDATE_CRON: "0 */6 * * *"
```

Set empty string to disable periodic checks.

## Verify expected logs

Healthy sync typically includes:

* `Syncing workshop mods`
* `Logging in using cached credentials`
* `Success. Downloaded item ...`
* `Mod changes detected` (only when effective changes are found)

## Troubleshooting quick checks

1. Workshop download fails

Check whether `/home/steam/Steam` is persisted and whether one-time login was completed with `steam-login.sh`.

2. Files downloaded but mod not active

Confirm `UE4SS_MODS_LAYOUT` matches your runtime expectation and that deployed files appear under the selected Win64 mod path.

3. Steam credentials prompts keep returning

Re-run `steam-login.sh --reset` and complete Steam Guard approval, then restart the container.
