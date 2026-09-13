extends Node3D
## Entry point. Builds the world, wires the HUD, runs matches; supports headless batch sim:
##   godot --headless --path . -- --sim=20 [--red=Brawler --blue=Slinger] [--seed=1]

const AUTO_RESTART_DELAY := 20.0

var manager: MatchManager
var arena: Arena
var cam: CameraRig
var hud: Hud
var headless := false
var batch_left := 0
var batch_results: Array[Dictionary] = []
var _restart_timer := -1.0
var _base_seed := -1


func _ready() -> void:
	arena = Arena.new()
	add_child(arena)
	_build_lighting()

	manager = MatchManager.new()
	manager.world = self
	manager.arena = arena
	manager.match_ended.connect(_on_match_ended)
	add_child(manager)

	var args := _parse_args(OS.get_cmdline_user_args())
	headless = (DisplayServer.get_name() == "headless" or args.has("sim")) and not args.has("ui")
	if args.has("red"):
		manager.team_personalities[0] = Personality.preset(args["red"])
		manager.team_preset_names[0] = args["red"]
	if args.has("blue"):
		manager.team_personalities[1] = Personality.preset(args["blue"])
		manager.team_preset_names[1] = args["blue"]
	if args.has("seed"):
		_base_seed = int(args["seed"])

	if headless:
		set_sim_speed(20.0)
		batch_left = maxi(int(args.get("sim", "5")), 1)
		print("Rock Bots headless sim: %d matches, %s vs %s" % [batch_left, manager.team_preset_names[0], manager.team_preset_names[1]])
		_start_next()
		return

	_setup_ui_scale()
	cam = CameraRig.new()
	add_child(cam)
	hud = Hud.new()
	add_child(hud)
	hud.setup(manager)
	hud.new_match_requested.connect(func(): batch_left = 0; batch_results.clear(); _start_next())
	hud.batch_requested.connect(_run_batch)
	hud.speed_changed.connect(set_sim_speed)
	_start_next()


## UI in real pixels, scaled by the device's pixel density, so a phone gets big
## controls and a desktop doesn't get a blown-up toy. Rows wrap instead of stretching.
func _setup_ui_scale() -> void:
	var root := get_tree().root
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	var dpi := DisplayServer.screen_get_dpi()
	root.content_scale_factor = clampf(float(dpi) / 96.0, 1.0, 3.0)


## Speed up game time WITHOUT coarsening physics: Godot scales the physics delta by time_scale,
## so we raise the tick rate to match and every step stays 1/60 s of game time.
func set_sim_speed(s: float) -> void:
	Engine.time_scale = s
	Engine.physics_ticks_per_second = int(round(60.0 * s))
	Engine.max_physics_steps_per_frame = maxi(8, int(s * 4.0))


func _build_lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = not headless
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.1, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.75)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)


