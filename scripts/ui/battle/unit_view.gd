extends Button

signal unit_selected(unit_id: String)
signal unit_hovered(unit_id: String)
signal unit_unhovered(unit_id: String)

const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
const IntentSummary = preload("res://scripts/ui/battle/intent_summary.gd")
const HoverHelp = preload("res://scripts/ui/presentation/hover_help.gd")
@export var breath_amount: float
@export var breath_speed: float
@export var attack_distance: float
@export var cue_duration: float
@export var dead_tint: Color
@export var heal_tint: Color
@export var shield_tint: Color
@export var impact_tint: Color
@export var reduced_impact_tint: Color

var unit_id := ""
var _selected := false
var _alive := true
var _friendly := true
var _motion_enabled := true
var _flash_enabled := true
var _elapsed := 0.0
var _motion_tween: Tween
var _portrait_base := Vector2.ZERO
var _boss := false
var _data: RefCounted
var _base_tooltip := ""
var _incoming: Array = []
var _related := false
var _target_active := false
var _target_primary := false
var _unit_help: Array = []


func _ready() -> void:
	pressed.connect(_on_pressed)
	mouse_entered.connect(_on_hovered)
	mouse_exited.connect(_on_unhovered)
	$Content/Portrait.resized.connect(_on_portrait_resized)
	resized.connect(_layout_stage)
	for control in [
		$IntentPlate,
		$IntentBadge,
		$Content/Intent,
		$Content/IntentFlags,
		$Content/IntentTargets,
		$StatusBadge,
		$Content/Statuses,
		$Content/ThreatIcon,
		$Incoming
	]:
		_connect_help_hover(control)
	_layout_stage.call_deferred()


func configure_stage(boss: bool = false) -> void:
	_boss = boss
	$Content/Details.add_theme_font_size_override("font_size", 18 if boss else 15)
	if not _friendly:
		$Content/Role.texture = Art.icon_texture("boss" if boss else "attack")
	_layout_stage()


func set_incoming_intents(entries: Array) -> void:
	if entries == _incoming:
		return
	_incoming = entries.duplicate(true)
	_refresh_incoming()
	_layout_stage()


func set_related_highlight(active: bool) -> void:
	_related = active
	$RelatedHighlight.visible = active


func set_target_feedback(active: bool, primary: bool = false) -> void:
	_target_active = active
	_target_primary = primary and active
	$TargetHighlight.visible = active
	$TargetHint.visible = active
	$TargetHighlight.self_modulate = Color(1, 0.81, 0.35) if primary else Color(0.59, 0.95, 0.83)
	if _data != null:
		$TargetHint.text = _data.presentation_text(
			"presentation.target.primary" if _target_primary else "presentation.target.legal"
		)


func _get_tooltip(_at_position: Vector2) -> String:
	return "" if has_meta("help_sections") else tooltip_text


