extends Control

signal drag_state_changed(active: bool)

const CardView = preload("res://scenes/presentation/card_view.tscn")
@export var drag_threshold: float = 8.0
@export var ghost_scale_in_hand: float = 1.0
@export var ghost_scale_in_field: float = 0.72
@export var ghost_pointer_offset: Vector2 = Vector2(20, -24)
@export var ghost_viewport_margin: float = 8.0
@export var aim_line_width: float = 4.0
@export var aim_arrow_length: float = 20.0
@export var aim_arrow_half_width: float = 9.0
@export var aim_minimum_bend: float = 60.0
@export var aim_maximum_bend: float = 160.0
@export var aim_segments: int = 32

var _battle: Control
var _hand: Control
var _pressed_copy: int = -1
var _press_position: Vector2 = Vector2.ZERO
var _dragging: bool = false
var _consume_release: bool = false
var _cancelling: bool = false
var _ghost: Control
var _source_size: Vector2 = Vector2.ZERO
var _aiming: bool = false
var _aim_valid: bool = false
var _aim_scope: String = ""
var _aim_points := PackedVector2Array()


func _ready() -> void:
	_battle = get_parent() as Control
	# A scene child becomes ready before its parent's @onready fields.
	_hand = _battle.get_node("Margin/Content/HandScroll/Hand") as Control
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 200
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_meta("help_disabled", true)
	if _hand != null:
		_hand.set_pointer_input_managed(true)
	get_viewport().size_changed.connect(cancel)
	get_window().focus_exited.connect(cancel)


func is_dragging() -> bool:
	return _dragging


func is_aiming() -> bool:
	return _dragging and _aiming


func has_pointer_capture() -> bool:
	return _pressed_copy >= 0 or _dragging or _consume_release


func cancel() -> void:
	if _cancelling:
		return
	var had_action: bool = _pressed_copy >= 0 or _dragging or _consume_release
	_cancelling = true
	_clear_visuals_and_candidate()
	if had_action and is_instance_valid(_battle):
		_battle.cancel_card_drag()
	_cancelling = false


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button_event: InputEventMouseButton = event as InputEventMouseButton
		if button_event.button_index == MOUSE_BUTTON_RIGHT and button_event.pressed:
			if has_pointer_capture():
				cancel()
				get_viewport().set_input_as_handled()
			return
		if button_event.button_index != MOUSE_BUTTON_LEFT:
			return
		if button_event.pressed:
			_begin_candidate(button_event.position)
		elif _consume_release:
			_finish_pointer(button_event.position)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and (_pressed_copy >= 0 or _dragging):
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		if not _can_interact() or (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			cancel()
		elif not _dragging and motion.position.distance_to(_press_position) >= drag_threshold:
			_start_drag(motion.position)
		elif _dragging:
			_update_drag(motion.position)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") and has_pointer_capture():
		cancel()
		get_viewport().set_input_as_handled()


func _begin_candidate(global_point: Vector2) -> void:
	# A fresh press also clears a release swallowed after an out-of-window cancel.
	_consume_release = false
	if not _can_interact():
		return
	for path in ["Interaction/CasterPicker", "Interaction/Preview"]:
		var overlay: Control = _battle.get_node_or_null(path) as Control
		if overlay != null and overlay.is_visible_in_tree():
			if overlay.get_global_rect().has_point(global_point):
				return
	var card: Button = _hand.card_at_position(global_point)
	if card == null or card.disabled:
		return
	_pressed_copy = int(card.get_meta("copy_id", -1))
	if _pressed_copy < 0:
		return
	_press_position = global_point
	_source_size = card.size
	_consume_release = true
	# Capture both ends here: BaseButton's release must not emit a second click.
	get_viewport().set_input_as_handled()


func _start_drag(global_point: Vector2) -> void:
	var copy: Dictionary = _battle.engine.find_card(_pressed_copy).duplicate(true)
	if copy.is_empty():
		cancel()
		return
	if not _battle.prepare_card_drag(_pressed_copy):
		# A multi-caster picker may have opened. Keep it, but consume this release.
		_pressed_copy = -1
		return
	_dragging = true
	_aim_scope = str(_battle.data.definition("cards", copy.card_id).target)
	_aiming = _aim_scope not in ["self", "none"]
	_hand.set_dragged_copy(_pressed_copy, not _aiming)
	if not _aiming:
		_create_ghost(copy)
	drag_state_changed.emit(true)
	_update_drag(global_point)


func _update_drag(global_point: Vector2) -> void:
	_battle.update_card_drag(global_point)
	if not _dragging:
		return
	if _aiming:
		_update_aim(global_point)
		return
	if _ghost == null:
		return
	var hand_point: Vector2 = _hand.get_global_transform().affine_inverse() * global_point
	var in_hand: bool = Rect2(Vector2.ZERO, _hand.size).has_point(hand_point)
	var magnification: float = ghost_scale_in_hand if in_hand else ghost_scale_in_field
	_ghost.scale = Vector2.ONE * magnification
	var extent: Vector2 = _ghost.size * magnification
	var position_global: Vector2 = global_point + ghost_pointer_offset - Vector2(0, extent.y * 0.5)
	var bounds: Rect2 = get_viewport_rect().grow(-ghost_viewport_margin)
	if position_global.x + extent.x > bounds.end.x:
		position_global.x = global_point.x - extent.x - absf(ghost_pointer_offset.x)
	position_global.x = clampf(
		position_global.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - extent.x)
	)
	position_global.y = clampf(
		position_global.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - extent.y)
	)
	_ghost.position = get_global_transform().affine_inverse() * position_global


