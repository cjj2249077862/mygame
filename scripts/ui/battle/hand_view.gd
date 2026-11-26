extends HBoxContainer

signal card_selected(copy_id: int)


func render(hand: Array, data: RefCounted, engine: RefCounted, locked: bool, selected: int) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	for copy in hand:
		var button := Button.new()
		button.text = data.card_text(copy)
		button.tooltip_text = button.text
		button.custom_minimum_size = Vector2(180, 130)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.toggle_mode = true
		button.button_pressed = copy.copy_id == selected
		var allowed := false
		for caster_id in engine.legal_casters(copy.copy_id):
			for target_id in engine.legal_targets(copy.copy_id, caster_id):
				var options: Array = engine.dispel_options(copy.copy_id, target_id)
				if (
					engine.validate_play(
						copy.copy_id,
						caster_id,
						target_id,
						options[0] if not options.is_empty() else ""
					)
					== ""
				):
					allowed = true
		button.disabled = locked or not allowed
		button.pressed.connect(_on_card_pressed.bind(int(copy.copy_id)))
		add_child(button)


func _on_card_pressed(copy_id: int) -> void:
	card_selected.emit(copy_id)