func _parse_args(list: PackedStringArray) -> Dictionary:
	var d := {}
	for a in list:
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			d[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return d


func _start_next() -> void:
	_restart_timer = -1.0
	if hud != null:
		hud.on_match_started()
	var s := -1
	if _base_seed >= 0:
		s = _base_seed + manager.match_index
	manager.start_match(s)


func _run_batch(n: int) -> void:
	batch_left = n
	batch_results.clear()
	set_sim_speed(8.0)
	if hud != null:
		hud._set_speed(8.0)
	_start_next()


func _process(delta: float) -> void:
	if _restart_timer > 0.0:
		_restart_timer -= delta
		if hud != null and batch_left == 0:
			hud.set_countdown(_restart_timer)
		if _restart_timer <= 0.0:
			_start_next()


func _on_match_ended(result: Dictionary) -> void:
	if batch_left > 0:
		batch_left -= 1
		batch_results.append(result)
		if headless:
			print("  match %d: %s by %s in %ds (alive %d-%d)" % [result["match"], result["winner_name"], result["reason"], int(result["duration"]), result["alive"][0], result["alive"][1]])
		if batch_left > 0:
			if hud != null:
				hud.set_status("Batch: %d done, %d to go..." % [batch_results.size(), batch_left])
			# let physics settle a frame before respawn
			_restart_timer = 0.05
			return
		var summary := _summarize(batch_results)
		if headless:
			print(summary["text"])
			for rr in batch_results[-1]["robots"]:
				print("  %s %s dmg=%d rock=%d punch=%d throws=%d/%d punches=%d/%d kd=%d kills=%d hp=%d" % [rr["name"], rr["preset"], int(rr["dmg_rock"] + rr["dmg_punch"]), int(rr["dmg_rock"]), int(rr["dmg_punch"]), rr["rock_hits"], rr["throws"], rr["punch_hits"], rr["punches"], rr["knockdowns"], rr["kills"], int(rr["hp"])])
			print(JSON.stringify(summary["data"]))
			get_tree().quit()
			return
		hud.show_batch(summary)
		set_sim_speed(1.0)
		hud._set_speed(1.0)
		_restart_timer = AUTO_RESTART_DELAY
		return
	if hud != null:
		hud.show_result(result)
	elif headless:
		print(JSON.stringify(result))
	_restart_timer = AUTO_RESTART_DELAY


func _summarize(results: Array[Dictionary]) -> Dictionary:
	var wins := [0, 0]
	var draws := 0
	var dur := 0.0
	var dmg := [{"rock": 0.0, "punch": 0.0}, {"rock": 0.0, "punch": 0.0}]
	var throws := [0, 0]
	var rock_hits := [0, 0]
	var punches := [0, 0]
	var punch_hits := [0, 0]
	var kds := [0, 0]
	var hist := {}
	for r in results:
		if r["winner"] >= 0:
			wins[r["winner"]] += 1
		else:
			draws += 1
		dur += r["duration"]
		var s: Dictionary = r["stats"]
		for t in 2:
			dmg[t]["rock"] += s["damage"][t]["rock"]
			dmg[t]["punch"] += s["damage"][t]["punch"]
			throws[t] += s["throws"][t]
			rock_hits[t] += s["rock_hits"][t]
			punches[t] += s["punches"][t]
			punch_hits[t] += s["punch_hits"][t]
			kds[t] += s["knockdowns"][t]
		for k in s["hitbox_hist"]:
			hist[k] = int(hist.get(k, 0)) + int(s["hitbox_hist"][k])
	var n := maxi(results.size(), 1)
	var names := manager.team_preset_names
	var txt := "Batch of %d: %s(%s) %d wins, %s(%s) %d wins, %d draws, avg %ds.  " % [
		results.size(), MatchManager.TEAM_NAMES[0], names[0], wins[0], MatchManager.TEAM_NAMES[1], names[1], wins[1], draws, int(dur / n)]
	for t in 2:
		var acc := float(rock_hits[t]) / maxf(throws[t], 1) * 100.0
		var pacc := float(punch_hits[t]) / maxf(punches[t], 1) * 100.0
		txt += "%s per match: rock %d / punch %d dmg, throw acc %d%%, punch acc %d%%, %d knockdowns.  " % [
			MatchManager.TEAM_NAMES[t], int(dmg[t]["rock"] / n), int(dmg[t]["punch"] / n), int(acc), int(pacc), kds[t] / n]
	var hk := hist.keys()
	hk.sort()
	var hparts := PackedStringArray()
	for k in hk:
		hparts.append("%s:%d" % [str(k), hist[k]])
	txt += "Hitboxes per rock hit -> " + ", ".join(hparts)
	return {
		"text": txt,
		"data": {"matches": results.size(), "wins": wins, "draws": draws, "avg_duration": dur / n,
			"damage": dmg, "throws": throws, "rock_hits": rock_hits, "punches": punches, "punch_hits": punch_hits,
			"hitbox_hist": hist, "knockdowns": kds, "presets": names},
	}
