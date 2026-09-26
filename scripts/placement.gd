class_name Placement
extends Node3D
## The army builder: an overhead view of the field, a 2 m grid, your half lit up, and a bar
## along the bottom with the three classes, their costs, the gold you have left and the type
## and personality pickers for the squad you are working on.
##
## A squad is a class, a type, a personality and a set of cells. There are no orders here and
## there never will be: what a unit does when the whistle goes comes out of its personality
## and whatever its class allows.
##
## Everything is built in code, like the rest of the game, and it is laid out for a phone
## first - the bar wraps, and the camera pulls back only as far as it must to show the whole
## build area above the bar.

signal fight_requested
signal closed

const MARKER_Y := 0.14
const FOV_HALF_TAN := 0.5774   # tan(30 deg): the camera keeps its *width*, so this is fixed
## What a fresh squad of each class starts as. The pickers change it from there.
const DEFAULTS := {
	"brawler": {"type": "Bruiser", "persona": "Brawler"},
	"slinger": {"type": "Sniper", "persona": "Slinger"},
	"shield": {"type": "Tank", "persona": "Guardian"},
}

var manager: MatchManager
var cam: CameraRig
var is_open := false
var team := 0
var sel_class := "brawler"

var ui: CanvasLayer
var _root: Control
var _bar: PanelContainer
var _team_btns: Array[Button] = []
var _class_btns := {}
var _gold_label: Label
var _units_label: Label
var _msg: Label
var _title: Label
var _type_btn: OptionButton
var _persona_btn: OptionButton
var _preset_btn: OptionButton
var _fill_btn: OptionButton
var _save_btn: OptionButton
var _load_btn: OptionButton
var _name_edit: LineEdit
var _sandbox_btn: CheckButton
var _rosters: Array = []

var _grid: MeshInstance3D
var _halves: Array[MeshInstance3D] = []
var _markers: Node3D
var _undo: Array = []
var _choice := {}
var _painting := false
var _erasing := false
var _stroke := {}
var _was_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for cid in DEFAULTS:
		_choice[cid] = (DEFAULTS[cid] as Dictionary).duplicate()
	_build_field()
	_build_ui()
	visible = false
	ui.visible = false
	get_tree().root.size_changed.connect(_relayout)


# ---------------------------------------------------------------- the field

func _build_field() -> void:
	for t in 2:
		var half := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(MatchManager.GRID_W * MatchManager.CELL * 0.5, MatchManager.GRID_H * MatchManager.CELL)
		half.mesh = q
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(MatchManager.TEAM_COLORS[t], 0.16)
		half.material_override = m
		half.rotation_degrees = Vector3(-90, 0, 0)
		half.position = Vector3((-1.0 if t == 0 else 1.0) * MatchManager.GRID_W * MatchManager.CELL * 0.25, 0.05, 0.0)
		add_child(half)
		_halves.append(half)

	_grid = MeshInstance3D.new()
	var im := ImmediateMesh.new()
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_grid.mesh = im
	_grid.material_override = lm
	_grid.position.y = 0.08
	add_child(_grid)
	var hw := MatchManager.GRID_W * MatchManager.CELL * 0.5
	var hh := MatchManager.GRID_H * MatchManager.CELL * 0.5
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(Color(0.85, 0.88, 0.95, 0.35))
	for i in MatchManager.GRID_W + 1:
		var x := -hw + MatchManager.CELL * i
		im.surface_add_vertex(Vector3(x, 0, -hh))
		im.surface_add_vertex(Vector3(x, 0, hh))
	for j in MatchManager.GRID_H + 1:
		var z := -hh + MatchManager.CELL * j
		im.surface_add_vertex(Vector3(-hw, 0, z))
		im.surface_add_vertex(Vector3(hw, 0, z))
	im.surface_end()

	_markers = Node3D.new()
	add_child(_markers)


static func _marker_mesh(class_id: String) -> Mesh:
	match class_id:
		"slinger":
			var sp := SphereMesh.new()
			sp.radius = 0.42
			sp.height = 0.84
			sp.radial_segments = 10
			sp.rings = 5
			return sp
		"shield":
			var sh := BoxMesh.new()
			sh.size = Vector3(1.15, 0.34, 0.5)
			return sh
	var bx := BoxMesh.new()
	bx.size = Vector3(0.8, 0.5, 0.8)
	return bx


