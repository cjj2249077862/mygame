extends Button

signal unit_selected(unit_id: String)
signal unit_hovered(unit_id: String)
signal unit_unhovered(unit_id: String)

var unit_id := ""
var _selected := false


func _ready() -> void:
	pressed.connect(_on_pressed)
	mouse_entered.connect(_on_hovered)
	mouse_exited.connect(_on_unhovered)


func render(
	unit: Dictionary, data: RefCounted, engine: RefCounted, highlighted: bool, selected: bool
) -> void:
	unit_id = unit.id
	text = ""
	$Content/Details.text = data.text(
		"ui.unit",
		{
			"name": data.text(unit.name_key),
			"hp": unit.hp,
			"max_hp": unit.max_hp,
			"shield": unit.shield,
			"threat": unit.threat
		}
	)
	$Content/Health.max_value = unit.max_hp
	$Content/Health.value = unit.hp
	$Content/Portrait.visible = unit.portrait != ""
	if unit.portrait != "":
		$Content/Portrait.texture = load(unit.portrait)
	var status_text: Array[String] = []
	var status_help: Array[String] = []
	if unit.friendly:
		status_help.append(
			data.text(
				"ui.revive_quota",
				{"used": unit.get("revives_used", 0), "limit": unit.get("revive_limit", 1)}
			)
		)
	for status in unit.statuses:
		status_text.append(
			"%s %d" % [data.text("status." + status), engine.status_count(unit, status)]
		)
		status_help.append(data.status_details(status))
	for mark in unit.get("marks", []):
		if mark.kind == "bomb":
			status_text.append(data.text("ui.bomb_remaining", {"remaining": mark.remaining}))
			status_help.append(
				data.text("ui.bomb_snapshot", {"remaining": mark.remaining, "amount": mark.amount})
			)
			status_help.append(data.status_details("bomb"))
	$Content/Statuses.text = "　".join(status_text)
	$Content/Intent.text = ""
	if unit.hp <= 0:
		$Content/Intent.text = data.text("ui.dead")
	elif not unit.friendly and not unit.intent.is_empty():
		var preview: Dictionary = engine.intent_preview(unit.id)
		var targets: Array[String] = []
		for target_id in preview.target_ids:
			var target: Dictionary = engine.find_unit(str(target_id))
			if not target.is_empty():
				targets.append(data.text(target.name_key))
		var lines: Array[String] = [
			data.text("ui.kind." + str(preview.kind)),
			data.text("ui.intent_targets", {"targets": " / ".join(targets)}),
			data.text("ui.interrupted") if unit.interrupted else str(preview.description),
			data.text("ui.immune" if preview.immune else "ui.not_immune")
		]
		if int(preview.boss_phase) > 0:
			lines.append(data.text("ui.boss_phase", {"phase": preview.boss_phase}))
		if preview.get("enraged", false):
			lines.append(data.text("ui.enraged"))
		elif int(preview.enrage_turn) > 0:
			lines.append(data.text("ui.enrage_turn", {"turn": preview.enrage_turn}))
		$Content/Intent.text = "\n".join(lines)
	_selected = selected
	set_pressed_no_signal(selected)
	modulate = get_theme_color("target_highlight", "UnitView") if highlighted else Color.WHITE
	tooltip_text = (
		$Content/Details.text
		+ "\n"
		+ $Content/Statuses.text
		+ "\n"
		+ "\n".join(status_help)
		+ "\n"
		+ $Content/Intent.text
	)


func _on_pressed() -> void:
	# The controller owns selection; idle clicks must not leave a false pressed state.
	set_pressed_no_signal(_selected)
	unit_selected.emit(unit_id)


func _on_hovered() -> void:
	unit_hovered.emit(unit_id)


func _on_unhovered() -> void:
	unit_unhovered.emit(unit_id)
