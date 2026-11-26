extends Control


func _draw() -> void:
	get_parent().draw_target_lines(self)
