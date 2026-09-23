class_name Hud
extends CanvasLayer

const MAX_PICKERS := 10   # per-robot pickers shown; the rest follow the team
## All UI built in code: scoreboard, controls, team setup overlay, results overlay.
## Lays itself out for phone widths too (rows wrap, overlays shrink to the screen).

signal new_match_requested
signal batch_requested(n: int)
signal speed_changed(scale: float)
signal pause_toggled(paused: bool)

const PRESET_LIST := ["Balanced", "Brawler", "Slinger", "Coward", "Tactician", "Guardian", "Random", "Custom"]
## What a robot *is*, as against how it behaves - see robot_type.gd.
const TYPE_LIST := ["Even", "Bruiser", "Runner", "Tank", "Sniper", "Ghost", "Random", "Custom"]


## The lists the pickers actually offer: the shipped presets, then the slots you filled in
## yourself. "Custom" is the label the sliders fall back to and is never an option to choose.
func _roster(is_type: bool) -> Array:
	var out: Array = []
	for n in (TYPE_LIST if is_type else PRESET_LIST):
		if n != "Custom":
			out.append(n)
	out.append_array(CustomSlots.build_names() if is_type else CustomSlots.persona_names())
	return out


## A badge for any name in any roster, custom slots included.
func _icon_for(n: String, is_type: bool) -> Texture2D:
	var slot := CustomSlots.build_slot(n) if is_type else CustomSlots.persona_slot(n)
	if slot >= 0:
		return Icons.custom_icon(slot, is_type)
	var base: Array = TYPE_LIST if is_type else PRESET_LIST
	return Icons.roster_icon(n, base.find(n), is_type)

var manager: MatchManager
var timer_label: Label
var team_labels: Array[Label] = []
var live_label: Label
var status_label: Label
var teams_overlay: Control
var teams_scroll: ScrollContainer
var results_overlay: Control
var results_scroll: ScrollContainer
var results_box: VBoxContainer
var results_title: Label
var results_countdown: Label
var next_row: HFlowContainer
var preset_buttons: Array[OptionButton] = []
var type_buttons: Array[OptionButton] = []
var type_sliders := [{}, {}]
var type_slider_vals := [{}, {}]
## [team][robot] -> the little icon button for that robot's personality / type
var pp_btns := [[], []]
var pt_btns := [[], []]
## every dropdown and icon button that lists a roster, so the five slots can be folded in
## again the moment one is saved or cleared
var _rosters: Array = []
var custom_overlay: Control
var custom_scroll: ScrollContainer
var custom_btn: Button
var _slot_sel := {"persona": 0, "type": 0}
var _slot_ui := {}
var sliders := [{}, {}]
var slider_vals := [{}, {}]
var speed_buttons: Array[Button] = []
var teams_btn: Button
var live_btn: Button
var results_btn: Button
var last_result := {}
var _updating := false
var _tick := 0.0
var _root: Control


func setup(m: MatchManager) -> void:
	manager = m
	var theme := Theme.new()
	theme.default_font_size = 16
	_root = Control.new()
	_root.theme = theme
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	# ---- row 1: clock + team status (wraps on phones)
	var row1 := HFlowContainer.new()
	row1.add_theme_constant_override("h_separation", 14)
	vbox.add_child(row1)
	timer_label = Label.new()
	timer_label.add_theme_font_size_override("font_size", 26)
	timer_label.text = "2:30"
	row1.add_child(timer_label)
	for t in 2:
		var l := Label.new()
		l.add_theme_color_override("font_color", MatchManager.TEAM_COLORS[t].lightened(0.2))
		l.add_theme_font_size_override("font_size", 19)
		row1.add_child(l)
		team_labels.append(l)

	# ---- row 2: controls (wraps on phones)
	var row2 := HFlowContainer.new()
	row2.add_theme_constant_override("h_separation", 6)
	vbox.add_child(row2)
	var pause_btn := Button.new()
	pause_btn.text = "Pause"
	pause_btn.toggle_mode = true
	pause_btn.toggled.connect(func(on: bool): pause_btn.text = "Play" if on else "Pause"; pause_toggled.emit(on))
	row2.add_child(pause_btn)
	for s in [1, 2, 4, 8]:
		var b := Button.new()
		b.text = "%dx" % s
		b.toggle_mode = true
		b.button_pressed = (s == 1)
		b.pressed.connect(func(): _set_speed(float(s)))
		row2.add_child(b)
		speed_buttons.append(b)
	teams_btn = Button.new()
	teams_btn.text = "Teams / setup"
	teams_btn.toggle_mode = true
	teams_btn.toggled.connect(func(on: bool): teams_overlay.visible = on; if on: results_overlay.visible = false)
	row2.add_child(teams_btn)
	live_btn = Button.new()
	live_btn.text = "Live list"
	live_btn.toggle_mode = true
	live_btn.toggled.connect(func(on: bool): live_label.visible = on)
	row2.add_child(live_btn)
	results_btn = Button.new()
	results_btn.text = "Last results"
	results_btn.disabled = true
	results_btn.pressed.connect(func(): if not last_result.is_empty(): show_result(last_result))
	row2.add_child(results_btn)
	var new_btn := Button.new()
	new_btn.text = "New match"
	new_btn.pressed.connect(func(): _close_overlays(); new_match_requested.emit())
	row2.add_child(new_btn)
	var batch_btn := Button.new()
	batch_btn.text = "Batch x10"
	batch_btn.pressed.connect(func(): _close_overlays(); batch_requested.emit(10))
	row2.add_child(batch_btn)
	var size_btn := OptionButton.new()
	var sizes: Array = [5, 10, 20, 30, 50]
	for n in sizes:
		size_btn.add_item("%d v %d" % [n, n])
	size_btn.select(sizes.find(MatchManager.TEAM_SIZE))
	size_btn.tooltip_text = "Army size per side (reloads the page)"
	size_btn.item_selected.connect(func(ix: int):
		var n: int = sizes[ix]
		if OS.has_feature("web"):
			JavaScriptBridge.eval("window.location.search = '?size=%d'" % n)
		else:
			MatchManager.TEAM_SIZE = n)
	row2.add_child(size_btn)
	custom_btn = Button.new()
	custom_btn.text = "Make your own"
	custom_btn.toggle_mode = true
	custom_btn.tooltip_text = "Five personality slots and five type slots of your own, kept in this browser"
	custom_btn.toggled.connect(func(on: bool):
		custom_overlay.visible = on
		if on:
			teams_overlay.visible = false
			teams_btn.set_pressed_no_signal(false)
			results_overlay.visible = false)
	row2.add_child(custom_btn)

	# ---- live list (toggle)
	live_label = Label.new()
	live_label.add_theme_font_size_override("font_size", 13)
	live_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 0.9))
	live_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	live_label.visible = false
	vbox.add_child(live_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(spacer)

	# ---- bottom status line
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 14)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(status_label)

	_build_teams_overlay()
	_build_results_overlay()
	_build_custom_overlay()
	_repopulate_rosters()
	_refresh_sliders()
	get_tree().root.size_changed.connect(_relayout)
	_relayout()


