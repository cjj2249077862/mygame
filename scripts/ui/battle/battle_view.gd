extends Control

signal presentation_finished
signal presentation_event(record: Dictionary, fast: bool)

const Types = preload("res://scripts/core/enums.gd")
const UnitView = preload("res://scenes/battle/unit_view.tscn")
const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
@export var event_duration: float
@export var fast_event_duration: float
@export var shake_angle: float
@export var shake_duration: float
@export var piles_preferred_size: Vector2i
@export var dispel_preferred_size: Vector2i
@export var popup_margin: Vector2i
var data: RefCounted
var engine: RefCounted
var deck: Array = []
var gold := 0
var selected_copy := -1
var selected_caster := ""
var pending_target := ""
var hovered_target := ""
var chosen_status := ""
var locked := false
var externally_blocked := false
var _generation := 0
var _active := false
var _has_presented_state := false
var _options: Dictionary = {
	"shake_enabled": true, "flash_enabled": true, "show_log": true, "fast": false
}
var _shake_tween: Tween
var _intent_cues: Dictionary = {}
var _intent_targets: Dictionary = {}
var _pending_card: Dictionary = {}
var _drag_active := false
var _preparing_drag := false
var _related_unit := ""
const PILE_KEYS := ["deck", "draw", "hand", "discard", "exhaust", "removed"]

@onready var hand = $Margin/Content/HandScroll/Hand
@onready var log_view = $Margin/Content/Middle/Log
@onready var hint = $Margin/Content/Hint
@onready var end_button = $Margin/Content/Actions/EndTurn
@onready var cast_button = $Margin/Content/Actions/Cast
@onready var dispel_choices = $DispelConfirm/Content/Choices
@onready var dispel_preview = $DispelConfirm/Content/Preview


func _ready() -> void:
	hand.card_selected.connect(_on_card_selected)
	end_button.pressed.connect(_on_end_pressed)
	cast_button.pressed.connect(_on_cast_pressed)
	cast_button.mouse_entered.connect(_on_cast_hovered)
	$Margin/Content/Actions/Cancel.pressed.connect(clear_selection)
	$Margin/Content/Actions/Piles.pressed.connect(_on_piles_pressed.bind("draw"))
	$Margin/Content/Actions/Discard.pressed.connect(_on_piles_pressed.bind("discard"))
	$Piles/Tabs.tab_changed.connect(_on_pile_tab_changed)
	$Margin/Content/Actions/Piles.icon = Art.icon_texture("draw")
	$Margin/Content/Actions/Discard.icon = Art.icon_texture("discard")
	$Margin/Content/Energy.texture = Art.icon_texture("energy")
	$EndConfirm.confirmed.connect(_end_turn)
	$DispelConfirm.confirmed.connect(_on_dispel_confirmed)
	$DispelConfirm.canceled.connect(clear_selection)
	dispel_choices.item_selected.connect(_on_dispel_selected)
	resized.connect(_on_layout_changed)
	for dialog in [$EndConfirm, $DispelConfirm, $Piles]:
		dialog.window_input.connect(_on_dialog_input.bind(dialog))
	configure_presentation(_options)


func configure_presentation(options: Dictionary) -> void:
	_options.merge(options, true)
	if not is_node_ready():
		return
	log_view.visible = bool(_options.get("show_log", true))
	if options.has("fast"):
		$Margin/Content/Actions/Fast.set_pressed_no_signal(bool(options.fast))
	for view in _unit_views().values():
		view.configure_presentation(_options)
	if not bool(_options.get("shake_enabled", true)):
		_stop_shake()


