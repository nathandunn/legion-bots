class_name MatchManager
extends Node
## Spawns teams + rocks, runs the clock, tallies stats, decides the winner.

signal match_started(match_index: int)
signal match_ended(result: Dictionary)
signal celebration_finished(match_index: int)
signal dance_started(match_index: int)

const MAX_SIZE := 20   # per side; raise when the ragdoll cap and spatial hash land
static var TEAM_SIZE := 20   # the *quick battle* size, per side, 1..MAX_SIZE; --size=N or ?size=N
## Gold a side in the army builder. A Sandbox toggle lifts it; MAX_SIZE never lifts.
const GOLD_BUDGET := 500
## The placement grid: 2 m cells over the whole 40x40 floor, Red the low-x half.
const CELL := 2.0
const GRID_W := 18
## 12 rows, not 18: the band of the field an overhead camera can show whole on a phone AND
## on a 16:9 laptop. The walls at |z| > 12 are still there, they are just not build space.
const GRID_H := 12
## Who stands in front when an army is laid out for you: shields, then fists, then rocks.
const FRONT_ORDER := {"shield": 0, "brawler": 1, "mixed": 1, "slinger": 2}
## Three armies that fit inside 500 gold and 20 units, for the preset buttons, the
## "fill enemy" button and the headless --red=/--blue= arguments.
const PRESET_ARMIES := {
	"Brawler Mob": [{"class": "brawler", "count": 20, "type": "Bruiser", "persona": "Brawler"}],
	"Slinger Line": [{"class": "shield", "count": 5, "type": "Tank", "persona": "Guardian"},
		{"class": "slinger", "count": 8, "type": "Sniper", "persona": "Slinger"}],
	"Shield Wall": [{"class": "shield", "count": 7, "type": "Tank", "persona": "Guardian"},
		{"class": "slinger", "count": 5, "type": "Sniper", "persona": "Slinger"}],
}
const MATCH_TIME := 150.0   # only the headless sims are capped (time_limit); a real match runs until a team is gone
const ARENA_HALF := 20.0
const ROCKS_PER_ROBOT := 0.5   # ~1 rock per 2 robots
const TEAM_NAMES := ["Red", "Blue"]
const TEAM_COLORS := [Color(0.9, 0.3, 0.25), Color(0.25, 0.5, 0.95)]

static func _blank_overrides() -> Array:
	var a: Array = []
	for i in MAX_SIZE:
		a.append("")
	return a


var world: Node3D
var arena: Arena
var team_personalities: Array[Personality] = [Personality.preset("Slinger"), Personality.preset("Brawler")]
var team_preset_names: Array[String] = ["Slinger", "Brawler"]
## What each team is made of, and the per-robot overrides. An entry of "" in the two override
## arrays means "whatever the team is set to", which is how the whole-team pickers stay
## meaningful after you have fiddled with one robot.
var team_types: Array[RobotType] = [RobotType.preset("Even"), RobotType.preset("Even")]
var team_type_names: Array[String] = ["Even", "Even"]
## Per-robot overrides for the quick battle, one entry per possible robot ("" = follow the
## team). Full length from the start: the HUD builds its pickers before the first spawn.
var player_persona := [_blank_overrides(), _blank_overrides()]
var player_type := [_blank_overrides(), _blank_overrides()]
## The army each side has been given in the placement screen: a list of squads, each
## {"class": id, "type": name, "persona": name, "positions": [Vector2 grid cells]}.
## An empty list means "nothing placed" and the side spawns the quick battle instead.
var armies: Array = [[], []]
## Sandbox lifts the gold budget (the 20-unit cap stays).
var sandbox := false
## Filled in at spawn: how many actually took the field, and what they cost.
var team_count := [0, 0]
var gold_spent := [0, 0]
var robots: Array[Robot] = []
var rocks: Array[Rock] = []
var time_left := INF
var time_limit := -1.0  # <= 0: no limit
var elapsed := 0.0
var running := false
var match_index := 0
var stats := {}
var rng := RandomNumberGenerator.new()
var _alive_cache: Array[Robot] = []
var _cache_frame := -1
var robot_stats := {}
var dance_clock := 0.0  # shared beat for the winners' dance
# victory celebration: "" (none) -> gather -> dance -> teabag -> done
const GATHER_CAP := 7.0
const TEABAG_CAP := 40.0
var celebration_phase := ""
var _phase_timer := 0.0
var _celebrants: Array[Robot] = []


