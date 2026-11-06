extends Node2D
## Community World - prototype v0.1
## Isometric ground + building placement + resource counters.
## All content (resources, buildings, costs, production) comes from data/buildings.json;
## all player-facing text comes from data/locales/<lang>.json (see loc.gd).
## Rule code is theme-independent (GDD pillar 5).

const SAVE_PATH := "user://kayit.json"
const DATA_PATH := "res://data/buildings.json"
const TAP_SLOP := 14.0
const PAN_SPEED := 0.8     # drag pans the camera at 80% of finger speed (feels calmer)
const START_ZOOM := 0.4    # whole island fits a 720 px wide screen
const ZOOM_MIN := 0.3
const ZOOM_MAX := 1.6
const Loc := preload("res://loc.gd")
const Assets := preload("res://assets.gd")
const TOKENS_PATH := "res://design/tokens.json"

# Tile geometry comes from design/tokens.json (grid.*), loaded in _load_tokens().
var TW: float = 128.0
var TH: float = 64.0
var slab_depth: float = 26.0

var cfg: Dictionary = {}
var tok: Dictionary = {}
var age: String = "stone"
var pal: Dictionary = {}
var tile_canvas: Vector2 = Vector2(132, 68)
var tile_anchor: Vector2 = Vector2(66, 34)
var sprite_canvas: Vector2 = Vector2(128, 128)
var sprite_anchor: Vector2 = Vector2(64, 88)
var tex_ground: Array = []
var tex_building: Dictionary = {}
var grid_w: int = 14
var grid_h: int = 14
var res_defs: Dictionary = {}
var defs: Dictionary = {}
var def_order: Array = []
var base_capacity: float = 50.0
var max_offline: float = 8.0 * 3600.0
var start_stock: Dictionary = {}

var buildings: Dictionary = {}   # Vector2i -> bina id
var stock: Dictionary = {}       # kaynak id -> float
var rates: Dictionary = {}       # resource id -> production per second
var caps: Dictionary = {}        # resource id -> storage cap

# Per-building state (keyed by tile like `buildings`): upgrade level and uncollected output.
var levels: Dictionary = {}      # tile -> level (1 = default)
var bucket: Dictionary = {}      # tile -> {resource: amount waiting to be collected}
var bucket_seconds: float = 120.0
var upg: Dictionary = {}         # default upgrade rules from buildings.json
var age_up: Dictionary = {}
var btn_upgrade: Button
var collect_btn: Button

# Selection: tapping a building selects it and shows an action menu under it.
var sel_tile: Vector2i = Vector2i(-1, -1)
var action_menu: PanelContainer
var btn_remove: Button
var remove_armed: float = 0.0

# Placement: a ghost on the grid for a NEW building or one being MOVED. Nothing is built or
# moved until the tick is pressed; the cross puts everything back.
var pending_id: String = ""
var pending_tile: Vector2i = Vector2i(-1, -1)
var moving_from: Vector2i = Vector2i(-1, -1)   # (-1, -1) = placing a new building
var intro_text: String = ""                    # first-run hint shown until the ghost is touched
var ghost_grab: bool = false                   # the current drag started on the ghost
var ghost_dragged: bool = false
var grab_offset: Vector2i = Vector2i.ZERO
var cam: Camera2D
var ready_ok: bool = false

# input state
var touches: Dictionary = {}
var pinch_last: float = 0.0
var dragging: bool = false
var drag_moved: float = 0.0

# HUD
var hud_root: VBoxContainer
var hud_top: PanelContainer
var hud_bottom: PanelContainer
var palette_row: HBoxContainer
var place_row: HBoxContainer
var btn_confirm: Button
var btn_cancel: Button
var res_labels: Dictionary = {}
var btns: Dictionary = {}
var toast_label: Label
var toast_tween: Tween
var reset_btn: Button
var reset_armed: float = 0.0
var hud_timer: float = 0.0
var save_timer: float = 0.0



func _ready() -> void:
	Loc.init_locale()
	if not _load_defs() or not _load_tokens():
		return
	RenderingServer.set_default_clear_color(_wcol("clear"))
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_load_textures()
	cam = Camera2D.new()
	add_child(cam)
	cam.position = _tile_center(grid_w * 0.5 - 0.5, grid_h * 0.5 - 0.5) + Vector2(0, 60)
	cam.zoom = Vector2(START_ZOOM, START_ZOOM)
	cam.make_current()
	_build_hud()
	_recalc()
	_load_game()
	_recalc()
	_update_hud()
	if buildings.is_empty():
		btns[def_order[0]].button_pressed = true   # starts placing the first hut
		intro_text = Loc.t("toast.welcome")
		_refresh_place_ui()
	ready_ok = true
	queue_redraw()


# ---------------------------------------------------------------- data

func _load_defs() -> bool:
	var txt := FileAccess.get_file_as_string(DATA_PATH)
	if txt == "":
		push_error("buildings.json could not be read: " + DATA_PATH)
		return false
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("buildings.json is invalid")
		return false
	cfg = parsed
	var g: Dictionary = cfg.get("grid", {})
	age = String(cfg.get("age", "stone"))
	grid_w = int(g.get("w", 14))
	grid_h = int(g.get("h", 14))
	base_capacity = float(cfg.get("base_capacity", 50))
	max_offline = float(cfg.get("max_offline_hours", 8)) * 3600.0
	bucket_seconds = float(cfg.get("bucket_seconds", 120))
	upg = cfg.get("upgrade", {})
	age_up = cfg.get("age_up", {})
	res_defs = cfg.get("resources", {})
	start_stock = cfg.get("start", {})
	for b in cfg.get("buildings", []):
		var id: String = b["id"]
		defs[id] = b
		def_order.append(id)
	for r in res_defs:
		stock[r] = float(start_stock.get(r, 0))
	return def_order.size() > 0


