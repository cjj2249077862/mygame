extends Button

signal unit_selected(unit_id: String)
signal unit_hovered(unit_id: String)
signal unit_unhovered(unit_id: String)

const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
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


func _ready() -> void:
	pressed.connect(_on_pressed)
	mouse_entered.connect(_on_hovered)
	mouse_exited.connect(_on_unhovered)
	$Content/Portrait.resized.connect(_on_portrait_resized)
	_on_portrait_resized.call_deferred()


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
	unit_id = unit.id
	_friendly = bool(unit.friendly)
	_alive = int(unit.hp) > 0
	text = ""
	$Content/Details.text = data.text(
		"ui.unit",
		{
			"name": data.text(unit.name_key),
			"hp": unit.hp,
			"max_hp": unit.max_hp,
			"shield": unit.shield,
			"threat": unit.threat
		}
	)
	$Content/Health.max_value = unit.max_hp
	$Content/Health.value = unit.hp
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
	for mark in unit.get("marks", []):
		if mark.kind == "bomb":
			$StatusBadge.texture = Art.icon_texture("bomb")
			$StatusBadge.visible = $StatusBadge.texture != null
			status_text.append(data.text("ui.bomb_remaining", {"remaining": mark.remaining}))
			status_help.append(
				data.text("ui.bomb_snapshot", {"remaining": mark.remaining, "amount": mark.amount})
			)
			status_help.append(data.status_details("bomb"))
	$Content/Statuses.text = "　".join(status_text)
	$Content/Intent.text = ""
	if unit.hp <= 0:
		$Content/Intent.text = data.text("ui.dead")
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
		if int(preview.boss_phase) > 0:
			lines.append(data.text("ui.boss_phase", {"phase": preview.boss_phase}))
		if preview.get("enraged", false):
			lines.append(data.text("ui.enraged"))
		elif int(preview.enrage_turn) > 0:
			lines.append(data.text("ui.enrage_turn", {"turn": preview.enrage_turn}))
		$Content/Intent.text = "\n".join(lines)
	_selected = selected
	set_pressed_no_signal(selected)
	modulate = get_theme_color("target_highlight", "UnitView") if highlighted else Color.WHITE
	tooltip_text = (
		$Content/Details.text
		+ "\n"
		+ $Content/Statuses.text
		+ "\n"
		+ "\n".join(status_help)
		+ "\n"
		+ $Content/Intent.text
	)
	$StatusBadge.tooltip_text = $Content/Statuses.text
	_on_portrait_resized.call_deferred()


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
	unit_unhovered.emit(unit_id)
