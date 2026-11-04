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
const REMOVE := "_remove"
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

var selected: String = ""        # "" = inspect, building id = build, REMOVE = demolish
var hover: Vector2i = Vector2i(-1, -1)
var cam: Camera2D
var ready_ok: bool = false

# input state
var touches: Dictionary = {}
var pinch_last: float = 0.0
var dragging: bool = false
var drag_moved: float = 0.0

# HUD
var hud_root: VBoxContainer
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
		btns[def_order[0]].button_pressed = true
		_toast(Loc.t("toast.welcome"))
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
		var d: Dictionary = defs[buildings[t]]
		var prod: Dictionary = d.get("produces", {})
		for r in prod:
			rates[r] = float(rates[r]) + float(prod[r])
		var cap_add: float = float(d.get("capacity", 0))
		if cap_add > 0.0:
			for r in res_defs:
				caps[r] = float(caps[r]) + cap_add
	for r in res_defs:
		stock[r] = minf(float(stock[r]), float(caps[r]))


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
	for r in rates:
		var rate: float = rates[r]
		if rate > 0.0:
			stock[r] = minf(float(caps[r]), float(stock[r]) + rate * delta)
	hud_timer += delta
	if hud_timer >= 0.2:
		hud_timer = 0.0
		_update_hud()
	save_timer += delta
	if save_timer >= 5.0:
		save_timer = 0.0
		_save_game()
	if reset_armed > 0.0:
		reset_armed -= delta
		if reset_armed <= 0.0:
			reset_btn.text = Loc.t("ui.reset")


func _tap(t: Vector2i) -> void:
	hover = t
	if _in_grid(t):
		if selected == "":
			_inspect(t)
		elif selected == REMOVE:
			_remove_at(t)
		else:
			_place(t, selected)
	queue_redraw()


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
	_recalc()
	_update_hud()
	_save_game()
	_toast(Loc.t("toast.built", {"name": _bname(id)}))


func _remove_at(t: Vector2i) -> void:
	if not buildings.has(t):
		return
	var buildings_id_removed: String = buildings[t]
	var d: Dictionary = defs[buildings_id_removed]
	var cost: Dictionary = d.get("cost", {})
	for r in cost:
		stock[r] = float(stock[r]) + floorf(float(cost[r]) * 0.5)
	buildings.erase(t)
	_recalc()
	_update_hud()
	_save_game()
	_toast(Loc.t("toast.removed", {"name": _bname(buildings_id_removed)}))


func _inspect(t: Vector2i) -> void:
	if not buildings.has(t):
		return
	var d: Dictionary = defs[buildings[t]]
	var parts: PackedStringArray = []
	var prod: Dictionary = d.get("produces", {})
	for r in prod:
		parts.append(Loc.t("info.produces", {"rate": "%.1f" % float(prod[r]), "res": _rname(r)}))
	var cap_add: float = float(d.get("capacity", 0))
	if cap_add > 0.0:
		parts.append(Loc.t("info.storage", {"n": int(cap_add)}))
	_toast(Loc.t("info.line", {"name": _bname(buildings[t]), "details": Loc.t("info.join").join(parts)}))


func _reset_game() -> void:
	buildings.clear()
	for r in res_defs:
		stock[r] = float(start_stock.get(r, 0))
	selected = ""
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
					_set_hover(_screen_to_tile(mb.position))
			else:
				if dragging and drag_moved < TAP_SLOP:
					_tap(_screen_to_tile(mb.position))
				dragging = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_set_hover(_screen_to_tile(mm.position))
		if dragging and touches.size() < 2:
			drag_moved += mm.relative.length()
			if drag_moved >= TAP_SLOP:
				cam.position -= mm.relative * PAN_SPEED / cam.zoom.x
				_clamp_cam()


func _set_hover(t: Vector2i) -> void:
	if t != hover:
		hover = t
		queue_redraw()


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
			if buildings.has(t):
				_draw_building(c, buildings[t])

	if _in_grid(hover):
		var hc := _tile_center(hover.x, hover.y)
		var outline := _wcol("hover_neutral")
		if selected == REMOVE:
			outline = _wcol("hover_bad") if buildings.has(hover) else _wcol("hover_dim")
		elif selected != "":
			if _check_place(hover, selected) == "":
				_draw_building(hc, selected, float(tok["ui"]["world"]["ghost_alpha"]))
				outline = _wcol("hover_ok")
			else:
				outline = _wcol("hover_bad")
		_outline(hc, outline)


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
	bottom.add_theme_stylebox_override("panel", _style(_ucol("panel_bottom")))
	root.add_child(bottom)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", gap)
	bottom.add_child(vb)
	toast_label = Label.new()
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.custom_minimum_size = Vector2(0, 36)
	toast_label.modulate.a = 0.0
	vb.add_child(toast_label)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", gap)
	vb.add_child(hb)

	var group := ButtonGroup.new()
	group.allow_unpress = true
	var ids: Array = def_order.duplicate()
	ids.append(REMOVE)
	for id in ids:
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, int(tok["ui"]["button"]["min_height"]))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if id == REMOVE:
			b.text = Loc.t("ui.remove") + "\n" + Loc.t("ui.remove_sub")
		else:
			var d: Dictionary = defs[id]
			b.text = Loc.t("building.%s.short" % id) + "\n" + _cost_text(d.get("cost", {}))
		b.toggled.connect(_on_btn_toggled.bind(id))
		hb.add_child(b)
		btns[id] = b


func _fit_hud() -> void:
	if hud_root != null:
		hud_root.position = Vector2.ZERO
		hud_root.size = get_viewport_rect().size


func _on_btn_toggled(on: bool, id: String) -> void:
	if on:
		selected = id
	elif selected == id:
		selected = ""
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


func _toast(msg: String) -> void:
	if toast_label == null:
		return
	toast_label.text = msg
	toast_label.modulate.a = 1.0
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
		b.append([t.x, t.y, buildings[t]])
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
	for e in data.get("b", []):
		var id := String(e[2])
		if defs.has(id):
			buildings[Vector2i(int(e[0]), int(e[1]))] = id
	var st: Dictionary = data.get("stock", {})
	for r in res_defs:
		if st.has(r):
			stock[r] = float(st[r])
	var cp: Array = data.get("cam", [])
	if cp.size() == 3:
		cam.position = Vector2(float(cp[0]), float(cp[1]))
		_set_zoom(float(cp[2]))
	_recalc()
	# Offline accumulation (GDD: a plot stores at most ~8 hours of production)
	var dt := clampf(Time.get_unix_time_from_system() - float(data.get("t", 0)), 0.0, max_offline)
	if dt > 30.0:
		var gained: PackedStringArray = []
		for r in res_defs:
			var add := minf(float(caps[r]) - float(stock[r]), float(rates[r]) * dt)
			if add >= 1.0:
				stock[r] = float(stock[r]) + add
				gained.append(Loc.t("toast.offline_part", {"n": int(add), "res": _rname(r)}))
		if gained.size() > 0:
			_toast(Loc.t("toast.offline", {"gains": Loc.t("info.join").join(gained)}))