func bind_battle(new_engine: RefCounted, game_data: RefCounted, run_deck: Array) -> void:
	$Drag.cancel()
	if engine != null and engine.settled.is_connected(_on_settled):
		engine.settled.disconnect(_on_settled)
	_generation += 1
	_reset_feedback()
	_has_presented_state = false
	_intent_cues.clear()
	_intent_targets.clear()
	_pending_card.clear()
	_close_dialogs()
	engine = new_engine
	data = game_data
	_active = true
	deck = run_deck.duplicate(true)
	engine.settled.connect(_on_settled)
	locked = false
	selected_copy = -1
	selected_caster = ""
	pending_target = ""
	hovered_target = ""
	chosen_status = ""
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
	if engine.state.has("hand"):
		refresh()
		_has_presented_state = true
		_announce_intents()


func leave_battle() -> void:
	if not _active:
		return
	_active = false
	_generation += 1
	_reset_feedback()
	_pending_card.clear()
	_intent_targets.clear()
	locked = false
	if engine != null and engine.settled.is_connected(_on_settled):
		engine.settled.disconnect(_on_settled)
	clear_selection()


func set_external_blocked(blocked: bool) -> void:
	if externally_blocked == blocked:
		return
	externally_blocked = blocked
	if blocked:
		clear_selection()
	elif _active:
		refresh()


func refresh() -> void:
	if engine == null or not engine.state.has("hand"):
		return
	if locked and _has_presented_state:
		return
	if selected_copy >= 0 and engine.find_card(selected_copy).is_empty():
		selected_copy = -1
		selected_caster = ""
		pending_target = ""
		hovered_target = ""
		chosen_status = ""
		$DispelConfirm.hide()
	var state: Dictionary = engine.snapshot()
	_intent_targets.clear()
	for enemy in state.enemies:
		if enemy.hp > 0 and not enemy.interrupted:
			_intent_targets[enemy.id] = engine.intent_preview(enemy.id).target_ids.duplicate()
	$Margin/Content/Header.text = data.text(
		"ui.stats", {"turn": state.turn, "energy": state.energy, "gold": gold}
	)
	for pair in [
		[state.heroes, $Margin/Content/Middle/Field/Heroes],
		[state.enemies, $Margin/Content/Middle/Field/Enemies]
	]:
		var container = pair[1]
		if container.get_child_count() != pair[0].size():
			for child in container.get_children():
				container.remove_child(child)
				child.queue_free()
			for unit in pair[0]:
				var view = UnitView.instantiate()
				container.add_child(view)
				view.unit_selected.connect(_on_unit_selected)
				view.unit_hovered.connect(_on_unit_hovered)
				view.unit_unhovered.connect(_on_unit_unhovered)
				view.resized.connect(_on_layout_changed)
				view.configure_presentation(_options)
		for i in range(pair[0].size()):
			var unit: Dictionary = pair[0][i]
			var view = container.get_child(i)
			var highlighted: bool = false
			if not locked and not externally_blocked and selected_copy >= 0:
				if selected_caster == "":
					highlighted = _caster_is_legal(unit.id)
				else:
					highlighted = _target_is_legal(unit.id)
					var selected_card: Dictionary = engine.find_card(selected_copy)
					if (
						not selected_card.is_empty()
						and data.definition("cards", selected_card.card_id).target == "none"
					):
						highlighted = (
							unit.id
							in engine.action_targets(
								selected_copy, selected_caster, selected_caster
							)
						)
			view.render(unit, data, engine, highlighted, unit.id == selected_caster)
			view.configure_stage(str(unit.definition_id).begins_with("boss_"))
	hand.render(state.hand, data, engine, locked or externally_blocked, selected_copy)
	$Margin/Content/Energy/Value.text = str(int(state.energy))
	$Margin/Content/Energy.tooltip_text = $Margin/Content/Header.text
	$Margin/Content/Actions/Piles.text = (
		data.text("ui.pile.draw").get_slice("（", 0) + "  " + str(state.draw.size())
	)
	$Margin/Content/Actions/Piles.tooltip_text = data.text("ui.piles")
	$Margin/Content/Actions/Discard.text = (
		data.text("ui.pile.discard") + "  " + str(state.discard.size())
	)
	end_button.disabled = locked or externally_blocked or state.phase != Types.BattlePhase.PLAYER
	cast_button.visible = (
		selected_copy >= 0
		and selected_caster != ""
		and (
			data.definition("cards", engine.find_card(selected_copy).get("card_id", "")).get(
				"target"
			)
			in ["self", "none"]
		)
	)
	cast_button.disabled = locked or externally_blocked
	$Margin/Content.layout_stage()
	_refresh_incoming_intents()
	_refresh_caster_picker()
	_update_unit_feedback()
	queue_redraw()