func _load_tokens() -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TOKENS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("design/tokens.json could not be read")
		return false
	tok = parsed
	var g: Dictionary = tok["grid"]
	TW = float(g["tile_w"])
	TH = float(g["tile_h"])
	slab_depth = float(g["slab_depth"])
	tile_canvas = Vector2(float(g["tile_canvas"][0]), float(g["tile_canvas"][1]))
	tile_anchor = Vector2(float(g["tile_anchor"][0]), float(g["tile_anchor"][1]))
	sprite_canvas = Vector2(float(g["sprite_canvas"][0]), float(g["sprite_canvas"][1]))
	sprite_anchor = Vector2(float(g["sprite_anchor"][0]), float(g["sprite_anchor"][1]))
	var ages: Dictionary = tok["ages"]
	if not ages.has(age):
		push_error("Unknown age in buildings.json: " + age)
		return false
	pal = ages[age]["palette"]
	return true


func _load_textures() -> void:
	var sc: float = float(tok["grid"]["raster_scale"])
	tex_ground.clear()
	for v in ["a", "b"]:
		tex_ground.append(Assets.load_svg(Assets.ground_path(age, v), sc))
	for id in def_order:
		tex_building[id] = Assets.load_svg(Assets.building_path(id, age), sc)


## Design-token color helpers
func _pcol(role: String) -> Color:
	return Color.html(String(pal[role]))


func _ucol(name: String) -> Color:
	return Color.html(String(tok["ui"]["colors"][name]))


func _wcol(name: String) -> Color:
	return Color.html(String(tok["ui"]["world"][name]))


func _recalc() -> void:
	rates.clear()
	caps.clear()
	for r in res_defs:
		rates[r] = 0.0
		caps[r] = base_capacity
	for t in buildings:
		var id: String = buildings[t]
		for r in defs[id].get("produces", {}):
			rates[r] = float(rates[r]) + _rate_at(id, _level(t), r)
		var cap_add := _capacity_at(id, _level(t))
		if cap_add > 0.0:
			for r in res_defs:
				caps[r] = float(caps[r]) + cap_add
	for r in res_defs:
		stock[r] = minf(float(stock[r]), float(caps[r]))


# ---------------------------------------------------------------- levels (data-driven, buildings.json)

## A building's own "upgrade" block overrides the global defaults.
func _up(id: String, key: String) -> float:
	return float(defs[id].get("upgrade", {}).get(key, upg.get(key, 1.0)))


func _level(t: Vector2i) -> int:
	return int(levels.get(t, 1))


func _max_level(id: String) -> int:
	return int(_up(id, "max_level"))


func _rate_at(id: String, lv: int, r: String) -> float:
	return float(defs[id].get("produces", {}).get(r, 0.0)) * pow(_up(id, "prod_growth"), lv - 1)


func _capacity_at(id: String, lv: int) -> float:
	return float(defs[id].get("capacity", 0)) * pow(_up(id, "capacity_growth"), lv - 1)


## How much of one resource a building can hold before you collect it.
func _bucket_cap_at(id: String, lv: int, r: String) -> float:
	return float(defs[id].get("produces", {}).get(r, 0.0)) * bucket_seconds * pow(_up(id, "bucket_growth"), lv - 1)


## Cost to go from level `lv` to `lv + 1`.
func _upgrade_cost(id: String, lv: int) -> Dictionary:
	var out := {}
	var cost: Dictionary = defs[id].get("cost", {})
	for r in cost:
		out[r] = ceilf(float(cost[r]) * pow(_up(id, "cost_growth"), lv))
	return out


## Everything spent on a building so far (build + upgrades).
func _invested(id: String, lv: int) -> Dictionary:
	var out: Dictionary = defs[id].get("cost", {}).duplicate()
	for l in range(1, lv):
		var c := _upgrade_cost(id, l)
		for r in c:
			out[r] = float(out.get(r, 0.0)) + float(c[r])
	return out


func _best_level(id: String) -> int:
	var best := 0
	for t in buildings:
		if buildings[t] == id:
			best = maxi(best, _level(t))
	return best


## Age-up needs certain buildings at certain levels. Returns [{id, have, need}].
func _age_progress() -> Array:
	var out: Array = []
	var req: Dictionary = age_up.get("requires", {})
	for id in req:
		out.append({"id": id, "have": _best_level(id), "need": int(req[id])})
	return out


func _age_ready() -> bool:
	for e in _age_progress():
		if int(e["have"]) < int(e["need"]):
			return false
	return not age_up.is_empty()


func _bucket_total(t: Vector2i) -> float:
	var n := 0.0
	for r in bucket.get(t, {}):
		n += float(bucket[t][r])
	return n


## Moves uncollected output into village storage (as much as fits). Returns what was taken.
func _collect(t: Vector2i) -> Dictionary:
	var got := {}
	if not bucket.has(t):
		return got
	var b: Dictionary = bucket[t]
	for r in b:
		var take := minf(float(b[r]), float(caps[r]) - float(stock[r]))
		take = floorf(take) if take < float(b[r]) else take
		if take > 0.0:
			stock[r] = float(stock[r]) + take
			b[r] = float(b[r]) - take
			got[r] = take
	return got


func _gains_text(got: Dictionary) -> String:
	var parts: PackedStringArray = []
	for r in got:
		if float(got[r]) >= 1.0:
			parts.append(Loc.t("toast.offline_part", {"n": int(float(got[r])), "res": _rname(r)}))
	return Loc.t("info.join").join(parts)


func _collect_and_report(tiles: Array) -> void:
	var total := {}
	var waiting := 0.0
	for t in tiles:
		var got := _collect(t)
		for r in got:
			total[r] = float(total.get(r, 0.0)) + float(got[r])
		waiting += _bucket_total(t)
	_update_hud()
	queue_redraw()
	var txt := _gains_text(total)
	if txt != "":
		_toast(Loc.t("toast.collected", {"gains": txt}))
		_save_game()
	elif waiting >= 1.0:
		_toast(Loc.t("toast.storage_full"))
	else:
		_toast(Loc.t("toast.nothing_to_collect"))


func _collect_all() -> void:
	_collect_and_report(buildings.keys())


func _rname(r: String) -> String:
	return Loc.t("res.%s.name" % r)


func _bname(id: String) -> String:
	return Loc.t("building.%s.name" % id)


func _has_building(id: String) -> bool:
	for t in buildings:
		if buildings[t] == id:
			return true
	return false


