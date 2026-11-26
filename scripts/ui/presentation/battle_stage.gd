extends Control

@export var hand_height := 310.0
@export var rail_width := 170.0
@export var stage_gap := 32.0
@export var table_color := Color(0.025, 0.027, 0.033, 0.94)
@export var rim_color := Color(0.57, 0.41, 0.22, 0.9)
var _hand_height := 310.0


func _ready() -> void:
	resized.connect(layout_stage)
	layout_stage.call_deferred()


func layout_stage() -> void:
	if not is_node_ready() or size.x <= 0 or size.y <= 0:
		return
	_hand_height = minf(hand_height, size.y * 0.42)
	var floor_y: float = size.y - _hand_height - stage_gap
	_set_rect($Header, Rect2(4, 0, size.x - 8, 28))
	_set_rect($Middle, Rect2(0, 32, size.x, maxf(220, floor_y - 32)))
	_set_rect($Middle/Field, Rect2(Vector2.ZERO, $Middle.size))
	_set_rect($Middle/Field/Heroes, Rect2(8, 0, size.x * 0.53, $Middle.size.y))
	_set_rect($Middle/Field/Enemies, Rect2(size.x * 0.61, 0, size.x * 0.38 - 8, $Middle.size.y))
	_arrange_side($Middle/Field/Heroes, false)
	_arrange_side($Middle/Field/Enemies, true)
	_set_rect($Middle/Log, Rect2(size.x - 330, 0, 320, minf(220, $Middle.size.y)))
	_set_rect(
		$Hint, Rect2(rail_width + 8, floor_y + 2, size.x - rail_width * 2 - 16, stage_gap - 4)
	)
	_set_rect(
		$HandScroll,
		Rect2(rail_width + 8, size.y - _hand_height, size.x - rail_width * 2 - 16, _hand_height)
	)
	_set_rect($HandScroll/Hand, Rect2(Vector2.ZERO, $HandScroll.size))
	_set_rect($Actions, Rect2(Vector2.ZERO, size))
	_set_rect($Energy, Rect2(18, size.y - 278, 116, 116))
	_set_rect($Actions/Piles, Rect2(5, size.y - 151, rail_width - 12, 40))
	_set_rect($Actions/Discard, Rect2(5, size.y - 106, rail_width - 12, 40))
	_set_rect($Actions/Exhaust, Rect2(5, size.y - 61, rail_width - 12, 40))
	_set_rect($Actions/Fast, Rect2(size.x - rail_width, size.y - 54, rail_width, 42))
	_set_rect($Actions/EndTurn, Rect2(size.x - rail_width, size.y - 160, rail_width, 64))
	_set_rect($Actions/Cancel, Rect2(size.x - rail_width, size.y - 94, rail_width, 36))
	_set_rect($Actions/Cast, Rect2(size.x - rail_width, size.y - 210, rail_width, 44))
	queue_redraw()


func _arrange_side(container: Control, enemies: bool) -> void:
	var count: int = container.get_child_count()
	if count == 0:
		return
	var step: float = container.size.x / count
	for index in range(count):
		var actor: Control = container.get_child(index)
		var width: float = minf(
			step + 12, container.size.y * (0.8 if enemies and count == 1 else 0.65)
		)
		var height: float = container.size.y
		if enemies and count > 1:
			height *= 0.9 if index % 2 else 0.96
		_set_rect(
			actor,
			Rect2(index * step + (step - width) * 0.5, container.size.y - height, width, height)
		)


func _set_rect(control: Control, area: Rect2) -> void:
	control.position = area.position
	control.size = area.size


func _draw() -> void:
	var points: PackedVector2Array = PackedVector2Array()
	var rim: PackedVector2Array = PackedVector2Array()
	for index in range(49):
		var ratio: float = float(index) / 48.0
		var point: Vector2 = Vector2(
			size.x * ratio, size.y - _hand_height + 66 + 28 * pow(2 * ratio - 1, 2)
		)
		points.append(point)
		rim.append(point)
	points.append(Vector2(size.x + 24, size.y + 24))
	points.append(Vector2(-24, size.y + 24))
	draw_colored_polygon(points, table_color)
	draw_polyline(rim, rim_color, 2, true)
	if is_node_ready():
		var center: Vector2 = $Energy.position + $Energy.size * 0.5
		var radius: float = $Energy.size.x * 0.5
		draw_circle(center, radius + 3, Color(0.015, 0.045, 0.08, 0.97))
		draw_arc(center, radius + 1, 0, TAU, 80, rim_color, 4, true)
		draw_arc(center, radius + 6, 0, TAU, 80, Color(0.3, 0.24, 0.17, 1), 1, true)
