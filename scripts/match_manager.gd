class_name MatchManager
extends Node
## Spawns teams + rocks, runs the clock, tallies stats, decides the winner.

signal match_started(match_index: int)
signal match_ended(result: Dictionary)

const TEAM_SIZE := 5
const MATCH_TIME := 150.0
const ARENA_HALF := 20.0
const ROCKS_PER_ROBOT := 0.5   # ~1 rock per 2 robots
const TEAM_NAMES := ["Red", "Blue"]
const TEAM_COLORS := [Color(0.9, 0.3, 0.25), Color(0.25, 0.5, 0.95)]

var world: Node3D
var arena: Arena
var team_personalities: Array[Personality] = [Personality.preset("Balanced"), Personality.preset("Balanced")]
var team_preset_names: Array[String] = ["Balanced", "Balanced"]
var robots: Array[Robot] = []
var rocks: Array[Rock] = []
var time_left := MATCH_TIME
var elapsed := 0.0
var running := false
var match_index := 0
var stats := {}
var rng := RandomNumberGenerator.new()
var _alive_cache: Array[Robot] = []
var _cache_frame := -1
var robot_stats := {}


func start_match(seed_value: int = -1) -> void:
	clear()
	if seed_value < 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	match_index += 1
	time_left = MATCH_TIME
	elapsed = 0.0
	stats = _fresh_stats()
	robot_stats = {}

	# interleave + shuffle spawn order so neither team gets first-strike from tree order
	var slots := []
	for t in 2:
		for i in TEAM_SIZE:
			slots.append([t, i])
	for k in range(slots.size() - 1, 0, -1):
		var j := rng.randi_range(0, k)
		var tmp = slots[k]
		slots[k] = slots[j]
		slots[j] = tmp
	for slot in slots:
		var t: int = slot[0]
		var i: int = slot[1]
		if true:
			var r := Robot.new()
			r.team = t
			r.team_color = TEAM_COLORS[t]
			r.robot_name = "%s%d" % [TEAM_NAMES[t][0], i + 1]
			r.personality = team_personalities[t].jittered(rng, 0.08)
			r.manager = self
			r.rng = RandomNumberGenerator.new()
			r.rng.seed = rng.randi()
			var x := -15.0 if t == 0 else 15.0
			var z := lerpf(-8.0, 8.0, float(i) / float(maxi(TEAM_SIZE - 1, 1)))
			r.position = Vector3(x + rng.randf_range(-1.5, 1.5), 0.0, z)
			r.rotation.y = PI * 0.5 if t == 0 else -PI * 0.5
			r.damaged.connect(_on_damaged)
			r.died.connect(_on_died)
			r.threw.connect(_on_threw)
			r.punched.connect(_on_punched)
			r.knocked_down.connect(_on_knocked_down)
			world.add_child(r)
			robots.append(r)
			robot_stats[r.robot_name] = {"name": r.robot_name, "team": t, "preset": r.personality.label(),
				"dmg_rock": 0.0, "dmg_punch": 0.0, "dmg_taken": 0.0, "throws": 0, "rock_hits": 0,
				"punches": 0, "punch_hits": 0, "knockdowns": 0, "kills": 0, "hp": r.hp, "alive": true}

	var n_rocks := int(ceil(TEAM_SIZE * 2 * ROCKS_PER_ROBOT))
	var tries := 0
	while rocks.size() < n_rocks and tries < 200:
		tries += 1
		var x := rng.randf_range(-11.0, 11.0)
		var z := rng.randf_range(-16.0, 16.0)
		if arena != null and not arena.is_clear(x, z):
			continue
		var rk := Rock.new()
		rk.manager = self
		rk.position = Vector3(x, 0.6, z)
		world.add_child(rk)
		rocks.append(rk)

	running = true
	match_started.emit(match_index)


func clear() -> void:
	running = false
	for r in robots:
		r.queue_free()
	for rk in rocks:
		rk.queue_free()
	robots.clear()
	rocks.clear()
	_cache_frame = -1


func _fresh_stats() -> Dictionary:
	return {
		"damage": [{"rock": 0.0, "punch": 0.0}, {"rock": 0.0, "punch": 0.0}],
		"throws": [0, 0],
		"rock_hits": [0, 0],
		"punches": [0, 0],
		"punch_hits": [0, 0],
		"kills": [0, 0],
		"knockdowns": [0, 0],
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


func team_hp(team: int) -> float:
	var s := 0.0
	for r in robots:
		if r.team == team:
			s += r.hp
	return s


func _physics_process(delta: float) -> void:
	if not running:
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
		rs["alive"] = r.alive
		per_robot.append(rs.duplicate())
	per_robot.sort_custom(func(a, b): return a["team"] < b["team"] if a["team"] != b["team"] else a["name"] < b["name"])
	var result := {
		"robots": per_robot,
		"match": match_index,
		"winner": winner,
		"winner_name": TEAM_NAMES[winner] if winner >= 0 else "Draw",
		"reason": reason,
		"duration": elapsed,
		"alive": [a0, a1],
		"hp": [hp0, hp1],
		"presets": team_preset_names.duplicate(),
		"stats": stats.duplicate(true),
	}
	match_ended.emit(result)


# ---------------------------------------------------------------- stat hooks

func _on_damaged(robot: Robot, amount: float, source: String, attacker: Robot, hitbox_count: int) -> void:
	if attacker == null:
		return
	var t := attacker.team
	stats["damage"][t][source] += amount
	robot_stats[robot.robot_name]["dmg_taken"] += amount
	var a: Dictionary = robot_stats[attacker.robot_name]
	if source == "rock":
		stats["rock_hits"][t] += 1
		a["rock_hits"] += 1
		a["dmg_rock"] += amount
		var h: Dictionary = stats["hitbox_hist"]
		h[hitbox_count] = int(h.get(hitbox_count, 0)) + 1
	else:
		a["dmg_punch"] += amount
	if robot.hp <= amount and robot.alive:
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


func _on_knocked_down(_robot: Robot, by: Robot, _source: String) -> void:
	if by == null:
		return
	stats["knockdowns"][by.team] += 1
	robot_stats[by.robot_name]["knockdowns"] += 1
