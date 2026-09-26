extends Node3D
## Entry point. Builds the world, wires the HUD, runs matches; supports headless batch sim:
##   godot --headless --path . -- --sim=20 [--red=Brawler --blue=Slinger] [--seed=1]
## and the M3 calibration overrides:
##   --costs=brawler:26,shield:44          class prices, for this run only
##   --gains=slinger.aim:1.4,shield.curve:0.6   type spans per class, for this run only
##   --types=SpecAim/0.1/0.1/0.1/0.1/0.6   a named type, for this run only

# Matches never start by themselves: the results panel asks. Only a batch chains on.
const CELEBRATION_CAP := 48.0      # results come up by then whatever the winners are doing

var manager: MatchManager
var arena: Arena
var cam: CameraRig
var hud: Hud
var placement: Placement
var headless := false
var batch_left := 0
var batch_results: Array[Dictionary] = []
var _restart_timer := -1.0
var _base_seed := -1
var _last_result: Dictionary = {}
var _results_shown_for := -1
var _result_waiting := -1   # a match that ended while the army builder was open


func _ready() -> void:
	arena = Arena.new()
	add_child(arena)
	_build_lighting()

	manager = MatchManager.new()
	manager.world = self
	manager.arena = arena
	manager.match_ended.connect(_on_match_ended)
	manager.celebration_finished.connect(_on_celebration_finished)
	manager.dance_started.connect(_on_celebration_finished)  # the stats come up as the dance starts
	add_child(manager)

	CustomSlots.load_slots()   # the five slots of each, off this browser's disk
	var args := _parse_args(OS.get_cmdline_user_args())
	# M3 calibration knobs, read before anything is spawned so a tuning run can probe a
	# price list or a set of type spans without rewriting the scripts between probes.
	if args.has("costs"):
		UnitClass.apply_cost_overrides(String(args["costs"]))
	if args.has("gains"):
		UnitClass.apply_span_overrides(String(args["gains"]))
	if args.has("types"):
		RobotType.apply_type_overrides(String(args["types"]))
	headless = (DisplayServer.get_name() == "headless" or args.has("sim")) and not args.has("ui")
	if args.has("size"):
		MatchManager.TEAM_SIZE = clampi(int(args["size"]), 1, MatchManager.MAX_SIZE)
	if OS.has_feature("web"):
		# the proven Dodgeball form: ask the page for exactly one parameter
		var qs: String = str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('size') || ''", true))
		if qs.is_valid_int():
			MatchManager.TEAM_SIZE = clampi(int(qs), 1, MatchManager.MAX_SIZE)
	if args.has("red"):
		_apply_army_arg(0, String(args["red"]))
	if args.has("blue"):
		_apply_army_arg(1, String(args["blue"]))
	if args.has("sandbox"):
		manager.sandbox = true
	if args.has("classcheck"):
		_class_check()
		get_tree().quit()
		return
	if args.has("type"):
		for t in 2:
			manager.team_types[t] = RobotType.preset(args["type"])
			manager.team_type_names[t] = args["type"]
	if args.has("redtype"):
		manager.team_types[0] = RobotType.preset(args["redtype"])
		manager.team_type_names[0] = args["redtype"]
	if args.has("bluetype"):
		manager.team_types[1] = RobotType.preset(args["bluetype"])
		manager.team_type_names[1] = args["bluetype"]
	if args.has("seed"):
		_base_seed = int(args["seed"])

	if headless:
		manager.time_limit = float(args.get("cap", "300"))  # sims can't wait forever; real matches do
		set_sim_speed(20.0)
		batch_left = maxi(int(args.get("sim", "5")), 1)
		print("Legion Bots headless sim: %d matches, Red %s vs Blue %s" % [batch_left, _army_arg_label(0), _army_arg_label(1)])
		_start_next()
		return

	_setup_ui_scale()
	cam = CameraRig.new()
	add_child(cam)
	hud = Hud.new()
	add_child(hud)
	hud.setup(manager)
	placement = Placement.new()
	placement.manager = manager
	placement.cam = cam
	add_child(placement)
	placement.fight_requested.connect(func(): batch_left = 0; batch_results.clear(); _start_next())
	placement.closed.connect(_on_placement_closed)
	hud.armies_requested.connect(func():
		hud.visible = false
		placement.open_screen())
	hud.new_match_requested.connect(func(): batch_left = 0; batch_results.clear(); _start_next())
	hud.batch_requested.connect(_run_batch)
	hud.speed_changed.connect(set_sim_speed)
	hud.pause_toggled.connect(func(p: bool): get_tree().paused = p)
	hud.process_mode = Node.PROCESS_MODE_ALWAYS
	cam.process_mode = Node.PROCESS_MODE_ALWAYS
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
	# a browser has no command line: the query string stands in for it
	if OS.has_feature("web"):
		var q: String = str(JavaScriptBridge.eval("window.location.search", true))
		if q.begins_with("?"):
			for part in q.substr(1).split("&"):
				var kv2: PackedStringArray = String(part).split("=", true, 1)
				if kv2[0] != "":
					d[kv2[0]] = kv2[1].uri_decode() if kv2.size() > 1 else "1"
	return d