func clear_selection() -> void:
	if not _preparing_drag:
		$Drag.cancel()
	_drag_active = false
	$Interaction/Preview.hide()
	selected_copy = -1
	selected_caster = ""
	pending_target = ""
	hovered_target = ""
	chosen_status = ""
	_close_dialogs()
	if data != null:
		hint.text = data.presentation_text("interaction.drag_hint")
	if _active:
		refresh()
	else:
		queue_redraw()


func _on_settled(records: Array, _snapshot: Dictionary) -> void:
	if not _active:
		return
	locked = true
	$Drag.cancel()
	_drag_active = false
	$Interaction/CasterPicker.hide()
	$Interaction/Preview.hide()
	selected_copy = -1
	selected_caster = ""
	pending_target = ""
	hovered_target = ""
	chosen_status = ""
	_close_dialogs()
	hint.text = data.presentation_text("interaction.drag_hint")
	# The core has finished this action. Retain the previous portraits while its
	# records play, then render the final snapshot; never simulate rules in the UI.
	if not _has_presented_state:
		refresh()
		_has_presented_state = true
	hand.render(engine.state.hand, data, engine, true, -1)
	end_button.disabled = true
	cast_button.hide()
	queue_redraw()
	var generation := _generation
	var battle_at_start := engine
	var playback: Array = records.duplicate(true)
	if not _pending_card.is_empty():
		playback.push_front(_pending_card.duplicate(true))
		_pending_card.clear()
	for record in playback:
		if record.kind != "card_play":
			log_view.append_records([record], data, battle_at_start)
		var fast: bool = $Margin/Content/Actions/Fast.button_pressed
		_present_record(record, fast)
		presentation_event.emit(record.duplicate(true), fast)
		var delay: float = fast_event_duration if fast else event_duration
		await get_tree().create_timer(delay).timeout
		if generation != _generation or not _active:
			return
	locked = false
	refresh()
	_announce_intents()
	presentation_finished.emit()


func _on_card_selected(copy_id: int) -> void:
	if locked or externally_blocked or not _active:
		return
	clear_selection()
	selected_copy = copy_id
	selected_caster = ""
	var casters: Array = engine.legal_casters(copy_id)
	if casters.size() == 1:
		selected_caster = casters[0]
	hint.text = data.text("ui.select_caster" if selected_caster == "" else "ui.select_target")
	refresh()
	if cast_button.visible:
		hint.text = _cast_hint()


func _on_unit_selected(id: String) -> void:
	if locked or externally_blocked or not _active or selected_copy < 0:
		return
	if selected_caster == "":
		if _caster_is_legal(id):
			selected_caster = id
			refresh()
			hint.text = _cast_hint() if cast_button.visible else data.text("ui.select_target")
		return
	if cast_button.visible:
		return
	_confirm_target(id)


func _confirm_target(id: String) -> void:
	if locked or externally_blocked or not _active or selected_copy < 0 or selected_caster == "":
		return
	var error: String = engine.validate_play(selected_copy, selected_caster, id)
	if error != "" and error != "error.dispel":
		hint.text = data.text(error)
		return
	var options: Array = engine.dispel_options(selected_copy, id)
	if options.size() > 1:
		pending_target = id
		dispel_choices.clear()
		for option in options:
			dispel_choices.add_item(data.text("status." + option))
			dispel_choices.set_item_metadata(dispel_choices.item_count - 1, option)
		dispel_choices.select(0)
		_on_dispel_selected(0)
		_popup_sized($DispelConfirm, dispel_preferred_size)
	else:
		_play(id, options[0] if not options.is_empty() else "")


