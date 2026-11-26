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
	for status in unit.statuses:
		status_text.append(
			"%s %d" % [data.text("status." + status), engine.status_count(unit, status)]
		)
		status_help.append(data.status_details(status))
	$Content/Statuses.text = "　".join(status_text)
	$Content/Intent.text = ""
	if unit.hp <= 0:
		$Content/Intent.text = data.text("ui.dead")
	elif not unit.friendly and not unit.intent.is_empty():
		var target: Dictionary = engine.find_unit(unit.target_id)
		var amount: int = (
			engine.resolver.damage_value(unit, target, unit.intent.amount)
			if not target.is_empty()
			else 0
		)
		$Content/Intent.text = (
			data.text("ui.interrupted")
			if unit.interrupted
			else data.text(
				"ui.intent",
				{
					"kind": data.text("ui.kind." + unit.intent.kind),
					"target": data.text(target.get("name_key", "")),
					"amount": amount,
					"hits": unit.intent.hits,
					"status":
					data.text("status." + unit.intent.status) if unit.intent.status != "" else "",
					"stacks": unit.intent.stacks if unit.intent.status != "" else "",
					"immunity": data.text("ui.immune" if unit.immunity > 0 else "ui.not_immune")
				}
			)
		)
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