func start_match(seed_value: int = -1) -> void:
	clear()
	if seed_value < 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	match_index += 1
	time_left = time_limit if time_limit > 0.0 else INF
	elapsed = 0.0
	stats = _fresh_stats()
	robot_stats = {}

	for t in 2:
		while player_persona[t].size() < TEAM_SIZE:
			player_persona[t].append("")
		while player_type[t].size() < TEAM_SIZE:
			player_type[t].append("")

	# who is taking the field, on both sides, before anyone is built
	var plans := [_team_plan(0), _team_plan(1)]
	for t in 2:
		team_count[t] = plans[t].size()
		gold_spent[t] = 0
		for e in plans[t]:
			gold_spent[t] += UnitClass.cost_of(String(e["class"]))

	# interleave + shuffle spawn order so neither team gets first-strike from tree order
	var slots := []
	for t in 2:
		for i in plans[t].size():
			slots.append([t, i])
	for k in range(slots.size() - 1, 0, -1):
		var j := rng.randi_range(0, k)
		var tmp = slots[k]
		slots[k] = slots[j]
		slots[j] = tmp
	for slot in slots:
		var t: int = slot[0]
		var i: int = slot[1]
		var entry: Dictionary = plans[t][i]
		var r := Robot.new()
		r.team = t
		r.team_color = TEAM_COLORS[t]
		r.robot_name = "%s%d" % [TEAM_NAMES[t][0], i + 1]
		r.unit_class = UnitClass.of(String(entry["class"]))
		# a robot follows its team unless it has been given its own personality or type
		var pname: String = String(entry["persona"])
		if pname == "":
			r.personality = team_personalities[t].jittered(rng, 0.08)
		else:
			r.personality = CustomSlots.resolve_persona(pname).jittered(rng, 0.05)
		var tname: String = String(entry["type"])
		if tname == "":
			r.robot_type = team_types[t].jittered(rng, 0.02)
			r.type_name = team_type_names[t]
		else:
			r.robot_type = CustomSlots.resolve_build(tname).jittered(rng, 0.02)
			r.type_name = tname
		r.manager = self
		r.rng = RandomNumberGenerator.new()
		r.rng.seed = rng.randi()
		r.position = entry["pos"]
		# face the other half, whatever the spawn point (forward is -Z, so this is +X / -X)
		r.rotation.y = -PI * 0.5 if t == 0 else PI * 0.5
		r.damaged.connect(_on_damaged)
		r.died.connect(_on_died)
		r.threw.connect(_on_threw)
		r.punched.connect(_on_punched)
		r.kicked.connect(_on_kicked)
		r.knocked_down.connect(_on_knocked_down)
		r.blocked.connect(_on_blocked)
		world.add_child(r)
		robots.append(r)
		robot_stats[r.robot_name] = {"name": r.robot_name, "team": t,
			"preset": (pname if pname != "" else team_preset_names[t]), "type": r.type_name,
			"class": r.unit_class.label, "class_id": r.unit_class.id, "cost": r.unit_class.cost,
			"dmg_rock": 0.0, "dmg_punch": 0.0, "dmg_kick": 0.0, "dmg_taken": 0.0, "throws": 0, "rock_hits": 0,
			"punches": 0, "punch_hits": 0, "kicks": 0, "kick_hits": 0, "knockdowns": 0, "blocks": 0,
			"kills": 0, "hp": r.hp, "alive": true}

	print("LEGION match %d: Red %s vs Blue %s - %d robots on the field" % [
		match_index, army_summary(0), army_summary(1), robots.size()])
	var n_rocks := int(ceil(maxi(team_count[0], team_count[1]) * 2 * ROCKS_PER_ROBOT))
	var tries := 0
	while rocks.size() < n_rocks and tries < 200:
		tries += 1
		var x := rng.randf_range(-11.0, 11.0)
		var z := rng.randf_range(-16.0, 16.0)
		if arena != null and not arena.is_clear(x, z):
			continue
		var rk := Rock.new()
		rk.manager = self
		rk.mass_kg = [1.2, 2.0, 2.0, 3.2][rng.randi_range(0, 3)]  # pebbles, stones and a lump
		rk.position = Vector3(x, 0.6, z)
		world.add_child(rk)
		rocks.append(rk)

	running = true
	dance_clock = 0.0
	celebration_phase = ""
	_celebrants.clear()
	match_started.emit(match_index)


