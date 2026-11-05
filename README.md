# Community World

A collaborative village-building game: mobile, isometric 2.5D, 50-player servers where everyone builds their own plot and a shared village, and the village advances through the ages together. This repo holds the Godot 4 web prototype (v0.1): isometric ground, building placement and resource counters, single player for now.

## Play it on a phone (no install)

1. Push this repo to GitHub (public, so free Pages works).
2. **Settings → Pages → Source: GitHub Actions.**
3. Every push to `main` runs the workflow: art check, smoke test, web export, deploy (about 3-4 minutes).
4. Open `https://<user>.github.io/community-world/` on your phone. "Add to Home Screen" works.

## Controls

| Action | Phone | Desktop |
|---|---|---|
| Place a building | Pick it at the bottom. A ghost appears on the map: drag it, tap a tile, or nudge it with the four arrows, then tap the green tick (the red cross cancels) | Same, click; `Enter` confirms, `Esc` cancels |
| Select a building | Tap it: a menu appears under it (Info, Move, Upgrade, Remove). Tap empty ground to close it | Same |
| Move a building | Select it, tap **Move**, move the ghost the same way, tick to confirm (free); cross puts it back | Same |
| Remove | Select it, tap the bin twice (refunds 50%). Upgrade is a placeholder for now | Same |
| Pan | Drag the map (a drag that starts on the ghost moves the ghost instead) | Drag |
| Zoom | Two fingers | Mouse wheel |

Nothing is built or moved until you tap the tick. The tick is greyed out, and the info line says why, when the spot is taken or you cannot afford it. The arrows point the way the next tile lies on screen.

Build a **Stone Hut** first: it unlocks everything else and adds storage. Progress is saved in the browser; production keeps accumulating for up to 8 hours while the game is closed. **Reset** (top right) needs two taps.

## Repo layout

- `main.gd`: the game (drawing, input, production, HUD, save)
- `loc.gd` and `data/locales/en.json`: all player-facing text, looked up by key
- `data/buildings.json`: gameplay data only (resources, costs, production, storage)
- `design/tokens.json`: the design system source of truth (palettes per age, shading, shape parameters, UI colors and sizes)
- `tools/gen_assets.py`: generates every SVG in `assets/` (world art and UI icons) and its `.import` file from the tokens (`--check` fails CI when they are stale)
- `assets.gd`: rasterizes the SVGs at runtime so they stay sharp when zoomed in
- `tools/smoke_test.gd`: headless test (`godot --headless --script res://tools/smoke_test.gd`)
- `.github/workflows/web.yml`: export and deploy

## Adding a language

1. Copy `data/locales/en.json` to `data/locales/<code>.json` and translate the values (keep the keys and `{placeholders}`).
2. Add the code to `SUPPORTED` in `loc.gd`.

Missing keys fall back to English. Before shipping scripts other than Latin, add a font that covers them (see the type note in `design/tokens.json`). A language picker and a saved choice are not built yet.

## Changing the look

Edit `design/tokens.json`, run `python3 tools/gen_assets.py`, commit the regenerated SVGs. Never edit files in `assets/` by hand.

## Known limits

- Production flows straight into storage (the "collect" loop from the design doc comes next).
- Only the Stone Age is playable; the Iron and Middle Ages art already exists.
- No server yet. Ads and in-app purchases do not run on web; they are tested with an APK.