# ---------------------------------------------------------------- overlays

func _overlay(title_text: String) -> Array:
	## Returns [overlay_control, scroll, content_vbox, title_label]
	var ov := Control.new()
	ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.visible = false
	_root.add_child(ov)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.9)
	sb.border_color = Color(0.35, 0.38, 0.45)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	panel.add_child(outer)
	var head := HBoxContainer.new()
	outer.add_child(head)
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(title)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func(): ov.visible = false; teams_btn.set_pressed_no_signal(false))
	head.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	outer.add_child(scroll)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return [ov, scroll, content, title]


func _build_teams_overlay() -> void:
	var parts := _overlay("Teams")
	teams_overlay = parts[0]
	teams_scroll = parts[1]
	var content: VBoxContainer = parts[2]
	var hint := Label.new()
	hint.text = "Personality is how a robot behaves; the type is what it is, five properties sharing one budget. Set a whole team at once, or give any single robot its own on the row of five. Hover an icon for what it does, or press ? for the whole key."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	content.add_child(hint)
	var teams_row := HFlowContainer.new()
	teams_row.add_theme_constant_override("h_separation", 24)
	content.add_child(teams_row)
	for t in 2:
		teams_row.add_child(_build_team_panel(t))
	var start := Button.new()
	start.text = "Start match with these teams"
	start.add_theme_font_size_override("font_size", 18)
	start.pressed.connect(func(): _close_overlays(); new_match_requested.emit())
	content.add_child(start)