# ---------------------------------------------------------------- the army model
##
## An army is a list of squads. A squad is one unit class, a type, a personality and the
## cells its units stand on - never an order. What the units then do comes out of the
## personality and the class fence, exactly as it does for a quick battle.

## Centre of a grid cell, in metres. Cell (0,0) is the far Red corner.
static func cell_to_world(cell: Vector2) -> Vector3:
	return Vector3(-GRID_W * CELL * 0.5 + CELL * (cell.x + 0.5), 0.0,
		-GRID_H * CELL * 0.5 + CELL * (cell.y + 0.5))


static func world_to_cell(p: Vector3) -> Vector2:
	return Vector2(floorf((p.x + GRID_W * CELL * 0.5) / CELL), floorf((p.z + GRID_H * CELL * 0.5) / CELL))


static func cell_in_grid(cell: Vector2) -> bool:
	return cell.x >= 0.0 and cell.x < GRID_W and cell.y >= 0.0 and cell.y < GRID_H


## Which half a cell is in. The grid splits down the middle: Red low x, Blue high x.
static func cell_team(cell: Vector2) -> int:
	return 0 if cell.x < GRID_W * 0.5 else 1


## A cell a cover block stands in (plus a body's width) is not somewhere you can put a unit.
static func cell_blocked(cell: Vector2) -> bool:
	var p := cell_to_world(cell)
	for c in Arena.COVER:
		if absf(p.x - float(c[0])) < float(c[2]) * 0.5 + 0.9 and absf(p.z - float(c[1])) < float(c[3]) * 0.5 + 0.9:
			return true
	return false


func army_units(t: int) -> int:
	var n := 0
	for sq in armies[t]:
		n += (sq["positions"] as Array).size()
	return n


func army_cost(t: int) -> int:
	var g := 0
	for sq in armies[t]:
		g += UnitClass.cost_of(String(sq["class"])) * (sq["positions"] as Array).size()
	return g


func gold_left(t: int) -> int:
	return GOLD_BUDGET - army_cost(t)


## The squad of this class for this team, made if it is not there yet. One squad per class:
## adding a class either starts its squad or selects the one that exists.
func ensure_squad(t: int, class_id: String, type_name: String = "Even", persona_name: String = "Balanced") -> Dictionary:
	var cid := UnitClass.normalize_id(class_id)
	for sq in armies[t]:
		if String(sq["class"]) == cid:
			return sq
	var made := {"class": cid, "type": type_name, "persona": persona_name, "positions": []}
	armies[t].append(made)
	return made


func find_squad(t: int, class_id: String) -> Dictionary:
	var cid := UnitClass.normalize_id(class_id)
	for sq in armies[t]:
		if String(sq["class"]) == cid:
			return sq
	return {}


## Whatever stands on this cell, as {"squad": squad, "index": i}, or an empty dict.
func unit_at(t: int, cell: Vector2) -> Dictionary:
	for sq in armies[t]:
		var ps: Array = sq["positions"]
		for i in ps.size():
			if Vector2(ps[i]) == cell:
				return {"squad": sq, "index": i}
	return {}


## "" if this unit can go down, otherwise the reason it cannot, in plain words.
func can_add(t: int, class_id: String, cell: Vector2) -> String:
	if not cell_in_grid(cell):
		return "Off the field."
	if cell_team(cell) != t:
		return "That is the other half."
	if cell_blocked(cell):
		return "A block is in the way."
	if not unit_at(t, cell).is_empty():
		return ""  # occupied is not an error: the tap removes instead
	if army_units(t) >= MAX_SIZE:
		return "%d units is the cap." % MAX_SIZE
	if not sandbox and army_cost(t) + UnitClass.cost_of(class_id) > GOLD_BUDGET:
		return "Not enough gold."
	return ""


