extends Control

signal node_chosen(node_id: String, token: int)

@export var node_size: Vector2
var _data: RefCounted
var _nodes: Array = []
var _buttons: Dictionary = {}
var _token := -1
var _blocked := false
var _submitted := false

@onready var canvas: Control = $Margin/Content/Canvas


func _ready() -> void:
	canvas.resized.connect(_place_nodes)


func render(state: Dictionary, data: RefCounted) -> void:
	_data = data
	_token = int(state.token)
	_blocked = state.get("persistence_error", "") != ""
	_submitted = false
	_nodes = state.map.get("nodes", []).duplicate(true)
	$Margin/Content/Title.text = data.text("ui.map_title")
	$Margin/Content/Hint.text = data.text("ui.map_hint")
	$Margin/Content/Boss.text = data.text("ui.map_boss", state.boss)
	for child in canvas.get_children():
		canvas.remove_child(child)
		child.queue_free()
	_buttons.clear()
	for node in _nodes:
		var button := Button.new()
		var status := "current" if node.current else ("visited" if node.visited else "unvisited")
		button.text = data.text(
			"ui.map_node", {"depth": node.depth, "kind": data.text("ui.node." + node.kind)}
		)
		if node.current:
			button.text = "● " + button.text
		elif node.visited:
			button.text = "✓ " + button.text
		button.tooltip_text = data.text("ui.map_status." + status)
		button.disabled = _blocked or not node.available
		button.custom_minimum_size = node_size
		button.size = node_size
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.pressed.connect(_on_node_pressed.bind(str(node.id), _token))
		canvas.add_child(button)
		_buttons[node.id] = button
	_place_nodes.call_deferred()


func _on_node_pressed(node_id: String, token: int) -> void:
	if not is_visible_in_tree() or _blocked or _submitted or token != _token:
		return
	var available := false
	for node in _nodes:
		if node.id == node_id:
			available = node.available
	if not available:
		return
	_submitted = true
	for button in _buttons.values():
		button.disabled = true
	node_chosen.emit(node_id, token)


func _place_nodes() -> void:
	if not is_node_ready():
		return
	var columns := 1
	var depth := 1
	for node in _nodes:
		columns = maxi(columns, int(node.column) + 1)
		depth = maxi(depth, int(node.depth))
	for node in _nodes:
		var button: Button = _buttons[node.id]
		# Font and theme margins can exceed the configured minimum node size.
		var extent: Vector2 = button.size.max(button.get_combined_minimum_size())
		button.size = extent
		button.position = Vector2(
			(canvas.size.x - extent.x) * (float(node.column) + 0.5) / columns,
			(canvas.size.y - extent.y) * float(int(node.depth) - 1) / maxi(1, depth - 1)
		)
	queue_redraw()


func _draw() -> void:
	if not is_node_ready():
		return
	for node in _nodes:
		if not _buttons.has(node.id):
			continue
		for next_id in node.next:
			if _buttons.has(next_id):
				var from: Vector2 = (
					_buttons[node.id].get_global_rect().get_center() - global_position
				)
				var to: Vector2 = _buttons[next_id].get_global_rect().get_center() - global_position
				draw_line(from, to, get_theme_color("route_line", "MapView"), 2.0)
