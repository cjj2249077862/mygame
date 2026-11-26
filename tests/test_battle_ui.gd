extends "res://tests/test_suite.gd"

const MainScene = preload("res://scenes/main.tscn")
const Models = preload("res://scripts/core/models.gd")
const Types = preload("res://scripts/core/enums.gd")

var app: Control
var view: Control
var _copy_id := 10000


func run_tests() -> void:
	root.size = Vector2i(1440, 900)
	root.gui_embed_subwindows = true
	app = MainScene.instantiate()
	root.add_child(app)
	await process_frame
	if not expect(app.run != null, "Main must load configuration and create RunManager"):
		app.queue_free()
		return
	view = app.get_node("Battle")
	view.get_node("Margin/Content/Actions/Fast").button_pressed = true
	app.get_node("Menu/Content/Start").pressed.emit()
	await _settle()
	expect(view.visible and view.engine.state.hand.size() == 5, "First start renders opening hand")
	expect(view.hand.get_child_count() == 5, "Opening cards reach the scene")
	expect(view.engine.state.energy == 3, "Opening energy is visible from the live engine")
	expect(_units("Heroes").get_child_count() == 3, "Three party slots render on first start")
	await _test_cancel_and_preview()
	await _test_unavailable_target_reason()
	await _test_end_turn_clears_selection()
	await _test_dispel_choice()
	await _test_multiple_casters()
	await _test_play_lock_and_restart()
	await _test_rewards_and_results()
	await _test_rebuild_during_presentation()
	await _test_keyword_details()
	await _test_resize()
	app.queue_free()
	await process_frame


func _settle() -> void:
	for i in range(300):
		if not view.locked:
			await process_frame
			return
		await create_timer(0.01).timeout
	expect(false, "Presentation must release its input lock within the test timeout")


func _restart() -> void:
	app._on_start()
	await _settle()


func _units(side: String) -> Node:
	return view.get_node("Margin/Content/Middle/Field/" + side)


func _unit(id: String) -> Node:
	for side in ["Heroes", "Enemies"]:
		for unit_view in _units(side).get_children():
			if unit_view.unit_id == id:
				return unit_view
	return null


func _hand(card_id: String) -> void:
	view.clear_selection()
	for pile in Types.PILES:
		view.engine.state[pile] = []
	_copy_id += 1
	view.engine.state.hand = [Models.card(_copy_id, card_id)]
	view.engine.state.energy = 3
	view.refresh()


func _select_card() -> void:
	view.hand.get_child(0).pressed.emit()


