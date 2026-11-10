extends Node2D
## Light animation layer drawn above the world. Everything it draws is described in
## design/tokens.json under "motion" (loops per building, ambient life, one-shot events).
## It never takes input and never changes game state. It switches itself off when the
## browser/OS asks for reduced motion.

var game                      # main.gd (untyped on purpose: we only read its public fields)
var m: Dictionary = {}
var enabled: bool = true
var _acc: float = 0.0
var _events: Array = []


func setup(g) -> void:
	game = g
	m = g.tok["motion"]
	enabled = bool(m.get("enabled", true))
	if OS.has_feature("web"):
		var reduce: Variant = JavaScriptBridge.eval("window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches")
		if reduce == true:
			enabled = false


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> void:
	if game == null:
		return
	if not enabled:
		_events.clear()
		return
	var now := _now()
	_events = _events.filter(func(e): return now - float(e["t0"]) < float(e["dur"]))
	_acc += delta
	if _acc >= 1.0 / float(m["fps"]):
		_acc = 0.0
		queue_redraw()


# ---------------------------------------------------------------- one-shot events (called by main.gd)

func burst_dust(tile: Vector2i) -> void:
	_add("dust", game._tile_center(tile.x, tile.y), m["events"]["place"]["dur"])


func sparkle(tile: Vector2i) -> void:
	_add("sparkle", game._tile_center(tile.x, tile.y), m["events"]["upgrade"]["dur"])


func float_text(world_pos: Vector2, text: String, color: Color) -> void:
	_add("text", world_pos, m["events"]["collect"]["dur"], {"text": text, "color": color})


func event_count() -> int:
	return _events.size()


func _add(kind: String, pos: Vector2, dur: float, extra: Dictionary = {}) -> void:
	if not enabled:
		return
	var e := {"k": kind, "pos": pos, "t0": _now(), "dur": float(dur), "seed": randf() * 100.0}
	e.merge(extra)
	_events.append(e)


# ---------------------------------------------------------------- helpers

static func _rnd(x: float) -> float:
	return fposmod(sin(x * 12.9898) * 43758.5453, 1.0)


static func _phase(t: Vector2i) -> float:
	return _rnd(float(t.x * 127 + t.y * 311))


static func _out(p: float) -> float:
	return 1.0 - pow(1.0 - p, 3.0)


func _col(role: String, a: float = 1.0) -> Color:
	return Color(Color.html(String(m["colors"][role])), a)


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if not enabled or game == null or not game.ready_ok:
		return
	var now := _now()
	var z: float = game.cam.zoom.x
	var k := clampf(float(m["min_screen_scale"]) / z, 1.0, 2.2)   # keep effects visible when zoomed out
	var vp: Vector2 = game.get_viewport_rect().size
	var view := Rect2(game.cam.position - vp / (2.0 * z), vp / z).grow(float(m["view_margin"]))
	var loops_by_id: Dictionary = m["loops"]
	for t in game.buildings:
		if t == game.moving_from:
			continue
		var loops: Array = loops_by_id.get(game.buildings[t], [])
		if loops.is_empty():
			continue
		var c: Vector2 = game._tile_center(t.x, t.y)
		if not view.has_point(c):
			continue
		var ph := _phase(t)
		for lp in loops:
			match String(lp["type"]):
				"smoke": _smoke(lp, c, now, ph, k)
				"sway": _sway(lp, c, now, ph, k)
				"shimmer": _shimmer(lp, c, now, ph, k)
				"dust": _dust(lp, c, now, ph, k)
	_butterflies(now, k, view)
	for e in _events:
		var p := (now - float(e["t0"])) / float(e["dur"])
		if p < 0.0 or p >= 1.0:
			continue
		match String(e["k"]):
			"dust": _ev_dust(e, p, k)
			"sparkle": _ev_sparkle(e, p, k)
			"text": _ev_text(e, p, z)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _smoke(lp: Dictionary, c: Vector2, now: float, ph: float, k: float) -> void:
	var a: Variant = lp["anchor"]
	if a is Dictionary:
		a = a.get(game.age, a.get("stone"))
	var o := c + Vector2(float(a[0]), float(a[1]))
	var n := int(lp["puffs"])
	for i in n:
		var p := fposmod(now / float(lp["period"]) + float(i) / n + ph, 1.0)
		var pos := o + Vector2(float(lp["drift"]) * p * k + sin(p * 5.0 + i * 2.0 + ph * 6.0) * 3.0 * k, -float(lp["rise"]) * p * k)
		var alpha := float(lp["alpha"]) * (1.0 - p) * minf(1.0, p * 8.0)
		draw_circle(pos, lerpf(float(lp["r0"]), float(lp["r1"]), p) * k, _col("smoke", alpha))