## --red= / --blue= take three shapes:
##   "Shield Wall"                                   one of the preset armies
##   "brawler:10:Bruiser:Brawler,slinger:6:Sniper:Slinger"   squads, class:count:type:personality
##   "Slinger"                                       legacy: TEAM_SIZE do-everything robots
func _apply_army_arg(t: int, spec: String) -> void:
	var text := spec.strip_edges()
	if text == "":
		return
	if text.contains(":"):
		var entries: Array = []
		for part in text.split(",", false):
			var f: PackedStringArray = String(part).strip_edges().split(":")
			if f.size() < 2 or not UnitClass.is_known(f[0]):
				push_warning("ignoring army entry '%s'" % part)
				continue
			entries.append({"class": f[0].strip_edges().to_lower(), "count": maxi(int(f[1]), 0),
				"type": String(f[2]).strip_edges() if f.size() > 2 else "Even",
				"persona": String(f[3]).strip_edges() if f.size() > 3 else "Balanced"})
		if not entries.is_empty():
			manager.set_army_from_entries(t, entries)
			return
	if manager.apply_preset_army(t, text):
		return
	# legacy: a bare personality name for the whole side, do-everything robots, quick-battle size
	manager.team_personalities[t] = CustomSlots.resolve_persona(text)
	manager.team_preset_names[t] = text


func _army_arg_label(t: int) -> String:
	if manager.armies[t].is_empty():
		return "%s (quick battle)" % manager.team_preset_names[t]
	return manager.army_label(t)