func _build_team_panel(t: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = MatchManager.TEAM_NAMES[t]
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", MatchManager.TEAM_COLORS[t].lightened(0.2))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(_key_button())
	box.add_child(head)

	var pl := Label.new()
	pl.text = "Personality (whole team)"
	pl.add_theme_font_size_override("font_size", 13)
	pl.add_theme_color_override("font_color", Color(0.62, 0.66, 0.74))
	box.add_child(pl)
	var ob := OptionButton.new()
	ob.item_selected.connect(func(idx: int): _on_preset(t, String(_roster(false)[idx])))
	box.add_child(ob)
	preset_buttons.append(ob)
	_rosters.append({"kind": "option", "node": ob, "is_type": false})

	for trait_name in Personality.TRAITS:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = trait_name
		l.custom_minimum_size.x = 84
		l.tooltip_text = Personality.TRAIT_HELP[trait_name]
		row.add_child(l)
		var s := HSlider.new()
		s.min_value = 0.0
		s.max_value = 1.0
		s.step = 0.05
		s.custom_minimum_size = Vector2(150, 28)
		s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		s.value_changed.connect(func(v: float): _on_slider(t, trait_name, v))
		row.add_child(s)
		var vl := Label.new()
		vl.custom_minimum_size.x = 36
		row.add_child(vl)
		box.add_child(row)
		sliders[t][trait_name] = s
		slider_vals[t][trait_name] = vl

	# ---- what they are, as against how they behave: five shares of one budget
	var tl := Label.new()
	tl.text = "Type (whole team) - five shares of one budget"
	tl.add_theme_font_size_override("font_size", 13)
	tl.add_theme_color_override("font_color", Color(0.62, 0.66, 0.74))
	box.add_child(tl)
	var tb := OptionButton.new()
	tb.item_selected.connect(func(idx: int): _on_type(t, String(_roster(true)[idx])))
	box.add_child(tb)
	type_buttons.append(tb)
	_rosters.append({"kind": "option", "node": tb, "is_type": true})
	for prop in RobotType.PROPS:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = prop
		l.custom_minimum_size.x = 84
		l.tooltip_text = RobotType.PROP_HELP[prop]
		row.add_child(l)
		var s := HSlider.new()
		s.min_value = 0.0
		s.max_value = 0.8
		s.step = 0.02
		s.custom_minimum_size = Vector2(150, 26)
		s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		s.value_changed.connect(func(v: float): _on_type_slider(t, prop, v))
		row.add_child(s)
		var vl := Label.new()
		vl.custom_minimum_size.x = 36
		row.add_child(vl)
		box.add_child(row)
		type_sliders[t][prop] = s
		type_slider_vals[t][prop] = vl

	# ---- and the five of them, one column each: the ring means "follow the team"
	var per := Label.new()
	per.text = "Each robot (ring = follow the team)"
	per.add_theme_font_size_override("font_size", 13)
	per.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	box.add_child(per)
	var grid := GridContainer.new()
	grid.columns = mini(MatchManager.TEAM_SIZE, MAX_PICKERS) + 1
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 2)
	box.add_child(grid)
	grid.add_child(_mini_label(""))
	for i in mini(MatchManager.TEAM_SIZE, MAX_PICKERS):
		var nl := _mini_label("%s%d" % [MatchManager.TEAM_NAMES[t][0], i + 1])
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nl.custom_minimum_size.x = 34
		grid.add_child(nl)
	grid.add_child(_mini_label("Person."))
	for i in mini(MatchManager.TEAM_SIZE, MAX_PICKERS):
		var b := _picker(t, i, false)
		pp_btns[t].append(b)
		grid.add_child(b)
	grid.add_child(_mini_label("Type"))
	for i in mini(MatchManager.TEAM_SIZE, MAX_PICKERS):
		var b := _picker(t, i, true)
		pt_btns[t].append(b)
		grid.add_child(b)
	return box


# ------------------------------------------------- make your own

## Five slots each for personalities and types. A slot is a name and a set of numbers; save one
## and it appears in every dropdown, every per-robot menu and the key, with a badge of its own.
func _build_custom_overlay() -> void:
	var parts := _overlay("Make your own")
	custom_overlay = parts[0]
	var content: VBoxContainer = parts[2]
	custom_scroll = parts[1]
	custom_overlay.visibility_changed.connect(func():
		if custom_btn != null:
			custom_btn.set_pressed_no_signal(custom_overlay.visible))
	var hint := Label.new()
	hint.text = "Five personalities and five types of your own. Pick a slot, start it from something that already exists if you like, drag the numbers about, give it a name and save. Saved ones turn up everywhere a preset does. They are kept in this browser, on this machine - nothing is sent anywhere."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	content.add_child(hint)
	content.add_child(_slot_editor(false))
	content.add_child(_slot_editor(true))


## One half of the editor. `is_type` picks which roster it edits; the two halves are identical
## apart from the field list and where a saved slot ends up.
func _slot_editor(is_type: bool) -> Control:
	var key := "type" if is_type else "persona"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.text = "Your types (5 slots)" if is_type else "Your personalities (5 slots)"
	title.add_theme_font_size_override("font_size", 17)
	box.add_child(title)

	# the five slots, as a row of buttons - empty ones show a dash
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var slot_btns: Array = []
	for i in CustomSlots.MAX_SLOTS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(110, 30)
		b.toggle_mode = true
		b.pressed.connect(func(): _slot_sel[key] = i; _refresh_slot_editor(is_type))
		row.add_child(b)
		slot_btns.append(b)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	box.add_child(grid)
	grid.add_child(_mini_label("Name"))
	var name_edit := LineEdit.new()
	name_edit.custom_minimum_size.x = 220
	name_edit.max_length = 18
	name_edit.placeholder_text = "Kneecapper"
	grid.add_child(name_edit)
	grid.add_child(_mini_label("Start from"))
	var from_btn := OptionButton.new()
	var sources: Array = []
	for n in (CustomSlots.build_presets().keys() if is_type else Personality.PRESETS.keys()):
		sources.append(String(n))
	# the first entry is a do-nothing, so the box never claims the numbers below came from a
	# preset when they are only the even starting point
	from_btn.add_item("start from scratch")
	for i in sources.size():
		from_btn.add_icon_item(_icon_for(sources[i], is_type), sources[i])
	from_btn.item_selected.connect(func(i: int):
		if i <= 0:
			_reset_draft(is_type)
			_refresh_slot_editor(is_type)
		else:
			_copy_from(is_type, String(sources[i - 1])))
	grid.add_child(from_btn)

	# one slider per field
	var sliders := {}
	var vals := {}
	var fields: Array = CustomSlots.build_props() if is_type else Personality.TRAITS
	var helps: Dictionary = CustomSlots.build_prop_help() if is_type else Personality.TRAIT_HELP
	for f in fields:
		var r := HBoxContainer.new()
		var l := Label.new()
		l.text = f
		l.custom_minimum_size.x = 96
		l.tooltip_text = String(helps.get(f, ""))
		r.add_child(l)
		var s := HSlider.new()
		s.min_value = 0.0
		s.max_value = 0.8 if is_type else 1.0
		s.step = 0.02 if is_type else 0.05
		s.custom_minimum_size = Vector2(190, 26)
		s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		s.value_changed.connect(func(v: float): _on_slot_slider(is_type, String(f), v))
		r.add_child(s)
		var vl := Label.new()
		vl.custom_minimum_size.x = 40
		r.add_child(vl)
		box.add_child(r)
		sliders[f] = s
		vals[f] = vl

	var note := Label.new()
	note.add_theme_font_size_override("font_size", 13)
	note.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	box.add_child(note)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	var save := Button.new()
	save.text = "Save slot"
	save.pressed.connect(func(): _save_slot(is_type))
	buttons.add_child(save)
	var clear := Button.new()
	clear.text = "Clear slot"
	clear.pressed.connect(func(): _clear_slot(is_type))
	buttons.add_child(clear)

	_slot_ui[key] = {"btns": slot_btns, "name": name_edit, "sliders": sliders, "vals": vals,
		"note": note, "draft": {}}
	_reset_draft(is_type)
	_refresh_slot_editor(is_type)
	return box