func _refresh_markers() -> void:
	for c in _markers.get_children():
		_markers.remove_child(c)
		c.queue_free()
	for t in 2:
		for sq in manager.armies[t]:
			var cid := String(sq["class"])
			var mat := StandardMaterial3D.new()
			# the side you are working on is bright; the other side is there for reference only
			mat.albedo_color = MatchManager.TEAM_COLORS[t].lightened(0.1) if t == team else MatchManager.TEAM_COLORS[t].darkened(0.45)
			mat.roughness = 0.5
			for cell in sq["positions"]:
				var mi := MeshInstance3D.new()
				mi.mesh = _marker_mesh(cid)
				mi.material_override = mat
				mi.position = MatchManager.cell_to_world(Vector2(cell)) + Vector3(0, MARKER_Y, 0)
				_markers.add_child(mi)


# ---------------------------------------------------------------- the bar

func _build_ui() -> void:
	ui = CanvasLayer.new()
	ui.layer = 2
	add_child(ui)
	var theme := Theme.new()
	theme.default_font_size = 14
	_root = Control.new()
	_root.theme = theme
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_root)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(col)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 17)
	_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_title.add_theme_constant_override("outline_size", 6)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := MarginContainer.new()
	top.add_theme_constant_override("margin_left", 12)
	top.add_theme_constant_override("margin_top", 46)   # clear of the page's "Apps" pill
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(_title)
	col.add_child(top)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(spacer)

	_bar = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.11, 0.96)   # opaque: the field runs underneath it
	sb.border_color = Color(0.35, 0.38, 0.45)
	sb.border_width_top = 1
	sb.set_content_margin_all(8)
	_bar.add_theme_stylebox_override("panel", sb)
	col.add_child(_bar)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 5)
	_bar.add_child(rows)

	# ---- row A: whose army, what it costs, the sandbox switch
	var row_a := HFlowContainer.new()
	row_a.add_theme_constant_override("h_separation", 6)
	rows.add_child(row_a)
	for t in 2:
		var b := Button.new()
		b.text = MatchManager.TEAM_NAMES[t]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(56, 30)
		b.add_theme_color_override("font_color", MatchManager.TEAM_COLORS[t].lightened(0.35))
		b.pressed.connect(func(): _set_team(t))
		row_a.add_child(b)
		_team_btns.append(b)
	_gold_label = Label.new()
	_gold_label.custom_minimum_size = Vector2(126, 0)
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row_a.add_child(_gold_label)
	_units_label = Label.new()
	_units_label.custom_minimum_size = Vector2(86, 0)
	_units_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row_a.add_child(_units_label)
	_sandbox_btn = CheckButton.new()
	_sandbox_btn.text = "Sandbox"
	_sandbox_btn.tooltip_text = "No gold limit. The 20-unit cap still applies."
	_sandbox_btn.toggled.connect(func(on: bool):
		manager.sandbox = on
		_refresh())
	row_a.add_child(_sandbox_btn)
	_preset_btn = _menu_button(["Preset army..."] + MatchManager.PRESET_ARMIES.keys(), func(i: int):
		if i > 0:
			_push_undo()
			manager.apply_preset_army(team, String(MatchManager.PRESET_ARMIES.keys()[i - 1]))
			_after_change("%s for %s." % [MatchManager.PRESET_ARMIES.keys()[i - 1], MatchManager.TEAM_NAMES[team]])
		_preset_btn.select(0))
	row_a.add_child(_preset_btn)
	_fill_btn = _menu_button(["Fill enemy from preset..."] + MatchManager.PRESET_ARMIES.keys(), func(i: int):
		if i > 0:
			_push_undo()
			manager.apply_preset_army(1 - team, String(MatchManager.PRESET_ARMIES.keys()[i - 1]))
			_after_change("%s stands up for %s." % [MatchManager.PRESET_ARMIES.keys()[i - 1], MatchManager.TEAM_NAMES[1 - team]])
		_fill_btn.select(0))
	row_a.add_child(_fill_btn)

	# ---- row B: the classes, and the squad you are working on
	var row_b := HFlowContainer.new()
	row_b.add_theme_constant_override("h_separation", 6)
	rows.add_child(row_b)
	for cid in UnitClass.PLACEABLE:
		var uc := UnitClass.of(cid)
		var b := Button.new()
		b.text = "%s  %dg" % [uc.label, uc.cost]
		b.icon = class_icon(cid)
		b.toggle_mode = true
		b.tooltip_text = "%s - %dg\n%s" % [uc.label, uc.cost, uc.blurb]
		b.custom_minimum_size = Vector2(112, 32)
		b.pressed.connect(func(): _select_class(cid))
		row_b.add_child(b)
		_class_btns[cid] = b
	row_b.add_child(_small("Type"))
	_type_btn = OptionButton.new()
	_type_btn.custom_minimum_size = Vector2(112, 30)
	_type_btn.item_selected.connect(func(i: int): _on_pick(true, String(Hud._roster(true)[i])))
	_rosters.append({"node": _type_btn, "is_type": true})
	row_b.add_child(_type_btn)
	row_b.add_child(_small("Personality"))
	_persona_btn = OptionButton.new()
	_persona_btn.custom_minimum_size = Vector2(118, 30)
	_persona_btn.item_selected.connect(func(i: int): _on_pick(false, String(Hud._roster(false)[i])))
	_rosters.append({"node": _persona_btn, "is_type": false})
	row_b.add_child(_persona_btn)

	# ---- row C: undo, clear, the five army slots, and the whistle
	var row_c := HFlowContainer.new()
	row_c.add_theme_constant_override("h_separation", 6)
	rows.add_child(row_c)
	row_c.add_child(_button("Undo", func(): _undo_last()))
	row_c.add_child(_button("Clear", func():
		_push_undo()
		manager.clear_army(team)
		_after_change("%s cleared." % MatchManager.TEAM_NAMES[team])))
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(104, 30)
	_name_edit.max_length = 18
	_name_edit.placeholder_text = "army name"
	row_c.add_child(_name_edit)
	_save_btn = _menu_button(["Save to..."], func(i: int):
		if i > 0:
			_save_army(i - 1)
		_save_btn.select(0))
	row_c.add_child(_save_btn)
	_load_btn = _menu_button(["Load..."], func(i: int):
		if i > 0:
			_load_army(i - 1)
		_load_btn.select(0))
	row_c.add_child(_load_btn)
	var fight := Button.new()
	fight.text = "Fight!"
	fight.add_theme_font_size_override("font_size", 17)
	fight.custom_minimum_size = Vector2(92, 34)
	fight.pressed.connect(_on_fight)
	row_c.add_child(fight)
	row_c.add_child(_button("Close", func(): close()))
	_msg = Label.new()
	_msg.add_theme_font_size_override("font_size", 13)
	_msg.add_theme_color_override("font_color", Color(0.95, 0.85, 0.5))
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.custom_minimum_size = Vector2(0, 17)   # an autowrapped label in a VBox can otherwise
	rows.add_child(_msg)                        # report no height at all and never be seen

	_repopulate()
	_select_class(sel_class)
	_set_team(0)
	_relayout.call_deferred()