func _on_unit_hovered(id: String) -> void:
	_related_unit = id
	_update_unit_feedback()
	if _drag_active:
		return
	if locked or externally_blocked or not _active or selected_copy < 0 or selected_caster == "":
		return
	hovered_target = id if _target_is_legal(id) else ""
	_show_preview(id, _preview_status(id))
	queue_redraw()


func _on_unit_unhovered(id: String) -> void:
	if _related_unit == id:
		_related_unit = ""
		_update_unit_feedback()
	if hovered_target == id:
		hovered_target = ""
		queue_redraw()


func _show_preview(id: String, status: String = "") -> void:
	var result: Dictionary = engine.preview(selected_copy, selected_caster, id, status)
	if result.error != "":
		hint.text = data.text(result.error)
		return
	var definition: Dictionary = data.definition("cards", engine.find_card(selected_copy).card_id)
	var lines: Array[String] = [
		data.text("ui.preview_cost", {"cost": definition.cost, "energy": result.energy})
	]
	for change in result.changes:
		change["name"] = data.text(change.name_key)
		lines.append(data.text("ui.preview", change))
	if status != "":
		lines.append(data.text("ui.preview_dispel", {"status": data.text("status." + status)}))
	for record in result.records:
		if record.kind in ["interrupt", "interrupt_failed"]:
			var target: Dictionary = engine.find_unit(record.target)
			lines.append(data.text("log." + record.kind, {"target": data.text(target.name_key)}))
	hint.text = "　".join(lines)
	if _drag_active:
		$Interaction/Preview/Text.text = "\n".join(lines)
		$Interaction/Preview.show()
	if pending_target == id:
		dispel_preview.text = "\n".join(lines)


func _on_cast_pressed() -> void:
	_confirm_target(selected_caster)


func _cast_hint() -> String:
	var copy: Dictionary = engine.find_card(selected_copy)
	var scope: String = str(data.definition("cards", copy.card_id).target)
	return data.text("ui.confirm_scope" if scope == "none" else "ui.confirm_self")


func _on_cast_hovered() -> void:
	_on_unit_hovered(selected_caster)


func _on_dispel_confirmed() -> void:
	_play(pending_target, chosen_status)


func _on_dispel_selected(index: int) -> void:
	if pending_target == "" or index < 0 or index >= dispel_choices.item_count:
		return
	chosen_status = str(dispel_choices.get_item_metadata(index))
	_show_preview(pending_target, chosen_status)
	queue_redraw()


func _play(target_id: String, status: String = "") -> void:
	if locked or externally_blocked or not _active or selected_copy < 0:
		return
	var caster_id: String = selected_caster
	var origin: Vector2 = _feedback_center(hand)
	for card in hand.get_children():
		if int(card.get_meta("copy_id", -1)) == selected_copy:
			origin = _feedback_center(card)
			break
	_pending_card = {
		"kind": "card_play",
		"source": caster_id,
		"target": target_id,
		"card": engine.find_card(selected_copy).duplicate(true),
		"origin": origin,
	}
	locked = true
	var error: String = engine.play_card(selected_copy, caster_id, target_id, status)
	if error != "":
		_pending_card.clear()
		locked = false
		refresh()
		hint.text = data.text(error)


func _on_end_pressed() -> void:
	if locked or externally_blocked or not _active:
		return
	clear_selection()
	if engine.has_playable_card():
		$EndConfirm.popup_centered()
	else:
		_end_turn()


func _end_turn() -> void:
	if not locked and not externally_blocked and _active:
		clear_selection()
		locked = true
		var error: String = engine.end_turn()
		if error != "":
			locked = false
			refresh()
			hint.text = data.text(error)


