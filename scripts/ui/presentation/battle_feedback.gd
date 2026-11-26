extends Control

const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
const MAX_VISIBLE_BANNERS := 3
const MIN_BANNER_DURATION := 2.0
@export var damage_color: Color
@export var heal_color: Color
@export var shield_color: Color
@export var warning_color: Color
@export var success_color: Color
@export var number_font_size: int
@export var float_distance: float
@export var float_duration: float
@export var banner_duration: float

var _tweens: Array[Tween] = []
var _pending_banners: Array[Dictionary] = []
var _visible_banners: Array[Dictionary] = []


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	var expired := false
	for index in range(_visible_banners.size() - 1, -1, -1):
		var entry: Dictionary = _visible_banners[index]
		entry.remaining = float(entry.remaining) - delta
		if float(entry.remaining) <= 0.0:
			_visible_banners.remove_at(index)
			expired = true
	if expired:
		_fill_banner_slots()
		_render_banners()


func show_number(text: String, origin: Vector2, kind: String, fast: bool) -> void:
	_tweens = _tweens.filter(func(tween: Tween) -> bool: return tween.is_valid())
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", number_font_size)
	label.add_theme_color_override("font_color", color_for(kind))
	label.add_theme_color_override("font_outline_color", Color(0.03, 0.03, 0.04, 0.95))
	label.add_theme_constant_override("outline_size", 5)
	label.position = origin - Vector2(48, 16)
	label.size = Vector2(96, 48)
	var icon := TextureRect.new()
	var icon_key: String = {"damage": "attack", "block": "shield"}.get(kind, kind)
	icon.texture = Art.icon_texture(icon_key)
	icon.position = Vector2(-24, 6)
	icon.size = Vector2(28, 28)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_child(icon)
	$Numbers.add_child(label)
	var duration: float = float_duration * (0.45 if fast else 1.0)
	var tween := create_tween().set_parallel(true)
	_tweens.append(tween)
	tween.tween_property(label, "position:y", label.position.y - float_distance, duration)
	tween.tween_property(label, "modulate:a", 0.0, duration).set_delay(duration * 0.4)
	tween.chain().tween_callback(label.queue_free)


func show_banner(text: String, kind: String) -> void:
	if text.is_empty():
		return
	# New warnings never replace a still-readable warning, including in fast mode.
	_pending_banners.append({"text": text.replace("\n", " "), "kind": kind})
	_fill_banner_slots()
	_render_banners()
	set_process(true)


func _fill_banner_slots() -> void:
	while _visible_banners.size() < MAX_VISIBLE_BANNERS and not _pending_banners.is_empty():
		var entry: Dictionary = _pending_banners.pop_front()
		entry["remaining"] = maxf(MIN_BANNER_DURATION, banner_duration)
		_visible_banners.append(entry)


func _render_banners() -> void:
	var lines: Array[String] = []
	for entry in _visible_banners:
		lines.append(str(entry.text))
	$Banner/Text.text = "\n".join(lines)
	$Banner/Text.tooltip_text = $Banner/Text.text
	# Each line carries its own mechanic in words; one attention color keeps the
	# compact Label compatible with the existing UI/test path.
	$Banner/Text.add_theme_color_override("font_color", warning_color)
	$Banner.modulate.a = 1.0
	$Banner.visible = not lines.is_empty()
	if lines.is_empty():
		set_process(false)


func color_for(kind: String) -> Color:
	if kind in ["heal", "revive"]:
		return heal_color
	if kind in ["shield", "block", "dispel"]:
		return shield_color
	if kind in ["interrupt", "win"]:
		return success_color
	if kind in ["damage", "death", "loss", "bomb_explode"]:
		return damage_color
	return warning_color


func reset() -> void:
	for tween in _tweens:
		if tween.is_valid():
			tween.kill()
	_tweens.clear()
	_pending_banners.clear()
	_visible_banners.clear()
	set_process(false)
	for child in $Numbers.get_children():
		$Numbers.remove_child(child)
		child.queue_free()
	$Banner.hide()
	$Banner.modulate.a = 1.0
	$Banner/Text.text = ""
	$Banner/Text.tooltip_text = ""
