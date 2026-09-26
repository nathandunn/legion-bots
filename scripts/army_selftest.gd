extends SceneTree
## Self-test for the army model, run headless and outside the game:
##   godot --headless --path . --script scripts/army_selftest.gd
## It checks the grid maths, the gold and unit refusals, the sandbox switch, that all three
## preset armies fit inside 500 gold / 20 units / their own half without stacking, and that a
## rotten saved army costs its slot rather than crashing. Exit code is the failure count.


func _initialize() -> void:
	var m := MatchManager.new()
	var fails := 0
	# cells and halves
	assert(MatchManager.cell_team(Vector2(0, 5)) == 0)
	assert(MatchManager.cell_team(Vector2(17, 5)) == 1)
	var w := MatchManager.cell_to_world(Vector2(0, 0))
	print("cell(0,0) -> ", w, "  back -> ", MatchManager.world_to_cell(w))
	if MatchManager.world_to_cell(w) != Vector2(0, 0):
		fails += 1
	# budget refusal: as many shields as 500 gold buys, and one more must be refused. The count
	# is derived from the price, not written down - M3 moved the Shield from 50 g to 34 g and a
	# hard-coded 10 turned a correct game into a failing test.
	var want_shields := mini(MatchManager.GOLD_BUDGET / UnitClass.cost_of("shield"), MatchManager.MAX_SIZE)
	var placed := 0
	for row in 12:
		for col in 9:
			var why := m.add_unit(0, "shield", Vector2(col, row), "Tank", "Guardian")
			if why == "":
				placed += 1
	print("shields placed on %d gold: " % MatchManager.GOLD_BUDGET, placed, " of ", want_shields,
		" cost ", m.army_cost(0), " units ", m.army_units(0))
	if placed != want_shields:
		fails += 1
	# other half refused
	print("blue cell for red: '", m.add_unit(0, "brawler", Vector2(12, 5), "Even", "Brawler"), "'")
	if m.add_unit(0, "brawler", Vector2(12, 5), "Even", "Brawler") == "":
		fails += 1
	# sandbox lifts gold but not the unit cap
	m.sandbox = true
	placed = 0
	for row in 12:
		for col in 9:
			if m.add_unit(0, "brawler", Vector2(col, row), "Even", "Brawler") == "":
				placed += 1
	print("sandbox extra units: ", placed, " total ", m.army_units(0), " cost ", m.army_cost(0))
	if m.army_units(0) != MatchManager.MAX_SIZE:
		fails += 1
	# remove
	var before := m.army_units(0)
	var hit := m.unit_at(0, Vector2(0, 0))
	if hit.is_empty() or not m.remove_unit(0, Vector2(0, 0)) or m.army_units(0) != before - 1:
		fails += 1
	# presets fit
	for name_ in MatchManager.PRESET_ARMIES:
		var mm := MatchManager.new()
		mm.apply_preset_army(0, String(name_))
		mm.apply_preset_army(1, String(name_))
		var cells := {}
		for t in 2:
			for sq in mm.armies[t]:
				for c in sq["positions"]:
					if MatchManager.cell_team(Vector2(c)) != t or MatchManager.cell_blocked(Vector2(c)) or cells.has([t, c]):
						fails += 1
					cells[[t, c]] = true
		print("%-13s %2d units  %3dg  %s" % [name_, mm.army_units(0), mm.army_cost(0), mm.army_label(0)])
		if mm.army_units(0) > MatchManager.MAX_SIZE or mm.army_cost(0) > MatchManager.GOLD_BUDGET:
			fails += 1
		mm.free()
	# save/load round trip, and a rotten save
	CustomSlots.set_army(0, "test army", m.armies[0])
	var back := CustomSlots.army_at(0)
	print("saved squads ", back.size(), " units ", m.army_units(0))
	if back.size() != m.armies[0].size():
		fails += 1
	var rotten = [{"name": "bad", "squads": "nonsense"}, {"name": "", "squads": []},
		{"name": "half", "squads": [{"class": "wizard", "cells": [[1, 1]]},
			{"class": "brawler", "type": "Even", "persona": "Brawler", "cells": [[1, 1], [999, 0], "x"]}]}, 17]
	var cleaned = CustomSlots._clean_armies(rotten)
	print("cleaned rotten save -> ", JSON.stringify(cleaned))
	if cleaned.size() != 1 or cleaned[0]["squads"].size() != 1 or cleaned[0]["squads"][0]["cells"].size() != 1:
		fails += 1
	CustomSlots.clear_army(0)
	m.free()
	print("ARMYTEST ", "PASS" if fails == 0 else "FAIL x%d" % fails)
	quit(fails)