## --classcheck: prove that an Even type reproduces each class's base numbers exactly. It is
## the one invariant the class table must never break, and it is cheaper to assert than to
## re-derive by hand every time the costs move.
func _class_check() -> void:
	var even := RobotType.preset("Even")
	for cid in UnitClass.PLACEABLE:
		var sp := PackedStringArray()
		for pr in RobotType.PROPS:
			sp.append("%s %.2f" % [pr, UnitClass.span_value(cid, pr)])
		print("  spans %-8s curve %.2f  %s" % [UnitClass.label_of(cid), UnitClass.span_value(cid, "curve"), ", ".join(sp)])
	print("class check (Even type, no jitter): base HP %d, speed %.2f, punch %.1f" % [
		int(Robot.MAX_HP), Robot.SPEED, Robot.MAX_HP * Robot.PUNCH_MAX_FRAC])
	var bad := 0
	for cid in UnitClass.TABLE:
		var uc := UnitClass.of(cid)
		var r := Robot.new()
		r.robot_type = even
		r.unit_class = uc
		r.personality = Personality.preset("Balanced")
		r.apply_type()
		var want_speed := Robot.SPEED * uc.speed_mult
		var want_punch := Robot.MAX_HP * Robot.PUNCH_MAX_FRAC * uc.melee_mult
		var got_punch := Robot.MAX_HP * Robot.PUNCH_MAX_FRAC * r.dmg_mult * r.melee_mult
		var ok := is_equal_approx(r.max_hp, Robot.MAX_HP) and is_equal_approx(r.move_speed, want_speed) \
			and is_equal_approx(got_punch, want_punch) and is_equal_approx(r.accuracy, Robot.ACCURACY)
		if not ok:
			bad += 1
		print("  %-8s cost %2dg  hp %6.2f  speed %5.3f  punch %6.2f  acc %.3f  throws=%s carries=%s shield=%s  %s" % [
			uc.label, uc.cost, r.max_hp, r.move_speed, got_punch, r.accuracy,
			uc.throws, uc.carries, uc.shield, "OK" if ok else "MISMATCH"])
		r.free()
	print("class check: %s" % ("all classes reproduce their base numbers" if bad == 0 else "%d MISMATCHES" % bad))


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
	if cam != null and manager != null and not manager.running and manager.celebration_phase != "" and manager.celebration_phase != "done":
		# follow the winners' celebration; back off to the whole arena for the results
		var c := Vector3.ZERO
		var n := 0
		for r in manager.robots:
			if r.alive and r.celebrating:
				c += r.global_position
				n += 1
		if n > 0:
			cam.set_focus(c / n, 16.0 if manager.celebration_phase == "teabag" else 18.0)
	elif cam != null:
		cam.clear_focus()
	if _restart_timer > 0.0:
		_restart_timer -= delta
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
				print("  %s %s dmg=%d rock=%d punch=%d kick=%d throws=%d/%d punches=%d/%d kicks=%d/%d kd=%d kills=%d hp=%d" % [rr["name"], rr["preset"], int(rr["dmg_rock"] + rr["dmg_punch"] + rr["dmg_kick"]), int(rr["dmg_rock"]), int(rr["dmg_punch"]), int(rr["dmg_kick"]), rr["rock_hits"], rr["throws"], rr["punch_hits"], rr["punches"], rr["kick_hits"], rr["kicks"], rr["knockdowns"], rr["kills"], int(rr["hp"])])
			print("SUMMARY " + JSON.stringify(summary["data"]))
			if OS.has_environment("RBCELEB") and manager.celebration_phase != "done":
				# let the winners finish their celebration so it gets exercised headless
				manager.celebration_finished.connect(func(_i: int): _celeb_report(); get_tree().quit())
				get_tree().create_timer(CELEBRATION_CAP).timeout.connect(func(): print("celebration: CAP HIT in phase %s" % manager.celebration_phase); _celeb_report(); get_tree().quit())
				return
			get_tree().quit()
			return
		hud.show_batch(summary)
		set_sim_speed(1.0)
		hud._set_speed(1.0)
		_restart_timer = -1.0
		return
	if hud != null:
		# the panel waits for the winners: gather, dance, pay their respects (or a draw's short pause)
		_last_result = result
		hud.set_status("Match over - %s" % result["winner_name"] if result["winner"] >= 0 else "Match over - draw")
		var delay := 1.5 if result["winner"] < 0 else CELEBRATION_CAP
		get_tree().create_timer(delay).timeout.connect(func(): _on_celebration_finished(result["match"]))
		_restart_timer = -1.0
		return
	elif headless:
		print(JSON.stringify(result))
	_restart_timer = -1.0


func _on_placement_closed() -> void:
	if hud != null:
		hud.visible = true
	if _result_waiting >= 0:
		var idx := _result_waiting
		_result_waiting = -1
		_on_celebration_finished(idx)


func _on_celebration_finished(idx: int) -> void:
	if hud == null or _last_result.is_empty() or manager.running or idx != manager.match_index or _results_shown_for == idx:
		return
	if placement != null and placement.is_open:
		_result_waiting = idx   # the builder is open: the panel waits until it closes
		return
	if batch_left > 0:
		return
	_results_shown_for = idx
	hud.show_result(_last_result)


