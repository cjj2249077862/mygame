extends "res://tests/test_suite.gd"

const MainScene = preload("res://scenes/main.tscn")
const Types = preload("res://scripts/core/enums.gd")

var app: Control
var view: Control
var _copy_id := 10000


func run_tests() -> void:
	root.size = Vector2i(1440, 900)
	root.gui_embed_subwindows = true
	app = MainScene.instantiate()
	app.save_directory = "user://battle_ui_%d" % Time.get_ticks_usec()
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
	await _test_self_dispel_choice()
	await _test_multiple_casters()
	await _test_scope_revive_and_bomb()
	await _test_play_lock_and_restart()
	await _test_rewards_and_results()
	await _test_rebuild_during_presentation()
	await _test_keyword_details()
	await _test_resize()
	app.get_node("AudioDirector").stop_all()
	# Let the audio mixer release stopped playback before this suite exits.
	await create_timer(0.1).timeout
	app.queue_free()
	await process_frame


func _settle() -> void:
	for i in range(300):
		if not view.locked:
			if app.get_node("ChapterMap").visible:
				app.get_node("ChapterMap").get_ok_button().pressed.emit()
			await process_frame
			return
		await create_timer(0.01).timeout
	expect(false, "Presentation must release its input lock within the test timeout")


func _restart() -> void:
	app._on_start()
	if app.get_node("Confirm").visible:
		app.get_node("Confirm").get_ok_button().pressed.emit()
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
	var selected: Dictionary = {}
	for copy in app.run.deck:
		if copy.card_id == card_id:
			selected = copy.duplicate(true)
			break
	if not expect(not selected.is_empty(), "UI fixture requires a real run card: " + card_id):
		return
	for pile in Types.PILES:
		view.engine.state[pile] = []
	_copy_id = int(selected.copy_id)
	view.engine.state.hand = [selected]
	for copy in app.run.deck:
		if copy.copy_id != _copy_id:
			var eligible: Array = view.engine._casters_for_definition(
				app.data.definition("cards", copy.card_id)
			)
			view.engine.state["removed" if eligible.is_empty() else "draw"].append(
				copy.duplicate(true)
			)
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


func _test_self_dispel_choice() -> void:
	# Exercise the supported self + dispel composition without altering source content.
	var original: Dictionary = app.data.books.duplicate(true)
	for definition in app.data.books.cards.sheets.main:
		if definition.id == "first_aid":
			definition.target = "self"
	_hand("first_aid")
	var hero: Dictionary = view.engine.find_unit("mender")
	hero.hp -= 20
	view.engine.resolver.add_status(view.engine.find_unit("enemy_0"), hero, "poison", 2)
	view.engine.resolver.add_status(view.engine.find_unit("enemy_0"), hero, "weak", 1)
	view.refresh()
	_select_card()
	var before: Dictionary = view.engine.snapshot()
	expect(view.cast_button.visible and view.selected_caster == "mender")
	view.cast_button.pressed.emit()
	var dialog = view.get_node("DispelConfirm")
	expect(
		dialog.visible and view.dispel_choices.item_count == 2,
		"Self-target cast uses the same status-choice flow as a clicked target"
	)
	expect(view.engine.snapshot() == before, "Opening self dispel confirmation spends nothing")
	dialog.get_cancel_button().pressed.emit()
	expect(view.engine.snapshot() == before and view.selected_copy == -1)
	_select_card()
	view.cast_button.pressed.emit()
	view.dispel_choices.select(1)
	view.dispel_choices.item_selected.emit(1)
	var status: String = view.chosen_status
	dialog.get_ok_button().pressed.emit()
	await _settle()
	expect(
		not hero.statuses.has(status) and hero.statuses.size() == 1,
		"Self dispel applies only the chosen status removal"
	)
	expect(hero.hp > before.heroes[2].hp)
	app.data.books = original
	await _restart()