## Put one unit of `class_id` on `cell`. Returns "" or why it did not happen.
func add_unit(t: int, class_id: String, cell: Vector2, type_name: String, persona_name: String) -> String:
	var why := can_add(t, class_id, cell)
	if why != "":
		return why
	if not unit_at(t, cell).is_empty():
		return "Taken."
	var sq := ensure_squad(t, class_id, type_name, persona_name)
	(sq["positions"] as Array).append(cell)
	return ""


func remove_unit(t: int, cell: Vector2) -> bool:
	var hit := unit_at(t, cell)
	if hit.is_empty():
		return false
	var sq: Dictionary = hit["squad"]
	(sq["positions"] as Array).remove_at(int(hit["index"]))
	if (sq["positions"] as Array).is_empty():
		armies[t].erase(sq)
	return true


func clear_army(t: int) -> void:
	armies[t] = []


## A deep copy, for the undo stack and for the saved-army slots.
static func copy_army(src: Array) -> Array:
	var out: Array = []
	for sq in src:
		var ps: Array = []
		for c in sq["positions"]:
			ps.append(Vector2(c))
		out.append({"class": String(sq["class"]), "type": String(sq["type"]),
			"persona": String(sq["persona"]), "positions": ps})
	return out


## Free cells on a side, rank by rank from the middle of the field backwards, five abreast
## and centred - the shape an army falls into when you ask the game to lay it out for you.
static func layout_cells(team: int, n: int) -> Array:
	var rows := [6, 5, 7, 4, 8, 3, 9, 2, 10, 1]
	var out: Array = []
	var rank := 0
	while out.size() < n and rank < 9:
		var col := (6 - rank) if team == 0 else (11 + rank)
		if col < 0 or col >= GRID_W:
			break
		for r in rows:
			if out.size() >= n:
				break
			var cell := Vector2(col, r)
			if cell_blocked(cell) or cell_team(cell) != team:
				continue
			out.append(cell)
		rank += 1
	return out


## Build a side from [{"class","count","type","persona"}, ...] and stand it up on its half:
## shields in front, then fists, then the rock throwers at the back.
func set_army_from_entries(t: int, entries: Array) -> void:
	var ordered: Array = entries.duplicate()
	ordered.sort_custom(func(a, b): return int(FRONT_ORDER.get(String(a["class"]), 1)) < int(FRONT_ORDER.get(String(b["class"]), 1)))
	var total := 0
	for e in ordered:
		total += maxi(int(e.get("count", 0)), 0)
	total = mini(total, MAX_SIZE)
	var cells := layout_cells(t, total)
	var squads: Array = []
	var k := 0
	for e in ordered:
		var cid := UnitClass.normalize_id(String(e.get("class", "brawler")))
		var want: int = maxi(int(e.get("count", 0)), 0)
		var ps: Array = []
		while ps.size() < want and k < cells.size():
			ps.append(cells[k])
			k += 1
		if ps.is_empty():
			continue
		squads.append({"class": cid, "type": String(e.get("type", "Even")),
			"persona": String(e.get("persona", "Balanced")), "positions": ps})
	armies[t] = squads


func apply_preset_army(t: int, army_name: String) -> bool:
	var key := preset_army_key(army_name)
	if key == "":
		return false
	set_army_from_entries(t, PRESET_ARMIES[key])
	return true


## Loose matching, so "shield wall", "Shield_Wall" and "shieldwall" all find it.
static func preset_army_key(army_name: String) -> String:
	var want := army_name.strip_edges().to_lower().replace(" ", "").replace("_", "").replace("-", "")
	for k in PRESET_ARMIES:
		if String(k).to_lower().replace(" ", "") == want:
			return k
	return ""


