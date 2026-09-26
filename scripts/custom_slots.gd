class_name CustomSlots
extends RefCounted
## Five personality slots and five type slots you fill in yourself, saved on the machine and
## offered everywhere a preset is - the team dropdowns, the per-robot menus and the key.
##
## Saved to `user://custom_slots.json`, which on the web Godot keeps in IndexedDB, so they
## survive a reload and a redeploy. Nothing leaves the browser.
##
## Everything here is static: the slots belong to the player, not to a match, and the manager
## has to be able to resolve a name to a Personality or a type long after the HUD built it.
##
## PER-GAME ADAPTER: the three functions under "the other half" are the only lines that differ
## between the games in the suite - Rock Bots and Melee Bots have RobotType, Dodgeball Bots and
## Dance-Off Bots call the same idea PlayerBuild.

const MAX_SLOTS := 5
const SAVE_PATH := "user://custom_slots.json"

## [{"name": String, "traits": {trait: float}}] - only filled slots are listed.
static var personas: Array = []
## [{"name": String, "props": {prop: float}}]
static var builds: Array = []
## [{"name": String, "squads": [{"class","type","persona","cells":[[col,row], ...]}]}] - whole
## armies off the placement screen, the third kind of slot.
static var armies: Array = []
static var _loaded := false


# ------------------------------------------------------------------ the other half

static func build_props() -> Array:
	return RobotType.PROPS


static func build_prop_help() -> Dictionary:
	return RobotType.PROP_HELP


static func build_presets() -> Dictionary:
	return RobotType.PRESETS


static func make_build(d: Dictionary):
	return RobotType.new(d)


# ------------------------------------------------------------------ resolving a name

## True if this name belongs to a slot the player filled in rather than a shipped preset.
static func is_custom_persona(n: String) -> bool:
	for s in personas:
		if String(s["name"]) == n:
			return true
	return false


static func is_custom_build(n: String) -> bool:
	for s in builds:
		if String(s["name"]) == n:
			return true
	return false


## The manager asks for a name and gets a Personality, whether that name is a preset, one of
## the five slots, or nonsense (in which case the preset lookup's own fallback answers).
static func resolve_persona(n: String) -> Personality:
	for s in personas:
		if String(s["name"]) == n:
			return Personality.new(s["traits"])
	return Personality.preset(n)


static func resolve_build(n: String):
	for s in builds:
		if String(s["name"]) == n:
			return make_build(s["props"])
	return make_build(build_presets().get(n, {})) if build_presets().has(n) else _preset_build(n)


static func _preset_build(n: String):
	# Random and anything unknown go through the type's own preset(), which handles them
	return RobotType.preset(n)


static func army_names() -> Array:
	var out: Array = []
	for s in armies:
		out.append(String(s["name"]))
	return out


static func army_slot(n: String) -> int:
	for i in armies.size():
		if String(armies[i]["name"]) == n:
			return i
	return -1


## The squads of a saved army, ready for MatchManager (cells as Vector2).
static func resolve_army(n: String) -> Array:
	for s in armies:
		if String(s["name"]) == n:
			return _squads_to_runtime(s["squads"])
	return []


static func army_at(idx: int) -> Array:
	if idx < 0 or idx >= armies.size():
		return []
	return _squads_to_runtime(armies[idx]["squads"])


static func _squads_to_runtime(squads: Array) -> Array:
	var out: Array = []
	for sq in squads:
		var ps: Array = []
		for c in sq["cells"]:
			ps.append(Vector2(float(c[0]), float(c[1])))
		out.append({"class": String(sq["class"]), "type": String(sq["type"]),
			"persona": String(sq["persona"]), "positions": ps})
	return out


## Store a whole army in slot `idx`. `squads` is the manager's runtime form; a blank name
## clears the slot, exactly as it does for the other two kinds.
static func set_army(idx: int, slot_name: String, squads: Array) -> void:
	slot_name = slot_name.strip_edges()
	while armies.size() <= idx and armies.size() < MAX_SLOTS:
		armies.append({"name": "", "squads": []})
	if idx < 0 or idx >= armies.size():
		return
	if slot_name == "":
		armies.remove_at(idx)
		save()
		return
	var stored: Array = []
	for sq in squads:
		var cells: Array = []
		for c in sq["positions"]:
			cells.append([int(Vector2(c).x), int(Vector2(c).y)])
		stored.append({"class": String(sq["class"]), "type": String(sq["type"]),
			"persona": String(sq["persona"]), "cells": cells})
	armies[idx] = {"name": _unique(slot_name, army_names(), idx), "squads": stored}
	save()


static func clear_army(idx: int) -> void:
	if idx >= 0 and idx < armies.size():
		armies.remove_at(idx)
		save()


static func persona_names() -> Array:
	var out: Array = []
	for s in personas:
		out.append(String(s["name"]))
	return out


static func build_names() -> Array:
	var out: Array = []
	for s in builds:
		out.append(String(s["name"]))
	return out


