class_name Robot
extends CharacterBody3D
## A blocky robot with six hitboxes (head, torso, 2 arms, 2 legs) and a utility-AI brain
## driven by a Personality. Faces -Z (Godot convention).

signal died(robot: Robot)
signal damaged(robot: Robot, amount: float, source: String, attacker: Robot, hitbox_count: int)
signal threw(robot: Robot)
signal punched(robot: Robot, landed: bool)

const SPEED := 6.0
const MAX_HP := 200.0
const PUNCH_DMG_PER_HITBOX := 2.5   # 1/3 of a rock hitbox
const PUNCH_COOLDOWN := 0.6         # 4x faster than a throw
const PUNCH_REACH := 1.7
const THROW_COOLDOWN := 2.4
const THROW_RANGE := 20.0
const PICKUP_RANGE := 1.5
const DECISION_INTERVAL := 0.15

const LAYER_WORLD := 1
const LAYER_ROBOTS := 2
const LAYER_HITBOXES := 8

const HAND_POS := Vector3(0.45, 1.5, -0.35)

var team := 0
var team_color := Color.RED
var robot_name := "bot"
var personality: Personality
var hp := MAX_HP
var alive := true
var held_rock: Rock = null
var manager = null
var rng: RandomNumberGenerator

var action := "wander"
var punch_timer := 0.0
var throw_timer := 0.0
var decide_timer := 0.0
var move_dir := Vector3.ZERO
var face_point := Vector3.ZERO
var has_face_point := false
var wander_point := Vector3.ZERO
var wander_timer := 0.0
var stuck_timer := 0.0
var fetch_rock: Rock = null
var _rock_notice := {}  # rock -> did we notice this throw (caution-based reaction)

var hitboxes: Array[Area3D] = []
var fist: Area3D
var body_root: Node3D
var arm_r: MeshInstance3D
var label: Label3D
var _swing := 0.0
var _mat: StandardMaterial3D
var _flash_tween: Tween


func _ready() -> void:
	collision_layer = LAYER_ROBOTS
	collision_mask = LAYER_WORLD | LAYER_ROBOTS
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	if personality == null:
		personality = Personality.preset("Balanced")
	decide_timer = rng.randf_range(0.0, DECISION_INTERVAL)
	punch_timer = rng.randf_range(0.0, PUNCH_COOLDOWN)
	wander_point = global_position
	_build_body()


# ---------------------------------------------------------------- body

func _build_body() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.9
	cs.shape = cap
	cs.position = Vector3(0, 0.95, 0)
	add_child(cs)

	body_root = Node3D.new()
	add_child(body_root)

	_mat = StandardMaterial3D.new()
	_mat.albedo_color = team_color
	_mat.roughness = 0.6
	_mat.metallic = 0.3
	var dark := StandardMaterial3D.new()
	dark.albedo_color = team_color.darkened(0.45)
	dark.roughness = 0.8

	# name, mesh, shape, position, material
	_part("torso", _box(Vector3(0.6, 0.7, 0.35)), _box_shape(Vector3(0.6, 0.7, 0.35)), Vector3(0, 1.15, 0), _mat)
	_part("head", _box(Vector3(0.36, 0.34, 0.36)), _box_shape(Vector3(0.4, 0.38, 0.4)), Vector3(0, 1.75, 0), _mat)
	_part("arm_l", _capsule(0.1, 0.62), _capsule_shape(0.12, 0.66), Vector3(-0.42, 1.2, 0), dark)
	arm_r = _part("arm_r", _capsule(0.1, 0.62), _capsule_shape(0.12, 0.66), Vector3(0.42, 1.2, 0), dark)
	_part("leg_l", _capsule(0.12, 0.76), _capsule_shape(0.14, 0.8), Vector3(-0.17, 0.4, 0), dark)
	_part("leg_r", _capsule(0.12, 0.76), _capsule_shape(0.14, 0.8), Vector3(0.17, 0.4, 0), dark)

	# eye so you can see which way it faces
	var eye := MeshInstance3D.new()
	eye.mesh = _box(Vector3(0.22, 0.06, 0.04))
	var em := StandardMaterial3D.new()
	em.albedo_color = Color(0.2, 1.0, 0.9)
	em.emission_enabled = true
	em.emission = Color(0.2, 1.0, 0.9)
	eye.material_override = em
	eye.position = Vector3(0, 1.78, -0.19)
	body_root.add_child(eye)

	fist = Area3D.new()
	fist.collision_layer = 0
	fist.collision_mask = LAYER_HITBOXES
	fist.monitoring = true
	fist.monitorable = false
	var fcs := CollisionShape3D.new()
	fcs.shape = _box_shape(Vector3(0.45, 0.5, PUNCH_REACH))
	fcs.position = Vector3(0.15, 1.3, -PUNCH_REACH * 0.5)
	fist.add_child(fcs)
	add_child(fist)

	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 40
	label.pixel_size = 0.011
	label.outline_size = 8
	label.position = Vector3(0, 2.25, 0)
	label.modulate = Color.WHITE
	add_child(label)
	_update_label()