## "12 units: 7 Shield, 5 Slinger [500g]", or the quick battle line when nothing is placed.
func army_summary(t: int) -> String:
	if armies[t].is_empty():
		return "%d %s (quick battle) [%dg]" % [team_count[t], team_type_names[t] + " " + team_preset_names[t], gold_spent[t]]
	var bits := PackedStringArray()
	for sq in armies[t]:
		bits.append("%d %s" % [(sq["positions"] as Array).size(), UnitClass.label_of(String(sq["class"]))])
	return "%d units: %s [%dg]" % [army_units(t), ", ".join(bits), army_cost(t)]


## Short composition label, for the saved-army slots.
func army_label(t: int) -> String:
	var bits := PackedStringArray()
	for sq in armies[t]:
		bits.append("%d %s" % [(sq["positions"] as Array).size(), UnitClass.label_of(String(sq["class"]))])
	return ", ".join(bits) if bits.size() > 0 else "empty"


## Who takes the field for this side: one entry per robot, in spawn order.
func _team_plan(t: int) -> Array:
	var plan: Array = []
	if not armies[t].is_empty():
		for sq in armies[t]:
			for cell in sq["positions"]:
				if plan.size() >= MAX_SIZE:
					break
				plan.append({"class": String(sq["class"]), "type": String(sq["type"]),
					"persona": String(sq["persona"]), "pos": cell_to_world(Vector2(cell))})
		return plan
	# nothing placed: the quick battle, which is v0 - TEAM_SIZE do-everything robots in ranks,
	# following the team pickers, with the per-robot overrides still honoured
	var n := clampi(TEAM_SIZE, 1, MAX_SIZE)
	for i in n:
		var per_row: int = mini(n, 10)
		var row: int = i / per_row
		var col: int = i % per_row
		var span: float = 8.0 if n <= 5 else 17.0
		var z := lerpf(-span, span, float(col) / float(maxi(per_row - 1, 1)))
		var depth: float = 15.0 if n <= 5 else 17.0 - float(row) * 2.4
		var x := -depth if t == 0 else depth
		plan.append({"class": UnitClass.DEFAULT_ID, "type": String(player_type[t][i]),
			"persona": String(player_persona[t][i]),
			"pos": Vector3(x + rng.randf_range(-1.5, 1.5), 0.0, z)})
	return plan


func clear() -> void:
	running = false
	celebration_phase = ""
	_celebrants.clear()
	for r in robots:
		r.cleanup()
		r.queue_free()
	for rk in rocks:
		rk.queue_free()
	robots.clear()
	rocks.clear()
	_cache_frame = -1


func _fresh_stats() -> Dictionary:
	return {
		"damage": [{"rock": 0.0, "punch": 0.0, "kick": 0.0}, {"rock": 0.0, "punch": 0.0, "kick": 0.0}],
		"kicks": [0, 0],
		"kick_hits": [0, 0],
		"throws": [0, 0],
		"rock_hits": [0, 0],
		"punches": [0, 0],
		"punch_hits": [0, 0],
		"kills": [0, 0],
		"friendly_fire": [0.0, 0.0],
		"own_goals": [0, 0],
		"knockdowns": [0, 0],
		"blocks": [0, 0],    # rocks stopped on a shield
		"hitbox_hist": {},   # hitboxes struck per rock hit -> count
	}


func alive_robots() -> Array[Robot]:
	var f := Engine.get_physics_frames()
	if f != _cache_frame:
		_cache_frame = f
		_alive_cache = []
		for r in robots:
			if r.alive:
				_alive_cache.append(r)
	return _alive_cache


func alive_count(team: int) -> int:
	var n := 0
	for r in robots:
		if r.alive and r.team == team:
			n += 1
	return n


## What the survivors cost: the gold still standing when the dust settles.
func gold_standing(team: int) -> int:
	var g := 0
	for r in robots:
		if r.team == team and r.alive and r.unit_class != null:
			g += r.unit_class.cost
	return g


## Kills and gold by class, for one side: {class_id: {"kills": n, "gold": g, "label": "Shield"}}.
func class_ledger(team: int) -> Dictionary:
	var out := {}
	for key in robot_stats:
		var rs: Dictionary = robot_stats[key]
		if int(rs["team"]) != team:
			continue
		var cid := String(rs.get("class_id", UnitClass.DEFAULT_ID))
		if not out.has(cid):
			out[cid] = {"label": String(rs.get("class", cid)), "kills": 0, "gold": 0, "units": 0}
		out[cid]["kills"] += int(rs.get("kills", 0))
		out[cid]["gold"] += int(rs.get("cost", 0))
		out[cid]["units"] += 1
	return out