## The numbers being edited live in a draft until Save, so half-dragged sliders never leak into
## a match and Clear always has something clean to fall back to.
func _reset_draft(is_type: bool) -> void:
	var key := "type" if is_type else "persona"
	var d := {}
	if is_type:
		for p in CustomSlots.build_props():
			d[p] = 0.2
	else:
		for t in Personality.TRAITS:
			d[t] = 0.5
	_slot_ui[key]["draft"] = d


func _copy_from(is_type: bool, source: String) -> void:
	var key := "type" if is_type else "persona"
	var d := {}
	if is_type:
		var src: Dictionary = CustomSlots.build_presets().get(source, {})
		for p in CustomSlots.build_props():
			d[p] = float(src.get(p, 0.2))
	else:
		var src: Dictionary = Personality.PRESETS.get(source, {})
		for t in Personality.TRAITS:
			d[t] = float(src.get(t, 0.5))
	_slot_ui[key]["draft"] = d
	_refresh_slot_editor(is_type)


func _on_slot_slider(is_type: bool, field: String, v: float) -> void:
	if _updating:
		return
	var key := "type" if is_type else "persona"
	var d: Dictionary = _slot_ui[key]["draft"]
	if is_type:
		# a type is a budget: take the difference out of the others, exactly as the team sliders do
		var tmp = CustomSlots.make_build(d)
		tmp.set_and_rebalance(field, v)
		for p in CustomSlots.build_props():
			d[p] = tmp.get_prop(p)
	else:
		d[field] = v
	_refresh_slot_editor(is_type)


func _save_slot(is_type: bool) -> void:
	var key := "type" if is_type else "persona"
	var ui: Dictionary = _slot_ui[key]
	var slot_name := String((ui["name"] as LineEdit).text).strip_edges()
	if slot_name == "":
		(ui["note"] as Label).text = "Give it a name first."
		return
	var idx: int = _slot_sel[key]
	if is_type:
		CustomSlots.set_build(idx, slot_name, ui["draft"])
	else:
		CustomSlots.set_persona(idx, slot_name, ui["draft"])
	_repopulate_rosters()
	_refresh_slot_editor(is_type)
	_refresh_pickers()


func _clear_slot(is_type: bool) -> void:
	var key := "type" if is_type else "persona"
	var idx: int = _slot_sel[key]
	if is_type:
		CustomSlots.clear_build(idx)
	else:
		CustomSlots.clear_persona(idx)
	_reset_draft(is_type)
	(_slot_ui[key]["name"] as LineEdit).text = ""
	_repopulate_rosters()
	_refresh_slot_editor(is_type)
	_refresh_pickers()