func _part(part_name: String, mesh: Mesh, shape: Shape3D, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	body_root.add_child(mi)

	var hb := Area3D.new()
	hb.name = "hb_" + part_name
	hb.collision_layer = LAYER_HITBOXES
	hb.collision_mask = 0
	hb.monitoring = false
	hb.monitorable = true
	hb.set_meta("robot", self)
	hb.set_meta("part", part_name)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	hb.add_child(cs)
	hb.position = pos
	body_root.add_child(hb)
	hitboxes.append(hb)
	return mi


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _box_shape(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


func _capsule(r: float, h: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	m.radial_segments = 8
	m.rings = 3
	return m


func _capsule_shape(r: float, h: float) -> CapsuleShape3D:
	var s := CapsuleShape3D.new()
	s.radius = r
	s.height = h
	return s


func _update_label() -> void:
	if label == null:
		return
	if alive:
		label.text = "%s %s\n%d" % [robot_name, personality.label(), int(ceil(hp))]
		var f := hp / MAX_HP
		label.modulate = Color(1.0, f, f) if f < 0.5 else Color.WHITE
	else:
		label.text = robot_name + " X"
		label.modulate = Color(0.5, 0.5, 0.5)


# ---------------------------------------------------------------- loop

func _physics_process(delta: float) -> void:
	if not alive:
		return
	punch_timer -= delta
	throw_timer -= delta
	decide_timer -= delta
	wander_timer -= delta
	if decide_timer <= 0.0:
		decide_timer = DECISION_INTERVAL
		_decide()

	# movement
	var mv := move_dir
	mv.y = 0.0
	if mv.length_squared() > 0.001:
		mv = mv.normalized()
	velocity = mv * SPEED * (0.92 + 0.16 * personality.get_trait("aggression"))
	velocity.y = 0.0
	var before := global_position
	move_and_slide()
	global_position.y = 0.0
	# unstick: if we wanted to move but barely did, veer
	if mv.length_squared() > 0.001 and before.distance_to(global_position) < SPEED * delta * 0.3:
		stuck_timer += delta
		if stuck_timer > 0.3:
			move_dir = mv.rotated(Vector3.UP, rng.randf_range(0.8, 1.6) * (1.0 if rng.randf() < 0.5 else -1.0))
			stuck_timer = 0.0
	else:
		stuck_timer = 0.0

	# facing
	var fp := face_point if has_face_point else global_position + mv
	fp.y = global_position.y
	if fp.distance_squared_to(global_position) > 0.01:
		look_at(fp, Vector3.UP)

	# arm swing anim
	if _swing > 0.0:
		_swing -= delta
		arm_r.rotation.x = -1.6 * (_swing / 0.2)
	else:
		arm_r.rotation.x = 0.0

	if held_rock != null:
		held_rock.global_position = to_global(HAND_POS)

	# opportunistic punch: anyone in reach and fist ready
	if manager != null and (punch_timer <= 0.0 or (held_rock != null and throw_timer <= 0.0)):
		var e := _nearest_enemy()
		if e != null:
			var ed := _flat_dist(e.global_position)
			if punch_timer <= 0.0 and ed <= PUNCH_REACH + 0.2:
				_punch()
			# opportunistic throw: arm is ready and someone is in range - fling it, whatever we were doing
			if held_rock != null and throw_timer <= 0.0 and ed <= THROW_RANGE and action != "dodge":
				_throw_at(e)


# ---------------------------------------------------------------- perception helpers

func _flat_dist(p: Vector3) -> float:
	var d := p - global_position
	d.y = 0.0
	return d.length()


func _nearest_enemy() -> Robot:
	var best: Robot = null
	var bd := INF
	for r: Robot in manager.alive_robots():
		if r.team == team or r == self or not r.alive:
			continue
		var d := _flat_dist(r.global_position)
		if d < bd:
			bd = d
			best = r
	return best


func _nearest_free_rock() -> Rock:
	var best: Rock = null
	var bd := INF
	for rk: Rock in manager.rocks:
		if not rk.is_free(self):
			continue
		var d := _flat_dist(rk.global_position)
		if d < bd:
			bd = d
			best = rk
	return best


## Returns {rock, time, perp} for the most urgent incoming enemy rock, or empty dict.
func _incoming_threat() -> Dictionary:
	var best := {}
	var best_t := INF
	var notice_p := 0.2 + personality.get_trait("caution") * 0.75
	for rk: Rock in manager.rocks:
		if rk.state != Rock.State.THROWN or rk.thrower == null or rk.thrower.team == team:
			_rock_notice.erase(rk)
			continue
		if not _rock_notice.has(rk):
			_rock_notice[rk] = rng.randf() < notice_p
		if not _rock_notice[rk]:
			continue
		var v: Vector3 = rk.linear_velocity
		v.y = 0.0
		var speed := v.length()
		if speed < 4.0:
			continue
		var dirv := v / speed
		var rel := global_position - rk.global_position
		rel.y = 0.0
		var along := rel.dot(dirv)
		if along < -1.0 or along > 24.0:
			continue
		var lateral := (rel - dirv * along).length()
		if lateral > 2.2:
			continue
		var t := along / speed
		if t < best_t:
			best_t = t
			var perp := dirv.cross(Vector3.UP)
			if rel.dot(perp) < 0.0:
				perp = -perp
			best = {"rock": rk, "time": t, "perp": perp}
	return best


func _team_centroid() -> Vector3:
	var c := Vector3.ZERO
	var n := 0
	for r: Robot in manager.alive_robots():
		if r.team == team and r != self:
			c += r.global_position
			n += 1
	return c / n if n > 0 else global_position


# ---------------------------------------------------------------- brain

func _decide() -> void:
	if manager == null:
		return
	var P := personality
	var aggression := P.get_trait("aggression")
	var caution := P.get_trait("caution")
	var rock_love := P.get_trait("rock_love")
	var teamwork := P.get_trait("teamwork")
	var patience := P.get_trait("patience")

	var enemy := _nearest_enemy()
	var edist := _flat_dist(enemy.global_position) if enemy != null else INF
	var threat := _incoming_threat()
	var rock := _nearest_free_rock() if held_rock == null else null
	var rdist := _flat_dist(rock.global_position) if rock != null else INF
	var hpf := hp / MAX_HP
	var centroid := _team_centroid()
	var cdist := _flat_dist(centroid)

	var scores := {}
	# dodge an incoming rock
	if not threat.is_empty():
		scores["dodge"] = 0.35 + caution * 1.4 * clampf(1.5 - threat["time"], 0.2, 1.0)
	# go get a rock
	if rock != null:
		scores["fetch"] = 0.12 + rock_love * clampf(1.0 - rdist / 30.0, 0.15, 1.0) * (1.2 if enemy == null or edist > 6.0 else 0.5)
		if rdist < 3.5:
			scores["fetch"] += 0.35 * rock_love  # it's right there, grab it
	# throw the rock we hold
	if held_rock != null and enemy != null:
		var in_range := edist <= THROW_RANGE
		var s := 0.45 + 0.45 * aggression + 0.2 * rock_love
		if not in_range:
			s *= 0.7  # approach to range
		if edist < 4.0:
			s *= 0.4 + 0.6 * rock_love  # close: brawlers would rather punch
		scores["throw"] = s
	# close the gap and punch
	if enemy != null:
		var s2 := aggression * (1.0 - rock_love * 0.55) * clampf(1.0 - edist / 40.0, 0.25, 1.0) + 0.1
		if edist < 3.5:
			s2 += 0.35
		if held_rock == null and rock == null:
			s2 += 0.25  # nothing else to do
		scores["punch"] = s2
	# run away
	if enemy != null:
		var s3 := caution * (1.0 - hpf) * 1.3
		if held_rock != null and edist < 5.0 and rock_love > 0.5 and throw_timer > 0.0:
			s3 += 0.4  # kite while the arm recharges
		if held_rock == null and rock == null and edist < 6.0:
			s3 += caution * 0.4
		scores["kite"] = s3
	# regroup with the pack
	scores["regroup"] = teamwork * clampf(cdist / 14.0, 0.0, 1.0) * 0.85
	# idle / hold position
	scores["wander"] = 0.06 + patience * 0.15

	# hysteresis so they don't twitch between actions
	if scores.has(action):
		scores[action] += 0.08

	var best := "wander"
	var bs := -INF
	for k in scores:
		if scores[k] > bs:
			bs = scores[k]
			best = k
	if best != "fetch" and fetch_rock != null:
		if fetch_rock.claimed_by == self:
			fetch_rock.claimed_by = null
		fetch_rock = null
	action = best
	has_face_point = false

	match action:
		"dodge":
			move_dir = threat["perp"]
			if enemy != null:
				face_point = enemy.global_position
				has_face_point = true
		"fetch":
			fetch_rock = rock
			rock.claimed_by = self
			var to := rock.global_position - global_position
			to.y = 0.0
			if to.length() <= PICKUP_RANGE:
				_pickup(rock)
				move_dir = Vector3.ZERO
			else:
				move_dir = to.normalized()
		"throw":
			face_point = enemy.global_position
			has_face_point = true
			if edist <= THROW_RANGE and throw_timer <= 0.0:
				_throw_at(enemy)
			# positioning: get into range, keep some distance, slight strafe for patience-low bots
			var to := enemy.global_position - global_position
			to.y = 0.0
			to = to.normalized()
			if edist > THROW_RANGE * 0.85:
				move_dir = to
			elif edist < 5.0 + 6.0 * caution:
				move_dir = -to
			else:
				var strafe := to.cross(Vector3.UP) * (1.0 if int(get_instance_id()) % 2 == 0 else -1.0)
				move_dir = strafe * (1.0 - patience) * 0.8
		"punch":
			face_point = enemy.global_position
			has_face_point = true
			var to := enemy.global_position - global_position
			to.y = 0.0
			move_dir = to.normalized() if edist > PUNCH_REACH * 0.7 else Vector3.ZERO
			if edist <= PUNCH_REACH and punch_timer <= 0.0:
				_punch()
		"kite":
			var away := global_position - enemy.global_position
			away.y = 0.0
			away = away.normalized()
			# bias toward teammates
			var to_c := centroid - global_position
			to_c.y = 0.0
			if to_c.length() > 3.0:
				away = (away + to_c.normalized() * 0.6 * teamwork).normalized()
			move_dir = _keep_in_arena(away)
			face_point = enemy.global_position
			has_face_point = true
		"regroup":
			var to := centroid - global_position
			to.y = 0.0
			move_dir = to.normalized()
		_:
			if wander_timer <= 0.0 or _flat_dist(wander_point) < 1.5:
				wander_timer = rng.randf_range(1.5, 4.0)
				var h: float = manager.ARENA_HALF - 2.0
				wander_point = global_position + Vector3(rng.randf_range(-6, 6), 0, rng.randf_range(-6, 6))
				wander_point.x = clampf(wander_point.x, -h, h)
				wander_point.z = clampf(wander_point.z, -h, h)
			var to := wander_point - global_position
			to.y = 0.0
			move_dir = to.normalized() * (0.6 - patience * 0.4) if to.length() > 0.5 else Vector3.ZERO
			if enemy != null:
				face_point = enemy.global_position
				has_face_point = true


func _keep_in_arena(dir: Vector3) -> Vector3:
	var h: float = manager.ARENA_HALF - 2.5
	var p := global_position + dir * 3.0
	if absf(p.x) > h:
		dir.x = -signf(global_position.x) * 0.8
	if absf(p.z) > h:
		dir.z = -signf(global_position.z) * 0.8
	return dir.normalized() if dir.length_squared() > 0.001 else Vector3.ZERO


# ---------------------------------------------------------------- actions

func _pickup(rock: Rock) -> void:
	if held_rock != null or not rock.is_free(self):
		return
	held_rock = rock
	rock.hold(self)
	fetch_rock = null
	action = "wander"


func _throw_at(target: Robot) -> void:
	if held_rock == null:
		return
	var accuracy := personality.get_trait("accuracy")
	var origin := to_global(HAND_POS)
	var tpos := target.global_position + Vector3(0, 1.1, 0)
	var dist := origin.distance_to(tpos)
	var t := dist / Rock.SPEED
	var aim := tpos + target.velocity * t * (0.4 + 0.6 * accuracy)
	var dir := (aim - origin).normalized()
	# loft to counter the reduced flight gravity: v_y = 0.5 * g * t
	dir.y += 0.5 * 9.8 * Rock.FLIGHT_GRAVITY * t / Rock.SPEED
	var err := (1.0 - accuracy) * 0.22
	dir = dir.rotated(Vector3.UP, rng.randf_range(-err, err))
	var side := dir.cross(Vector3.UP)
	if side.length_squared() > 0.001:
		dir = dir.rotated(side.normalized(), rng.randf_range(-err, err) * 0.5)
	dir = dir.normalized()
	var rock := held_rock
	held_rock = null
	rock.launch(origin, dir * Rock.SPEED, self)
	throw_timer = THROW_COOLDOWN
	_swing = 0.2
	threw.emit(self)


func _punch() -> void:
	punch_timer = PUNCH_COOLDOWN
	_swing = 0.2
	var hits := {}
	for a in fist.get_overlapping_areas():
		if not a.has_meta("robot"):
			continue
		var r: Robot = a.get_meta("robot")
		if r == null or r == self or r.team == team or not r.alive:
			continue
		hits[r] = int(hits.get(r, 0)) + 1
	var landed := false
	for r in hits:
		landed = true
		r.take_damage(PUNCH_DMG_PER_HITBOX * hits[r], "punch", self, hits[r])
	punched.emit(self, landed)


func take_damage(amount: float, source: String, attacker: Robot, hitbox_count: int) -> void:
	if not alive:
		return
	hp -= amount
	damaged.emit(self, amount, source, attacker, hitbox_count)
	_flash()
	if hp <= 0.0:
		hp = 0.0
		_die()
	_update_label()


func _flash() -> void:
	if _mat == null:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_mat.albedo_color = Color.WHITE
	_flash_tween = create_tween()
	_flash_tween.tween_property(_mat, "albedo_color", team_color, 0.25)


func _die() -> void:
	alive = false
	action = "dead"
	move_dir = Vector3.ZERO
	velocity = Vector3.ZERO
	if held_rock != null:
		held_rock.drop()
		held_rock = null
	if fetch_rock != null and fetch_rock.claimed_by == self:
		fetch_rock.claimed_by = null
	collision_layer = 0
	collision_mask = 0
	for hb in hitboxes:
		hb.collision_layer = 0
	fist.monitoring = false
	body_root.rotation.x = -PI * 0.5
	body_root.position.y = 0.35
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_mat.albedo_color = team_color.darkened(0.6)
	set_physics_process(false)
	_update_label()
	died.emit(self)