func _on_piles_pressed(pile: String = "draw") -> void:
	if not _active or engine == null:
		return
	$Drag.cancel()
	$Piles/Tabs.clear_tabs()
	for key in PILE_KEYS:
		$Piles/Tabs.add_tab(data.text("ui.pile." + key).get_slice("（", 0))
	$Piles/Tabs.current_tab = maxi(0, PILE_KEYS.find(pile))
	_on_pile_tab_changed($Piles/Tabs.current_tab)
	_popup_sized($Piles, piles_preferred_size)


func _on_pile_tab_changed(index: int) -> void:
	if engine == null or index < 0 or index >= PILE_KEYS.size():
		return
	var lines: Array[String] = []
	for pile in [PILE_KEYS[index]]:
		lines.append(data.text("ui.pile." + pile))
		var cards: Array = deck if pile == "deck" else engine.state[pile].duplicate(true)
		# Never expose the live draw order, even in a text-only pile viewer.
		cards = cards.duplicate(true)
		cards.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				return a.card_id < b.card_id if a.card_id != b.card_id else a.copy_id < b.copy_id
		)
		for copy in cards:
			lines.append(data.card_details(copy).replace("\n", "　"))
		lines.append("")
	$Piles/Text.text = "\n".join(lines)
	$Piles/Text.scroll_to_line(0)


func _input(event: InputEvent) -> void:
	# GUI buttons consume mouse events before _unhandled_input is reached.
	if _active and is_visible_in_tree() and _is_cancel(event):
		clear_selection()
		get_viewport().set_input_as_handled()


func _on_dialog_input(event: InputEvent, dialog: Window) -> void:
	if _active and dialog.visible and _is_cancel(event):
		clear_selection()
		dialog.set_input_as_handled()


func _is_cancel(event: InputEvent) -> bool:
	return (
		event.is_action_pressed("ui_cancel")
		or (
			event is InputEventMouseButton
			and event.pressed
			and event.button_index == MOUSE_BUTTON_RIGHT
		)
	)


func _close_dialogs() -> void:
	for dialog in [$EndConfirm, $DispelConfirm, $Piles]:
		dialog.hide()


func _preview_status(target_id: String) -> String:
	var options: Array = engine.dispel_options(selected_copy, target_id)
	if target_id == pending_target and chosen_status in options:
		return chosen_status
	return options[0] if not options.is_empty() else ""


func _target_is_legal(target_id: String) -> bool:
	return (
		selected_copy >= 0
		and selected_caster != ""
		and (
			engine.validate_play(
				selected_copy, selected_caster, target_id, _preview_status(target_id)
			)
			== ""
		)
	)


func _caster_is_legal(caster_id: String) -> bool:
	for target_id in engine.legal_targets(selected_copy, caster_id):
		if (
			engine.validate_play(selected_copy, caster_id, target_id, _preview_status(target_id))
			== ""
		):
			return true
	return false


func _on_layout_changed() -> void:
	# Containers finish child placement after their current resize notification.
	$Margin/Content.layout_stage.call_deferred()
	_position_interaction.call_deferred()
	queue_redraw.call_deferred()
	if $Piles.visible:
		_popup_sized($Piles, piles_preferred_size)
	if $DispelConfirm.visible:
		_popup_sized($DispelConfirm, dispel_preferred_size)


func _unit_views() -> Dictionary:
	var views: Dictionary = {}
	for container in [$Margin/Content/Middle/Field/Heroes, $Margin/Content/Middle/Field/Enemies]:
		for view in container.get_children():
			views[view.unit_id] = view
	return views


func _feedback_center(control: Control) -> Vector2:
	return (
		$Feedback.get_global_transform().affine_inverse()
		* (control.get_global_transform() * (control.size * 0.5))
	)