func _refresh_slot_editor(is_type: bool) -> void:
	var key := "type" if is_type else "persona"
	if not _slot_ui.has(key):
		return
	var ui: Dictionary = _slot_ui[key]
	var sel: int = _slot_sel[key]
	var saved: Array = CustomSlots.builds if is_type else CustomSlots.personas
	var btns: Array = ui["btns"]
	for i in btns.size():
		var b: Button = btns[i]
		b.set_pressed_no_signal(i == sel)
		if i < saved.size():
			b.text = String(saved[i]["name"])
			b.icon = Icons.custom_icon(i, is_type)
		else:
			b.text = "slot %d" % (i + 1)
			b.icon = null
	# selecting a filled slot loads it for editing
	if sel < saved.size():
		var stored: Dictionary = saved[sel][("props" if is_type else "traits")]
		var d := {}
		for f in (CustomSlots.build_props() if is_type else Personality.TRAITS):
			d[f] = float(stored.get(f, 0.2 if is_type else 0.5))
		if String((ui["name"] as LineEdit).text).strip_edges() != String(saved[sel]["name"]):
			(ui["name"] as LineEdit).text = String(saved[sel]["name"])
			ui["draft"] = d
	elif CustomSlots.build_slot(String((ui["name"] as LineEdit).text).strip_edges()) >= 0 \
			or CustomSlots.persona_slot(String((ui["name"] as LineEdit).text).strip_edges()) >= 0:
		# moved off a filled slot onto an empty one: don't leave the old name behind to be saved twice
		(ui["name"] as LineEdit).text = ""
		_reset_draft(is_type)
	_updating = true
	var draft: Dictionary = ui["draft"]
	var total := 0.0
	for f in draft:
		var s: HSlider = ui["sliders"][f]
		s.value = float(draft[f])
		(ui["vals"][f] as Label).text = "%.2f" % float(draft[f])
		total += float(draft[f])
	_updating = false
	var note: Label = ui["note"]
	if is_type:
		note.text = "%d of %d slots used - total %.2f, the five always come back to 1" % [saved.size(), CustomSlots.MAX_SLOTS, total]
	else:
		note.text = "%d of %d slots used" % [saved.size(), CustomSlots.MAX_SLOTS]


func _mini_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.8, 0.8, 0.86))
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l


# ------------------------------------------------- the per-player pickers and their key

## One icon-only button that opens a menu of icons and names, for a single robot. "Team"
## is always the first option and means "whatever the whole team is set to".
func _picker(t: int, idx: int, is_type: bool) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(32, 28)
	var pm := PopupMenu.new()
	pm.id_pressed.connect(func(id: int):
		var options: Array = ["Team"] + _roster(is_type)
		if id >= 0 and id < options.size():
			_on_pick(t, idx, is_type, String(options[id])))
	b.add_child(pm)
	b.pressed.connect(func():
		var origin := b.get_screen_transform().origin
		pm.popup(Rect2i(Vector2i(int(origin.x), int(origin.y + b.size.y)), Vector2i(0, 0))))
	_rosters.append({"kind": "menu", "node": pm, "is_type": is_type})
	return b


## Refill every dropdown and every pop-up menu from the live roster. Called once at startup and
## again whenever a slot is saved or cleared, so a new personality shows up everywhere at once.
func _repopulate_rosters() -> void:
	for r in _rosters:
		var is_type: bool = r["is_type"]
		var names: Array = _roster(is_type)
		if r["kind"] == "option":
			var ob: OptionButton = r["node"]
			var was := ob.get_item_text(ob.selected) if ob.selected >= 0 else ""
			ob.clear()
			for i in names.size():
				var n: String = names[i]
				ob.add_icon_item(_icon_for(n, is_type), n)
				ob.get_popup().set_item_tooltip(i, _describe(n, is_type))
			var back := names.find(was)
			ob.select(back if back >= 0 else 0)
		else:
			var pm: PopupMenu = r["node"]
			pm.clear()
			var options: Array = ["Team"] + names
			for i in options.size():
				var n: String = options[i]
				pm.add_icon_item(_icon_for(n, is_type) if n != "Team" else Icons.roster_icon("Team", -1, is_type), n, i)
				pm.set_item_tooltip(i, _describe(n, is_type))


## The key: icon / name / what it does, for both rosters, in one panel.
func _key_button() -> Button:
	var b := Button.new()
	b.text = "?"
	b.tooltip_text = "What the icons mean"
	b.custom_minimum_size = Vector2(28, 26)
	var pop := PopupPanel.new()
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.07, 0.08, 0.11, 1.0)      # opaque: it sits over the setup panel
	psb.border_color = Color(0.4, 0.44, 0.52)
	psb.set_border_width_all(1)
	psb.set_corner_radius_all(6)
	psb.set_content_margin_all(12)
	pop.add_theme_stylebox_override("panel", psb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	pop.add_child(vb)
	for pair in [["Personalities - how it behaves", _roster(false), false], ["Types - what a robot is", _roster(true), true]]:
		var hl := Label.new()
		hl.text = String(pair[0])
		hl.add_theme_font_size_override("font_size", 15)
		vb.add_child(hl)
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 3)
		vb.add_child(grid)
		var is_type: bool = pair[2]
		var list: Array = pair[1]
		for i in list.size():
			var n: String = list[i]
			if n == "Custom":
				continue
			var tr := TextureRect.new()
			tr.texture = _icon_for(n, is_type)
			tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
			tr.custom_minimum_size = Vector2(22, 22)
			grid.add_child(tr)
			grid.add_child(_cell(n, true, Color.WHITE, 13))
			var lines := _describe(n, is_type).split("\n")
			grid.add_child(_cell(lines[lines.size() - 1], false, Color(0.82, 0.82, 0.88), 13))
	var note := Label.new()
	note.text = "A robot set to Team (the ring) just follows whatever the team is set to."
	note.add_theme_font_size_override("font_size", 13)
	note.add_theme_color_override("font_color", Color(0.75, 0.75, 0.82))
	vb.add_child(note)
	b.add_child(pop)
	b.pressed.connect(func():
		var origin := b.get_screen_transform().origin
		var x := maxi(int(origin.x) - 260, 8)
		pop.popup(Rect2i(Vector2i(x, int(origin.y + b.size.y)), Vector2i(0, 0))))
	return b