func _sway(lp: Dictionary, c: Vector2, now: float, ph: float, k: float) -> void:
	var g := int(lp["grid"])
	var span := float(lp["span"])
	var f: float = game.tok["shapes"]["farm"]["f"]
	var hw: float = game.TW * 0.5 * f
	var hh: float = game.TH * 0.5 * f
	var top := c + Vector2(0, float(lp["top"]))
	var crop := Color.html(String(game.pal["crop"]))
	var stalk := crop.darkened(0.3)
	var head := crop.lightened(0.45)
	var h0 := float(lp["height"][0])
	var h1 := float(lp["height"][1])
	for i in g:
		for j in g:
			var u := lerpf(-span, span, float(i) / (g - 1))
			var v := lerpf(-span, span, float(j) / (g - 1))
			var base := top + Vector2((u - v) * hw * 0.5, (u + v) * hh * 0.5)
			var h := lerpf(h0, h1, _rnd(float(i * 3 + j) + ph * 10.0)) * k
			var sway := sin(now * float(lp["speed"]) + (u + v) * float(lp["wave"]) * PI + ph * 6.0) * float(lp["amp"]) * k
			var tip := base + Vector2(sway, -h)
			draw_line(base, tip, stalk, 2.0 * k)
			draw_circle(tip, 2.6 * k, head)


func _shimmer(lp: Dictionary, c: Vector2, now: float, ph: float, k: float) -> void:
	var cen := c + Vector2(float(lp["center"][0]), float(lp["center"][1]))
	var half := Vector2(float(lp["half"][0]), float(lp["half"][1]))
	var rp := fposmod(now / float(lp["ripple_period"]) + ph, 1.0)
	draw_set_transform(cen, 0.0, Vector2(1.0, 0.5))
	draw_arc(Vector2.ZERO, 3.0 + half.x * 0.5 * rp, 0.0, TAU, 20, _col("glint", 0.5 * (1.0 - rp)), 1.6 * minf(k, 1.4))
	for i in int(lp["glints"]):
		var cyc := now / (float(lp["period"]) * (0.8 + 0.4 * _rnd(i))) + ph + i * 0.37
		var cycle := floorf(cyc)
		var p := cyc - cycle
		var u := (_rnd(cycle * 7.1 + i * 3.3) * 2.0 - 1.0) * 0.65
		var v := (_rnd(cycle * 5.3 + i * 9.1) * 2.0 - 1.0) * 0.65
		draw_set_transform(cen + Vector2((u - v) * half.x * 0.5, (u + v) * half.y * 0.5), 0.0, Vector2(1.0, 0.4))
		draw_circle(Vector2.ZERO, 3.4 * k, _col("glint", sin(p * PI) * 0.85))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _dust(lp: Dictionary, c: Vector2, now: float, ph: float, k: float) -> void:
	var a: Array = lp["anchor"]
	for i in int(lp["puffs"]):
		var cyc := now / float(lp["period"]) + ph + i * 0.5
		var cycle := floorf(cyc)
		var p := (cyc - cycle) / 0.5        # a puff lives for the first half of its cycle, then rests
		if p >= 1.0:
			continue
		var x := float(a[0]) + (_rnd(cycle * 3.7 + i * 5.1) * 2.0 - 1.0) * float(lp["spread"])
		var pos := c + Vector2(x, float(a[1]) - 10.0 * p * k)
		draw_circle(pos, lerpf(float(lp["r0"]), float(lp["r1"]), p) * k, _col("dust", float(lp["alpha"]) * (1.0 - p)))