static func _small(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.72, 0.76, 0.84))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


static func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 30)
	b.pressed.connect(cb)
	return b


static func _menu_button(items: Array, cb: Callable) -> OptionButton:
	var ob := OptionButton.new()
	for it in items:
		ob.add_item(String(it))
	ob.select(0)
	ob.custom_minimum_size = Vector2(0, 30)
	ob.item_selected.connect(cb)
	return ob


## A badge per class, drawn the same way as every other icon in the game.
static func class_icon(class_id: String) -> Texture2D:
	match class_id:
		"slinger":
			return Icons.get_icon(Icons.Shape.DISC, Color(0.72, 0.74, 0.80))
		"shield":
			return Icons.get_icon(Icons.Shape.SHIELD, Color(0.55, 0.70, 0.95))
	return Icons.get_icon(Icons.Shape.CROSS, Color(0.92, 0.45, 0.30))


func _repopulate() -> void:
	for r in _rosters:
		var is_type: bool = r["is_type"]
		var ob: OptionButton = r["node"]
		var names: Array = Hud._roster(is_type)
		var was := ob.get_item_text(ob.selected) if ob.selected >= 0 else ""
		ob.clear()
		for i in names.size():
			var n: String = names[i]
			ob.add_icon_item(Hud._icon_for(n, is_type), n)
			ob.get_popup().set_item_tooltip(i, Hud._describe(n, is_type))
		var back := names.find(was)
		ob.select(back if back >= 0 else 0)
	_refresh_slot_menus()


func _refresh_slot_menus() -> void:
	var saved: Array = CustomSlots.army_names()
	_save_btn.clear()
	_save_btn.add_item("Save to...")
	for i in CustomSlots.MAX_SLOTS:
		_save_btn.add_item("slot %d: %s" % [i + 1, saved[i] if i < saved.size() else "empty"])
	_save_btn.select(0)
	_load_btn.clear()
	_load_btn.add_item("Load...")
	for i in CustomSlots.MAX_SLOTS:
		_load_btn.add_item("slot %d: %s" % [i + 1, saved[i] if i < saved.size() else "empty"])
	_load_btn.select(0)


# ---------------------------------------------------------------- opening and closing