## One line of plain English per entry - the same words the tooltip and the key both use.
func _describe(n: String, is_type: bool) -> String:
	var slot := CustomSlots.build_slot(n) if is_type else CustomSlots.persona_slot(n)
	if slot >= 0:
		return "%s\nYour own %s, slot %d" % [n, "type" if is_type else "personality", slot + 1]
	match n:
		"Team":
			return "Team\nFollow whatever the whole team is set to"
		"Random":
			return "Random\nRolled fresh for every robot at the start of the match"
		"Custom":
			return "Custom\nWhatever the sliders currently say"
		"Even":
			return "Even\nNo strengths, no holes - the reference build"
	if is_type:
		return "%s\n%s" % [n, String(RobotType.TYPE_HELP.get(n, "A mix of the five properties"))]
	var bits := PackedStringArray()
	var tp: Dictionary = Personality.PRESETS.get(n, {})
	for tr_name in Personality.TRAITS:
		if float(tp.get(tr_name, 0.5)) >= 0.7:
			bits.append(tr_name)
	return "%s\nHigh %s" % [n, ", ".join(bits)] if bits.size() > 0 else "%s\nNo strong leanings" % n


func _on_pick(t: int, idx: int, is_type: bool, name_picked: String) -> void:
	var v := "" if name_picked == "Team" else name_picked
	if is_type:
		manager.player_type[t][idx] = v
	else:
		manager.player_persona[t][idx] = v
	_refresh_pickers()


func _refresh_pickers() -> void:
	for t in 2:
		var tp: String = manager.team_preset_names[t]
		var tb: String = manager.team_build_names[t]
		for i in mini(MatchManager.TEAM_SIZE, MAX_PICKERS):
			var who := "%s%d" % [MatchManager.TEAM_NAMES[t][0], i + 1]
			var pn: String = String(manager.player_persona[t][i])
			var pb: Button = pp_btns[t][i]
			pb.icon = _icon_for(pn, false) if pn != "" else Icons.roster_icon("Team", -1, false)
			pb.tooltip_text = "%s personality: %s" % [who, _describe(pn if pn != "" else "Team", false)] \
				+ ("\n(the team is %s)" % tp if pn == "" else "")
			var bn: String = String(manager.player_type[t][i])
			var bb2: Button = pt_btns[t][i]
			bb2.icon = _icon_for(bn, true) if bn != "" else Icons.roster_icon("Team", -1, true)
			bb2.tooltip_text = "%s type: %s" % [who, _describe(bn if bn != "" else "Team", true)] \
				+ ("\n(the team is %s)" % tb if bn == "" else "")


func _build_results_overlay() -> void:
	var parts := _overlay("Results")
	results_overlay = parts[0]
	results_scroll = parts[1]
	results_box = parts[2]
	results_title = parts[3]
	# nothing starts by itself: the panel asks, you answer
	results_countdown = Label.new()
	results_countdown.add_theme_font_size_override("font_size", 13)
	results_countdown.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	next_row = HFlowContainer.new()
	next_row.add_theme_constant_override("h_separation", 10)
	next_row.add_theme_constant_override("v_separation", 6)
	var q := _cell("Start the next match?", true, Color.WHITE, 16)
	q.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	next_row.add_child(q)
	var same := Button.new()
	same.text = "Yes - same teams"
	same.pressed.connect(func(): _close_overlays(); new_match_requested.emit())
	next_row.add_child(same)
	var change := Button.new()
	change.text = "Change teams first"
	change.pressed.connect(func(): results_overlay.visible = false; teams_btn.button_pressed = true)
	next_row.add_child(change)
	var later := Button.new()
	later.text = "Not yet"
	later.pressed.connect(func(): results_overlay.visible = false; teams_btn.set_pressed_no_signal(false))
	next_row.add_child(later)


func on_match_started() -> void:
	results_overlay.visible = false
	set_countdown(0.0)


func _close_overlays() -> void:
	teams_overlay.visible = false
	results_overlay.visible = false
	custom_overlay.visible = false
	teams_btn.set_pressed_no_signal(false)
	if custom_btn != null:
		custom_btn.set_pressed_no_signal(false)


func _relayout() -> void:
	var vs := get_viewport().get_visible_rect().size
	var w := vs.x
	var h := vs.y
	teams_scroll.custom_minimum_size = Vector2(minf(880.0, w - 40.0), minf(640.0, h - 120.0))
	if custom_scroll != null:
		custom_scroll.custom_minimum_size = Vector2(minf(700.0, w - 40.0), maxf(minf(660.0, h - 230.0), 260.0))
	# results share the screen with the celebration: right half in landscape, lower part in portrait
	var rc: Control = results_overlay.get_child(0)
	if w > h:
		rc.anchor_left = 0.5
		rc.anchor_top = 0.0
		rc.offset_left = 0.0
		rc.offset_top = 96.0  # below the button rows
		results_scroll.custom_minimum_size = Vector2(minf(620.0, w * 0.5 - 40.0), minf(560.0, h - 210.0))
	else:
		rc.anchor_left = 0.0
		rc.anchor_top = 0.42
		rc.offset_left = 0.0
		rc.offset_top = 0.0
		results_scroll.custom_minimum_size = Vector2(minf(900.0, w - 40.0), minf(600.0, h * 0.58 - 90.0))