func _layout_stage() -> void:
	if not is_node_ready():
		return
	reset_presentation()
	var plate_width: float = minf(size.x - 12.0, 300.0 if _boss else 236.0)
	var plate_left: float = (size.x - plate_width) * 0.5
	var plate_top: float = size.y - 84.0
	var intent_height: float = 78.0 if $Content/IntentExtras.get_child_count() > 0 else 58.0
	var header_height: float = (
		intent_height + 4.0 if not _friendly else (30.0 if $Incoming.visible else 0.0)
	)
	var available := Vector2(size.x, maxf(plate_top + 3.0 - header_height, 1.0))
	var texture: Texture2D = $Content/Portrait.texture
	var natural: Vector2 = texture.get_size() if texture != null else Vector2(2.0, 3.0)
	var fit: float = minf(available.x / natural.x, available.y / natural.y)
	var portrait_size: Vector2 = natural * fit
	# Content carries the stage offset; Portrait keeps a zero animation origin.
	$Content.position = Vector2((size.x - portrait_size.x) * 0.5, plate_top + 3.0 - portrait_size.y)
	$Content.size = portrait_size
	$Content/Portrait.size = portrait_size
	$Nameplate.position = Vector2(plate_left, plate_top)
	$Nameplate.size = Vector2(plate_width, 66.0)
	_place_content($Content/Role, Vector2(plate_left + 7.0, plate_top + 4.0), Vector2(18, 20))
	_place_content(
		$Content/Details,
		Vector2(plate_left + 28.0, plate_top + 3.0),
		Vector2(plate_width - 35.0, 22)
	)
	_place_content(
		$Content/Health,
		Vector2(plate_left + 7.0, plate_top + 27.0),
		Vector2(plate_width - 14.0, 14)
	)
	var shield_left: float = plate_left + plate_width * (0.35 if _friendly else 0.22)
	var stat_width: float = maxf(12.0, plate_width * 0.5 - 30.0)
	_place_content($Content/ShieldIcon, Vector2(shield_left, plate_top + 45.0), Vector2(18, 18))
	_place_content(
		$Content/ShieldValue, Vector2(shield_left + 21.0, plate_top + 44.0), Vector2(stat_width, 20)
	)
	_place_content(
		$Content/ThreatIcon,
		Vector2(plate_left + plate_width * 0.75, plate_top + 43.0),
		Vector2(20, 20)
	)
	$StatusBadge.position = Vector2(plate_left + 4.0, plate_top + 69.0)
	$StatusBadge.size = Vector2(16, 16)
	_place_content(
		$Content/Statuses,
		Vector2(plate_left + (24.0 if $StatusBadge.visible else 0.0), plate_top + 67.0),
		Vector2(plate_width - (24.0 if $StatusBadge.visible else 0.0), 18)
	)
	$IntentPlate.position = Vector2(plate_left, 0)
	$IntentPlate.size = Vector2(plate_width, intent_height)
	$IntentPlate.visible = not _friendly and not $Content/Intent.text.is_empty()
	$IntentBadge.position = Vector2(plate_left + 5.0, 6.0)
	$IntentBadge.size = Vector2(20, 20)
	var targets_width: float = 38.0 if $Content/IntentTargets.get_child_count() > 0 else 0.0
	_place_content(
		$Content/Intent,
		Vector2(plate_left + 28.0, 3.0),
		Vector2(plate_width - 33.0 - targets_width, 27)
	)
	_place_content(
		$Content/IntentTargets, Vector2(plate_left + plate_width - 38.0, 3.0), Vector2(33, 27)
	)
	_place_content(
		$Content/IntentFlags, Vector2(plate_left + 5.0, 31.0), Vector2(plate_width - 10.0, 22)
	)
	_place_content(
		$Content/IntentExtras, Vector2(plate_left + 5.0, 55.0), Vector2(plate_width - 10.0, 20)
	)
	var intent_font: Font = $Content/Intent.get_theme_font("font")
	var intent_size: int = 16 if plate_width < 180.0 else 19
	while (
		intent_size > 11
		and (
			(
				intent_font
				. get_string_size($Content/Intent.text, HORIZONTAL_ALIGNMENT_LEFT, -1, intent_size)
				. x
			)
			> $Content/Intent.size.x
		)
	):
		intent_size -= 1
	$Content/Intent.add_theme_font_size_override("font_size", intent_size)
	$Content/IntentFlags.visible = not $Content/IntentFlags.text.is_empty()
	$Incoming.position = Vector2((size.x - 66.0) * 0.5, 0)
	$Incoming.size = Vector2(66, 28)
	for outline in [$RelatedHighlight, $TargetHighlight]:
		outline.position = Vector2(plate_left - 2.0, plate_top - 2.0)
		outline.size = Vector2(plate_width + 4.0, 70)
	$TargetHint.position = Vector2(plate_left, plate_top - 23.0)
	$TargetHint.size = Vector2(plate_width, 21)
	_on_portrait_resized()


func _place_content(control: Control, position_on_stage: Vector2, extent: Vector2) -> void:
	control.position = position_on_stage - $Content.position
	control.size = extent


func configure_presentation(options: Dictionary) -> void:
	_motion_enabled = bool(options.get("motion_enabled", true))
	_flash_enabled = bool(options.get("flash_enabled", true))
	if not _motion_enabled:
		$Content/Portrait.scale = Vector2.ONE


func _process(delta: float) -> void:
	if not is_visible_in_tree() or not _alive or not _motion_enabled:
		return
	_elapsed += delta
	var amount: float = sin(_elapsed * breath_speed + float(unit_id.hash() % 13)) * breath_amount
	$Content/Portrait.scale = Vector2(1.0 + amount * 0.35, 1.0 + amount)


func _on_portrait_resized() -> void:
	$Content/Portrait.pivot_offset = $Content/Portrait.size * Vector2(0.5, 1.0)


