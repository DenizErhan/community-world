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


## Builds through the same steps a player takes: pick the building, put the ghost on a tile, tick.
func build_at(main: Node2D, id: String, t: Vector2i) -> void:
	main._begin_place(id)
	main._set_pending(t)
	main._confirm_place()


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

	print("Placement ghost")
	main._begin_place("hut")
	check(main.pending_id == "hut", "choosing a building puts a ghost on the grid")
	check(main._in_grid(main.pending_tile) and not main.buildings.has(main.pending_tile), "the ghost starts on a free tile")
	check(main.place_row.visible and not main.palette_row.visible, "the tick/cross bar replaces the palette")
	check(main.buildings.is_empty(), "nothing is built before the tick")
	main._tap(Vector2i(6, 6))
	check(main.pending_tile == Vector2i(6, 6) and main.buildings.is_empty(), "tapping a tile only moves the ghost")
	main._nudge(Vector2i(1, 0))
	check(main.pending_tile == Vector2i(7, 6), "an arrow moves the ghost one tile")
	main._set_pending(Vector2i(-5, 99))
	check(main.pending_tile == Vector2i(0, main.grid_h - 1), "the ghost stays inside the grid")
	main._set_pending(Vector2i(6, 6))
	var centre: Vector2 = main._tile_center(6, 6)
	check(main._on_ghost(centre), "a press on the ghost grabs it")
	check(not main._on_ghost(centre + Vector2(900, 900)), "a press far from the ghost pans the camera instead")
	main._cancel_place()
	check(main.pending_id == "" and main.buildings.is_empty(), "the cross cancels without building")
	check(float(main.stock["stone"]) == 30.0, "cancelling spends nothing")
	check(main.palette_row.visible and not main.place_row.visible, "the palette comes back after cancel")

	print("Rules")
	main._begin_place("farm")
	check(main._pending_error() != "" and main.btn_confirm.disabled, "farm cannot be confirmed before a hut (tick is disabled)")
	main._confirm_place()
	check(main.buildings.is_empty(), "confirming an invalid ghost builds nothing")
	main._cancel_place()
	build_at(main, "hut", Vector2i(6, 6))
	check(main.buildings.has(Vector2i(6, 6)), "hut built with the tick")
	check(absf(float(main.stock["stone"]) - 20.0) < 0.5, "hut cost 10 stone")
	check(main.pending_id == "", "the ghost is gone after building")
	main._begin_place("hut")
	main._set_pending(Vector2i(6, 6))
	check(main._pending_error() != "", "cannot place on an occupied tile")
	main._cancel_place()
	build_at(main, "quarry", Vector2i(7, 6))
	check(main.buildings.has(Vector2i(7, 6)), "quarry built")
	main._begin_place("farm")
	main._set_pending(Vector2i(8, 6))
	check(main._pending_error() != "", "farm refused when stone is short")
	main._confirm_place()
	check(not main.buildings.has(Vector2i(8, 6)), "confirming without enough stone builds nothing")
	main._cancel_place()

	print("Production and storage")
	var before: float = main.stock["stone"]
	main._process(10.0)
	check(float(main.stock["stone"]) == before, "production does not go straight into storage")
	check(absf(float(main.bucket[Vector2i(7, 6)]["stone"]) - 5.0) < 0.01, "quarry holds +5 stone after 10 s")
	main._collect_and_report([Vector2i(7, 6)])
	check(absf(float(main.stock["stone"]) - before - 5.0) < 0.5, "collecting moves +5 stone into storage")
	check(main._bucket_total(Vector2i(7, 6)) < 0.01, "the building is empty after collecting")
	main._process(100000.0)
	var cap_b: float = main._bucket_cap_at("quarry", 1, "stone")
	check(absf(float(main.bucket[Vector2i(7, 6)]["stone"]) - cap_b) < 0.01 and cap_b == 60.0, "a building stops producing when its store is full (120 s of output)")
	main.stock["stone"] = 40.0
	main._collect_all()
	check(float(main.stock["stone"]) <= float(main.caps["stone"]) + 0.001, "storage never exceeds the cap")
	check(float(main.stock["stone"]) >= float(main.caps["stone"]) - 1.0 and main._bucket_total(Vector2i(7, 6)) > 0.0, "what does not fit stays in the building")
	check(float(main.caps["stone"]) == 75.0, "hut raised storage 50 -> 75")

	print("Tapping a building")
	var hut_c: Vector2 = main._tile_center(6, 6)
	for z in [main.START_ZOOM, 1.0, main.ZOOM_MAX]:
		main.cam.zoom = Vector2(z, z)
		var tag := "zoom %.1f: " % z
		# the quarry stands on the next tile (7, 6); both hit boxes overlap when zoomed out
		check(main._pick_tile(hut_c + Vector2(0, -30)) == Vector2i(6, 6), tag + "a tap on the hut's body picks the hut, not a neighbour")
		check(main._pick_tile(main._tile_center(7, 6) + Vector2(0, -20)) == Vector2i(7, 6), tag + "a tap on the quarry's body picks the quarry")
		check(main._pick_tile(hut_c + Vector2(0, -400)) != Vector2i(6, 6), tag + "a tap far above the roof does not pick the hut")
	main.cam.zoom = Vector2(main.START_ZOOM, main.START_ZOOM)
	check(main._world_to_tile(hut_c + Vector2(0, -45)) != Vector2i(6, 6), "(the roof is drawn over a different ground tile)")
	check(main._pick_tile(hut_c + Vector2(0, -45)) == Vector2i(6, 6), "a tap on the roof picks the hut even though the ground tile under it is another")
	check(main._pick_tile(hut_c + Vector2(500, 0)) == main._world_to_tile(hut_c + Vector2(500, 0)), "a tap on open ground picks that ground tile")

	print("Moving a building")
	var stone_before_move: float = main.stock["stone"]
	main._tap(Vector2i(7, 6))
	check(main.pending_id == "" and main.sel_tile == Vector2i(7, 6) and main.action_menu.visible, "tapping a building only selects it and opens the menu")
	check(main.buildings.has(Vector2i(7, 6)), "selecting does not move or change anything")
	main._tap(Vector2i(12, 12))
	check(main.sel_tile == Vector2i(-1, -1) and not main.action_menu.visible, "tapping open ground deselects")
	main._tap(Vector2i(7, 6))
	main._on_upgrade_pressed()
	check(main.buildings.has(Vector2i(7, 6)) and main.sel_tile == Vector2i(7, 6), "upgrade is a placeholder and changes nothing")
	main._on_info_pressed()
	check(main.sel_tile == Vector2i(7, 6), "info keeps the selection")
	main._on_move_pressed()
	check(main.pending_id == "quarry" and main.moving_from == Vector2i(7, 6) and not main.action_menu.visible, "Move picks the building up and hides the menu")
	check(main.buildings.has(Vector2i(7, 6)), "the building stays where it was until the tick")
	main._set_pending(Vector2i(6, 6))
	check(main._pending_error() != "", "cannot move onto an occupied tile")
	main._set_pending(Vector2i(9, 9))
	main._confirm_place()
	check(main.buildings.has(Vector2i(9, 9)) and not main.buildings.has(Vector2i(7, 6)), "tick moves the building")
	check(float(main.stock["stone"]) == stone_before_move, "moving is free")
	check(absf(float(main.rates["stone"]) - 0.5) < 0.001, "production is unchanged by moving")
	main._tap(Vector2i(9, 9))
	main._on_move_pressed()
	main._set_pending(Vector2i(3, 3))
	main._cancel_place()
	check(main.buildings.has(Vector2i(9, 9)) and not main.buildings.has(Vector2i(3, 3)), "cross puts the building back")

	print("Save / load")
	main._save_game()
	var main2: Node2D = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main2)
	await process_frame
	check(main2.buildings.size() == 2, "2 buildings restored from save")
	check(main2.buildings.has(Vector2i(9, 9)), "moved building position is saved")
	check(main2.pending_id == "", "no ghost after loading a village that has buildings")
	main2.queue_free()

	print("Demolish")
	main._tap(Vector2i(9, 9))
	main._on_remove_pressed()
	check(main.buildings.has(Vector2i(9, 9)) and main.remove_armed > 0.0, "first Remove tap only arms the button")
	main._tap(Vector2i(6, 6))
	check(main.remove_armed == 0.0, "selecting another building disarms Remove")
	main._tap(Vector2i(9, 9))
	main._on_remove_pressed()
	check(main._refund_of("quarry")["stone"] == 6.0, "refund is half the cost, e.g. 6 of the quarry's 12 stone")
	main._on_remove_pressed()
	check(not main.buildings.has(Vector2i(9, 9)) and main.sel_tile == Vector2i(-1, -1), "second Remove tap demolishes the quarry")

	print("Upgrades")
	main.buildings[Vector2i(3, 3)] = "hut"
	main.buildings[Vector2i(4, 3)] = "farm"
	main.levels[Vector2i(3, 3)] = 1
	main.levels[Vector2i(4, 3)] = 1
	main._recalc()
	main.stock["stone"] = 70.0
	main._tap(Vector2i(4, 3))
	main._on_upgrade_pressed()
	check(main._level(Vector2i(4, 3)) == 1, "a building cannot pass the level of the hut it needs")
	check(main._upgrade_cost("hut", 1)["stone"] == 18.0, "hut level 2 costs 18 stone (10 x 1.8)")
	main._tap(Vector2i(3, 3))
	main._on_upgrade_pressed()
	check(main._level(Vector2i(3, 3)) == 2 and absf(float(main.stock["stone"]) - 52.0) < 0.01, "upgrading the hut costs 18 stone and raises its level")
	check(float(main.caps["stone"]) == 50.0 + 25.0 + 50.0, "hut level 2 doubles its storage bonus (25 -> 50)")
	main._tap(Vector2i(4, 3))
	main._on_upgrade_pressed()
	check(main._level(Vector2i(4, 3)) == 2, "farm can now reach level 2")
	check(absf(main._rate_at("farm", 2, "food") - 0.6) < 0.001 and absf(float(main.rates["food"]) - 0.6) < 0.001, "farm level 2 produces 1.5x")
	check(main._bucket_cap_at("farm", 2, "food") > main._bucket_cap_at("farm", 1, "food"), "a higher level holds more output")
	main.stock["stone"] = 70.0
	main._tap(Vector2i(3, 3))
	main._on_upgrade_pressed()
	main.stock["stone"] = 70.0
	main._on_upgrade_pressed()
	check(main._level(Vector2i(3, 3)) == 3, "hut stops at the maximum level")
	main.stock["stone"] = 0.0
	main._tap(Vector2i(4, 3))
	main._on_upgrade_pressed()
	check(main._level(Vector2i(4, 3)) == 2, "upgrade needs the resources")
	main.stock["stone"] = 70.0
	main._on_upgrade_pressed()
	check(main._level(Vector2i(4, 3)) == 3, "farm reaches level 3")
	var refund: Dictionary = main._refund_of("farm", 3)
	check(float(refund["stone"]) == floorf((15.0 + 27.0 + 49.0) * 0.5), "removing refunds half of everything invested, upgrades included")
	main._save_game()
	var main3: Node2D = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main3)
	await process_frame
	check(main3._level(Vector2i(3, 3)) == 3 and main3._level(Vector2i(4, 3)) == 3, "levels are saved and restored")
	main3.queue_free()
	check(not main._age_ready(), "age-up is not ready until the required levels are reached")
	check(main._age_progress().size() == 4, "age-up lists its four requirements")

	print("Animation")
	var loops: Dictionary = main.tok["motion"]["loops"]
	for id in main.def_order:
		check(loops.has(id) and (loops[id] as Array).size() > 0, "%s has an animation loop in the design tokens" % id)
	check(main.fx != null and main.fx.enabled, "the animation layer is on")
	var fx_before: int = main.fx.event_count()
	main.fx.burst_dust(Vector2i(6, 6))
	main.fx.sparkle(Vector2i(6, 6))
	main.fx.float_text(main._badge_centre(Vector2i(6, 6)), "+5", Color.WHITE)
	check(main.fx.event_count() == fx_before + 3, "one-shot effects are queued")
	for i in 5:
		main.fx.queue_redraw()
		await process_frame      # lets fx._draw run: loops, butterflies and events (errors would print)
	main.fx.enabled = false
	main.fx._process(0.1)
	check(main.fx.event_count() == 0, "turning animation off clears running effects")
	main.fx.enabled = true

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
	var icons_ok := true
	for n in ["confirm", "cancel", "arrow_nw", "arrow_ne", "arrow_sw", "arrow_se"]:
		if not FileAccess.file_exists("res://assets/ui/icon_%s.svg" % n):
			icons_ok = false
	check(icons_ok, "tick, cross and the four arrow icons exist")
	check(main.btn_confirm.icon != null and main.btn_cancel.icon != null, "tick and cross buttons have their icons loaded")

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
	for k in ["place.new", "place.move", "toast.moved", "toast.welcome"]:
		if Loc.t(k) == k:
			missing = false
	check(missing, "every resource, building and placement message has English strings")
	check(Loc.t("toast.built", {"name": "Farm"}) == "Farm built.", "placeholders are substituted")
	check(Loc.t("no.such.key") == "no.such.key", "missing keys return the key (visible gap, no crash)")

	main._reset_game()
	check(main.buildings.is_empty(), "reset cleared the village")
	check(float(main.stock["stone"]) == 30.0, "reset restored the starting stock")

	print("Result: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)