func open_screen() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	ui.visible = true
	_undo.clear()
	# the battle underneath is paused and hidden: this is a drawing board, not a spectacle
	_was_paused = get_tree().paused
	get_tree().paused = true
	_show_world(false)
	if cam != null:
		cam.set_overview(true)
	_sandbox_btn.set_pressed_no_signal(manager.sandbox)
	_repopulate()
	_refresh_markers()
	_sync_pickers()
	_refresh()
	_relayout()
	_relayout.call_deferred()


func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	ui.visible = false
	_show_world(true)
	if cam != null:
		cam.set_overview(false)
	get_tree().paused = _was_paused
	closed.emit()


## The battle underneath: robots, their ragdolls (which are siblings, not children) and the
## rocks. All of it goes away while the field is a drawing board.
func _show_world(on: bool) -> void:
	for r in manager.robots:
		r.visible = on
		if r.ragdoll != null and is_instance_valid(r.ragdoll):
			r.ragdoll.visible = on
	for rk in manager.rocks:
		rk.visible = on


func _on_fight() -> void:
	for t in 2:
		if manager.army_units(t) == 0:
			# an empty side would be a walkover: stand something up and say so
			manager.apply_preset_army(t, "Brawler Mob")
			_flash("%s was empty - Brawler Mob stands in." % MatchManager.TEAM_NAMES[t])
	close()
	fight_requested.emit()


# ---------------------------------------------------------------- editing

func _set_team(t: int) -> void:
	team = t
	for i in _team_btns.size():
		_team_btns[i].set_pressed_no_signal(i == t)
	for i in 2:
		var m: StandardMaterial3D = _halves[i].material_override
		m.albedo_color = Color(MatchManager.TEAM_COLORS[i], 0.22 if i == t else 0.05)
	_sync_pickers()
	_refresh()


func _select_class(cid: String) -> void:
	sel_class = cid
	for k in _class_btns:
		(_class_btns[k] as Button).set_pressed_no_signal(k == cid)
	_sync_pickers()
	_refresh()


## The pickers show the squad of the selected class if it exists, otherwise what a new one
## would be built with.
func _sync_pickers() -> void:
	var sq := manager.find_squad(team, sel_class)
	var src: Dictionary = sq if not sq.is_empty() else _choice[sel_class]
	var tn := String(src.get("type", "Even"))
	var pn := String(src.get("persona", "Balanced"))
	var types: Array = Hud._roster(true)
	var personas: Array = Hud._roster(false)
	_type_btn.select(maxi(types.find(tn), 0))
	_persona_btn.select(maxi(personas.find(pn), 0))


func _on_pick(is_type: bool, picked: String) -> void:
	(_choice[sel_class] as Dictionary)[("type" if is_type else "persona")] = picked
	var sq := manager.find_squad(team, sel_class)
	if not sq.is_empty():
		sq[("type" if is_type else "persona")] = picked
	_refresh()
	_flash("%s squad: %s" % [UnitClass.label_of(sel_class), picked])


func _push_undo() -> void:
	_undo.append({"team": team, "red": MatchManager.copy_army(manager.armies[0]),
		"blue": MatchManager.copy_army(manager.armies[1])})
	if _undo.size() > 40:
		_undo.pop_front()


func _undo_last() -> void:
	if _undo.is_empty():
		_flash("Nothing to undo.")
		return
	var step: Dictionary = _undo.pop_back()
	manager.armies[0] = step["red"]
	manager.armies[1] = step["blue"]
	_refresh_markers()
	_sync_pickers()
	_refresh()


func _after_change(message: String) -> void:
	_refresh_markers()
	_sync_pickers()
	_refresh()
	_flash(message)


func _save_army(idx: int) -> void:
	if manager.army_units(team) == 0:
		_flash("Nothing to save.")
		return
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		nm = manager.army_label(team)
	CustomSlots.set_army(idx, nm, manager.armies[team])
	_refresh_slot_menus()
	_flash("Saved to slot %d as \"%s\"." % [idx + 1, nm])


func _load_army(idx: int) -> void:
	var squads := CustomSlots.army_at(idx)
	if squads.is_empty():
		_flash("Slot %d is empty." % (idx + 1))
		return
	_push_undo()
	# a saved army is stored on the half it was built on; mirror it if it is going to the other
	var mirrored: Array = []
	for sq in squads:
		var ps: Array = []
		for c in sq["positions"]:
			var cell := Vector2(c)
			if MatchManager.cell_team(cell) != team:
				cell = Vector2(MatchManager.GRID_W - 1 - cell.x, cell.y)
			if not MatchManager.cell_blocked(cell):
				ps.append(cell)
		if not ps.is_empty():
			mirrored.append({"class": sq["class"], "type": sq["type"], "persona": sq["persona"], "positions": ps})
	manager.armies[team] = mirrored
	var over := not manager.sandbox and manager.army_cost(team) > MatchManager.GOLD_BUDGET
	_after_change("Loaded slot %d.%s" % [idx + 1, "  Over budget - it was built in sandbox." if over else ""])


