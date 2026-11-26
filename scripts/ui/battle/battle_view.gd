extends Control

signal presentation_finished

const Types = preload("res://scripts/core/enums.gd")
const UnitView = preload("res://scenes/battle/unit_view.tscn")
var data: RefCounted
var engine: RefCounted
var deck: Array = []
var gold := 0
var selected_copy := -1
var selected_caster := ""
var pending_target := ""
var locked := false
var _generation := 0

@onready var hand = $Margin/Content/HandScroll/Hand
@onready var log_view = $Margin/Content/Middle/Log
@onready var hint = $Margin/Content/Hint
@onready var end_button = $Margin/Content/Actions/EndTurn
@onready var cast_button = $Margin/Content/Actions/Cast


func _ready() -> void:
	hand.card_selected.connect(_on_card_selected)
	end_button.pressed.connect(_on_end_pressed)
	cast_button.pressed.connect(_on_cast_pressed)
	cast_button.mouse_entered.connect(_on_cast_hovered)
	$Margin/Content/Actions/Cancel.pressed.connect(clear_selection)
	$Margin/Content/Actions/Piles.pressed.connect(_on_piles_pressed)
	$EndConfirm.confirmed.connect(_end_turn)
	$DispelConfirm.confirmed.connect(_on_dispel_confirmed)
	$DispelConfirm.canceled.connect(clear_selection)


func bind_battle(new_engine: RefCounted, game_data: RefCounted, run_deck: Array) -> void:
	if engine != null and engine.settled.is_connected(_on_settled):
		engine.settled.disconnect(_on_settled)
	_generation += 1
	engine = new_engine
	data = game_data
	deck = run_deck.duplicate(true)
	engine.settled.connect(_on_settled)
	locked = false
	selected_copy = -1
	selected_caster = ""
	pending_target = ""
	log_view.reset()
	for item in [
		[$Margin/Content/Actions/EndTurn, "ui.end_turn"],
		[$Margin/Content/Actions/Cast, "ui.cast"],
		[$Margin/Content/Actions/Cancel, "ui.cancel"],
		[$Margin/Content/Actions/Piles, "ui.piles"],
		[$Margin/Content/Actions/Fast, "ui.fast"]
	]:
		item[0].text = data.text(item[1])
	$EndConfirm.dialog_text = data.text("ui.confirm_end")
	$EndConfirm.ok_button_text = data.text("ui.confirm")
	$EndConfirm.cancel_button_text = data.text("ui.cancel")
	$DispelConfirm.title = data.text("ui.dispel")
	$DispelConfirm.ok_button_text = data.text("ui.dispel_confirm")
	$DispelConfirm.cancel_button_text = data.text("ui.cancel")
	$Piles.title = data.text("ui.piles")
	$Piles.ok_button_text = data.text("ui.close")


func refresh() -> void:
	if engine == null or not engine.state.has("hand"):
		return
	if selected_copy >= 0 and engine.find_card(selected_copy).is_empty():
		selected_copy = -1
		selected_caster = ""
	var state: Dictionary = engine.snapshot()
	$Margin/Content/Header.text = data.text(
		"ui.stats", {"turn": state.turn, "energy": state.energy, "gold": gold}
	)
	for pair in [
		[state.heroes, $Margin/Content/Middle/Field/Heroes],
		[state.enemies, $Margin/Content/Middle/Field/Enemies]
	]:
		var container = pair[1]
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
		for unit in pair[0]:
			var view = UnitView.instantiate()
			container.add_child(view)
			var highlighted: bool = false
			if selected_copy >= 0:
				highlighted = (
					unit.id
					in (
						engine.legal_casters(selected_copy)
						if selected_caster == ""
						else engine.legal_targets(selected_copy, selected_caster)
					)
				)
			view.render(unit, data, engine, highlighted, unit.id == selected_caster)
			view.unit_selected.connect(_on_unit_selected)
			view.unit_hovered.connect(_on_unit_hovered)
	hand.render(state.hand, data, engine, locked, selected_copy)
	end_button.disabled = locked or state.phase != Types.BattlePhase.PLAYER
	cast_button.visible = (
		selected_copy >= 0
		and selected_caster != ""
		and (
			data.definition("cards", engine.find_card(selected_copy).get("card_id", "")).get(
				"target"
			)
			== "self"
		)
	)
	cast_button.disabled = locked
	queue_redraw()


func clear_selection() -> void:
	selected_copy = -1
	selected_caster = ""
	pending_target = ""
	if data != null:
		hint.text = data.text("ui.select_card")
	refresh()