func render(
	unit: Dictionary, data: RefCounted, engine: RefCounted, highlighted: bool, selected: bool
) -> void:
	reset_presentation()
	_data = data
	if unit_id != str(unit.id):
		_incoming.clear()
	unit_id = unit.id
	_friendly = bool(unit.friendly)
	_alive = int(unit.hp) > 0
	text = ""
	var details: String = data.text(
		"ui.unit",
		{
			"name": data.text(unit.name_key),
			"hp": unit.hp,
			"max_hp": unit.max_hp,
			"shield": unit.shield,
			"threat": unit.threat
		}
	)
	$Content/Details.text = data.text(unit.name_key)
	$Content/Health.max_value = unit.max_hp
	$Content/Health.value = unit.hp
	$Content/Health/Value.text = "%d/%d" % [unit.hp, unit.max_hp]
	$Content/ShieldIcon.texture = Art.icon_texture("shield")
	$Content/ShieldValue.text = str(unit.shield)
	$Content/ThreatIcon.texture = Art.icon_texture("threat")
	$Content/ThreatValue.text = ""
	$Content/ThreatIcon.visible = not _friendly and _alive
	$Content/ThreatValue.hide()
	var threat_help: Array = [] if _friendly else data.threat_sections(unit, engine)
	$Content/ThreatIcon.tooltip_text = HoverHelp.plain_text(threat_help)
	HoverHelp.attach($Content/ThreatIcon, threat_help, true)
	var role: String = "boss" if _boss else "attack"
	if _friendly:
		role = str(data.definition("characters", str(unit.definition_id)).get("role", "tank"))
	$Content/Role.texture = Art.icon_texture(role)
	var portrait: Texture2D = Art.actor_texture(str(unit.definition_id))
	if portrait == null and unit.portrait != "":
		portrait = load(unit.portrait) as Texture2D
	if portrait == null:
		portrait = Art.icon_texture("attack")
	$Content/Portrait.visible = portrait != null
	$Content/Portrait.texture = portrait
	$Content/Portrait.modulate = Color.WHITE if _alive else dead_tint
	$StatusBadge.hide()
	$IntentBadge.hide()
	var status_text: Array[String] = []
	var status_help: Array[String] = []
	var status_sections: Array = []
	if unit.friendly:
		status_help.append(
			data.text(
				"ui.revive_quota",
				{"used": unit.get("revives_used", 0), "limit": unit.get("revive_limit", 1)}
			)
		)
	for status in unit.statuses:
		if not $StatusBadge.visible:
			$StatusBadge.texture = Art.icon_texture(str(status))
			$StatusBadge.visible = $StatusBadge.texture != null
		status_text.append(
			"%s %d" % [data.text("status." + status), engine.status_count(unit, status)]
		)
		status_help.append(data.status_details(status))
		status_sections.append_array(data.status_sections(str(status)))
	for mark in unit.get("marks", []):
		if mark.kind == "bomb":
			$StatusBadge.texture = Art.icon_texture("bomb")
			$StatusBadge.visible = $StatusBadge.texture != null
			status_text.append(data.text("ui.bomb_remaining", {"remaining": mark.remaining}))
			status_help.append(
				data.text("ui.bomb_snapshot", {"remaining": mark.remaining, "amount": mark.amount})
			)
			status_help.append(data.status_details("bomb"))
			if not unit.statuses.has("bomb"):
				status_sections.append_array(data.status_sections("bomb"))
	$Content/Statuses.text = "　".join(status_text)
	$Content/Intent.text = ""
	$Content/IntentFlags.text = ""
	_clear_children($Content/IntentExtras)
	_clear_children($Content/IntentTargets)
	var intent_details := ""
	if unit.hp <= 0:
		$Content/Intent.text = data.text("ui.dead")
		intent_details = $Content/Intent.text
	elif not unit.friendly and not unit.intent.is_empty():
		var preview: Dictionary = engine.intent_preview(unit.id)
		var intent_icon: String = (
			{"normal": "attack", "interruptible": "cast", "uninterruptible": "uninterruptible"}
			. get(str(preview.kind), "attack")
		)
		$IntentBadge.texture = Art.icon_texture(intent_icon)
		$IntentBadge.visible = $IntentBadge.texture != null
		$IntentBadge.tooltip_text = data.text("ui.kind." + str(preview.kind))
		var targets: Array[String] = []
		for target_id in preview.target_ids:
			var target: Dictionary = engine.find_unit(str(target_id))
			if not target.is_empty():
				targets.append(data.text(target.name_key))
		var lines: Array[String] = [
			data.text("ui.kind." + str(preview.kind)),
			data.text("ui.intent_targets", {"targets": " / ".join(targets)}),
			data.text("ui.interrupted") if unit.interrupted else str(preview.description),
			data.text("ui.immune" if preview.immune else "ui.not_immune")
		]
		var state_key: String = str(preview.kind)
		var flags: Array[String] = [data.presentation_text("presentation.intent." + state_key)]
		if preview.immune:
			flags.append(data.presentation_text("presentation.intent.immune"))
		if int(preview.boss_phase) > 0:
			var phase_text: String = data.text("ui.boss_phase", {"phase": preview.boss_phase})
			lines.append(phase_text)
			flags.append(phase_text)
		if preview.get("enraged", false):
			lines.append(data.text("ui.enraged"))
			flags.append(data.text("ui.enraged"))
		elif int(preview.enrage_turn) > 0:
			lines.append(data.text("ui.enrage_turn", {"turn": preview.enrage_turn}))
		intent_details = "\n".join(lines)
		var summary: Dictionary = IntentSummary.compact(preview, data)
		$Content/Intent.text = (
			data.text("ui.interrupted") if unit.interrupted else str(summary.value)
		)
		$IntentBadge.texture = Art.icon_texture(
			"interrupt" if unit.interrupted else str(summary.icon)
		)
		$IntentBadge.visible = $IntentBadge.texture != null
		if not unit.interrupted:
			_render_intent_extras(summary.extras)
			_render_intent_targets(summary, engine)
		$Content/IntentFlags.text = " · ".join(flags)
		set_meta("intent_preview", preview.duplicate(true))
	$Content/Intent.tooltip_text = intent_details
	$Content/IntentFlags.tooltip_text = intent_details
	$IntentPlate.tooltip_text = intent_details
	$IntentBadge.tooltip_text = intent_details
	_selected = selected
	set_pressed_no_signal(selected)
	$Nameplate.self_modulate = (
		get_theme_color("target_highlight", "UnitView") if selected else Color.WHITE
	)
	modulate = get_theme_color("target_highlight", "UnitView") if highlighted else Color.WHITE
	_base_tooltip = (
		details
		+ "\n"
		+ $Content/Statuses.text
		+ "\n"
		+ "\n".join(status_help)
		+ "\n"
		+ intent_details
	)
	$StatusBadge.tooltip_text = $Content/Statuses.text
	$Content/Statuses.tooltip_text = $Content/Statuses.text + "\n" + "\n".join(status_help)
	_unit_help = data.unit_sections(unit, engine)
	status_sections = _unique_sections(status_sections)
	HoverHelp.attach($StatusBadge, status_sections, true)
	HoverHelp.attach($Content/Statuses, status_sections, true)
	var intent_sections: Array = []
	if not intent_details.is_empty():
		intent_sections.append(
			{
				"id": "intent",
				"title": data.text(unit.name_key),
				"body": intent_details,
				"kind": "main"
			}
		)
	for control in [$IntentPlate, $IntentBadge, $Content/Intent, $Content/IntentFlags]:
		HoverHelp.attach(control, intent_sections, true)
	_refresh_incoming()
	set_target_feedback(_target_active, _target_primary)
	_layout_stage()


