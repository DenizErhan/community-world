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
| Build / remove | Pick a tool at the bottom, tap a tile | Same, click |
| Pan | Drag | Drag |
| Zoom | Two fingers | Mouse wheel |
| Inspect | With no tool selected, tap a building | Same |

Build a **Stone Hut** first: it unlocks everything else and adds storage. Remove refunds 50%. Progress is saved in the browser; production keeps accumulating for up to 8 hours while the game is closed. **Reset** (top right) needs two taps.

## Repo layout

- `main.gd`: the game (drawing, input, production, HUD, save)
- `loc.gd` and `data/locales/en.json`: all player-facing text, looked up by key
- `data/buildings.json`: gameplay data only (resources, costs, production, storage)
- `design/tokens.json`: the design system source of truth (palettes per age, shading, shape parameters, UI colors and sizes)
- `tools/gen_assets.py`: generates every SVG in `assets/` from the tokens (`--check` fails CI when they are stale)
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