func _update_aim(global_point: Vector2) -> void:
	var inverse: Transform2D = get_global_transform().affine_inverse()
	var origin: Vector2 = inverse * _hand.aim_origin(_pressed_copy)
	var destination: Vector2 = inverse * global_point
	var difference: Vector2 = destination - origin
	var bend: float = clampf(
		absf(difference.x) * 0.18 + absf(difference.y) * 0.35, aim_minimum_bend, aim_maximum_bend
	)
	var control_start: Vector2 = origin + Vector2(0, -bend)
	var control_end: Vector2 = destination + Vector2(-difference.x * 0.2, bend * 0.45)
	_aim_points.clear()
	for index in range(maxi(aim_segments, 2) + 1):
		var t: float = float(index) / float(maxi(aim_segments, 2))
		_aim_points.append(origin.bezier_interpolate(control_start, control_end, destination, t))
	var target_id: String = str(_battle.hovered_target)
	_aim_valid = target_id != "" and _battle._target_is_legal(target_id)
	queue_redraw()


func _draw() -> void:
	if not is_aiming() or _aim_points.size() < 2:
		return
	var color_name: String = "neutral"
	if _aim_valid:
		color_name = "enemy" if _aim_scope == "enemy" else "ally"
	elif str(_battle.hovered_target) != "":
		color_name = "invalid"
	var color: Color = get_theme_color(color_name, "TargetAim")
	var outline: Color = get_theme_color("outline", "TargetAim")
	draw_polyline(_aim_points, outline, aim_line_width + 4.0, true)
	draw_polyline(_aim_points, color, aim_line_width, true)
	var tip: Vector2 = _aim_points[_aim_points.size() - 1]
	var tangent: Vector2 = (tip - _aim_points[_aim_points.size() - 2]).normalized()
	var side := Vector2(-tangent.y, tangent.x)
	var base: Vector2 = tip - tangent * aim_arrow_length
	var arrow := PackedVector2Array(
		[tip, base + side * aim_arrow_half_width, base - side * aim_arrow_half_width]
	)
	draw_colored_polygon(arrow, color)
	arrow.append(tip)
	draw_polyline(arrow, outline, 1.5, true)


func _finish_pointer(global_point: Vector2) -> void:
	var was_dragging: bool = _dragging
	var copy_id: int = _pressed_copy
	var released_card: Button = _hand.card_at_position(global_point) if _hand != null else null
	var short_click: bool = (
		not was_dragging
		and copy_id >= 0
		and released_card != null
		and int(released_card.get_meta("copy_id", -1)) == copy_id
	)
	_consume_release = false
	if not _can_interact():
		cancel()
		return
	_clear_visuals_and_candidate()
	if was_dragging:
		_battle.finish_card_drag(global_point)
	elif short_click:
		_battle._on_card_selected(copy_id)


func _create_ghost(copy: Dictionary) -> void:
	_ghost = Control.new()
	_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost.set_meta("help_disabled", true)
	_ghost.size = _source_size
	add_child(_ghost)
	var card: Button = CardView.instantiate()
	card.custom_minimum_size = Vector2.ZERO
	card.size = _source_size
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.focus_mode = Control.FOCUS_NONE
	card.set_meta("help_disabled", true)
	_ghost.add_child(card)
	card.render(copy, _battle.data)


func _clear_visuals_and_candidate() -> void:
	var was_dragging: bool = _dragging
	_pressed_copy = -1
	_dragging = false
	_aiming = false
	_aim_valid = false
	_aim_scope = ""
	_aim_points.clear()
	queue_redraw()
	if is_instance_valid(_hand):
		_hand.clear_dragged_copy()
	if is_instance_valid(_ghost):
		remove_child(_ghost)
		_ghost.queue_free()
	_ghost = null
	if was_dragging:
		drag_state_changed.emit(false)


func _can_interact() -> bool:
	return (
		is_instance_valid(_battle)
		and is_instance_valid(_hand)
		and _battle.is_visible_in_tree()
		and bool(_battle.get("_active"))
		and not bool(_battle.get("locked"))
		and not bool(_battle.get("externally_blocked"))
		and not _battle._modal_open()
		and _battle.engine != null
	)


func _exit_tree() -> void:
	_clear_visuals_and_candidate()
	if is_instance_valid(_hand):
		_hand.set_pointer_input_managed(false)