## The line at the bottom of the bar. It stays until the next thing you do rather than
## fading on a timer: a browser frame after a stall can be seconds long, and a refusal that
## blinks out before you have looked at it is worse than no refusal at all.
func _flash(message: String) -> void:
	_msg.text = message


func _refresh() -> void:
	_msg.text = ""   # any message belongs to the action that put it there
	var cost := manager.army_cost(team)
	var units := manager.army_units(team)
	_gold_label.text = "Gold left %d" % (MatchManager.GOLD_BUDGET - cost) if not manager.sandbox \
		else "Gold %d (sandbox)" % cost
	_gold_label.add_theme_color_override("font_color",
		Color(0.95, 0.45, 0.4) if (not manager.sandbox and cost > MatchManager.GOLD_BUDGET) else Color(0.95, 0.85, 0.45))
	_units_label.text = "Units %d / %d" % [units, MatchManager.MAX_SIZE]
	_title.text = "Armies - placing %s.  %s" % [MatchManager.TEAM_NAMES[team], manager.army_label(team)]
	_title.add_theme_color_override("font_color", MatchManager.TEAM_COLORS[team].lightened(0.35))


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_stroke(_cell_under(get_viewport().get_mouse_position()))
		else:
			_painting = false
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _painting:
		_paint(_cell_under(get_viewport().get_mouse_position()))
	elif event is InputEventScreenTouch:
		if event.pressed:
			_begin_stroke(_cell_under(event.position))
		else:
			_painting = false
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and _painting:
		_paint(_cell_under(event.position))


## Where a screen point lands on the floor, as a grid cell. Vector2(-1, -1) for "nowhere".
func _cell_under(pos: Vector2) -> Vector2:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector2(-1, -1)
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	if absf(dir.y) < 0.0001:
		return Vector2(-1, -1)
	var t := -from.y / dir.y
	if t <= 0.0:
		return Vector2(-1, -1)
	var cell := MatchManager.world_to_cell(from + dir * t)
	return cell if MatchManager.cell_in_grid(cell) else Vector2(-1, -1)


## The first cell of a stroke decides what the stroke does: start on one of yours and you are
## rubbing out, start on an empty cell and you are painting units.
func _begin_stroke(cell: Vector2) -> void:
	_painting = true
	_stroke.clear()
	if cell.x < 0.0:
		return
	_erasing = not manager.unit_at(team, cell).is_empty()
	_push_undo()
	_paint(cell)


func _paint(cell: Vector2) -> void:
	if cell.x < 0.0 or _stroke.has(cell):
		return
	_stroke[cell] = true
	if _erasing:
		if manager.remove_unit(team, cell):
			_refresh_markers()
			_refresh()
		return
	var why := manager.add_unit(team, sel_class, cell, String(_choice[sel_class]["type"]),
		String(_choice[sel_class]["persona"]))
	if why != "":
		_flash(why)
		return
	_refresh_markers()
	_sync_pickers()
	_refresh()


# ---------------------------------------------------------------- layout

## Pull the camera back just far enough that the whole build area clears the bar, and no
## further - on a phone that is a lot closer than on a laptop, because the phone is taller.
func _relayout() -> void:
	if cam == null or not is_open:
		return
	var vs := get_viewport().get_visible_rect().size
	var bar_h := _bar.get_combined_minimum_size().y if _bar != null else 0.0
	var top_px := 74.0    # the title line and the page's Apps pill
	var usable := maxf(vs.y - bar_h - top_px, 120.0)
	var need_w := MatchManager.GRID_W * MatchManager.CELL + 2.0
	var need_h := MatchManager.GRID_H * MatchManager.CELL + 2.0
	var d_w := need_w / (2.0 * FOV_HALF_TAN)
	var d_h := need_h * vs.x / (usable * 2.0 * FOV_HALF_TAN)
	var dist := clampf(maxf(d_w, d_h), 18.0, 70.0)
	# the bar covers the bottom of the screen, so slide the field up out from under it
	var metres_per_px := (2.0 * FOV_HALF_TAN * dist) / maxf(vs.x, 1.0)
	cam.set_overview(true, dist, (bar_h - top_px) * 0.5 * metres_per_px)