func _present_record(record: Dictionary, fast: bool) -> void:
	var views: Dictionary = _unit_views()
	var kind: String = record.kind
	var source_id: String = str(record.get("source", ""))
	var target_id: String = str(record.get("target", ""))
	if kind in ["card_play", "damage", "heal", "shield", "revive"] and views.has(source_id):
		views[source_id].play_cue("cast", fast)
	if kind == "card_play" and record.has("card") and views.has(source_id):
		var destination: Vector2 = _feedback_center(views[source_id])
		$Feedback.show_card(record.card, data, record.origin, destination, fast)
	if views.has(target_id) and kind != "card_play":
		var hp_loss: int = int(record.get("hp_loss", record.get("amount", 0)))
		var shield_loss: int = int(record.get("shield_loss", 0))
		var cue: String = "block" if kind == "damage" and hp_loss == 0 and shield_loss > 0 else kind
		views[target_id].play_cue(cue, fast)
		var origin: Vector2 = _feedback_center(views[target_id])
		var source: Vector2 = origin
		if views.has(source_id):
			source = _feedback_center(views[source_id])
		$Feedback.show_effect(cue, source, origin, fast)
		if kind == "damage":
			if shield_loss > 0:
				$Feedback.show_number(
					"−" + str(shield_loss), origin + Vector2(0, 24), "block", fast
				)
			if hp_loss > 0 or shield_loss == 0:
				$Feedback.show_number("−" + str(hp_loss), origin - Vector2(0, 24), kind, fast)
		elif kind in ["heal", "shield", "revive"]:
			var amount: int = int(record.get("amount", 0))
			$Feedback.show_number("+" + str(amount), origin, kind, fast)
	if kind == "damage" and int(record.get("hp_loss", record.get("amount", 0))) > 0:
		_shake_field(fast)
	if (
		kind
		in [
			"ot",
			"interrupt",
			"interrupt_failed",
			"bomb",
			"bomb_explode",
			"phase",
			"enrage",
			"revive",
			"summon",
			"death",
			"win",
			"loss"
		]
	):
		var message: String = _record_text(record)
		$Feedback.show_banner(message, kind)
		hint.text = message
	queue_redraw()


func _record_text(record: Dictionary) -> String:
	var values: Dictionary = record.duplicate(true)
	for key in ["source", "target"]:
		if values.has(key):
			var unit: Dictionary = engine.find_unit(str(values[key]))
			values[key] = (
				data.text(unit.name_key) if not unit.is_empty() else data.text("ui.status_effect")
			)
	if values.has("status"):
		values.status = data.text("status." + str(values.status))
	return data.text("log." + str(record.kind), values)


func _announce_intents() -> void:
	# New turn/phase intentions may cue once; hovering or redrawing cannot repeat audio.
	if engine.state.phase != Types.BattlePhase.PLAYER:
		return
	for enemy in engine.state.enemies:
		if enemy.hp <= 0 or enemy.intent.is_empty() or enemy.intent.kind == "normal":
			continue
		var key: String = "%d:%s" % [int(engine.state.turn), str(enemy.intent.get("id", ""))]
		if _intent_cues.get(enemy.id, "") == key:
			continue
		_intent_cues[enemy.id] = key
		presentation_event.emit(
			{"kind": "cast", "target": enemy.id}, $Margin/Content/Actions/Fast.button_pressed
		)


func _shake_field(fast: bool) -> void:
	if not bool(_options.get("shake_enabled", true)) or fast:
		return
	_stop_shake()
	var field: Control = $Margin/Content/Middle/Field
	field.pivot_offset = field.size * 0.5
	_shake_tween = create_tween()
	_shake_tween.tween_property(field, "rotation", shake_angle, shake_duration * 0.25)
	_shake_tween.tween_property(field, "rotation", -shake_angle, shake_duration * 0.35)
	_shake_tween.tween_property(field, "rotation", 0.0, shake_duration * 0.4)


func _stop_shake() -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	$Margin/Content/Middle/Field.rotation = 0.0


func _reset_feedback() -> void:
	_stop_shake()
	$Feedback.reset()
	for view in _unit_views().values():
		view.reset_presentation()


