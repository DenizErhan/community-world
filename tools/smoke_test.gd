extends SceneTree
## Quick smoke test (runs headless):
##   godot --headless --path . --script res://tools/smoke_test.gd
## Exits with code 1 on failure.

const Loc := preload("res://loc.gd")

var failures: int = 0


func check(cond: bool, label: String) -> void:
	if cond:
		print("  ok    - ", label)
	else:
		failures += 1
		printerr("  FAIL  - ", label)


func _initialize() -> void:
	var main: Node2D = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main._reset_game()

	print("Coordinates")
	var rt_ok := true
	for gx in range(main.grid_w):
		for gy in range(main.grid_h):
			var c: Vector2 = main._tile_center(gx, gy)
			if main._world_to_tile(c) != Vector2i(gx, gy):
				rt_ok = false
			if main._world_to_tile(c + Vector2(12, 5)) != Vector2i(gx, gy):
				rt_ok = false
	check(rt_ok, "tile center <-> world conversion is consistent on every tile")

	print("Rules")
	check(main._check_place(Vector2i(1, 1), "farm") != "", "farm cannot be built before a hut")
	main.selected = "hut"
	main._tap(Vector2i(6, 6))
	check(main.buildings.has(Vector2i(6, 6)), "hut built")
	check(absf(float(main.stock["stone"]) - 20.0) < 0.5, "hut cost 10 stone")
	main._tap(Vector2i(6, 6))
	check(main.buildings.size() == 1, "cannot build on an occupied tile")
	main.selected = "quarry"
	main._tap(Vector2i(7, 6))
	check(main.buildings.has(Vector2i(7, 6)), "quarry built")
	main.selected = "farm"
	main._tap(Vector2i(8, 6))
	check(not main.buildings.has(Vector2i(8, 6)), "farm refused when stone is short")

	print("Production and storage")
	var before: float = main.stock["stone"]
	main._process(10.0)
	check(absf(float(main.stock["stone"]) - before - 5.0) < 0.5, "quarry produced +5 stone in 10 s")
	main._process(100000.0)
	check(float(main.stock["stone"]) <= float(main.caps["stone"]) + 0.001, "stock never exceeds the cap")
	check(float(main.caps["stone"]) == 75.0, "hut raised storage 50 -> 75")

	print("Save / load")
	main._save_game()
	var main2: Node2D = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main2)
	await process_frame
	check(main2.buildings.size() == 2, "2 buildings restored from save")
	check(main2.buildings.has(Vector2i(7, 6)), "building position preserved")
	main2.queue_free()

	print("Demolish")
	main.selected = "_remove"
	main._tap(Vector2i(7, 6))
	check(not main.buildings.has(Vector2i(7, 6)), "quarry demolished")

	print("Design system")
	var tokens_ok: bool = main.tok.has("ages") and main.tok["ages"].has(main.age)
	check(tokens_ok, "tokens loaded and the current age has a palette")
	var tex_ok := true
	for id in main.def_order:
		if main.tex_building.get(id) == null:
			tex_ok = false
	check(tex_ok, "every building has a rasterized sprite for the current age")
	check(main.tex_ground.size() == 2 and main.tex_ground[0] != null and main.tex_ground[1] != null, "both ground variants loaded")
	var all_ages_ok := true
	for a in main.tok["ages"]:
		for id in main.def_order:
			if not FileAccess.file_exists("res://assets/buildings/%s_%s.svg" % [id, a]):
				all_ages_ok = false
	check(all_ages_ok, "assets exist for every building in every age")

	print("Localization")
	Loc.init_locale("xx")
	check(Loc.lang == "en", "unsupported language falls back to English")
	var missing := true
	for r in main.res_defs:
		if Loc.t("res.%s.name" % r) == "res.%s.name" % r:
			missing = false
	for id in main.def_order:
		for k in ["name", "short"]:
			if Loc.t("building.%s.%s" % [id, k]) == "building.%s.%s" % [id, k]:
				missing = false
	check(missing, "every resource and building has English strings")
	check(Loc.t("toast.built", {"name": "Farm"}) == "Farm built.", "placeholders are substituted")
	check(Loc.t("no.such.key") == "no.such.key", "missing keys return the key (visible gap, no crash)")

	main._reset_game()
	check(main.buildings.is_empty(), "reset cleared the village")
	check(float(main.stock["stone"]) == 30.0, "reset restored the starting stock")

	print("Result: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)