func _render_intent_extras(extras: Array) -> void:
	var limit: int = 2 if size.x < 150.0 else 3
	for index in range(mini(extras.size(), limit)):
		var extra: Dictionary = extras[index]
		var chip := HBoxContainer.new()
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_theme_constant_override("separation", 2)
		var icon := TextureRect.new()
		icon.texture = Art.icon_texture(str(extra.icon))
		icon.custom_minimum_size = Vector2(16, 18)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(icon)
		var value := Label.new()
		value.text = str(extra.value)
		value.add_theme_font_size_override("font_size", 12)
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(value)
		$Content/IntentExtras.add_child(chip)
		_connect_help_hover(chip)
		HoverHelp.attach(
			chip,
			[{"id": "intent_effect", "title": "", "body": str(extra.details), "kind": "keyword"}],
			true
		)
	if extras.size() > limit:
		var more := Label.new()
		more.text = "+%d" % (extras.size() - limit)
		more.add_theme_font_size_override("font_size", 12)
		more.mouse_filter = Control.MOUSE_FILTER_IGNORE
		$Content/IntentExtras.add_child(more)


func _render_intent_targets(preview: Dictionary, engine: RefCounted) -> void:
	var targets: Array = preview.get("target_ids", [])
	var names: Array[String] = []
	for id in targets:
		var target: Dictionary = engine.find_unit(str(id))
		if not target.is_empty():
			names.append(_data.text(target.name_key))
	if bool(preview.get("all_targets", false)):
		var all := Label.new()
		all.text = _data.presentation_text("presentation.intent.all_targets")
		all.add_theme_font_size_override("font_size", 12)
		all.mouse_filter = Control.MOUSE_FILTER_IGNORE
		$Content/IntentTargets.add_child(all)
	else:
		for id in targets.slice(0, 2):
			var target: Dictionary = engine.find_unit(str(id))
			if target.is_empty():
				continue
			var texture: Texture2D = Art.actor_texture(str(target.definition_id))
			if texture == null:
				continue
			var face := AtlasTexture.new()
			face.atlas = texture
			face.region = Rect2(
				texture.get_size() * Vector2(0.2, 0.0), texture.get_size() * Vector2(0.6, 0.34)
			)
			face.filter_clip = true
			var avatar := TextureRect.new()
			avatar.texture = face
			avatar.custom_minimum_size = Vector2(26 if targets.size() == 1 else 15, 26)
			avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			$Content/IntentTargets.add_child(avatar)
	var detail: String = _data.presentation_text(
		"presentation.intent.targets", {"targets": " / ".join(names)}
	)
	HoverHelp.attach(
		$Content/IntentTargets,
		[{"id": "intent_targets", "title": "", "body": detail, "kind": "main"}],
		true
	)


