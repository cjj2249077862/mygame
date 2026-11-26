extends HBoxContainer

signal card_selected(copy_id: int)

const CardView = preload("res://scenes/presentation/card_view.tscn")
@export var card_minimum_size: Vector2


func render(hand: Array, data: RefCounted, engine: RefCounted, locked: bool, selected: int) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	for copy in hand:
		var button = CardView.instantiate()
		button.custom_minimum_size = card_minimum_size
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.toggle_mode = true
		button.button_pressed = copy.copy_id == selected
		var allowed := false
		var casters: Array = engine.legal_casters(copy.copy_id)
		var reason := "error.caster" if casters.is_empty() else "error.target"
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


func _on_card_pressed(copy_id: int) -> void:
	card_selected.emit(copy_id)