func _popup_sized(dialog: Window, preferred: Vector2i) -> void:
	var available: Vector2i = Vector2i(get_viewport_rect().size) - popup_margin
	if not dialog.visible:
		dialog.popup_centered()
	dialog.size = Vector2i(mini(preferred.x, available.x), mini(preferred.y, available.y))
	_center_popup(dialog)
	_center_popup.call_deferred(dialog)


func _center_popup(dialog: Window) -> void:
	if dialog.visible:
		dialog.move_to_center()


func prepare_card_drag(copy_id: int) -> bool:
	if locked or externally_blocked or not _active or _modal_open():
		return false
	if engine.find_card(copy_id).is_empty():
		return false
	_preparing_drag = true
	if selected_copy != copy_id or selected_caster not in engine.legal_casters(copy_id):
		_on_card_selected(copy_id)
	_preparing_drag = false
	if selected_caster == "":
		hint.text = data.presentation_text("interaction.choose_caster")
		return false
	_drag_active = true
	$Interaction/CasterPicker.hide()
	_related_unit = ""
	return true


func update_card_drag(pointer: Vector2) -> void:
	if not _drag_active:
		return
	if locked or externally_blocked or not _active or _modal_open():
		$Drag.cancel()
		return
	hovered_target = _drop_target(pointer)
	$Interaction/Preview.hide()
	if hovered_target != "" and _target_is_legal(hovered_target):
		_show_preview(hovered_target, _preview_status(hovered_target))
		hint.text = (
			data.presentation_text("interaction.release_cast")
			+ " · "
			+ data.presentation_text(
				"interaction.caster",
				{"name": data.text(engine.find_unit(selected_caster).name_key)}
			)
		)
	else:
		hint.text = data.presentation_text("interaction.cancel_drag")
		if hovered_target != "":
			var error: String = engine.validate_play(selected_copy, selected_caster, hovered_target)
			hint.text = data.text(error) if error != "" else hint.text
	_update_unit_feedback()
	_position_interaction()
	queue_redraw()


func finish_card_drag(pointer: Vector2) -> void:
	var target_id: String = _drop_target(pointer) if _drag_active else ""
	_drag_active = false
	$Interaction/Preview.hide()
	if target_id != "" and not locked and not externally_blocked and not _modal_open():
		if _target_is_legal(target_id):
			_confirm_target(target_id)
			return
		var error: String = engine.validate_play(selected_copy, selected_caster, target_id)
		clear_selection()
		hint.text = (
			data.text(error) if error != "" else data.presentation_text("interaction.no_target")
		)
		return
	clear_selection()


func cancel_card_drag() -> void:
	_drag_active = false
	clear_selection()


func _modal_open() -> bool:
	# Embedded dialogs route mouse input to another viewport. Never treat the
	# stage underneath them as a drop target or a second click destination.
	for window in get_tree().root.get_embedded_subwindows():
		if window.visible:
			return true
	return false


func _drop_target(pointer: Vector2) -> String:
	if not _active or selected_copy < 0 or selected_caster == "" or _modal_open():
		return ""
	var hand_top: float = hand.get_global_rect().position.y
	var area := Rect2(
		global_position + Vector2(16, 38), Vector2(size.x - 32, hand_top - global_position.y - 38)
	)
	if not area.has_point(pointer):
		return ""
	for control in [log_view, $Interaction/CasterPicker]:
		if control.is_visible_in_tree() and control.get_global_rect().has_point(pointer):
			return ""
	for control in $Margin/Content/Actions.get_children():
		if control.is_visible_in_tree() and control.get_global_rect().has_point(pointer):
			return ""
	var copy: Dictionary = engine.find_card(selected_copy)
	if copy.is_empty():
		return ""
	var scope: String = str(data.definition("cards", copy.card_id).target)
	if scope in ["self", "none"]:
		return selected_caster
	var nearest := ""
	var distance := INF
	for id in _unit_views():
		var unit_view: Control = _unit_views()[id]
		var bounds: Rect2 = unit_view.get_global_rect()
		if bounds.has_point(pointer):
			var candidate_distance: float = pointer.distance_squared_to(bounds.get_center())
			if candidate_distance < distance:
				nearest = id
				distance = candidate_distance
	return nearest