func _on_settled(records: Array, _snapshot: Dictionary) -> void:
	locked = true
	clear_selection()
	var generation := _generation
	var battle_at_start := engine
	for record in records:
		log_view.append_records([record], data, battle_at_start)
		var delay := 0.025 if $Margin/Content/Actions/Fast.button_pressed else 0.12
		await get_tree().create_timer(delay).timeout
		if generation != _generation:
			return
	locked = false
	refresh()
	presentation_finished.emit()


func _on_card_selected(copy_id: int) -> void:
	if locked:
		return
	selected_copy = copy_id
	selected_caster = ""
	var casters: Array = engine.legal_casters(copy_id)
	if casters.size() == 1:
		selected_caster = casters[0]
	hint.text = data.text("ui.select_caster" if selected_caster == "" else "ui.select_target")
	refresh()
	if cast_button.visible:
		hint.text = data.text("ui.confirm_self")


func _on_unit_selected(id: String) -> void:
	if locked or selected_copy < 0:
		return
	if selected_caster == "":
		if id in engine.legal_casters(selected_copy):
			selected_caster = id
			hint.text = data.text("ui.select_target")
			refresh()
		return
	if cast_button.visible:
		return
	var error: String = engine.validate_play(selected_copy, selected_caster, id)
	if error != "" and error != "error.dispel":
		hint.text = data.text(error)
		return
	var options: Array = engine.dispel_options(selected_copy, id)
	if options.size() > 1:
		pending_target = id
		$DispelConfirm/Choices.clear()
		for option in options:
			$DispelConfirm/Choices.add_item(data.text("status." + option))
			$DispelConfirm/Choices.set_item_metadata($DispelConfirm/Choices.item_count - 1, option)
		$DispelConfirm.popup_centered()
	else:
		_play(id, options[0] if not options.is_empty() else "")


func _on_unit_hovered(id: String) -> void:
	if locked or selected_copy < 0 or selected_caster == "":
		return
	var result: Dictionary = engine.preview(selected_copy, selected_caster, id)
	if result.error != "":
		hint.text = data.text(result.error)
		return
	var lines: Array[String] = []
	for change in result.changes:
		change["name"] = data.text(change.name_key)
		lines.append(data.text("ui.preview", change))
	hint.text = "　".join(lines)


func _on_cast_pressed() -> void:
	_play(selected_caster)


func _on_cast_hovered() -> void:
	_on_unit_hovered(selected_caster)


func _on_dispel_confirmed() -> void:
	var choice = $DispelConfirm/Choices.get_item_metadata($DispelConfirm/Choices.selected)
	_play(pending_target, str(choice))


func _play(target_id: String, status: String = "") -> void:
	if locked or selected_copy < 0:
		return
	var error: String = engine.play_card(selected_copy, selected_caster, target_id, status)
	if error != "":
		hint.text = data.text(error)


func _on_end_pressed() -> void:
	if locked:
		return
	clear_selection()
	if engine.has_playable_card():
		$EndConfirm.popup_centered()
	else:
		_end_turn()


func _end_turn() -> void:
	if not locked:
		clear_selection()
		engine.end_turn()


func _on_piles_pressed() -> void:
	var lines: Array[String] = []
	for pile in ["deck", "draw", "hand", "discard", "exhaust", "removed"]:
		lines.append(data.text("ui.pile." + pile))
		var cards: Array = deck if pile == "deck" else engine.state[pile].duplicate(true)
		# Never expose the live draw order, even in a text-only pile viewer.
		cards = cards.duplicate(true)
		cards.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				return a.card_id < b.card_id if a.card_id != b.card_id else a.copy_id < b.copy_id
		)
		for copy in cards:
			lines.append(data.card_text(copy).replace("\n", "　"))
		lines.append("")
	$Piles/Text.text = "\n".join(lines)
	$Piles.popup_centered(Vector2i(800, 550))


func _unhandled_input(event: InputEvent) -> void:
	if (
		visible
		and (
			event.is_action_pressed("ui_cancel")
			or (
				event is InputEventMouseButton
				and event.pressed
				and event.button_index == MOUSE_BUTTON_RIGHT
			)
		)
	):
		clear_selection()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	if engine == null or not engine.state.has("enemies"):
		return
	var views: Dictionary = {}
	for container in [$Margin/Content/Middle/Field/Heroes, $Margin/Content/Middle/Field/Enemies]:
		for view in container.get_children():
			views[view.unit_id] = view
	for enemy in engine.state.enemies:
		if (
			enemy.hp > 0
			and not enemy.interrupted
			and views.has(enemy.id)
			and views.has(enemy.target_id)
		):
			var start: Vector2 = views[enemy.id].get_global_rect().get_center() - global_position
			var finish: Vector2 = (
				views[enemy.target_id].get_global_rect().get_center() - global_position
			)
			draw_line(start, finish, Color(0.9, 0.55, 0.2, 0.55), 2)