## Types change how big a robot's HP pool is, so "team HP left" needs the team's own total
## rather than five times the reference constant.
func team_max_hp(team: int) -> float:
	var s := 0.0
	for r in robots:
		if r.team == team:
			s += r.max_hp
	return maxf(s, 1.0)


func team_hp(team: int) -> float:
	var s := 0.0
	for r in robots:
		if r.team == team:
			s += r.hp
	return s


func _physics_process(delta: float) -> void:
	if not running:
		dance_clock += delta
		_run_celebration(delta)
		return
	elapsed += delta
	time_left -= delta
	if alive_count(0) == 0 or alive_count(1) == 0:
		end_match("elimination")
	elif time_left <= 0.0:
		time_left = 0.0
		end_match("time")


func end_match(reason: String) -> void:
	if not running:
		return
	running = false
	_cache_frame = -1
	var a0 := alive_count(0)
	var a1 := alive_count(1)
	var hp0 := team_hp(0)
	var hp1 := team_hp(1)
	var winner := -1
	if a0 > 0 and a1 == 0:
		winner = 0
	elif a1 > 0 and a0 == 0:
		winner = 1
	elif hp0 != hp1:
		winner = 0 if hp0 > hp1 else 1
	if OS.has_environment("RBDBG"):
		for r in robots:
			if r.alive:
				var e := r._nearest_enemy()
				print("    %s hp=%d act=%s rock=%s edist=%.1f pos=%s" % [r.robot_name, int(r.hp), r.action, r.held_rock != null, r._flat_dist(e.global_position) if e else -1.0, r.global_position])
	var per_robot := []
	for r in robots:
		var rs: Dictionary = robot_stats[r.robot_name]
		rs["hp"] = r.hp
		rs["max_hp"] = r.max_hp
		rs["alive"] = r.alive
		per_robot.append(rs.duplicate())
	per_robot.sort_custom(func(a, b): return a["team"] < b["team"] if a["team"] != b["team"] else a["name"] < b["name"])
	var result := {
		"robots": per_robot,
		"match": match_index,
		"counts": team_count.duplicate(),
		"budget": GOLD_BUDGET,
		"sandbox": sandbox,
		"gold_spent": gold_spent.duplicate(),
		"gold_left": [GOLD_BUDGET - gold_spent[0], GOLD_BUDGET - gold_spent[1]],
		"gold_standing": [gold_standing(0), gold_standing(1)],
		"from_army": [not armies[0].is_empty(), not armies[1].is_empty()],
		"army_labels": [army_label(0), army_label(1)],
		"classes": [class_ledger(0), class_ledger(1)],
		"winner": winner,
		"winner_name": TEAM_NAMES[winner] if winner >= 0 else "Draw",
		"reason": reason,
		"duration": elapsed,
		"alive": [a0, a1],
		"hp": [hp0, hp1],
		"max_hp": [team_max_hp(0), team_max_hp(1)],
		"presets": team_preset_names.duplicate(),
		"types": team_type_names.duplicate(),
		"stats": stats.duplicate(true),
	}
	if winner >= 0:
		_begin_celebration(winner)
	else:
		celebration_phase = "done"
		_phase_timer = 0.0
	match_ended.emit(result)


## Winners jog to a line in front of the centre block, dance together, then the fallen
## enemies are shared out between them and each winner goes and squats over his share,
## then pees on it (every corpse gets it at least once). Then the celebration is done.
func _begin_celebration(winner: int) -> void:
	_celebrants.clear()
	for r in robots:
		if r.alive and r.team == winner:
			_celebrants.append(r)
	var corpses: Array[Robot] = []
	for r in robots:
		if not r.alive and r.team != winner:
			corpses.append(r)
	# ... nearest to the formation first, so the walk is short
	corpses.sort_custom(func(a: Robot, b: Robot): return a.global_position.length_squared() < b.global_position.length_squared())
	var n := _celebrants.size()
	var shares: Array = []
	for i in n:
		var order: Array[Robot] = []
		shares.append(order)
	var m := maxi(n, corpses.size())
	for k in m:
		if corpses.is_empty():
			break
		shares[k % n].append(corpses[k % corpses.size()])
	for i in n:
		var spot := Vector3((float(i) - float(n - 1) * 0.5) * 1.8, 0.0, 4.0)
		_celebrants[i].cheer(spot, shares[i])
	celebration_phase = "gather"
	_phase_timer = 0.0
	dance_clock = 0.0