func _refresh_incoming() -> void:
	if not is_node_ready() or _data == null:
		return
	$Incoming.visible = _friendly and _alive and not _incoming.is_empty()
	$Incoming/Icon.texture = Art.icon_texture("attack")
	$Incoming/Count.text = str(_incoming.size())
	$Incoming.set_meta("incoming_entries", _incoming.duplicate(true))
	var help: Array = _unit_help.duplicate(true)
	tooltip_text = _base_tooltip
	var incoming_sections: Array = []
	if $Incoming.visible:
		var descriptions: Array[String] = []
		for entry in _incoming:
			descriptions.append(
				_data.presentation_text(
					"presentation.intent.incoming_entry",
					{
						"name": str(entry.get("name", "")),
						"description": str(entry.get("description", ""))
					}
				)
			)
		var title: String = _data.presentation_text(
			"presentation.intent.incoming", {"count": _incoming.size()}
		)
		var body: String = "\n".join(descriptions)
		incoming_sections.append({"id": "incoming", "title": title, "body": body, "kind": "main"})
		tooltip_text += "\n\n" + title + "\n" + body
	HoverHelp.attach($Incoming, incoming_sections, true)
	HoverHelp.attach(self, help)


func _clear_children(control: Node) -> void:
	for child in control.get_children():
		control.remove_child(child)
		child.queue_free()


func _unique_sections(sections: Array) -> Array:
	var unique: Array = []
	var seen: Dictionary = {}
	for section in sections:
		var key: String = str(section.get("id", ""))
		if key.is_empty():
			key = str(section.get("title", "")) + str(section.get("body", ""))
		if not seen.has(key):
			seen[key] = true
			unique.append(section)
	return unique


func _connect_help_hover(control: Control) -> void:
	control.mouse_filter = Control.MOUSE_FILTER_PASS
	control.mouse_entered.connect(_on_hovered)
	control.mouse_exited.connect(_on_unhovered)


func play_cue(kind: String, fast: bool = false) -> void:
	reset_presentation()
	var portrait: TextureRect = $Content/Portrait
	var duration: float = cue_duration * (0.45 if fast else 1.0)
	_motion_tween = create_tween()
	match kind:
		"cast":
			_motion_tween.tween_property(
				portrait,
				"position:x",
				_portrait_base.x + attack_distance * (1 if _friendly else -1),
				duration * 0.4
			)
			_motion_tween.tween_property(portrait, "position", _portrait_base, duration * 0.6)
		"death":
			_alive = false
			portrait.scale = Vector2.ONE
			_motion_tween.tween_property(portrait, "modulate", dead_tint, duration)
		"revive":
			_alive = true
			portrait.modulate = dead_tint
			_motion_tween.tween_property(portrait, "modulate", Color.WHITE, duration)
		_:
			var tint: Color = heal_tint if kind == "heal" else shield_tint
			if kind in ["damage", "bomb_explode"]:
				tint = impact_tint if _flash_enabled else reduced_impact_tint
			portrait.modulate = tint
			_motion_tween.tween_property(
				portrait, "modulate", Color.WHITE if _alive else dead_tint, duration
			)


func reset_presentation() -> void:
	if _motion_tween != null and _motion_tween.is_valid():
		_motion_tween.kill()
	$Content/Portrait.position = _portrait_base
	$Content/Portrait.scale = Vector2.ONE
	$Content/Portrait.modulate = Color.WHITE if _alive else dead_tint


func _on_pressed() -> void:
	# The controller owns selection; idle clicks must not leave a false pressed state.
	set_pressed_no_signal(_selected)
	unit_selected.emit(unit_id)


func _on_hovered() -> void:
	unit_hovered.emit(unit_id)


func _on_unhovered() -> void:
	if get_global_rect().has_point(get_global_mouse_position()):
		return
	unit_unhovered.emit(unit_id)