# ---------------------------------------------------------------- team setup

func _on_preset(t: int, preset_name: String) -> void:
	if preset_name == "Custom":
		manager.team_preset_names[t] = "Custom"
		return
	manager.team_personalities[t] = CustomSlots.resolve_persona(preset_name)
	manager.team_preset_names[t] = preset_name
	_refresh_sliders()


func _on_slider(t: int, trait_name: String, v: float) -> void:
	if _updating:
		return
	manager.team_personalities[t].set_trait(trait_name, v)
	slider_vals[t][trait_name].text = "%.2f" % v
	var lbl := manager.team_personalities[t].label()
	manager.team_preset_names[t] = lbl
	var idx := PRESET_LIST.find(lbl)
	preset_buttons[t].select(idx if idx >= 0 else PRESET_LIST.size() - 1)


func _on_type(t: int, preset_name: String) -> void:
	if preset_name == "Custom":
		manager.team_type_names[t] = "Custom"
		return
	manager.team_types[t] = CustomSlots.resolve_build(preset_name)
	manager.team_type_names[t] = preset_name
	_refresh_sliders()


## Dragging one type slider takes the difference out of the other four in proportion - the
## budget is the point, so it has to be visible.
func _on_type_slider(t: int, prop: String, v: float) -> void:
	if _updating:
		return
	manager.team_types[t].set_and_rebalance(prop, v)
	manager.team_type_names[t] = manager.team_types[t].label()
	_refresh_sliders()


func _refresh_sliders() -> void:
	_updating = true
	for t in 2:
		var p := manager.team_personalities[t]
		for trait_name in Personality.TRAITS:
			sliders[t][trait_name].value = p.get_trait(trait_name)
			slider_vals[t][trait_name].text = "%.2f" % p.get_trait(trait_name)
		var pnames: Array = _roster(false)
		var idx := pnames.find(manager.team_preset_names[t])
		if idx >= 0:
			preset_buttons[t].select(idx)
		var ty := manager.team_types[t]
		for prop in RobotType.PROPS:
			type_sliders[t][prop].value = ty.get_prop(prop)
			type_slider_vals[t][prop].text = "%.2f" % ty.get_prop(prop)
		var tnames: Array = _roster(true)
		var tidx := tnames.find(manager.team_type_names[t])
		if tidx >= 0:
			type_buttons[t].select(tidx)
	_updating = false
	_refresh_pickers()


func _set_speed(s: float) -> void:
	for b in speed_buttons:
		b.button_pressed = (b.text == "%dx" % int(s))
	speed_changed.emit(s)


# ---------------------------------------------------------------- live

func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0 or manager == null:
		return
	_tick = 0.2
	var tl := manager.elapsed
	timer_label.text = "%d:%02d" % [int(tl) / 60, int(tl) % 60]
	for t in 2:
		team_labels[t].text = "%s %d/%d  HP %d%%" % [MatchManager.TEAM_NAMES[t], manager.alive_count(t), MatchManager.TEAM_SIZE,
			int(round(100.0 * manager.team_hp(t) / manager.team_max_hp(t)))]
	if live_label.visible:
		var lines := PackedStringArray()
		for r in manager.robots:
			var rk := " [rock]" if r.held_rock != null else ""
			lines.append("%s %3d%% %s%s" % [r.robot_name, int(round(100.0 * r.hp / r.max_hp)), r.action, rk])
		live_label.text = "\n".join(lines)


func set_status(text: String) -> void:
	status_label.text = text


func set_countdown(_seconds: float) -> void:
	results_countdown.text = ""  # matches no longer start on a timer


# ---------------------------------------------------------------- results

func _clear_results() -> void:
	for c in results_box.get_children():
		results_box.remove_child(c)
		if c != results_countdown and c != next_row:
			c.queue_free()


func _cell(text: String, bold := false, color := Color.WHITE, size := 14) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_color_override("font_color", color.lightened(0.15))
	return l


static func _pct(hits: int, tries: int) -> String:
	return "%d%%" % int(round(100.0 * hits / tries)) if tries > 0 else "-"