func _run_celebration(delta: float) -> void:
	if celebration_phase == "" or celebration_phase == "done":
		return
	_phase_timer += delta
	var before := celebration_phase
	match celebration_phase:
		"gather":
			var all_there := true
			for r in _celebrants:
				if r.alive and not r.at_spot:
					all_there = false
					break
			if all_there or _phase_timer >= GATHER_CAP:
				celebration_phase = "dance"
				_phase_timer = 0.0
				dance_clock = 0.0
				dance_started.emit(match_index)
		"dance":
			if _phase_timer >= Robot.DANCE_TIME:
				celebration_phase = "teabag"
				_phase_timer = 0.0
		"teabag":
			var finished := true
			for r in _celebrants:
				if r.alive and not r.teabag_done():
					finished = false
					break
			if finished or _phase_timer >= TEABAG_CAP:
				celebration_phase = "done"
				_phase_timer = 0.0
				celebration_finished.emit(match_index)
	if celebration_phase != before and OS.has_environment("RBCELEB"):
		print("celebration: %s -> %s at t=%.1f" % [before, celebration_phase, dance_clock])


# ---------------------------------------------------------------- stat hooks

func _on_damaged(robot: Robot, amount: float, source: String, attacker: Robot, hitbox_count: int) -> void:
	if attacker == null:
		return
	var t := attacker.team
	if robot.team == t:
		stats["friendly_fire"][t] += amount
		robot_stats[robot.robot_name]["dmg_taken"] += amount
		if robot.hp <= 0.0 and robot.alive:
			stats["own_goals"][t] += 1  # killed by a teammate's rock
		return  # own goal: not credited as damage dealt
	stats["damage"][t][source] += amount
	robot_stats[robot.robot_name]["dmg_taken"] += amount
	var a: Dictionary = robot_stats[attacker.robot_name]
	if source == "rock":
		stats["rock_hits"][t] += 1
		a["rock_hits"] += 1
		a["dmg_rock"] += amount
		var h: Dictionary = stats["hitbox_hist"]
		h[hitbox_count] = int(h.get(hitbox_count, 0)) + 1
	elif source == "kick":
		a["dmg_kick"] += amount
	else:
		a["dmg_punch"] += amount
	if robot.hp <= 0.0 and robot.alive:  # hp is already reduced; _die() follows this signal
		a["kills"] += 1


func _on_died(robot: Robot) -> void:
	stats["kills"][1 - robot.team] += 1


func _on_threw(robot: Robot) -> void:
	stats["throws"][robot.team] += 1
	robot_stats[robot.robot_name]["throws"] += 1


func _on_punched(robot: Robot, landed: bool) -> void:
	stats["punches"][robot.team] += 1
	robot_stats[robot.robot_name]["punches"] += 1
	if landed:
		stats["punch_hits"][robot.team] += 1
		robot_stats[robot.robot_name]["punch_hits"] += 1


func _on_kicked(robot: Robot, landed: bool) -> void:
	stats["kicks"][robot.team] += 1
	robot_stats[robot.robot_name]["kicks"] += 1
	if landed:
		stats["kick_hits"][robot.team] += 1
		robot_stats[robot.robot_name]["kick_hits"] += 1


func _on_blocked(robot: Robot, _thrower: Robot) -> void:
	stats["blocks"][robot.team] += 1
	robot_stats[robot.robot_name]["blocks"] += 1


func _on_knocked_down(_robot: Robot, by: Robot, _source: String) -> void:
	if by == null:
		return
	stats["knockdowns"][by.team] += 1
	robot_stats[by.robot_name]["knockdowns"] += 1
