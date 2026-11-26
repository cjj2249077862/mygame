extends Node2D

# Small deterministic presentation strokes. No gameplay objects or RNG are read.
var _kind := ""
var _source := Vector2.ZERO
var _target := Vector2.ZERO
var _color := Color.WHITE
var _progress := 0.0


func configure(kind: String, source: Vector2, target: Vector2, fast: bool, tint: Color) -> void:
	_kind = kind
	_source = source
	_target = target
	_color = tint
	var duration: float = 0.28
	if kind in ["heal", "revive"]:
		duration = 0.56
	elif kind in ["shield", "block"]:
		duration = 0.42
	var tween: Tween = create_tween()
	tween.tween_method(_advance, 0.0, 1.0, duration * (0.45 if fast else 1.0))
	tween.tween_callback(queue_free)


func _advance(value: float) -> void:
	_progress = value
	queue_redraw()


func _draw() -> void:
	var strength: float = sin(_progress * PI)
	if strength <= 0.0:
		return
	match _kind:
		"damage", "bomb_explode":
			_draw_strike(strength)
		"heal", "revive":
			_draw_heal(strength)
		"shield", "block":
			_draw_shield(strength)
		"interrupt", "dispel":
			_draw_break(strength)


func _draw_strike(strength: float) -> void:
	var side: float = 1.0 if _target.x >= _source.x else -1.0
	var direction := Vector2(0.72 * side, -0.7)
	var extent: float = 30.0 + 36.0 * _progress
	var start: Vector2 = _target - direction * extent
	var end: Vector2 = _target + direction * extent
	draw_line(start, end, Color(0.2, 0.04, 0.01, strength * 0.55), 11.0, true)
	draw_line(start, end, _tint(_color, strength * 0.7), 5.0, true)
	draw_line(start, end, Color(1.0, 0.9, 0.63, strength), 1.8, true)
	for index in range(9):
		var angle: float = float(index) * 2.39996
		var ray := Vector2(cos(angle), sin(angle))
		var radius: float = (12.0 + float(index % 4) * 9.0) * _progress
		var point: Vector2 = _target + ray * radius
		draw_line(
			point, point + ray * (5.0 + strength * 6.0), Color(1.0, 0.69, 0.3, strength), 1.4, true
		)


func _draw_heal(strength: float) -> void:
	draw_set_transform(_target + Vector2(0, 32), 0.0, Vector2(1.0, 0.34))
	draw_arc(
		Vector2.ZERO, 26.0 + _progress * 22.0, 0, TAU, 48, _tint(_color, strength * 0.65), 2.0, true
	)
	draw_set_transform(Vector2.ZERO)
	for index in range(10):
		var phase: float = float(index) * 2.39996
		var spread: float = 16.0 + float(index % 3) * 8.0
		var point: Vector2 = (
			_target
			+ Vector2(
				sin(phase + _progress * 1.5) * spread,
				28.0 - _progress * (50.0 + float(index % 4) * 15.0)
			)
		)
		var gold: Color = Color(1.0, 0.87, 0.48) if index % 3 == 0 else _color
		draw_circle(point, 4.0, _tint(gold, strength * 0.15))
		draw_circle(point, 1.3 + float(index % 2), _tint(gold, strength))
		draw_line(
			point + Vector2(0, 5), point - Vector2(0, 4), _tint(gold, strength * 0.65), 1.0, true
		)


func _draw_shield(strength: float) -> void:
	var radius: float = 36.0 + _progress * 13.0
	draw_arc(_target, radius, -PI * 0.82, PI * 0.82, 48, _tint(_color, strength * 0.2), 9.0, true)
	draw_arc(_target, radius, -PI * 0.82, PI * 0.82, 48, _tint(_color, strength), 2.2, true)
	var points := PackedVector2Array(
		[
			_target + Vector2(-20, -23),
			_target + Vector2(0, -30),
			_target + Vector2(20, -23),
			_target + Vector2(16, 8),
			_target + Vector2(0, 27),
			_target + Vector2(-16, 8),
			_target + Vector2(-20, -23)
		]
	)
	draw_polyline(points, _tint(_color.lightened(0.35), strength * 0.8), 2.0, true)


func _draw_break(strength: float) -> void:
	for side in [-1.0, 1.0]:
		var drift := Vector2(side * _progress * 26.0, -_progress * 9.0)
		var points := PackedVector2Array(
			[
				_target + drift + Vector2(side * 3.0, -28),
				_target + drift + Vector2(side * 16.0, -11),
				_target + drift + Vector2(side * 8.0, 1),
				_target + drift + Vector2(side * 25.0, 22)
			]
		)
		draw_polyline(points, _tint(_color, strength * 0.2), 7.0, true)
		draw_polyline(points, Color(1.0, 0.92, 0.65, strength), 1.8, true)
	draw_arc(
		_target,
		24.0 + _progress * 25.0,
		0.2,
		PI - 0.2,
		24,
		_tint(_color, strength * 0.65),
		2.0,
		true
	)


func _tint(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)