func _afford(cost: Dictionary) -> bool:
	for r in cost:
		if float(stock.get(r, 0.0)) < float(cost[r]):
			return false
	return true


func _cost_text(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	for r in cost:
		parts.append(Loc.t("ui.cost_part", {"n": int(cost[r]), "res": _rname(r)}))
	return Loc.t("ui.cost_join").join(parts)


## Empty string = placeable, otherwise the reason to show the player.
func _check_place(t: Vector2i, id: String) -> String:
	if buildings.has(t):
		return Loc.t("toast.occupied")
	var d: Dictionary = defs[id]
	var req: String = String(d.get("requires", ""))
	if req != "" and not _has_building(req):
		return Loc.t("toast.need_building", {"name": _bname(req)})
	var cost: Dictionary = d.get("cost", {})
	for r in cost:
		if float(stock.get(r, 0.0)) < float(cost[r]):
			return Loc.t("toast.not_enough", {"res": _rname(r)})
	return ""


# ---------------------------------------------------------------- game rules

func _process(delta: float) -> void:
	if not ready_ok:
		return
	_produce(delta)
	hud_timer += delta
	if hud_timer >= 0.2:
		hud_timer = 0.0
		_update_hud()
		queue_redraw()   # collect badges grow over time
	save_timer += delta
	if save_timer >= 5.0:
		save_timer = 0.0
		_save_game()
	if reset_armed > 0.0:
		reset_armed -= delta
		if reset_armed <= 0.0:
			reset_btn.text = Loc.t("ui.reset")
	if remove_armed > 0.0:
		remove_armed -= delta
		if remove_armed <= 0.0:
			_disarm_remove()
	_position_menu()


func _produce(delta: float) -> void:
	for t in buildings:
		var id: String = buildings[t]
		var prod: Dictionary = defs[id].get("produces", {})
		if prod.is_empty():
			continue
		var b: Dictionary = bucket.get(t, {})
		var lv := _level(t)
		for r in prod:
			b[r] = minf(_bucket_cap_at(id, lv, r), float(b.get(r, 0.0)) + _rate_at(id, lv, r) * delta)
		bucket[t] = b


func _tap(t: Vector2i) -> void:
	if pending_id != "":
		if _in_grid(t):
			_set_pending(t)        # a tap only moves the ghost; the tick builds
	elif _in_grid(t) and buildings.has(t):
		_select(t)                 # a tap only selects; the menu offers the actions
	else:
		_deselect()
	queue_redraw()


# ---------------------------------------------------------------- selection / action menu

func _select(t: Vector2i) -> void:
	if t != sel_tile:
		_disarm_remove()
	sel_tile = t
	action_menu.visible = true
	_position_menu()
	var id: String = buildings[t]
	_toast(Loc.t("info.selected", {"name": _bname(id), "lv": _level(t), "max": _max_level(id), "details": _details(id, _level(t))}))
	_refresh_menu()
	queue_redraw()


func _deselect() -> void:
	sel_tile = Vector2i(-1, -1)
	_disarm_remove()
	if action_menu != null:
		action_menu.visible = false
	queue_redraw()


func _disarm_remove() -> void:
	remove_armed = 0.0
	if btn_remove != null:
		btn_remove.add_theme_stylebox_override("normal", _button_style(_ucol("button_normal")))
		btn_remove.add_theme_stylebox_override("hover", _button_style(_ucol("button_normal")))


## Keeps the menu under the selected building (above it when the bottom bar would cover it).
func _position_menu() -> void:
	if action_menu == null or not action_menu.visible:
		return
	if not buildings.has(sel_tile) or pending_id != "":
		_deselect()
		return
	var ab: Dictionary = tok["ui"]["actionbar"]
	var size := action_menu.get_combined_minimum_size()
	action_menu.size = size
	var c := get_canvas_transform() * _tile_center(sel_tile.x, sel_tile.y)
	var vp := get_viewport_rect().size
	var margin := float(ab["margin"])
	var pos := Vector2(c.x - size.x * 0.5, c.y + TH * 0.5 * cam.zoom.y + float(ab["offset"]))
	var bottom_y := vp.y - (hud_bottom.size.y if hud_bottom != null else 0.0)
	if pos.y + size.y > bottom_y - margin:
		pos.y = c.y - float(tok["ui"]["placement"]["pick_height"]) * cam.zoom.y - size.y - float(ab["offset"])
	var top_y := hud_top.size.y if hud_top != null else 0.0
	pos.y = clampf(pos.y, top_y + margin, maxf(top_y + margin, bottom_y - size.y - margin))
	pos.x = clampf(pos.x, margin, maxf(margin, vp.x - size.x - margin))
	action_menu.position = pos


func _refresh_menu() -> void:
	if btn_upgrade == null or not buildings.has(sel_tile):
		return
	var id: String = buildings[sel_tile]
	var lv := _level(sel_tile)
	var ok := lv < _max_level(id) and _afford(_upgrade_cost(id, lv)) and _upgrade_blocker(id, lv) == ""
	btn_upgrade.modulate = Color.WHITE if ok else _ucol("button_unaffordable_tint")


## Empty = can upgrade (apart from cost). Non-hut buildings cannot pass the level of the building they require.
func _upgrade_blocker(id: String, lv: int) -> String:
	if lv >= _max_level(id):
		return Loc.t("toast.max_level", {"name": _bname(id)})
	var req: String = String(defs[id].get("requires", ""))
	if req != "" and _best_level(req) < lv + 1:
		return Loc.t("toast.upgrade_needs", {"name": _bname(req), "n": lv + 1})
	return ""


func _on_info_pressed() -> void:
	if not buildings.has(sel_tile):
		return
	var id: String = buildings[sel_tile]
	var lv := _level(sel_tile)
	if lv >= _max_level(id):
		_toast(Loc.t("toast.max_level", {"name": _bname(id)}))
	else:
		_toast(Loc.t("info.next_level", {"lv": lv + 1, "details": _details(id, lv + 1), "cost": _cost_text(_upgrade_cost(id, lv))}))


func _on_move_pressed() -> void:
	if buildings.has(sel_tile):
		var t := sel_tile
		_deselect()
		_begin_place(buildings[t], t)


func _on_upgrade_pressed() -> void:
	if not buildings.has(sel_tile):
		return
	var id: String = buildings[sel_tile]
	var lv := _level(sel_tile)
	var blocked := _upgrade_blocker(id, lv)
	if blocked != "":
		_toast(blocked)
		return
	var cost := _upgrade_cost(id, lv)
	for r in cost:
		if float(stock.get(r, 0.0)) < float(cost[r]):
			_toast(Loc.t("toast.upgrade_cost", {"cost": _cost_text(cost)}))
			return
	for r in cost:
		stock[r] = float(stock[r]) - float(cost[r])
	levels[sel_tile] = lv + 1
	_recalc()
	_update_hud()
	_save_game()
	_toast(Loc.t("toast.upgraded", {"name": _bname(id), "lv": lv + 1}))
	_refresh_menu()
	queue_redraw()


func _on_remove_pressed() -> void:
	if not buildings.has(sel_tile):
		return
	if remove_armed > 0.0:
		var t := sel_tile
		_deselect()
		_remove_at(t)
		return
	remove_armed = float(tok["ui"]["actionbar"]["arm_seconds"])
	var red := _ucol("button_cancel")
	btn_remove.add_theme_stylebox_override("normal", _button_style(red))
	btn_remove.add_theme_stylebox_override("hover", _button_style(red))
	_toast(Loc.t("toast.confirm_remove", {"name": _bname(buildings[sel_tile]), "refund": _cost_text(_refund_of(buildings[sel_tile], _level(sel_tile)))}))


func _place(t: Vector2i, id: String) -> void:
	var err := _check_place(t, id)
	if err != "":
		_toast(err)
		return
	var d: Dictionary = defs[id]
	var cost: Dictionary = d.get("cost", {})
	for r in cost:
		stock[r] = float(stock[r]) - float(cost[r])
	buildings[t] = id
	levels[t] = 1
	bucket.erase(t)
	_recalc()
	_update_hud()
	_save_game()
	_toast(Loc.t("toast.built", {"name": _bname(id)}))


func _remove_at(t: Vector2i) -> void:
	if not buildings.has(t):
		return
	var id: String = buildings[t]
	_collect(t)   # whatever fits in storage is kept; the rest is lost with the building
	var refund := _refund_of(id, _level(t))
	for r in refund:
		stock[r] = float(stock[r]) + float(refund[r])
	buildings.erase(t)
	levels.erase(t)
	bucket.erase(t)
	_recalc()
	_update_hud()
	_save_game()
	_toast(Loc.t("toast.removed", {"name": _bname(id), "refund": _cost_text(refund)}))


## Half of everything spent on the building (build + upgrades), rounded down.
func _refund_of(id: String, lv: int = 1) -> Dictionary:
	var out := {}
	var spent := _invested(id, lv)
	for r in spent:
		out[r] = floorf(float(spent[r]) * 0.5)
	return out


func _details(id: String, lv: int = 1) -> String:
	var d: Dictionary = defs[id]
	var parts: PackedStringArray = []
	var prod: Dictionary = d.get("produces", {})
	for r in prod:
		parts.append(Loc.t("info.produces", {"rate": "%.1f" % _rate_at(id, lv, r), "res": _rname(r)}))
		parts.append(Loc.t("info.holds", {"n": int(_bucket_cap_at(id, lv, r))}))
	var cap_add := _capacity_at(id, lv)
	if cap_add > 0.0:
		parts.append(Loc.t("info.storage", {"n": int(cap_add)}))
	return Loc.t("info.join").join(parts)


# ---------------------------------------------------------------- placement / moving

func _begin_place(id: String, from: Vector2i = Vector2i(-1, -1)) -> void:
	_deselect()
	pending_id = id
	moving_from = from
	intro_text = ""
	pending_tile = from if from.x >= 0 else _nearest_free(_world_to_tile(cam.position))
	palette_row.visible = false
	place_row.visible = true
	_refresh_place_ui()
	_ensure_ghost_visible()
	queue_redraw()


func _end_place() -> void:
	pending_id = ""
	moving_from = Vector2i(-1, -1)
	intro_text = ""
	ghost_grab = false
	ghost_dragged = false
	if place_row != null:
		place_row.visible = false
		palette_row.visible = true
	for id in def_order:
		var b: Button = btns[id]
		b.button_pressed = false
	queue_redraw()


func _nearest_free(c: Vector2i) -> Vector2i:
	c = Vector2i(clampi(c.x, 0, grid_w - 1), clampi(c.y, 0, grid_h - 1))
	if not buildings.has(c):
		return c
	var best := c
	var best_d := 1 << 30
	for gx in range(grid_w):
		for gy in range(grid_h):
			var t := Vector2i(gx, gy)
			if buildings.has(t):
				continue
			var d := absi(t.x - c.x) + absi(t.y - c.y)
			if d < best_d:
				best_d = d
				best = t
	return best


func _set_pending(t: Vector2i) -> void:
	if pending_id == "":
		return
	t = Vector2i(clampi(t.x, 0, grid_w - 1), clampi(t.y, 0, grid_h - 1))
	if t != pending_tile:
		pending_tile = t
		intro_text = ""
		_refresh_place_ui()
		queue_redraw()


func _nudge(d: Vector2i) -> void:
	_set_pending(pending_tile + d)
	_ensure_ghost_visible()


## Empty string = the ghost may be confirmed where it is, otherwise the reason.
func _pending_error() -> String:
	if pending_id == "":
		return ""
	if moving_from.x >= 0:
		if pending_tile != moving_from and buildings.has(pending_tile):
			return Loc.t("toast.occupied")
		return ""
	return _check_place(pending_tile, pending_id)


func _confirm_place() -> void:
	if pending_id == "":
		return
	var err := _pending_error()
	if err != "":
		_hold_info(err, true)
		return
	var id := pending_id
	var t := pending_tile
	if moving_from.x >= 0:
		var from := moving_from
		_end_place()
		if t != from:
			buildings.erase(from)
			buildings[t] = id
			levels[t] = _level(from)
			levels.erase(from)
			if bucket.has(from):
				bucket[t] = bucket[from]
				bucket.erase(from)
			_save_game()
			_toast(Loc.t("toast.moved", {"name": _bname(id)}))
	else:
		_end_place()
		_place(t, id)


func _cancel_place() -> void:
	if pending_id != "":
		_end_place()


func _refresh_place_ui() -> void:
	if pending_id == "" or btn_confirm == null:
		return
	var err := _pending_error()
	btn_confirm.disabled = err != ""
	if err != "":
		_hold_info(err, true)
	elif intro_text != "":
		_hold_info(intro_text)
	elif moving_from.x >= 0:
		_hold_info(Loc.t("place.move", {"name": _bname(pending_id), "details": _details(pending_id)}))
	else:
		_hold_info(Loc.t("place.new", {"name": _bname(pending_id)}))


## Keep the ghost between the two HUD bars; recenter the camera on it if it is out of view.
func _ensure_ghost_visible() -> void:
	if pending_id == "" or cam == null:
		return
	var margin: float = float(tok["ui"]["placement"]["view_margin"])
	var vp := get_viewport_rect().size
	var top_h := hud_top.size.y if hud_top != null else 0.0
	var bot_h := hud_bottom.size.y if hud_bottom != null else 0.0
	var tc := _tile_center(pending_tile.x, pending_tile.y)
	var sp := get_canvas_transform() * tc
	if sp.x >= margin and sp.x <= vp.x - margin and sp.y >= top_h + margin and sp.y <= vp.y - bot_h - margin * 0.5:
		return
	var free_cy := (top_h + vp.y - bot_h) * 0.5
	cam.position = tc - Vector2(0.0, free_cy - vp.y * 0.5) / cam.zoom.y
	_clamp_cam()


## The tile a tap means. With a ghost out, that is the ground tile under the finger. Otherwise a tap
## on a building's visible body counts even when the body stands over the tile behind it. When hit
## boxes overlap (neighbours, zoomed far out) the building whose body is nearest the finger wins.
func _pick_tile(w: Vector2) -> Vector2i:
	var ground := _world_to_tile(w)
	if pending_id != "":
		return ground
	var place: Dictionary = tok["ui"]["placement"]
	# The hit box is never smaller than a fingertip on screen, however far the map is zoomed out.
	var rise: float = maxf(float(place["pick_height"]), float(place["pick_min_px"]) / cam.zoom.y)
	var half_w: float = maxf(TW * 0.4, float(place["pick_min_px"]) * 0.6 / cam.zoom.x)
	var body := Vector2(0, -float(place["pick_height"]) * 0.4)   # about the middle of a building
	var best := ground
	var best_d := INF
	for t in buildings:
		var c := _tile_center(t.x, t.y)
		var inside := absf(w.x - c.x) <= half_w and w.y <= c.y + TH * 0.25 and w.y >= c.y - rise
		if inside or t == ground:
			var d := w.distance_to(c + body)
			if d < best_d:
				best = t
				best_d = d
	return best


func _on_ghost(world: Vector2) -> bool:
	var grab: float = maxf(float(tok["ui"]["placement"]["grab_px"]), TW * 0.7 * cam.zoom.x)
	var centre := get_canvas_transform() * (_tile_center(pending_tile.x, pending_tile.y) + Vector2(0, -sprite_anchor.y * 0.4))
	var pointer := get_canvas_transform() * world
	return pointer.distance_to(centre) <= grab


func _reset_game() -> void:
	_end_place()
	buildings.clear()
	levels.clear()
	bucket.clear()
	for r in res_defs:
		stock[r] = float(start_stock.get(r, 0))
	_deselect()
	for id in btns:
		var b: Button = btns[id]
		b.button_pressed = false
	_recalc()
	_update_hud()
	_save_game()
	queue_redraw()


# ---------------------------------------------------------------- coordinates

func _tile_center(gx: float, gy: float) -> Vector2:
	return Vector2((gx - gy) * TW * 0.5, (gx + gy) * TH * 0.5)


func _world_to_tile(w: Vector2) -> Vector2i:
	var u := (w.x / (TW * 0.5) + w.y / (TH * 0.5)) * 0.5
	var v := (w.y / (TH * 0.5) - w.x / (TW * 0.5)) * 0.5
	return Vector2i(roundi(u), roundi(v))


func _screen_to_tile(p: Vector2) -> Vector2i:
	var w := get_canvas_transform().affine_inverse() * p
	return _world_to_tile(w)


func _in_grid(t: Vector2i) -> bool:
	return t.x >= 0 and t.y >= 0 and t.x < grid_w and t.y < grid_h


func _clamp_cam() -> void:
	var min_x := _tile_center(0, grid_h - 1).x - TW * 0.5
	var max_x := _tile_center(grid_w - 1, 0).x + TW * 0.5
	var min_y := -TH * 0.5
	var max_y := _tile_center(grid_w - 1, grid_h - 1).y + TH * 0.5 + slab_depth
	cam.position.x = clampf(cam.position.x, min_x, max_x)
	cam.position.y = clampf(cam.position.y, min_y, max_y)


func _set_zoom(z: float) -> void:
	z = clampf(z, ZOOM_MIN, ZOOM_MAX)
	cam.zoom = Vector2(z, z)
	_clamp_cam()


# ---------------------------------------------------------------- input

func _pinch_dist() -> float:
	if touches.size() < 2:
		return 0.0
	var keys := touches.keys()
	return (touches[keys[0]] as Vector2).distance_to(touches[keys[1]] as Vector2)


func _unhandled_input(event: InputEvent) -> void:
	if not ready_ok:
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			touches[st.index] = st.position
			if touches.size() == 2:
				dragging = false
				pinch_last = _pinch_dist()
		else:
			touches.erase(st.index)
			if touches.size() < 2:
				pinch_last = 0.0
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		touches[sd.index] = sd.position
		if touches.size() == 2:
			var d := _pinch_dist()
			if pinch_last > 0.0 and d > 0.0:
				_set_zoom(cam.zoom.x * d / pinch_last)
			pinch_last = d
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_set_zoom(cam.zoom.x * 1.12)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_set_zoom(cam.zoom.x / 1.12)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if touches.size() < 2:
					dragging = true
					drag_moved = 0.0
					ghost_grab = false
					ghost_dragged = false
					if pending_id != "":
						var w := get_canvas_transform().affine_inverse() * mb.position
						if _on_ghost(w):
							ghost_grab = true
							grab_offset = pending_tile - _world_to_tile(w)
			else:
				if dragging and drag_moved < TAP_SLOP and not ghost_dragged:
					var w := get_canvas_transform().affine_inverse() * mb.position
					var bt := _badge_at(w) if pending_id == "" else Vector2i(-1, -1)
					if bt.x >= 0:
						_collect_and_report([bt])
					else:
						_tap(_pick_tile(w))
				dragging = false
				ghost_grab = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if dragging and touches.size() < 2:
			drag_moved += mm.relative.length()
			if ghost_grab:
				if drag_moved >= float(tok["ui"]["placement"]["drag_slop"]):
					ghost_dragged = true
					_set_pending(_screen_to_tile(mm.position) + grab_offset)
			elif drag_moved >= TAP_SLOP:
				cam.position -= mm.relative * PAN_SPEED / cam.zoom.x
				_clamp_cam()
	elif event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if event.is_action_pressed("ui_accept"):
			_confirm_place()
		elif event.is_action_pressed("ui_cancel"):
			if pending_id != "":
				_cancel_place()
			else:
				_deselect()


# ---------------------------------------------------------------- drawing

func _diamond(c: Vector2, sx: float = 1.0) -> PackedVector2Array:
	var hw := TW * 0.5 * sx
	var hh := TH * 0.5 * sx
	return PackedVector2Array([
		c + Vector2(0, -hh), c + Vector2(hw, 0), c + Vector2(0, hh), c + Vector2(-hw, 0)
	])


func _outline(c: Vector2, col: Color) -> void:
	var p := _diamond(c)
	p.append(p[0])
	draw_polyline(p, col, float(tok["ui"]["world"]["highlight_width"]))


func _draw_building(c: Vector2, id: String, alpha: float = 1.0) -> void:
	var tex: Texture2D = tex_building.get(id)
	if tex == null:
		return
	draw_texture_rect(tex, Rect2(c - sprite_anchor, sprite_canvas), false, Color(1, 1, 1, alpha))


func _badge_centre(t: Vector2i) -> Vector2:
	return _tile_center(t.x, t.y) + Vector2(0, -float(tok["ui"]["badge"]["lift"]))


## The building whose collect badge is under the pointer, or (-1, -1).
func _badge_at(world: Vector2) -> Vector2i:
	var rad := float(tok["ui"]["badge"]["radius"]) + 6.0
	var xf := get_canvas_transform()
	var p := xf * world
	var best := Vector2i(-1, -1)
	var best_d := INF
	for t in buildings:
		if _bucket_total(t) < 1.0 or t == moving_from:
			continue
		var d := p.distance_to(xf * _badge_centre(t))
		if d <= rad and d < best_d:
			best = t
			best_d = d
	return best


## Collect badges and level marks: drawn after the tiles (never hidden) and at a constant size on screen.
func _draw_marks() -> void:
	var bd: Dictionary = tok["ui"]["badge"]
	var z := cam.zoom.x
	var font := ThemeDB.fallback_font
	var rad := float(bd["radius"])
	var fs := int(bd["font"])
	for t in buildings:
		if t == moving_from:
			continue
		var id: String = buildings[t]
		var c := _tile_center(t.x, t.y)
		if _level(t) >= 2:
			draw_set_transform(c + Vector2(TW * 0.30, 6), 0.0, Vector2(1, 1) / z)
			var lt := Loc.t("ui.level_mark", {"n": _level(t)})
			var lfs := int(bd["level_font"])
			draw_string_outline(font, Vector2.ZERO, lt, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs, 6, Color(0, 0, 0, 0.8))
			draw_string(font, Vector2.ZERO, lt, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs, _ucol("text"))
		var tot := _bucket_total(t)
		if tot >= 1.0:
			var prod: Dictionary = defs[id].get("produces", {})
			var res := String(prod.keys()[0]) if prod.size() > 0 else "stone"
			var full := tot >= _bucket_cap_at(id, _level(t), res) - 0.01
			draw_set_transform(_badge_centre(t), 0.0, Vector2(1, 1) / z)
			draw_circle(Vector2.ZERO, rad, _ucol("panel_bottom"))
			draw_arc(Vector2.ZERO, rad - 2.0, 0.0, TAU, 28, _ucol("resource_" + res), float(bd["ring"]) * (1.6 if full else 1.0))
			draw_string(font, Vector2(-rad, fs * 0.35), str(int(tot)), HORIZONTAL_ALIGNMENT_CENTER, rad * 2.0, fs, _ucol("text"))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw() -> void:
	if not ready_ok and defs.is_empty():
		return
	var dv := Vector2(0, slab_depth)
	var left_p := _tile_center(0, grid_h - 1) + Vector2(-TW * 0.5, 0)
	var bottom_p := _tile_center(grid_w - 1, grid_h - 1) + Vector2(0, TH * 0.5)
	var right_p := _tile_center(grid_w - 1, 0) + Vector2(TW * 0.5, 0)
	draw_colored_polygon(PackedVector2Array([left_p, bottom_p, bottom_p + dv, left_p + dv]), _pcol("slab_left"))
	draw_colored_polygon(PackedVector2Array([bottom_p, right_p, right_p + dv, bottom_p + dv]), _pcol("slab_right"))

	# Painter's algorithm: draw by diagonals (gx+gy), back to front.
	for s in range(grid_w + grid_h - 1):
		for gx in range(grid_w):
			var gy: int = s - gx
			if gy < 0 or gy >= grid_h:
				continue
			var t := Vector2i(gx, gy)
			var c := _tile_center(gx, gy)
			var gt: Texture2D = tex_ground[(gx + gy) % 2]
			if gt != null:
				draw_texture_rect(gt, Rect2(c - tile_anchor, tile_canvas), false)
			if buildings.has(t) and t != moving_from:
				_draw_building(c, buildings[t])
			if pending_id != "" and t == pending_tile:
				_draw_building(c, pending_id, float(tok["ui"]["world"]["ghost_alpha"]))

	_draw_marks()
	if pending_id != "":
		if moving_from.x >= 0 and moving_from != pending_tile:
			_outline(_tile_center(moving_from.x, moving_from.y), _wcol("hover_dim"))
		var ok := _pending_error() == ""
		_outline(_tile_center(pending_tile.x, pending_tile.y), _wcol("hover_ok") if ok else _wcol("hover_bad"))
	elif buildings.has(sel_tile):
		_outline(_tile_center(sel_tile.x, sel_tile.y), _wcol("hover_neutral"))


# ---------------------------------------------------------------- HUD

func _style(col: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_content_margin_all(int(tok["ui"]["spacing"]["panel_margin"]))
	return s


func _button_style(col: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(int(tok["ui"]["button"]["radius"]))
	s.set_content_margin_all(8)
	return s


## One Theme built from the design tokens: every Button/Label in the HUD inherits it.
func _make_theme() -> Theme:
	var th := Theme.new()
	th.set_stylebox("normal", "Button", _button_style(_ucol("button_normal")))
	th.set_stylebox("hover", "Button", _button_style(_ucol("button_hover")))
	th.set_stylebox("pressed", "Button", _button_style(_ucol("button_pressed")))
	th.set_stylebox("hover_pressed", "Button", _button_style(_ucol("button_pressed")))
	th.set_stylebox("disabled", "Button", _button_style(_ucol("button_disabled")))
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", _ucol("text"))
	th.set_color("font_hover_color", "Button", _ucol("text"))
	th.set_color("font_pressed_color", "Button", _ucol("text"))
	th.set_color("font_hover_pressed_color", "Button", _ucol("text"))
	th.set_color("font_disabled_color", "Button", _ucol("text_dim"))
	th.set_color("font_color", "Label", _ucol("text"))
	th.set_font_size("font_size", "Button", int(tok["ui"]["font_size"]["button"]))
	th.set_font_size("font_size", "Label", int(tok["ui"]["font_size"]["label"]))
	return th


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	# A Control under a CanvasLayer does not resolve its size from anchors (stays 0),
	# so we size the root explicitly from the viewport.
	var root := VBoxContainer.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_theme_constant_override("separation", 0)
	layer.add_child(root)
	hud_root = root
	root.theme = _make_theme()
	var gap: int = int(tok["ui"]["spacing"]["gap"])
	_fit_hud()
	get_viewport().size_changed.connect(_fit_hud)

	# top bar: resource counters
	var top := PanelContainer.new()
	hud_top = top
	top.add_theme_stylebox_override("panel", _style(_ucol("panel_top")))
	root.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", gap)
	top.add_child(row)
	for r in res_defs:
		var l := Label.new()
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_color_override("font_color", _ucol("resource_" + String(r)))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(l)
		res_labels[r] = l
	collect_btn = Button.new()
	collect_btn.text = Loc.t("ui.collect_all")
	collect_btn.add_theme_font_size_override("font_size", int(tok["ui"]["font_size"]["small"]))
	collect_btn.pressed.connect(_collect_all)
	row.add_child(collect_btn)
	reset_btn = Button.new()
	reset_btn.text = Loc.t("ui.reset")
	reset_btn.add_theme_font_size_override("font_size", int(tok["ui"]["font_size"]["small"]))
	reset_btn.pressed.connect(_on_reset_pressed)
	row.add_child(reset_btn)

	# middle spacer: lets touches reach the world
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	# bottom bar: building palette + info line
	var bottom := PanelContainer.new()
	hud_bottom = bottom
	bottom.add_theme_stylebox_override("panel", _style(_ucol("panel_bottom")))
	root.add_child(bottom)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", gap)
	bottom.add_child(vb)
	toast_label = Label.new()
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.custom_minimum_size = Vector2(0, 36)
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_label.modulate.a = 0.0
	vb.add_child(toast_label)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", gap)
	vb.add_child(hb)
	palette_row = hb

	# placement bar (replaces the palette while a ghost is on the grid):
	# cross, four diagonal arrows (they point the way the next tile lies), tick
	place_row = HBoxContainer.new()
	place_row.add_theme_constant_override("separation", gap)
	place_row.visible = false
	vb.add_child(place_row)
	var stretch: float = float(tok["ui"]["placement"]["confirm_stretch"])
	btn_cancel = _icon_button("cancel", "button_cancel")
	btn_cancel.size_flags_stretch_ratio = stretch
	btn_cancel.pressed.connect(_cancel_place)
	place_row.add_child(btn_cancel)
	for a in [["arrow_nw", Vector2i(-1, 0)], ["arrow_sw", Vector2i(0, 1)], ["arrow_ne", Vector2i(0, -1)], ["arrow_se", Vector2i(1, 0)]]:
		var ab := _icon_button(a[0], "button_normal")
		ab.pressed.connect(_nudge.bind(a[1]))
		place_row.add_child(ab)
	btn_confirm = _icon_button("confirm", "button_confirm")
	btn_confirm.size_flags_stretch_ratio = stretch
	btn_confirm.pressed.connect(_confirm_place)
	place_row.add_child(btn_confirm)

	# action menu: floats under the selected building (hidden until a building is tapped)
	var ab: Dictionary = tok["ui"]["actionbar"]
	action_menu = PanelContainer.new()
	action_menu.visible = false
	action_menu.add_theme_stylebox_override("panel", _style(_ucol("panel_bottom")))
	layer.add_child(action_menu)
	var amr := HBoxContainer.new()
	amr.add_theme_constant_override("separation", int(ab["gap"]))
	action_menu.add_child(amr)
	var side := int(ab["button"])
	for a in [["info", _on_info_pressed], ["move", _on_move_pressed], ["upgrade", _on_upgrade_pressed], ["remove", _on_remove_pressed]]:
		var mb := _icon_button(a[0], "button_normal", side)
		mb.pressed.connect(a[1])
		amr.add_child(mb)
		if a[0] == "remove":
			btn_remove = mb
		elif a[0] == "upgrade":
			btn_upgrade = mb

	var group := ButtonGroup.new()
	group.allow_unpress = true
	for id in def_order:
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, int(tok["ui"]["button"]["min_height"]))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var d: Dictionary = defs[id]
		b.text = Loc.t("building.%s.short" % id) + "\n" + _cost_text(d.get("cost", {}))
		b.toggled.connect(_on_btn_toggled.bind(id))
		hb.add_child(b)
		btns[id] = b


func _icon_button(icon_name: String, color_key: String, side: int = 0) -> Button:
	var ic: Dictionary = tok["ui"]["icon"]
	var b := Button.new()
	if side > 0:
		b.custom_minimum_size = Vector2(side, side)
	else:
		b.custom_minimum_size = Vector2(0, int(tok["ui"]["button"]["min_height"]))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Rasterized at 2x the display size, drawn down with mipmaps so it stays crisp on phones.
	b.icon = Assets.load_svg(Assets.icon_path(icon_name), float(ic["display"]) * 2.0 / float(ic["canvas"]))
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.add_theme_constant_override("icon_max_width", int(ic["display"]))
	b.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, float(ic["disabled_alpha"])))
	b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var col := _ucol(color_key)
	for st in ["normal", "hover"]:
		b.add_theme_stylebox_override(st, _button_style(col))
	for st in ["pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st, _button_style(col.darkened(0.15)))
	b.add_theme_stylebox_override("disabled", _button_style(_ucol("button_disabled")))
	return b


func _fit_hud() -> void:
	if hud_root != null:
		hud_root.position = Vector2.ZERO
		hud_root.size = get_viewport_rect().size


func _on_btn_toggled(on: bool, id: String) -> void:
	if on:
		_begin_place(id)
	queue_redraw()


func _on_reset_pressed() -> void:
	if reset_armed > 0.0:
		reset_armed = 0.0
		reset_btn.text = Loc.t("ui.reset")
		_reset_game()
		_toast(Loc.t("toast.reset_done"))
	else:
		reset_armed = 3.0
		reset_btn.text = Loc.t("ui.reset_confirm")


func _update_hud() -> void:
	for r in res_defs:
		var l: Label = res_labels[r]
		var rate: float = rates[r]
		var rate_txt := Loc.t("ui.rate", {"rate": "%.1f" % rate}) if rate > 0.0 else Loc.t("ui.no_rate")
		l.text = Loc.t("ui.res_line", {"name": _rname(r), "cur": int(stock[r]), "cap": int(caps[r])}) + "\n" + rate_txt
	for id in def_order:
		var d: Dictionary = defs[id]
		var b: Button = btns[id]
		var req: String = String(d.get("requires", ""))
		var locked: bool = req != "" and not _has_building(req)
		if locked and b.button_pressed:
			b.button_pressed = false
		b.disabled = locked
		var ok: bool = _afford(d.get("cost", {})) and not locked
		b.modulate = Color.WHITE if ok else _ucol("button_unaffordable_tint")
	_refresh_place_ui()
	_refresh_menu()


## Show text on the info line and keep it there (no fade) while a ghost is being placed.
func _hold_info(msg: String, warn: bool = false) -> void:
	if toast_label == null:
		return
	if toast_tween != null and toast_tween.is_valid():
		toast_tween.kill()
	toast_label.text = msg
	toast_label.modulate.a = 1.0
	if warn:
		toast_label.add_theme_color_override("font_color", _ucol("text_warn"))
	else:
		toast_label.remove_theme_color_override("font_color")


func _toast(msg: String) -> void:
	if toast_label == null:
		return
	toast_label.text = msg
	toast_label.modulate.a = 1.0
	toast_label.remove_theme_color_override("font_color")
	if toast_tween != null and toast_tween.is_valid():
		toast_tween.kill()
	toast_tween = create_tween()
	toast_tween.tween_interval(float(tok["motion"]["toast_hold"]))
	toast_tween.tween_property(toast_label, "modulate:a", 0.0, float(tok["motion"]["toast_fade"]))


# ---------------------------------------------------------------- save / load

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED:
			_save_game()


func _save_game() -> void:
	if cam == null:
		return
	var b: Array = []
	for t in buildings:
		b.append([t.x, t.y, buildings[t], _level(t), bucket.get(t, {})])
	var data := {
		"v": 1,
		"t": Time.get_unix_time_from_system(),
		"stock": stock,
		"b": b,
		"cam": [cam.position.x, cam.position.y, cam.zoom.x],
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))


