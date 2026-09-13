class_name Rock
extends RigidBody3D
## A reusable rock. Idle on the ground -> held by a robot -> thrown (dangerous) -> spent -> idle again.

enum State { IDLE, HELD, THROWN, SPENT }

const SPEED := 18.0          # 3x robot speed
const DMG_PER_HITBOX := 7.5
const RADIUS := 0.3
const FLIGHT_GRAVITY := 0.35 # lofted throw so 18 m/s reaches ~20 m
const MAX_AIRTIME := 3.0
const SPLASH_RADIUS := 0.78  # hitbox centres within this of the rock centre count as struck

const LAYER_WORLD := 1
const LAYER_ROBOTS := 2
const LAYER_ROCKS := 4
const LAYER_HITBOXES := 8

var state: State = State.IDLE
var thrower: Robot = null
var claimed_by: Robot = null
var manager = null
var impact: Area3D
var airtime := 0.0
var _pending := false
var _pending_origin := Vector3.ZERO
var _pending_vel := Vector3.ZERO
var _mesh: MeshInstance3D


func _ready() -> void:
	mass = 2.0
	collision_layer = LAYER_ROCKS
	collision_mask = LAYER_WORLD | LAYER_ROBOTS
	contact_monitor = true
	max_contacts_reported = 4
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	can_sleep = true
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.25
	pm.friction = 0.9
	physics_material_override = pm

	_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = RADIUS
	sm.height = RADIUS * 2.0
	sm.radial_segments = 10
	sm.rings = 6
	_mesh.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.53, 0.5)
	mat.roughness = 1.0
	_mesh.material_override = mat
	_mesh.scale = Vector3(1.0, 0.85, 1.1)
	add_child(_mesh)

	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = RADIUS
	cs.shape = sh
	add_child(cs)

	impact = Area3D.new()
	impact.collision_layer = 0
	impact.collision_mask = LAYER_HITBOXES
	impact.monitoring = true
	impact.monitorable = false
	var ics := CollisionShape3D.new()
	var ish := SphereShape3D.new()
	ish.radius = 0.7
	ics.shape = ish
	impact.add_child(ics)
	add_child(impact)
	impact.area_entered.connect(_on_impact_area)
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if state == State.THROWN:
		airtime += delta
		if airtime > MAX_AIRTIME:
			_spend()
	if state == State.THROWN or state == State.SPENT:
		if linear_velocity.length() < 2.5 and global_position.y < RADIUS + 0.4:
			_settle()
	if global_position.y < -5.0:
		# fell through something; put it back
		global_position = Vector3(0, 1, 0)
		_settle()


func is_free(for_robot: Robot = null) -> bool:
	if state != State.IDLE:
		return false
	return claimed_by == null or claimed_by == for_robot or not claimed_by.alive


func hold(r: Robot) -> void:
	state = State.HELD
	thrower = r
	claimed_by = null
	freeze = true
	collision_layer = 0
	collision_mask = 0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	impact.monitoring = false
	sleeping = false


func launch(origin: Vector3, vel: Vector3, r: Robot) -> void:
	global_position = origin
	state = State.THROWN
	thrower = r
	airtime = 0.0
	gravity_scale = FLIGHT_GRAVITY
	collision_layer = LAYER_ROCKS
	collision_mask = LAYER_WORLD | LAYER_ROBOTS
	freeze = false
	sleeping = false
	# velocity set inside _integrate_forces: setting it directly on a just-unfrozen body gets lost
	_pending = true
	_pending_origin = origin
	_pending_vel = vel
	impact.set_deferred("monitoring", true)


func _integrate_forces(st: PhysicsDirectBodyState3D) -> void:
	if _pending:
		_pending = false
		st.transform = Transform3D(Basis.IDENTITY, _pending_origin)
		st.linear_velocity = _pending_vel
		st.angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))


func drop() -> void:
	# dropped by a dying robot
	state = State.IDLE
	thrower = null
	gravity_scale = 1.0
	collision_layer = LAYER_ROCKS
	collision_mask = LAYER_WORLD | LAYER_ROBOTS
	freeze = false
	sleeping = false
	linear_velocity = Vector3(randf_range(-1, 1), 1.0, randf_range(-1, 1))
	impact.monitoring = false


func _spend() -> void:
	if state == State.THROWN:
		state = State.SPENT
		impact.set_deferred("monitoring", false)


func _settle() -> void:
	state = State.IDLE
	thrower = null
	gravity_scale = 1.0
	impact.set_deferred("monitoring", false)


func _on_body_entered(body: Node) -> void:
	if state != State.THROWN:
		return
	# Hitting the floor/walls/cover ends the dangerous phase. Hitting a robot body
	# without any hitbox overlap (edge case) also ends it.
	if body is StaticBody3D:
		_spend()


func _on_impact_area(area: Area3D) -> void:
	if state != State.THROWN or thrower == null:
		return
	if not area.has_meta("robot"):
		return
	var robot: Robot = area.get_meta("robot")
	if robot == null or robot == thrower or not robot.alive or robot.team == thrower.team:
		return
	# Count every hitbox of this robot within the rock's splash radius; more parts struck = more damage.
	var count := 0
	for hb in robot.hitboxes:
		if hb.global_position.distance_to(global_position) < SPLASH_RADIUS:
			count += 1
	count = maxi(count, 1)
	robot.take_damage(DMG_PER_HITBOX * count, "rock", thrower, count)
	linear_velocity *= 0.3
	_spend()
