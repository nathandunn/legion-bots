class_name Hud
extends CanvasLayer
## All UI built in code: scoreboard, speed, team personality panel, results.

signal new_match_requested
signal batch_requested(n: int)
signal speed_changed(scale: float)

var manager: MatchManager
var timer_label: Label
var team_labels: Array[Label] = []
var live_label: Label
var result_label: Label
var panel: PanelContainer
var preset_buttons: Array[OptionButton] = []
var sliders := [{}, {}]
var slider_vals := [{}, {}]
var speed_buttons: Array[Button] = []
var _updating := false
var _tick := 0.0

const PRESET_LIST := ["Balanced", "Brawler", "Slinger", "Coward", "Tactician", "Random", "Custom"]


func setup(m: MatchManager) -> void:
	manager = m
	var theme := Theme.new()
	theme.default_font_size = 16
	var root := MarginContainer.new()
	root.theme = theme
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left", 10)
	root.add_theme_constant_override("margin_right", 10)
	root.add_theme_constant_override("margin_top", 8)
	root.add_theme_constant_override("margin_bottom", 8)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(vbox)

	# ---- top bar
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	vbox.add_child(top)

	timer_label = Label.new()
	timer_label.add_theme_font_size_override("font_size", 26)
	timer_label.text = "3:00"
	top.add_child(timer_label)

	for t in 2:
		var l := Label.new()
		l.add_theme_color_override("font_color", MatchManager.TEAM_COLORS[t].lightened(0.2))
		l.add_theme_font_size_override("font_size", 20)
		top.add_child(l)
		team_labels.append(l)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(spacer)

	for s in [1, 2, 4, 8]:
		var b := Button.new()
		b.text = "%dx" % s
		b.toggle_mode = true
		b.button_pressed = (s == 1)
		b.pressed.connect(func(): _set_speed(float(s)))
		top.add_child(b)
		speed_buttons.append(b)

	var teams_btn := Button.new()
	teams_btn.text = "Teams"
	teams_btn.toggle_mode = true
	teams_btn.toggled.connect(func(on: bool): panel.visible = on)
	top.add_child(teams_btn)

	var new_btn := Button.new()
	new_btn.text = "New match"
	new_btn.pressed.connect(func(): new_match_requested.emit())
	top.add_child(new_btn)

	var batch_btn := Button.new()
	batch_btn.text = "Batch x10"
	batch_btn.pressed.connect(func(): batch_requested.emit(10))
	top.add_child(batch_btn)

	# ---- middle: live list left, team panel right
	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(mid)

	live_label = Label.new()
	live_label.add_theme_font_size_override("font_size", 13)
	live_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 0.9))
	live_label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	live_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(live_label)

	var mid_spacer := Control.new()
	mid_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(mid_spacer)

	panel = PanelContainer.new()
	panel.visible = false
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var pbox := VBoxContainer.new()
	pbox.add_theme_constant_override("separation", 6)
	scroll.add_child(pbox)
	var hint := Label.new()
	hint.text = "Applies to the next match"
	hint.add_theme_font_size_override("font_size", 12)
	pbox.add_child(hint)
	for t in 2:
		pbox.add_child(_build_team_panel(t))

	# ---- bottom result
	result_label = Label.new()
	result_label.add_theme_font_size_override("font_size", 15)
	result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(result_label)

	_refresh_sliders()


func _build_team_panel(t: int) -> Control:
	var box := VBoxContainer.new()
	var title := Label.new()
	title.text = MatchManager.TEAM_NAMES[t]
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", MatchManager.TEAM_COLORS[t].lightened(0.2))
	box.add_child(title)

	var ob := OptionButton.new()
	for p in PRESET_LIST:
		ob.add_item(p)
	ob.select(0)
	ob.item_selected.connect(func(idx: int): _on_preset(t, PRESET_LIST[idx]))
	box.add_child(ob)
	preset_buttons.append(ob)

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
		s.custom_minimum_size.x = 130
		s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		s.value_changed.connect(func(v: float): _on_slider(t, trait_name, v))
		row.add_child(s)
		var vl := Label.new()
		vl.custom_minimum_size.x = 34
		row.add_child(vl)
		box.add_child(row)
		sliders[t][trait_name] = s
		slider_vals[t][trait_name] = vl
	return box


func _on_preset(t: int, preset_name: String) -> void:
	if preset_name == "Custom":
		manager.team_preset_names[t] = "Custom"
		return
	manager.team_personalities[t] = Personality.preset(preset_name)
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


func _refresh_sliders() -> void:
	_updating = true
	for t in 2:
		var p := manager.team_personalities[t]
		for trait_name in Personality.TRAITS:
			sliders[t][trait_name].value = p.get_trait(trait_name)
			slider_vals[t][trait_name].text = "%.2f" % p.get_trait(trait_name)
		var idx := PRESET_LIST.find(manager.team_preset_names[t])
		preset_buttons[t].select(idx if idx >= 0 else PRESET_LIST.size() - 1)
	_updating = false


func _set_speed(s: float) -> void:
	for b in speed_buttons:
		b.button_pressed = (b.text == "%dx" % int(s))
	speed_changed.emit(s)


func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0 or manager == null:
		return
	_tick = 0.2
	var tl := manager.time_left
	timer_label.text = "%d:%02d" % [int(tl) / 60, int(tl) % 60]
	for t in 2:
		team_labels[t].text = "%s %d/%d  HP %d" % [MatchManager.TEAM_NAMES[t], manager.alive_count(t), MatchManager.TEAM_SIZE, int(manager.team_hp(t))]
	var lines := PackedStringArray()
	for r in manager.robots:
		var rk := " [rock]" if r.held_rock != null else ""
		lines.append("%s %3d %s%s" % [r.robot_name, int(r.hp), r.action, rk])
	live_label.text = "\n".join(lines)


func show_result(res: Dictionary) -> void:
	var s: Dictionary = res["stats"]
	var txt := "Match %d: %s wins by %s in %ds  |  " % [res["match"], res["winner_name"], res["reason"], int(res["duration"])]
	for t in 2:
		txt += "%s(%s) rock %d / punch %d dmg, %d throws (%d hit), %d punches (%d hit)   " % [
			MatchManager.TEAM_NAMES[t], res["presets"][t],
			int(s["damage"][t]["rock"]), int(s["damage"][t]["punch"]),
			s["throws"][t], s["rock_hits"][t], s["punches"][t], s["punch_hits"][t]]
	result_label.text = txt


func show_batch(summary: Dictionary) -> void:
	result_label.text = summary["text"]