func _test_multiple_casters() -> void:
	var original: Dictionary = app.data.books.duplicate(true)
	var definition: Dictionary = app.data.definition("characters", "warden").duplicate(true)
	definition.id = "second_tank_fixture"
	app.data.books.characters.sheets.main.append(definition)
	for entry in [{"card_id": "slash", "count": 2}, {"card_id": "guard", "count": 3}]:
		app.data.books.characters.sheets.starter.append(
			{
				"id": "ui_fixture_" + entry.card_id,
				"character_id": definition.id,
				"card_id": entry.card_id,
				"count": entry.count,
				"_source": "UI fixture"
			}
		)
	expect(app.run.abandon_run() == "")
	var lineup: Array[String] = ["warden", "second_tank_fixture", "mender"]
	expect(app.run.start(261126, lineup))
	await _settle()
	var second: Dictionary = view.engine.find_unit("second_tank_fixture")
	_hand("guard")
	_select_card()
	expect(view.selected_caster == "", "A shared class card asks which matching hero casts")
	_unit("second_tank_fixture").pressed.emit()
	expect(
		view.selected_caster == "second_tank_fixture" and view.cast_button.visible,
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
	app.data.books = original


func _test_scope_revive_and_bomb() -> void:
	app.run._add_card("warden_wall")
	_hand("warden_wall")
	_select_card()
	expect(
		view.cast_button.visible and view.selected_caster == "warden",
		"Group cards explicitly confirm their caster"
	)
	var affected: Array = view.engine.action_targets(_copy_id, "warden", "warden")
	expect(affected.size() == 3, "Group card range includes all three living allies")
	for id in affected:
		expect(
			_unit(id).modulate == _unit(id).get_theme_color("target_highlight", "UnitView"),
			"Every affected ally is highlighted"
		)
	var before: Dictionary = view.engine.snapshot()
	_unit("blade").pressed.emit()
	expect(view.engine.snapshot() == before, "A group card waits for the explicit cast button")
	view.cast_button.pressed.emit()
	await _settle()
	for hero in view.engine.state.heroes:
		expect(hero.shield > 0, "Group shield reaches each living ally")
	app.run._add_card("mender_resuscitate")
	var fallen: Dictionary = view.engine.find_unit("warden")
	view.engine.resolver.damage(view.engine.find_unit("enemy_0"), fallen, fallen.hp + fallen.shield)
	_hand("mender_resuscitate")
	_select_card()
	expect(view._target_is_legal("warden"), "Revival offers a dead ally as a valid target")
	_unit("warden").pressed.emit()
	await _settle()
	expect(fallen.hp > 0, "Choosing the fallen ally resolves revival")
	var hero: Dictionary = view.engine.find_unit("blade")
	hero.marks.append(
		{
			"id": 999,
			"kind": "bomb",
			"source_id": "enemy_0",
			"remaining": 2,
			"first_tick_turn": view.engine.state.turn + 1,
			"amount": 18
		}
	)
	view.refresh()
	expect(
		_unit("blade").get_node("Content/Statuses").text.contains(
			app.data.text("ui.bomb_remaining", {"remaining": 2})
		)
	)
	hero.marks.back().remaining = 1
	view.refresh()
	expect(
		_unit("blade").get_node("Content/Statuses").text.contains(
			app.data.text("ui.bomb_remaining", {"remaining": 1})
		),
		"Bomb display follows the live remaining countdown"
	)
	expect(
		_unit("blade").tooltip_text.contains(app.data.status_details("bomb")),
		"Bomb inspection includes dispel and effect details"
	)
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
	var presentation_connections := 0
	var save_connections := 0
	for connection in view.engine.settled.get_connections():
		if connection.callable == Callable(view, "_on_settled"):
			presentation_connections += 1
		if connection.callable == Callable(app.run, "_on_battle_settled"):
			save_connections += 1
	expect(presentation_connections == 1, "Restart connects exactly one battle presentation")
	expect(save_connections == 1, "Restart retains the separate automatic-save connection")
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
	var candidates: Array = app.run.view_snapshot().rewards.cards.duplicate()
	var random_state: int = app.run.rng.state
	app._on_run_changed()
	expect(
		app.run.view_snapshot().rewards.cards == candidates and app.run.rng.state == random_state,
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
		"Double reward click adds one card"
	)
	expect(app.get_node("Map").visible and not reward.visible, "Claim returns to the chapter map")
	await _advance_to_battle()
	await _win()
	var skips := {"count": 0}
	reward.skipped.connect(func(_token: int) -> void: skips.count += 1)
	var before_deck: Array = app.run.deck.duplicate(true)
	reward.get_node("Margin/Content/Skip").pressed.emit()
	reward.get_node("Margin/Content/Skip").pressed.emit()
	expect(skips.count == 1 and app.run.deck == before_deck, "Double skip preserves the deck")
	_skip_remaining_rewards()
	for step in range(12):
		if app.run.phase == Types.RunPhase.WON:
			break
		await _advance_to_battle()
		if app.run.phase != Types.RunPhase.BATTLE:
			break
		await _win(true)
		_skip_remaining_rewards()
	expect(
		app.get_node("Result").visible and app.run.phase == Types.RunPhase.WON,
		"Boss rewards finish the first chapter trial"
	)
	expect(
		not view.get_node("Piles").visible and view.selected_copy == -1,
		"Leaving combat clears its popup and selection"
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


func _skip_remaining_rewards() -> void:
	var reward = app.get_node("Reward")
	if app.run.phase == Types.RunPhase.REWARD and not app.run.view_snapshot().rewards.cards_done:
		reward.get_node("Margin/Content/Skip").pressed.emit()
	if app.run.phase == Types.RunPhase.REWARD and not app.run.view_snapshot().rewards.relics_done:
		reward.get_node("Margin/Content/SkipRelic").pressed.emit()


func _advance_to_battle() -> void:
	for step in range(30):
		var state: Dictionary = app.run.view_snapshot()
		match app.run.phase:
			Types.RunPhase.BATTLE:
				await _settle()
				return
			Types.RunPhase.WON, Types.RunPhase.LOST:
				return
			Types.RunPhase.MAP:
				var chosen := ""
				for node in state.map.nodes:
					if node.available:
						chosen = str(node.id)
						break
				if not expect(chosen != "", "Map offers a connected next node"):
					return
				app.get_node("Map")._on_node_pressed(chosen, int(state.token))
			Types.RunPhase.CAMP:
				app.get_node("NodePanel/Margin/Content/Camp/Rest").pressed.emit()
			Types.RunPhase.SHOP:
				app.get_node("NodePanel/Margin/Content/ShopActions/Leave").pressed.emit()
			Types.RunPhase.EVENT:
				var found := false
				for option in state.event.options:
					if str(option.id).ends_with("_leave"):
						app.get_node("NodePanel")._on_event_option(option, int(state.token))
						app.get_node("NodePanel/Picker").get_ok_button().pressed.emit()
						if app.get_node("Inspect").visible:
							app.get_node("Inspect").get_ok_button().pressed.emit()
						found = true
						break
				if not expect(found, "Every event includes a free leave option"):
					return
			Types.RunPhase.REWARD:
				_skip_remaining_rewards()
			_:
				expect(false, "Unexpected chapter phase")
				return
		await process_frame
	expect(false, "Navigation must reach combat within its bounded action count")


func _test_rebuild_during_presentation() -> void:
	_hand("slash")
	_select_card()
	_unit("enemy_0").pressed.emit()
	expect(view.locked, "Old presentation is pending")
	app._on_start()
	if app.get_node("Confirm").visible:
		app.get_node("Confirm").get_ok_button().pressed.emit()
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
		# canvas_items keeps a fixed logical viewport unless this is changed too.
		root.content_scale_size = window_size
		root.size = window_size
		await process_frame
		await process_frame
		expect(
			app.get_viewport_rect().size == Vector2(window_size),
			"Resize test changes the logical viewport to %s" % window_size
		)
		expect(app.size == Vector2(window_size), "Main follows the changed logical viewport")
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