func _refresh_caster_picker() -> void:
	var picker: Control = $Interaction/CasterPicker
	for child in $Interaction/CasterPicker/Content/Choices.get_children():
		child.get_parent().remove_child(child)
		child.queue_free()
	picker.hide()
	if selected_copy < 0 or locked or externally_blocked or _drag_active:
		return
	var casters: Array = engine.legal_casters(selected_copy)
	if casters.size() <= 1:
		return
	$Interaction/CasterPicker/Content/Title.text = data.presentation_text(
		"interaction.choose_caster"
	)
	for caster_id in casters:
		var unit: Dictionary = engine.find_unit(caster_id)
		var button := Button.new()
		button.text = data.text(unit.name_key)
		button.icon = Art.actor_texture(unit.definition_id)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 24)
		button.custom_minimum_size = Vector2(96, 38)
		button.toggle_mode = true
		button.button_pressed = caster_id == selected_caster
		button.disabled = not _caster_is_legal(caster_id)
		button.set_meta("caster_id", caster_id)
		button.pressed.connect(_choose_caster.bind(caster_id))
		$Interaction/CasterPicker/Content/Choices.add_child(button)
	picker.show()
	_position_interaction.call_deferred()


func _choose_caster(id: String) -> void:
	if locked or externally_blocked or selected_copy < 0 or not _caster_is_legal(id):
		return
	selected_caster = id
	hovered_target = ""
	refresh()
	hint.text = (
		data.presentation_text(
			"interaction.caster", {"name": data.text(engine.find_unit(id).name_key)}
		)
		+ " · "
		+ data.presentation_text("interaction.drag_hint")
	)


func _position_interaction() -> void:
	var top: Vector2 = hand.get_global_rect().position - global_position
	for panel in [$Interaction/CasterPicker, $Interaction/Preview]:
		panel.reset_size()
		panel.position = Vector2((size.x - panel.size.x) * 0.5, top.y + 4)


func _refresh_incoming_intents() -> void:
	for unit_view in _unit_views().values():
		var entries: Array = []
		var unit: Dictionary = engine.find_unit(unit_view.unit_id)
		if unit.friendly:
			for enemy_id in _intent_targets:
				if unit.id in _intent_targets[enemy_id]:
					var enemy: Dictionary = engine.find_unit(enemy_id)
					var preview: Dictionary = engine.intent_preview(enemy_id)
					entries.append(
						{
							"enemy_id": enemy_id,
							"name": data.text(enemy.name_key),
							"description": preview.description,
							"kind": preview.kind
						}
					)
		unit_view.set_incoming_intents(entries)


func _update_unit_feedback() -> void:
	if engine == null or not engine.state.has("heroes"):
		return
	var related: Array = []
	if _related_unit != "" and selected_copy < 0:
		related.append(_related_unit)
		if _intent_targets.has(_related_unit):
			related.append_array(_intent_targets[_related_unit])
		else:
			for enemy_id in _intent_targets:
				if _related_unit in _intent_targets[enemy_id]:
					related.append(enemy_id)
	for id in _unit_views():
		var unit_view: Control = _unit_views()[id]
		unit_view.set_related_highlight(id in related)
		var legal: bool = selected_copy >= 0 and not locked and not externally_blocked
		if legal:
			legal = _caster_is_legal(id) if selected_caster == "" else _target_is_legal(id)
			if selected_caster != "" and not engine.find_card(selected_copy).is_empty():
				var scope: String = (
					data.definition("cards", engine.find_card(selected_copy).card_id).target
				)
				if scope == "none":
					legal = (
						id in engine.action_targets(selected_copy, selected_caster, selected_caster)
					)
		unit_view.set_target_feedback(legal, legal and id == hovered_target)