func _butterflies(now: float, k: float, view: Rect2) -> void:
	var b: Dictionary = m["ambient"]["butterflies"]
	var cols: Array = m["colors"]["butterfly"]
	var cx: float = float(game.grid_w) * 0.5 - 0.5
	var cy: float = float(game.grid_h) * 0.5 - 0.5
	var sp := float(b["speed"])
	for i in int(b["count"]):
		var s := i * 2.1
		var gx: float = cx + sin(now * sp * (1.0 + 0.3 * i) + s) * float(game.grid_w) * float(b["area"]) * 0.5 + sin(now * sp * 2.3 + s * 1.7) * 1.2
		var gy: float = cy + cos(now * sp * (0.8 + 0.25 * i) + s * 1.3) * float(game.grid_h) * float(b["area"]) * 0.5
		var pos: Vector2 = game._tile_center(gx, gy) + Vector2(0, -18.0 + sin(now * 3.0 + s) * 4.0)
		if not view.has_point(pos):
			continue
		var flap := 0.25 + 0.75 * absf(sin(now * 14.0 + s))
		var col := Color.html(String(cols[i % cols.size()]))
		draw_set_transform(pos, 0.0, Vector2.ONE * float(b["size"]) / 9.0 * k)
		draw_colored_polygon(PackedVector2Array([Vector2(0, 0), Vector2(-6.0 * flap, -5), Vector2(-5.0 * flap, 3)]), col)
		draw_colored_polygon(PackedVector2Array([Vector2(0, 0), Vector2(6.0 * flap, -5), Vector2(5.0 * flap, 3)]), col)
		draw_line(Vector2(0, -2), Vector2(0, 3), Color(0.2, 0.18, 0.16), 1.4)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _ev_dust(e: Dictionary, p: float, k: float) -> void:
	var cfg: Dictionary = m["events"]["place"]
	var n := int(cfg["puffs"])
	var rad := Vector2(float(cfg["radius"][0]), float(cfg["radius"][1]))
	for i in n:
		var a := float(i) / n * TAU + float(e["seed"])
		var pos: Vector2 = e["pos"] + Vector2(cos(a) * rad.x, sin(a) * rad.y) * (0.35 + 0.65 * _out(p))
		draw_circle(pos, lerpf(4.0, 10.0, p) * k, _col("dust", 0.6 * (1.0 - p)))


func _ev_sparkle(e: Dictionary, p: float, k: float) -> void:
	var cfg: Dictionary = m["events"]["upgrade"]
	for i in int(cfg["stars"]):
		var a := _rnd(float(e["seed"]) + i * 1.7) * TAU
		var r := 14.0 + _rnd(float(e["seed"]) + i * 4.1) * 30.0
		var pos: Vector2 = e["pos"] + Vector2(cos(a) * r, -26.0 - float(cfg["rise"]) * _out(p) + sin(a) * r * 0.4)
		var s := (1.0 - p) * float(cfg["size"]) * k
		var col := _col("sparkle", 1.0 - p)
		draw_line(pos - Vector2(s, 0), pos + Vector2(s, 0), col, 2.5)
		draw_line(pos - Vector2(0, s), pos + Vector2(0, s), col, 2.5)
		draw_circle(pos, s * 0.35, col)


func _ev_text(e: Dictionary, p: float, z: float) -> void:
	var cfg: Dictionary = m["events"]["collect"]
	var font := ThemeDB.fallback_font
	var fs := int(cfg["font"])
	var col: Color = e["color"]
	draw_set_transform(e["pos"] + Vector2(0, -float(cfg["rise"]) * _out(p)), 0.0, Vector2.ONE / z)
	var a := 1.0 - p * p
	draw_string_outline(font, Vector2(-70, 0), String(e["text"]), HORIZONTAL_ALIGNMENT_CENTER, 140.0, fs, 6, Color(0, 0, 0, 0.7 * a))
	draw_string(font, Vector2(-70, 0), String(e["text"]), HORIZONTAL_ALIGNMENT_CENTER, 140.0, fs, Color(col, a))