func _summarize(results: Array[Dictionary]) -> Dictionary:
	var wins := [0, 0]
	var draws := 0
	var dur := 0.0
	var dmg := [{"rock": 0.0, "punch": 0.0, "kick": 0.0}, {"rock": 0.0, "punch": 0.0, "kick": 0.0}]
	var throws := [0, 0]
	var rock_hits := [0, 0]
	var punches := [0, 0]
	var punch_hits := [0, 0]
	var kds := [0, 0]
	var blocks := [0, 0]
	var ff := [0.0, 0.0]
	var hist := {}
	# what the armies cost and what the gold bought, by class, across the whole batch
	var cost_left := [0, 0]
	var ledgers := [{}, {}]
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
			dmg[t]["kick"] += s["damage"][t].get("kick", 0.0)
			throws[t] += s["throws"][t]
			rock_hits[t] += s["rock_hits"][t]
			punches[t] += s["punches"][t]
			punch_hits[t] += s["punch_hits"][t]
			kds[t] += s["knockdowns"][t]
			blocks[t] += int(s.get("blocks", [0, 0])[t])
			ff[t] += s["friendly_fire"][t]
			cost_left[t] += int(r.get("gold_left", [0, 0])[t])
			var led: Dictionary = (r.get("classes", [{}, {}]) as Array)[t]
			for cid in led:
				if not ledgers[t].has(cid):
					ledgers[t][cid] = {"kills": 0, "gold": 0}
				ledgers[t][cid]["kills"] += int(led[cid]["kills"])
				ledgers[t][cid]["gold"] += int(led[cid]["gold"])
		for k in s["hitbox_hist"]:
			hist[k] = int(hist.get(k, 0)) + int(s["hitbox_hist"][k])
	var n := maxi(results.size(), 1)
	var names := [_army_arg_label(0), _army_arg_label(1)]
	var txt := "Batch of %d: %s(%s) %d wins, %s(%s) %d wins, %d draws, avg %ds.  " % [
		results.size(), MatchManager.TEAM_NAMES[0], names[0], wins[0], MatchManager.TEAM_NAMES[1], names[1], wins[1], draws, int(dur / n)]
	for t in 2:
		var acc := float(rock_hits[t]) / maxf(throws[t], 1) * 100.0
		var pacc := float(punch_hits[t]) / maxf(punches[t], 1) * 100.0
		txt += "%s per match: rock %d / punch %d / kick %d dmg, throw acc %d%%, punch acc %d%%, %d knockdowns, %d friendly-fire dmg.  " % [
			MatchManager.TEAM_NAMES[t], int(dmg[t]["rock"] / n), int(dmg[t]["punch"] / n), int(dmg[t]["kick"] / n), int(acc), int(pacc), kds[t] / n, int(ff[t] / n)]
	# the number M3 calibrates the costs against: kills bought per gold piece, by class
	var kpg := [{}, {}]
	for t in 2:
		cost_left[t] = int(round(float(cost_left[t]) / float(n)))
		for cid in ledgers[t]:
			var gold: int = int(ledgers[t][cid]["gold"])
			kpg[t][cid] = (float(ledgers[t][cid]["kills"]) / float(gold)) if gold > 0 else 0.0
	for t in 2:
		var parts := PackedStringArray()
		for cid in kpg[t]:
			parts.append("%s %.4f" % [cid, kpg[t][cid]])
		txt += "%s gold left unspent %d; kills per gold: %s.  " % [
			MatchManager.TEAM_NAMES[t], cost_left[t], ", ".join(parts) if parts.size() > 0 else "-"]
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
			"hitbox_hist": hist, "knockdowns": kds, "blocks": blocks, "friendly_fire": ff, "presets": names,
			"armies": [_army_arg_label(0), _army_arg_label(1)],
			"cost_left": cost_left, "kills_per_gold": kpg},
	}


func _celeb_report() -> void:
	for r in manager.robots:
		if r.celebrating:
			print("  %s spot=%s at_spot=%s teabagged=%d/%d pos=%s" % [r.robot_name, r.formation_spot, r.at_spot, r.teabag_idx, r.teabag_targets.size(), r.global_position])