## Where a custom slot sits in its own list, for picking its badge. -1 if it is not one.
static func persona_slot(n: String) -> int:
	for i in personas.size():
		if String(personas[i]["name"]) == n:
			return i
	return -1


static func build_slot(n: String) -> int:
	for i in builds.size():
		if String(builds[i]["name"]) == n:
			return i
	return -1


# ------------------------------------------------------------------ editing

## Write slot `idx`, creating it if the list is shorter. A blank name clears the slot instead,
## which is the only way to get rid of one.
static func set_persona(idx: int, slot_name: String, traits: Dictionary) -> void:
	slot_name = slot_name.strip_edges()
	while personas.size() <= idx and personas.size() < MAX_SLOTS:
		personas.append({"name": "", "traits": {}})
	if idx < 0 or idx >= personas.size():
		return
	if slot_name == "":
		personas.remove_at(idx)
	else:
		personas[idx] = {"name": _unique(slot_name, persona_names(), idx), "traits": traits.duplicate()}
	save()


static func set_build(idx: int, slot_name: String, props: Dictionary) -> void:
	slot_name = slot_name.strip_edges()
	while builds.size() <= idx and builds.size() < MAX_SLOTS:
		builds.append({"name": "", "props": {}})
	if idx < 0 or idx >= builds.size():
		return
	if slot_name == "":
		builds.remove_at(idx)
	else:
		builds[idx] = {"name": _unique(slot_name, build_names(), idx), "props": props.duplicate()}
	save()


static func clear_persona(idx: int) -> void:
	if idx >= 0 and idx < personas.size():
		personas.remove_at(idx)
		save()


static func clear_build(idx: int) -> void:
	if idx >= 0 and idx < builds.size():
		builds.remove_at(idx)
		save()


## Two slots with the same name would be indistinguishable in a dropdown, so the second one
## gets a numeral. Reserved names are taken by the pickers themselves and cannot be used.
static func _unique(wanted: String, taken: Array, skip_idx: int) -> String:
	const RESERVED := ["Team", "Random", "Custom", "Even", "Balanced"]
	if wanted in RESERVED:
		wanted += "*"
	var candidate := wanted
	var n := 2
	while true:
		var clash := false
		for i in taken.size():
			if i != skip_idx and String(taken[i]) == candidate:
				clash = true
				break
		if not clash:
			return candidate
		candidate = "%s %d" % [wanted, n]
		n += 1
	return candidate


# ------------------------------------------------------------------ saving

static func load_slots() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	personas = _clean(parsed.get("personas", []), "traits", Personality.TRAITS)
	builds = _clean(parsed.get("builds", []), "props", build_props())
	armies = _clean_armies(parsed.get("armies", []))


## Never trust what came off disk: an older version, a hand-edited file or a half-written save
## should cost you your slots, not crash the game on startup.
static func _clean(raw, key: String, fields: Array) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var nm := String(entry.get("name", "")).strip_edges()
		if nm == "" or out.size() >= MAX_SLOTS:
			continue
		var vals := {}
		var src = entry.get(key, {})
		if typeof(src) != TYPE_DICTIONARY:
			continue
		for fld in fields:
			vals[fld] = clampf(float(src.get(fld, 0.2)), 0.0, 1.0)
		out.append({"name": nm, key: vals})
	return out


## Armies are a good deal more structure than a bag of floats, so every field is checked on
## the way in: a class that no longer exists, a cell off the grid, a squad that is not a
## dictionary, an army over the unit cap - any of them costs that slot and nothing else.
static func _clean_armies(raw) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var nm := String(entry.get("name", "")).strip_edges()
		if nm == "" or out.size() >= MAX_SLOTS:
			continue
		var raw_squads = entry.get("squads", [])
		if typeof(raw_squads) != TYPE_ARRAY:
			continue
		var squads: Array = []
		var units := 0
		var seen := {}
		for sq in raw_squads:
			if typeof(sq) != TYPE_DICTIONARY:
				continue
			var cid := String(sq.get("class", "")).strip_edges().to_lower()
			if not UnitClass.is_known(cid) or seen.has(cid):
				continue
			var raw_cells = sq.get("cells", [])
			if typeof(raw_cells) != TYPE_ARRAY:
				continue
			var cells: Array = []
			for c in raw_cells:
				if typeof(c) != TYPE_ARRAY or (c as Array).size() < 2:
					continue
				var col := int(c[0])
				var row := int(c[1])
				if not MatchManager.cell_in_grid(Vector2(col, row)):
					continue
				if units >= MatchManager.MAX_SIZE:
					break
				cells.append([col, row])
				units += 1
			if cells.is_empty():
				continue
			seen[cid] = true
			squads.append({"class": cid, "type": String(sq.get("type", "Even")),
				"persona": String(sq.get("persona", "Balanced")), "cells": cells})
		if squads.is_empty():
			continue
		out.append({"name": nm, "squads": squads})
	return out


static func save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"personas": personas, "builds": builds, "armies": armies}))
	f.close()
