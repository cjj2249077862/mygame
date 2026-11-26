extends TextureRect

@export var parallax_distance := 7.0
@export var follow_speed := 2.0
var motion_enabled := true
var _offset := Vector2.ZERO


func _process(delta: float) -> void:
	var viewport_size: Vector2 = get_viewport_rect().size
	var destination := Vector2.ZERO
	if motion_enabled and viewport_size.x > 0 and viewport_size.y > 0:
		var cursor: Vector2 = get_viewport().get_mouse_position() / viewport_size
		cursor = cursor.clamp(Vector2.ZERO, Vector2.ONE)
		destination = (cursor - Vector2.ONE * 0.5) * parallax_distance
	_offset = _offset.lerp(destination, 1.0 - exp(-follow_speed * delta))
	position = Vector2(-12, -12) + _offset
