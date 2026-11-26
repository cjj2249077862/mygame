extends Control

signal card_selected(copy_id: int)

const CardView = preload("res://scenes/presentation/card_view.tscn")
const HoverHelp = preload("res://scripts/ui/presentation/hover_help.gd")
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
var _dragged_copy_id: int = -1
var _pointer_input_managed: bool = false
var _slot_bounds: Dictionary = {}
var _hit_regions: Dictionary = {}
var _battle_overlay: Control


func _ready() -> void:
	add_to_group("hover_help_sources")
	var ancestor: Node = get_parent()
	while ancestor != null:
		if ancestor.has_method("_modal_open"):
			_battle_overlay = ancestor as Control
			break
		ancestor = ancestor.get_parent()
	resized.connect(layout_cards)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_set_hovered_card(card_at_position(event.position))


func _process(_delta: float) -> void:
	# Pointer coordinates are stable while the card itself is moving under the mouse.
	_set_hovered_card(card_at_position(get_global_mouse_position()))


func render(hand: Array, data: RefCounted, engine: RefCounted, locked: bool, selected: int) -> void:
	_clear_motion()
	_hovered = null
	_slot_bounds.clear()
	_hit_regions.clear()
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
		button.set_meta("drag_input_managed", _pointer_input_managed)
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
		add_child(button)
		button.render(copy, data)
		if not allowed:
			button.tooltip_text += "\n" + data.text(reason)
			var sections: Array = button.get_meta("help_sections", []).duplicate(true)
			sections.append(
				{"id": "unavailable", "title": "", "body": data.text(reason), "kind": "main"}
			)
			HoverHelp.attach(button, sections)
	_apply_drag_visibility()
	layout_cards()
	layout_cards.call_deferred()


func set_pointer_input_managed(managed: bool) -> void:
	_pointer_input_managed = managed
	for card in get_children():
		card.set_meta("drag_input_managed", managed)


func card_at_position(global_point: Vector2) -> Button:
	if not is_visible_in_tree() or _dragged_copy_id >= 0:
		return null
	for window in get_tree().root.get_embedded_subwindows():
		if window.visible:
			return null
	if is_instance_valid(_battle_overlay):
		for path in ["Interaction/CasterPicker", "Interaction/Preview"]:
			var overlay: Control = _battle_overlay.get_node_or_null(path) as Control
			if overlay != null and overlay.is_visible_in_tree():
				if overlay.get_global_rect().has_point(global_point):
					return null
	var local_point: Vector2 = get_global_transform().affine_inverse() * global_point
	for child in get_children():
		var card: Button = child as Button
		if card == null or not card.is_visible_in_tree() or card.is_queued_for_deletion():
			continue
		var region: Rect2 = _hit_regions.get(card.get_instance_id(), Rect2())
		if region.has_point(local_point):
			return card
	return null


func hovered_card() -> Control:
	return _hovered if is_instance_valid(_hovered) else null


func help_hover_owner(global_point: Vector2) -> Control:
	return card_at_position(global_point)


func hover_region() -> Rect2:
	# layout_cards keeps both normal and raised card corners inside this region.
	return get_global_rect()


func help_exclusion_rect() -> Rect2:
	return hover_region()


func help_anchor_rect(card: Control) -> Rect2:
	var bounds: Rect2 = _slot_bounds.get(card.get_instance_id(), Rect2())
	return get_global_transform() * bounds


func _set_hovered_card(card: Control) -> void:
	if not is_inside_tree() or _hovered == card:
		return
	if is_instance_valid(_hovered):
		_hovered.set_layout_hover(false)
	_hovered = card
	if is_instance_valid(_hovered):
		_hovered.set_layout_hover(true)
	layout_cards(true)


func set_dragged_copy(copy_id: int) -> void:
	_dragged_copy_id = copy_id
	_set_hovered_card(null)
	_apply_drag_visibility()


func clear_dragged_copy() -> void:
	_dragged_copy_id = -1
	_apply_drag_visibility()
	_hovered = null
	layout_cards()


func _apply_drag_visibility() -> void:
	for card in get_children():
		var hidden_for_drag: bool = (
			int(card.get_meta("copy_id", -1)) == _dragged_copy_id and _dragged_copy_id >= 0
		)
		card.modulate.a = 0.0 if hidden_for_drag else 1.0
		card.set_drag_suppressed(_dragged_copy_id >= 0)


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
	var rest_bounds: Array[Rect2] = []
	var hover_bounds: Array[Rect2] = []
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
		var rest_position: Vector2 = _fit_pose(position_goal, card_size, 1.0, rotation_goal)
		var stable_bounds: Rect2 = _pose_bounds(rest_position, card_size, 1.0, rotation_goal)
		_slot_bounds[card.get_instance_id()] = stable_bounds
		rest_bounds.append(stable_bounds)
		var raised_position: Vector2 = _fit_pose(
			position_goal - Vector2(0, hover_lift), card_size, hover_scale, 0.0
		)
		hover_bounds.append(_pose_bounds(raised_position, card_size, hover_scale, 0.0))
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
	# Split overlapping faces at fixed slot-center midpoints. Raising a card never
	# expands its ownership over its neighbors, so horizontal browsing is monotonic.
	_hit_regions.clear()
	var band: Rect2 = rest_bounds[0].merge(hover_bounds[0])
	for index in range(1, count):
		band = band.merge(rest_bounds[index]).merge(hover_bounds[index])
	for index in range(count):
		var bounds: Rect2 = rest_bounds[index].merge(hover_bounds[index])
		var left: float = bounds.position.x
		var right: float = bounds.end.x
		if index > 0:
			left = (rest_bounds[index - 1].get_center().x + rest_bounds[index].get_center().x) * 0.5
		if index < count - 1:
			right = (
				(rest_bounds[index].get_center().x + rest_bounds[index + 1].get_center().x) * 0.5
			)
		_hit_regions[get_child(index).get_instance_id()] = Rect2(
			Vector2(left, band.position.y), Vector2(right - left, band.size.y)
		)


func _fit_pose(
	position_goal: Vector2, card_size: Vector2, magnification: float, angle: float
) -> Vector2:
	var bounds: Rect2 = _pose_bounds(position_goal, card_size, magnification, angle)
	var shift: Vector2 = Vector2.ZERO
	shift.x = maxf(0.0, 5.0 - bounds.position.x) - maxf(0.0, bounds.end.x - size.x + 5.0)
	shift.y = maxf(0.0, 5.0 - bounds.position.y) - maxf(0.0, bounds.end.y - size.y + 5.0)
	return position_goal + shift


func _pose_bounds(
	position_goal: Vector2, card_size: Vector2, magnification: float, angle: float
) -> Rect2:
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
	return bounds


func accepts_card_point(card: Control, point: Vector2) -> bool:
	var global_point: Vector2 = card.get_global_transform() * point
	return card_at_position(global_point) == card


func _on_card_pressed(copy_id: int) -> void:
	card_selected.emit(copy_id)


func _clear_motion() -> void:
	for tween in _layout_tweens.values():
		if tween.is_valid():
			tween.kill()
	_layout_tweens.clear()


func _exit_tree() -> void:
	_clear_motion()