func show_result(res: Dictionary) -> void:
	last_result = res
	results_btn.disabled = false
	_clear_results()
	teams_overlay.visible = false
	teams_btn.set_pressed_no_signal(false)
	# a match finishing while you are halfway through naming a slot must not shove a second
	# panel over the top of the first; the results are still a button away
	custom_overlay.visible = false
	if custom_btn != null:
		custom_btn.set_pressed_no_signal(false)
	var s: Dictionary = res["stats"]
	var wcol: Color = MatchManager.TEAM_COLORS[res["winner"]].lightened(0.25) if res["winner"] >= 0 else Color.WHITE
	results_title.text = "Match %d - %s wins by %s in %d s" % [res["match"], res["winner_name"], res["reason"], int(res["duration"])]
	results_title.add_theme_color_override("font_color", wcol)
	results_box.add_child(next_row)

	# team table
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 3)
	results_box.add_child(grid)
	grid.add_child(_cell(""))
	for t in 2:
		grid.add_child(_cell("%s (%s)" % [MatchManager.TEAM_NAMES[t], res["presets"][t]], true, MatchManager.TEAM_COLORS[t].lightened(0.2), 15))
	var rows := [
		["Alive", func(t): return "%d / %d" % [res["alive"][t], MatchManager.TEAM_SIZE]],
		["Team HP left", func(t): return "%d%%" % int(round(100.0 * res["hp"][t] / maxf(float(res.get("max_hp", [1.0, 1.0])[t]), 1.0)))],
		["Throws / hits", func(t): return "%d / %d  (%s)" % [s["throws"][t], s["rock_hits"][t], _pct(s["rock_hits"][t], s["throws"][t])]],
		["Punches / hits", func(t): return "%d / %d  (%s)" % [s["punches"][t], s["punch_hits"][t], _pct(s["punch_hits"][t], s["punches"][t])]],
		["Kicks / hits", func(t): return "%d / %d  (%s)" % [s["kicks"][t], s["kick_hits"][t], _pct(s["kick_hits"][t], s["kicks"][t])]],
		["Rock damage", func(t): return "%d" % int(s["damage"][t]["rock"])],
		["Punch damage", func(t): return "%d" % int(s["damage"][t]["punch"])],
		["Kick damage", func(t): return "%d" % int(s["damage"][t].get("kick", 0.0))],
		["Knockdowns dealt", func(t): return "%d" % s["knockdowns"][t]],
		["Kills (enemy dead)", func(t): return "%d" % s["kills"][t]],
		["Friendly-fire damage", func(t): return "%d" % int(s["friendly_fire"][t])],
		["Own goals (killed a mate)", func(t): return "%d" % int(s.get("own_goals", [0, 0])[t])],
	]
	for row in rows:
		grid.add_child(_cell(row[0], false, Color(0.8, 0.8, 0.85)))
		for t in 2:
			grid.add_child(_cell(row[1].call(t)))
	var hk: Array = s["hitbox_hist"].keys()
	hk.sort()
	var hparts := PackedStringArray()
	for k in hk:
		hparts.append("%s part%s: %d" % [str(k), "" if int(k) == 1 else "s", s["hitbox_hist"][k]])
	if hparts.size() > 0:
		results_box.add_child(_cell("Rock hits by parts struck - " + ", ".join(hparts), false, Color(0.8, 0.8, 0.85), 13))

	# per-robot table
	results_box.add_child(_cell("Robots", true, Color.WHITE, 16))
	var rg := GridContainer.new()
	rg.columns = 12
	rg.add_theme_constant_override("h_separation", 14)
	rg.add_theme_constant_override("v_separation", 2)
	results_box.add_child(rg)
	for hdr in ["Robot", "Type", "Personality", "Damage", "Rock", "Punch", "Kick", "Throw acc", "Punch acc", "Kick acc", "KD", "Kills / HP"]:
		rg.add_child(_cell(hdr, false, Color(0.75, 0.75, 0.8), 13))
	for r in res["robots"]:
		var col: Color = MatchManager.TEAM_COLORS[r["team"]].lightened(0.25)
		rg.add_child(_cell(r["name"], true, col))
		rg.add_child(_cell(String(r.get("type", "Even"))))
		rg.add_child(_cell(r["preset"]))
		rg.add_child(_cell("%d" % int(r["dmg_rock"] + r["dmg_punch"] + r.get("dmg_kick", 0.0))))
		rg.add_child(_cell("%d" % int(r["dmg_rock"])))
		rg.add_child(_cell("%d" % int(r["dmg_punch"])))
		rg.add_child(_cell("%d" % int(r.get("dmg_kick", 0.0))))
		rg.add_child(_cell("%d/%d %s" % [r["rock_hits"], r["throws"], _pct(r["rock_hits"], r["throws"])]))
		rg.add_child(_cell("%d/%d %s" % [r["punch_hits"], r["punches"], _pct(r["punch_hits"], r["punches"])]))
		rg.add_child(_cell("%d/%d %s" % [r.get("kick_hits", 0), r.get("kicks", 0), _pct(r.get("kick_hits", 0), r.get("kicks", 0))]))
		rg.add_child(_cell("%d" % r["knockdowns"]))
		rg.add_child(_cell("%d / %s" % [r["kills"], ("%d%%" % int(round(100.0 * r["hp"] / maxf(float(r.get("max_hp", Robot.MAX_HP)), 1.0)))) if r["alive"] else "dead"]))

	results_overlay.visible = true
	results_scroll.scroll_vertical = 0
	set_status("Match over. Close the panel to watch; New match (or Teams / setup) when ready.")


func show_batch(summary: Dictionary) -> void:
	_clear_results()
	results_title.text = "Batch results"
	results_title.add_theme_color_override("font_color", Color.WHITE)
	results_box.add_child(next_row)
	var l := _cell(summary["text"])
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = minf(820.0, get_viewport().get_visible_rect().size.x - 70.0)
	results_box.add_child(l)
	results_overlay.visible = true