func _right_click(position: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	event.position = position
	event.global_position = position
	return event


func _test_cancel_and_preview() -> void:
	_hand("slash")
	_select_card()
	var before: Dictionary = view.engine.snapshot()
	var random_state: int = view.engine.rng.state
	_unit("enemy_0").mouse_entered.emit()
	expect(view.hovered_target == "enemy_0", "Legal hover supplies the targeting line endpoint")
	expect(not view.hint.text.contains("ui.preview_cost"), "Preview cost must resolve a text key")
	expect(
		view.engine.snapshot() == before and view.engine.rng.state == random_state,
		"UI preview is read-only"
	)
	_unit("warden").pressed.emit()
	expect(view.engine.snapshot() == before, "Enemy-only card rejects an ally through the UI")
	# Push through the viewport so GUI mouse filtering cannot mask a cancellation bug.
	var target_center: Vector2 = _unit("enemy_0").get_global_rect().get_center()
	app.get_viewport().push_input(_right_click(target_center), true)
	await process_frame
	expect(
		view.selected_copy == -1 and view.hovered_target == "",
		"Right click over a unit cancels selection"
	)
	expect(view.engine.snapshot() == before, "Right cancellation spends nothing")
	_select_card()
	var card_center: Vector2 = view.hand.get_child(0).get_global_rect().get_center()
	app.get_viewport().push_input(_right_click(card_center), true)
	await process_frame
	expect(view.selected_copy == -1, "Right click over a hand button also cancels")
	_select_card()
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	app.get_viewport().push_input(escape, true)
	await process_frame
	expect(view.selected_copy == -1, "Escape cancels a selection")
	view.engine.state.energy = 0
	view.refresh()
	expect(view.hand.get_child(0).disabled, "Unaffordable card is disabled")
	expect(
		view.hand.get_child(0).tooltip_text.contains(app.data.text("error.energy")),
		"Disabled card explains insufficient energy"
	)
	await _restart()


func _test_unavailable_target_reason() -> void:
	_hand("slash")
	# Isolate unavailable targets from caster eligibility without settling a new action.
	for enemy in view.engine.state.enemies:
		enemy.hp = 0
	view.refresh()
	expect(not view.engine.legal_casters(_copy_id).is_empty())
	expect(view.engine.legal_targets(_copy_id, "warden").is_empty())
	var button: Button = view.hand.get_child(0)
	expect(button.disabled, "A card with no valid target is disabled")
	expect(
		(
			button.tooltip_text.contains(app.data.text("error.target"))
			and not button.tooltip_text.contains(app.data.text("error.caster"))
		),
		"A living caster without a target must receive the target failure reason"
	)
	view.engine.find_unit("warden").hp = 0
	view.refresh()
	expect(
		view.hand.get_child(0).tooltip_text.contains(app.data.text("error.caster")),
		"A card without an eligible living caster still explains caster eligibility"
	)
	await _restart()


func _test_end_turn_clears_selection() -> void:
	_hand("slash")
	_select_card()
	var before: Dictionary = view.engine.snapshot()
	view.end_button.pressed.emit()
	var dialog = view.get_node("EndConfirm")
	expect(dialog.visible, "Ending with a playable hand requires confirmation")
	expect(view.selected_copy == -1, "Opening end-turn confirmation clears selection")
	dialog.window_input.emit(_right_click(Vector2(20, 20)))
	expect(
		not dialog.visible and view.engine.snapshot() == before,
		"Cancelling end-turn dialog is read-only"
	)
	_select_card()
	view.end_button.pressed.emit()
	dialog.get_ok_button().pressed.emit()
	await _settle()
	var after: Dictionary = view.engine.snapshot()
	_unit("enemy_0").pressed.emit()
	expect(
		view.engine.snapshot() == after, "Old target click cannot play the redrawn copy next turn"
	)
	await _restart()


func _test_dispel_choice() -> void:
	_hand("first_aid")
	var hero: Dictionary = view.engine.find_unit("warden")
	hero.hp -= 20
	view.engine.resolver.add_status(view.engine.find_unit("enemy_0"), hero, "poison", 2)
	view.engine.resolver.add_status(view.engine.find_unit("enemy_0"), hero, "weak", 1)
	view.refresh()
	_select_card()
	var before: Dictionary = view.engine.snapshot()
	var random_state: int = view.engine.rng.state
	_unit("warden").mouse_entered.emit()
	expect(
		not view.hint.text.contains(app.data.text("error.dispel")),
		"Multi-status heal still previews before opening the choice"
	)
	_unit("warden").pressed.emit()
	var dialog = view.get_node("DispelConfirm")
	expect(
		dialog.visible and view.dispel_choices.item_count == 2,
		"First aid asks which status to dispel"
	)
	view.dispel_choices.select(1)
	view.dispel_choices.item_selected.emit(1)
	var status: String = view.chosen_status
	expect(
		view.dispel_preview.text.contains(app.data.text("status." + status)),
		"Choice preview identifies the selected status"
	)
	expect(
		view.engine.snapshot() == before and view.engine.rng.state == random_state,
		"Changing dispel choice cannot mutate battle or RNG"
	)
	dialog.window_input.emit(_right_click(Vector2(20, 20)))
	expect(
		not dialog.visible and view.pending_target == "", "Modal right-click clears pending target"
	)
	expect(view.engine.snapshot() == before, "Cancelling dispel spends no energy or card")
	_select_card()
	_unit("warden").pressed.emit()
	view.dispel_choices.select(1)
	view.dispel_choices.item_selected.emit(1)
	status = view.chosen_status
	dialog.get_ok_button().pressed.emit()
	await _settle()
	expect(not hero.statuses.has(status), "Confirmed choice dispels exactly the chosen status")
	expect(hero.statuses.size() == 1, "The other dispellable status remains")
	expect(hero.hp > before.heroes[0].hp, "The same action heals its target")
	await _restart()


func _test_multiple_casters() -> void:
	var second: Dictionary = Models.unit(
		app.data.definition("characters", "warden"), "tank_2", true
	)
	second.definition_id = "second_tank_fixture"
	view.engine.state.heroes[1] = second
	_hand("guard")
	_select_card()
	expect(view.selected_caster == "", "A shared class card asks which matching hero casts")
	_unit("tank_2").pressed.emit()
	expect(
		view.selected_caster == "tank_2" and view.cast_button.visible,
		"Second same-class hero can be selected"
	)
	expect(
		view.hint.text == app.data.text("ui.confirm_self"),
		"Self-target prompt follows multi-caster selection"
	)
	view.cast_button.pressed.emit()
	await _settle()
	expect(
		second.shield > 0 and view.engine.find_unit("warden").shield == 0,
		"UI assigns self shield to the selected hero"
	)
	_hand("shield_bash")
	_select_card()
	expect(view.selected_caster == "warden", "A personal card still selects only its owner")
	await _restart()


func _test_play_lock_and_restart() -> void:
	_hand("slash")
	_select_card()
	var target_hp: int = view.engine.find_unit("enemy_0").hp
	_unit("enemy_0").pressed.emit()
	expect(view.locked and view.end_button.disabled, "Presentation locks combat input immediately")
	var after: Dictionary = view.engine.snapshot()
	view._end_turn()
	_unit("enemy_0").pressed.emit()
	expect(
		view.engine.snapshot() == after,
		"Repeated input during presentation does not settle another action"
	)
	await _settle()
	expect(view.engine.find_unit("enemy_0").hp < target_hp, "One target click resolves one card")
	await _restart()
	await _restart()
	expect(
		view.engine.settled.get_connections().size() == 1,
		"Restart connects exactly one battle view"
	)
	_hand("guard")
	_select_card()
	var before: Dictionary = view.engine.snapshot()
	_unit("warden").pressed.emit()
	expect(
		view.engine.snapshot() == before and view.cast_button.visible,
		"Self cards require the explicit cast button"
	)
	view.cast_button.pressed.emit()
	await _settle()
	expect(
		view.engine.state.energy == 2 and view.engine.state.hand.is_empty(),
		"Restarted view casts only once per click"
	)
	await _restart()


func _win(open_piles_on_last: bool = false) -> void:
	var enemy_ids: Array[String] = []
	for enemy in view.engine.state.enemies:
		if enemy.hp > 0:
			enemy_ids.append(enemy.id)
	for i in range(enemy_ids.size()):
		var enemy: Dictionary = view.engine.find_unit(enemy_ids[i])
		enemy.hp = 1
		_hand("slash")
		_select_card()
		_unit(enemy.id).pressed.emit()
		if open_piles_on_last and i == enemy_ids.size() - 1:
			view.get_node("Margin/Content/Actions/Piles").pressed.emit()
			expect(
				view.get_node("Piles").visible,
				"Pile inspection stays available during presentation"
			)
		await _settle()


func _test_rewards_and_results() -> void:
	await _win()
	var reward = app.get_node("Reward")
	expect(reward.visible and not view.visible, "Ordinary victory enters the reward page")
	var candidates: Array = app.run.reward_candidates.duplicate()
	var random_state: int = app.run.rng.state
	app._on_run_changed()
	expect(
		app.run.reward_candidates == candidates and app.run.rng.state == random_state,
		"Reward redraw preserves candidates and RNG"
	)
	var claims := {"count": 0}
	reward.claimed.connect(func(_id: String, _token: int) -> void: claims.count += 1)
	var old_size: int = app.run.deck.size()
	var button = reward.get_node("Margin/Content/Cards").get_child(0)
	button.pressed.emit()
	button.pressed.emit()
	expect(
		claims.count == 1 and app.run.deck.size() == old_size + 1,
		"Double reward click emits once and adds one card"
	)
	expect(not reward.visible and view.visible, "Claim switches immediately to the next battle")
	await _settle()
	await _win()
	var skips := {"count": 0}
	reward.skipped.connect(func(_token: int) -> void: skips.count += 1)
	var before_deck: Array = app.run.deck.duplicate(true)
	reward.get_node("Margin/Content/Skip").pressed.emit()
	reward.get_node("Margin/Content/Skip").pressed.emit()
	expect(
		skips.count == 1 and app.run.deck == before_deck,
		"Double skip emits once and preserves the deck"
	)
	await _settle()
	await _win(true)
	expect(
		app.get_node("Result").visible and not reward.visible,
		"Final victory goes straight to result"
	)
	expect(
		not view.get_node("Piles").visible and view.selected_copy == -1,
		"Leaving battle clears its popup and selection"
	)
	app.get_node("Result/Content/Restart").pressed.emit()
	await _settle()
	for hero in view.engine.state.heroes:
		hero.hp = 1
		hero.statuses = {"poison": [{"source": "enemy_0", "stacks": 100, "multiplier": 1}]}
	view._end_turn()
	await _settle()
	expect(
		app.get_node("Result").visible and app.run.phase == Types.RunPhase.LOST,
		"Defeat shows the failure result"
	)
	app.get_node("Result/Content/Restart").pressed.emit()
	await _settle()
	expect(
		app.run.deck.size() == 15 and app.run.stage_index == 0 and app.run.gold == 0,
		"Failure restart creates a fresh run"
	)


func _test_rebuild_during_presentation() -> void:
	_hand("slash")
	_select_card()
	_unit("enemy_0").pressed.emit()
	expect(view.locked, "Old presentation is pending")
	app._on_start()
	var new_engine: RefCounted = view.engine
	await _settle()
	await create_timer(0.1).timeout
	expect(
		view.engine == new_engine and not view.locked,
		"An old callback cannot alter the rebound view"
	)
	expect(
		view.log_view.get_parsed_text().strip_edges() == app.data.text("log.start", {"turn": 1}),
		"Old combat records never leak into a restarted log"
	)


func _test_keyword_details() -> void:
	var original: Dictionary = app.data.books.duplicate(true)
	for card in app.data.books.cards.sheets.main:
		if card.id == "slash":
			card.retain = true
			card.exhaust = true
	_hand("slash")
	var tooltip: String = view.hand.get_child(0).tooltip_text
	expect(
		tooltip.contains("保留") and tooltip.contains("消耗"),
		"Card tooltip names both configured keywords"
	)
	expect(
		tooltip.length() > view.hand.get_child(0).text.length() + 8,
		"Keyword details contain explanatory text"
	)
	var hero: Dictionary = view.engine.find_unit("warden")
	view.engine.resolver.add_status(view.engine.find_unit("enemy_0"), hero, "poison", 2)
	view.refresh()
	var explanation: String = app.data.status_details("poison")
	var key_pattern := RegEx.new()
	key_pattern.compile("^[A-Za-z_][A-Za-z0-9_.]+$")
	expect(
		key_pattern.search(explanation) == null,
		"Status explanation resolves to content, not a localization key"
	)
	expect(
		explanation.length() > app.data.text("status.poison").length() + 4,
		"Status tooltip explains its effect"
	)
	expect(
		_unit("warden").tooltip_text.contains(explanation),
		"Live status explanation reaches the unit tooltip"
	)
	app.data.books = original
	await _restart()


func _test_resize() -> void:
	for window_size in [Vector2i(1280, 800), Vector2i(1440, 900)]:
		root.size = window_size
		await process_frame
		await process_frame
		var bounds: Rect2 = app.get_viewport_rect().grow(1)
		expect(
			bounds.encloses(view.end_button.get_global_rect()),
			"End-turn button stays inside viewport"
		)
		expect(
			bounds.encloses(view.get_node("Margin/Content/HandScroll").get_global_rect()),
			"Hand scrolling region stays inside viewport"
		)
		for side in ["Heroes", "Enemies"]:
			for unit_view in _units(side).get_children():
				expect(
					bounds.encloses(unit_view.get_global_rect()),
					"Unit remains inside viewport at supported size"
				)