func _load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	buildings.clear()
	levels.clear()
	bucket.clear()
	for e in data.get("b", []):
		var id := String(e[2])
		if defs.has(id):
			var tile := Vector2i(int(e[0]), int(e[1]))
			buildings[tile] = id
			if e.size() >= 4:
				levels[tile] = clampi(int(e[3]), 1, _max_level(id))
			if e.size() >= 5 and typeof(e[4]) == TYPE_DICTIONARY:
				var bk := {}
				for r in e[4]:
					if res_defs.has(r):
						bk[r] = minf(float(e[4][r]), _bucket_cap_at(id, _level(tile), r))
				bucket[tile] = bk
	var st: Dictionary = data.get("stock", {})
	for r in res_defs:
		if st.has(r):
			stock[r] = float(st[r])
	var cp: Array = data.get("cam", [])
	if cp.size() == 3:
		cam.position = Vector2(float(cp[0]), float(cp[1]))
		_set_zoom(float(cp[2]))
	_recalc()
	# Offline accumulation: buildings keep producing into their own stores (up to their capacity)
	var dt := clampf(Time.get_unix_time_from_system() - float(data.get("t", 0)), 0.0, max_offline)
	if dt > 30.0:
		var made := {}
		for t in buildings:
			var id: String = buildings[t]
			var b: Dictionary = bucket.get(t, {})
			for r in defs[id].get("produces", {}):
				var cur := float(b.get(r, 0.0))
				var add := minf(_bucket_cap_at(id, _level(t), r) - cur, _rate_at(id, _level(t), r) * dt)
				if add > 0.0:
					b[r] = cur + add
					made[r] = float(made.get(r, 0.0)) + add
			bucket[t] = b
		var txt := _gains_text(made)
		if txt != "":
			_toast(Loc.t("toast.offline", {"gains": txt}))
