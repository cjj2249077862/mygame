extends Control

signal card_selected(copy_id: int)

const CardView = preload("res://scenes/presentation/card_view.tscn")
@export var card_minimum_size: Vector2
@export var hover_scale: float
@export var hover_lift: float
@export var selected_lift: float
@export var fan_angle: float
@export var fan_depth: float
@export var bottom_margin: float
@export var card_spacing_ratio: float
@export var layout_duration: float
var _hovered: Control
var _layout_tweens: Dictionary = {}


func _ready() -> void:
	resized.connect(layout_cards)


func render(hand: Array, data: RefCounted, engine: RefCounted, locked: bool, selected: int) -> void:
	_clear_motion()
	_hovered = null
	for child in get_children():
		remove_child(child)
		child.queue_free()
	for copy in hand:
		var button: Button = CardView.instantiate()
		button.layout_owner = self
		button.custom_minimum_size = card_minimum_size
		button.toggle_mode = true
		button.button_pressed = copy.copy_id == selected
		button.set_meta("copy_id", int(copy.copy_id))
		var allowed: bool = false
		var casters: Array = engine.legal_casters(copy.copy_id)
		var reason: String = "error.caster" if casters.is_empty() else "error.target"
		for caster_id in casters:
			for target_id in engine.legal_targets(copy.copy_id, caster_id):
				var options: Array = engine.dispel_options(copy.copy_id, target_id)
				reason = engine.validate_play(
					copy.copy_id, caster_id, target_id, options[0] if not options.is_empty() else ""
				)
				if reason == "":
					allowed = true
		button.disabled = locked or not allowed
		button.pressed.connect(_on_card_pressed.bind(int(copy.copy_id)))
		button.preview_requested.connect(_on_preview_requested)
		add_child(button)
		button.render(copy, data)
		if not allowed:
			button.tooltip_text += "\n" + data.text(reason)
	layout_cards()
	layout_cards.call_deferred()


func layout_cards(animated: bool = false) -> void:
	var count: int = get_child_count()
	if count == 0 or size.x <= 0 or size.y <= 0:
		return
	# Reserve room for the raised, enlarged card inside the hand region itself.
	var height: float = minf(
		card_minimum_size.y,
		maxf(120.0, (size.y - bottom_margin - fan_depth - hover_lift - 12.0) / hover_scale)
	)
	var card_size: Vector2 = Vector2(height * 2.0 / 3.0, height)
	var side_margin: float = height * sin(deg_to_rad(fan_angle)) + 10.0
	var available: float = maxf(card_size.x, size.x - side_margin * 2.0)
	var step: float = 0.0
	if count > 1:
		step = minf(card_size.x * card_spacing_ratio, (available - card_size.x) / float(count - 1))
	var span: float = card_size.x + step * float(count - 1)
	var origin: float = (size.x - span) * 0.5
	var baseline: float = size.y - height - bottom_margin - fan_depth - 8.0
	for index in range(count):
		var card: Button = get_child(index)
		card.custom_minimum_size = card_size
		card.size = card_size
		card.pivot_offset = Vector2(card_size.x * 0.5, card_size.y)
		var fraction: float = (float(index) / float(count - 1) * 2.0 - 1.0) if count > 1 else 0.0
		var position_goal: Vector2 = Vector2(
			origin + step * float(index), baseline + fan_depth * fraction * fraction
		)
		var rotation_goal: float = deg_to_rad(fraction * fan_angle)
		var scale_goal: Vector2 = Vector2.ONE
		card.z_index = index
		if card == _hovered:
			position_goal.y -= hover_lift
			rotation_goal = 0.0
			scale_goal = Vector2.ONE * hover_scale
			card.z_index = 100
		elif card.button_pressed:
			position_goal.y -= selected_lift
			rotation_goal *= 0.4
			scale_goal = Vector2.ONE * 1.025
			card.z_index = 50
		position_goal = _fit_pose(position_goal, card_size, scale_goal.x, rotation_goal)
		var previous: Tween = _layout_tweens.get(card.get_instance_id())
		if previous != null and previous.is_valid():
			previous.kill()
		if animated:
			var tween: Tween = create_tween().set_parallel(true).set_ease(Tween.EASE_OUT).set_trans(
				Tween.TRANS_CUBIC
			)
			_layout_tweens[card.get_instance_id()] = tween
			tween.tween_property(card, "position", position_goal, layout_duration)
			tween.tween_property(card, "rotation", rotation_goal, layout_duration)
			tween.tween_property(card, "scale", scale_goal, layout_duration)
		else:
			card.position = position_goal
			card.rotation = rotation_goal
			card.scale = scale_goal


func _fit_pose(
	position_goal: Vector2, card_size: Vector2, magnification: float, angle: float
) -> Vector2:
	var pivot: Vector2 = Vector2(card_size.x * 0.5, card_size.y)
	var corners: Array[Vector2] = [
		Vector2.ZERO, Vector2(card_size.x, 0), card_size, Vector2(0, card_size.y)
	]
	var bounds: Rect2 = Rect2(
		position_goal + pivot + ((corners[0] - pivot) * magnification).rotated(angle), Vector2.ZERO
	)
	for corner in corners:
		bounds = bounds.expand(
			position_goal + pivot + ((corner - pivot) * magnification).rotated(angle)
		)
	var shift: Vector2 = Vector2.ZERO
	shift.x = maxf(0.0, 5.0 - bounds.position.x) - maxf(0.0, bounds.end.x - size.x + 5.0)
	shift.y = maxf(0.0, 5.0 - bounds.position.y) - maxf(0.0, bounds.end.y - size.y + 5.0)
	return position_goal + shift


func accepts_card_point(card: Control, point: Vector2) -> bool:
	# Raised cards also own input over their neighbors, without reordering copies.
	if not is_instance_valid(_hovered) or card == _hovered:
		return true
	var global_point: Vector2 = card.get_global_transform() * point
	var hovered_point: Vector2 = _hovered.get_global_transform().affine_inverse() * global_point
	return not Rect2(Vector2.ZERO, _hovered.size).has_point(hovered_point)


func _on_preview_requested(card: Control, active: bool) -> void:
	if active:
		_hovered = card
	elif _hovered == card:
		_hovered = null
	layout_cards(true)


func _on_card_pressed(copy_id: int) -> void:
	card_selected.emit(copy_id)


func _clear_motion() -> void:
	for tween in _layout_tweens.values():
		if tween.is_valid():
			tween.kill()
	_layout_tweens.clear()


func _exit_tree() -> void:
	_clear_motion()
