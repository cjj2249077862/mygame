extends "res://tests/test_suite.gd"

const MainScene = preload("res://scenes/main.tscn")
const Types = preload("res://scripts/core/enums.gd")
const Summary = preload("res://scripts/ui/battle/intent_summary.gd")

var app: Control
var view: Control
var drag: Control
var _copy_id: int = -1
var _pointer: Vector2 = Vector2.ZERO


func run_tests() -> void:
	root.size = Vector2i(1440, 900)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	app = MainScene.instantiate()
	app.save_directory = ""
	root.add_child(app)
	await process_frame
	if not expect(app.run != null, "Interaction tests load the real Main scene"):
		app.queue_free()
		await process_frame
		return
	view = app.get_node("Battle")
	drag = view.get_node("Drag")
	app.preferences.set_option("fast", true)
	app.preferences.set_option("audio_enabled", false)
	app.preferences.set_option("shake_enabled", false)
	app.preferences.set_option("show_log", false)
	await _restart()
	await _test_click_and_release()
	await _test_cancel_paths()
	await _test_unavailable_and_overlays()
	await _test_self_and_group()
	await _test_ally_and_revive()
	await _test_multiple_casters()
	await _test_dispel()
	await _test_piles()
	await _test_stable_hand_hover()
	await _test_keyword_panels()
	await _test_help_and_intents()
	await _test_help_content_and_threat()
	_test_revive_quota()
	view.leave_battle()
	app.get_node("AudioDirector").stop_all()
	await create_timer(0.1).timeout
	app.queue_free()
	await process_frame


func _settle() -> void:
	for index in range(400):
		if not view.locked:
			await _layout()
			return
		await create_timer(0.01).timeout
	expect(false, "Interaction presentation finishes within its timeout")


func _layout() -> void:
	await process_frame
	await process_frame


func _restart(lineup: Array[String] = ["warden", "blade", "mender"]) -> void:
	app._dismiss_dialogs()
	app.get_node("HoverHelp").hide_help()
	if app.run.phase in app.run.ACTIVE_PHASES:
		expect(app.run.abandon_run() == "", "Fixture abandons its previous in-memory run")
	app._showing_menu = false
	expect(app.run.start(261126, lineup), "Fixture starts deterministic in-memory run")
	await _settle()
	expect(view.is_visible_in_tree(), "Real Main displays the battle for pointer routing")


func _hand(card_id: String) -> void:
	view.clear_selection()
	app.get_node("HoverHelp").hide_help()
	var selected: Dictionary = {}
	for copy in app.run.deck:
		if copy.card_id == card_id:
			selected = copy.duplicate(true)
			break
	if selected.is_empty():
		app.run._add_card(card_id)
		selected = app.run.deck.back().duplicate(true)
	_copy_id = int(selected.copy_id)
	for pile in Types.PILES:
		view.engine.state[pile] = []
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
	await _layout()


func _unit(id: String) -> Control:
	return view._unit_views().get(id) as Control


func _card_center() -> Vector2:
	var card: Control = view.hand.get_child(0)
	return card.get_global_transform() * (card.size * 0.5)


func _field_point() -> Vector2:
	var bounds: Rect2 = view.hand.get_global_rect()
	return Vector2(bounds.get_center().x, bounds.position.y - 30.0)


func _motion(point: Vector2, held: bool = false) -> void:
	var event: InputEventMouseMotion = InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = point - _pointer
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	_pointer = point
	root.push_input(event, true)


func _button(point: Vector2, pressed: bool, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = point
	event.global_position = point
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	_pointer = point
	root.push_input(event, true)


func _click(point: Vector2) -> void:
	_motion(point)
	_button(point, true)
	_button(point, false)


func _start_drag(destination: Vector2) -> void:
	var origin: Vector2 = _card_center()
	_motion(origin)
	_button(origin, true)
	_motion(destination, true)


func _expect_unchanged(before: Dictionary, rng_state: int, label: String) -> void:
	expect(
		view.engine.snapshot() == before and view.engine.rng.state == rng_state,
		label + " leaves battle state and RNG unchanged"
	)


func _test_click_and_release() -> void:
	await _hand("slash")
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	var point: Vector2 = _card_center()
	_motion(point)
	_button(point, true)
	_motion(point + Vector2(7, 0), true)
	expect(not drag.is_dragging(), "Movement below eight logical pixels remains a click")
	_button(point + Vector2(7, 0), false)
	expect(view.selected_copy == _copy_id, "Short click retains click-to-select fallback")
	_expect_unchanged(before, rng_state, "Short selection")
	_click(_unit("enemy_0").get_global_rect().get_center())
	expect(view.engine.state.hand.is_empty(), "Click fallback plays once on target release")
	await _settle()
	await _restart()
	await _hand("slash")
	before = view.engine.snapshot()
	rng_state = view.engine.rng.state
	point = _card_center()
	_motion(point)
	_button(point, true)
	_motion(point + Vector2(8, 0), true)
	expect(drag.is_dragging(), "Eight logical pixels starts drag")
	expect(view.hand.get_child(0).modulate.a == 0.0, "Original card keeps its slot but hides")
	var target: Vector2 = _unit("enemy_0").get_global_rect().get_center()
	_motion(target, true)
	_expect_unchanged(before, rng_state, "Held card and target preview")
	expect(view.hovered_target == "enemy_0", "Drag identifies the unit beneath the pointer")
	expect(_unit("enemy_0").get_node("TargetHint").visible, "Primary target has visible feedback")
	_button(target, false)
	var after: Dictionary = view.engine.snapshot()
	expect(
		view.engine.state.energy == 2 and view.engine.state.hand.is_empty(),
		"Release spends one card and one energy"
	)
	expect(
		not drag.is_dragging() and drag.get_child_count() == 0, "Release removes ghost immediately"
	)
	_button(target, false)
	_motion(target, true)
	expect(view.engine.snapshot() == after, "Duplicate release and motion cannot replay the card")
	await _settle()


func _test_cancel_paths() -> void:
	await _restart()
	for method in ["hand", "right", "escape", "focus", "resize", "invalid"]:
		await _hand("slash")
		var before: Dictionary = view.engine.snapshot()
		var rng_state: int = view.engine.rng.state
		var target: Vector2 = _unit("enemy_0").get_global_rect().get_center()
		_start_drag(target)
		expect(drag.is_dragging(), "Cancel fixture starts drag: " + method)
		match method:
			"hand":
				_motion(_card_center(), true)
				_button(_card_center(), false)
			"right":
				_button(target, true, MOUSE_BUTTON_RIGHT)
			"escape":
				var escape: InputEventKey = InputEventKey.new()
				escape.keycode = KEY_ESCAPE
				escape.pressed = true
				root.push_input(escape, true)
			"focus":
				root.focus_exited.emit()
			"resize":
				root.content_scale_size = Vector2i(1200, 760)
				root.size = Vector2i(1200, 760)
				await _layout()
			"invalid":
				_button(_unit("warden").get_global_rect().get_center(), false)
		_button(target, false)
		expect(
			not drag.is_dragging() and drag.get_child_count() == 0, "Cancel clears ghost: " + method
		)
		expect(view.hand.get_child(0).modulate.a == 1.0, "Cancel restores original card: " + method)
		expect(view.selected_copy == -1, "Cancel clears pending selection: " + method)
		_expect_unchanged(before, rng_state, method + " cancel plus later release")
	root.content_scale_size = Vector2i(1440, 900)
	root.size = Vector2i(1440, 900)
	await _layout()


func _test_unavailable_and_overlays() -> void:
	await _hand("slash")
	view.engine.state.energy = 0
	view.refresh()
	await _layout()
	var card: Button = view.hand.get_child(0)
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	_start_drag(_unit("enemy_0").get_global_rect().get_center())
	_button(_pointer, false)
	expect(
		not drag.is_dragging() and view.selected_copy == -1, "Unavailable card cannot drag or click"
	)
	expect(
		card.tooltip_text.contains(app.data.text("error.energy")),
		"Native tooltip property remains compatible"
	)
	expect(
		str(card.get_meta("help_plain_text")).contains(app.data.text("error.energy")),
		"Disabled card explains its unavailable reason"
	)
	var unavailable: Array = card.get_meta("help_sections")
	expect(
		(
			unavailable.size() == 1
			and unavailable[0].id == "unavailable"
			and unavailable[0].body == app.data.text("error.energy")
		),
		"Plain unavailable card adds only its specific failure reason"
	)
	expect(
		card._get_tooltip(Vector2.ZERO) == "", "Structured help suppresses duplicate native popup"
	)
	_expect_unchanged(before, rng_state, "Unaffordable drag")
	await _hand("slash")
	var help: Node = app.get_node("HoverHelp")
	var panel: Control = help.panel
	help._candidate = view.hand.get_child(0)
	panel.position = _card_center() - Vector2(60, 60)
	panel.size = Vector2(120, 120)
	panel.show()
	var point: Vector2 = _card_center()
	_button(point, true)
	_motion(point + Vector2(20, 0), true)
	expect(drag.is_dragging(), "Ordinary hover help over a card does not intercept dragging")
	_button(point + Vector2(20, 0), false)
	expect(view.selected_copy == -1, "Releasing through help inside hand still cancels the drag")
	help.hide_help()
	view._on_piles_pressed("draw")
	_click(_card_center())
	expect(
		view.selected_copy == -1 and not drag.has_pointer_capture(),
		"Embedded modal blocks card short clicks"
	)
	view.get_node("Piles").hide()


func _test_self_and_group() -> void:
	await _restart()
	for card_id in ["guard", "warden_wall"]:
		await _hand(card_id)
		var before: Dictionary = view.engine.snapshot()
		var rng_state: int = view.engine.rng.state
		var inside: Vector2 = view.hand.get_global_rect().get_center()
		_start_drag(inside + Vector2(20, 0))
		_motion(_field_point(), true)
		_expect_unchanged(before, rng_state, "Self/group crossing before release")
		_motion(inside, true)
		_button(inside, false)
		_expect_unchanged(before, rng_state, "Self/group returned to hand")
		_start_drag(_field_point())
		_button(_field_point(), false)
		expect(
			view.engine.state.hand.is_empty(), "Self/group releases above hand to cast: " + card_id
		)
		if card_id == "guard":
			expect(
				(
					view.engine.find_unit("warden").shield > 0
					and view.engine.find_unit("blade").shield == 0
				),
				"Self shield belongs only to its caster"
			)
		else:
			for hero in view.engine.state.heroes:
				expect(hero.shield > 0, "No-target group shield reaches each living ally")
		await _settle()


func _test_ally_and_revive() -> void:
	await _restart()
	view.engine.find_unit("mender").hp -= 20
	await _hand("heal")
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	_start_drag(_field_point())
	_button(_field_point(), false)
	_expect_unchanged(before, rng_state, "Ally heal released on empty field")
	var target: Vector2 = _unit("mender").get_global_rect().get_center()
	_start_drag(target)
	_button(target, false)
	expect(
		view.engine.find_unit("mender").hp > before.heroes[2].hp,
		"Ally heal can explicitly target its own caster"
	)
	await _settle()
	var fallen: Dictionary = view.engine.find_unit("warden")
	view.engine.resolver.damage(view.engine.find_unit("enemy_0"), fallen, fallen.hp + fallen.shield)
	await _hand("mender_resuscitate")
	before = view.engine.snapshot()
	rng_state = view.engine.rng.state
	target = _unit("blade").get_global_rect().get_center()
	_start_drag(target)
	_button(target, false)
	_expect_unchanged(before, rng_state, "Revive released on a living ally")
	target = _unit("warden").get_global_rect().get_center()
	_start_drag(target)
	_button(target, false)
	expect(fallen.hp > 0 and fallen.revives_used == 1, "Revive requires the selected fallen ally")
	await _settle()


func _test_multiple_casters() -> void:
	var original: Dictionary = app.data.books.duplicate(true)
	var second: Dictionary = app.data.definition("characters", "warden").duplicate(true)
	second.id = "interaction_second_tank"
	app.data.books.characters.sheets.main.append(second)
	for entry in [{"card_id": "slash", "count": 2}, {"card_id": "guard", "count": 3}]:
		app.data.books.characters.sheets.starter.append(
			{
				"id": "interaction_" + entry.card_id,
				"character_id": second.id,
				"card_id": entry.card_id,
				"count": entry.count,
				"_source": "Interaction fixture"
			}
		)
	await _restart(["warden", "interaction_second_tank", "mender"])
	await _hand("guard")
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	_start_drag(_field_point())
	_button(_field_point(), false)
	_expect_unchanged(before, rng_state, "Unchosen shared-class caster")
	expect(
		view.selected_caster == "" and not drag.is_dragging(),
		"Multiple eligible casters never auto-select"
	)
	var picker: Control = view.get_node("Interaction/CasterPicker")
	expect(picker.visible, "Multiple casters expose the explicit avatar picker")
	await _layout()
	for button in picker.get_node("Content/Choices").get_children():
		if str(button.get_meta("caster_id")) == "interaction_second_tank":
			_click(button.get_global_rect().get_center())
	expect(
		view.selected_caster == "interaction_second_tank",
		"Avatar click above the hand is not swallowed by card input"
	)
	_start_drag(_field_point())
	expect(drag.is_dragging(), "Chosen caster permits the same card to drag")
	_button(_field_point(), false)
	expect(
		(
			view.engine.find_unit("interaction_second_tank").shield > 0
			and view.engine.find_unit("warden").shield == 0
		),
		"Self effect preserves explicit same-class caster"
	)
	await _settle()
	await _hand("shield_bash")
	_start_drag(_unit("enemy_0").get_global_rect().get_center())
	expect(view.selected_caster == "warden", "Personal owner stays unique among same-class heroes")
	drag.cancel()
	_button(_pointer, false)
	app.data.books = original
	await _restart()


func _test_dispel() -> void:
	await _hand("first_aid")
	var hero: Dictionary = view.engine.find_unit("warden")
	hero.hp -= 20
	view.engine.resolver.add_status(view.engine.find_unit("enemy_0"), hero, "poison", 2)
	view.engine.resolver.add_status(view.engine.find_unit("enemy_0"), hero, "weak", 1)
	view.refresh()
	await _layout()
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	var target: Vector2 = _unit("warden").get_global_rect().get_center()
	_start_drag(target)
	_button(target, false)
	var dialog: ConfirmationDialog = view.get_node("DispelConfirm")
	expect(
		dialog.visible and view.dispel_choices.item_count == 2,
		"Drag with multiple dispels opens status choice"
	)
	_expect_unchanged(before, rng_state, "Pending dispel confirmation")
	view.dispel_choices.select(1)
	view.dispel_choices.item_selected.emit(1)
	var chosen: String = view.chosen_status
	dialog.get_ok_button().pressed.emit()
	expect(
		not hero.statuses.has(chosen) and hero.statuses.size() == 1,
		"Confirmed dispel removes exactly its chosen status"
	)
	expect(
		view.engine.state.energy == 2 and view.engine.state.hand.is_empty(),
		"Dispel confirmation charges exactly once"
	)
	await _settle()


func _test_piles() -> void:
	await _restart()
	await _hand("slash")
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	for pair in [["Piles", "draw"], ["Discard", "discard"]]:
		view.get_node("Margin/Content/Actions/" + pair[0]).pressed.emit()
		var tabs: TabBar = view.get_node("Piles/Tabs")
		expect(
			view.get_node("Piles").visible and tabs.current_tab == view.PILE_KEYS.find(pair[1]),
			"Pile button chooses its initial tab: " + pair[1]
		)
		for index in range(tabs.tab_count):
			tabs.current_tab = index
			tabs.tab_changed.emit(index)
		_expect_unchanged(before, rng_state, "Browsing all sorted pile tabs")
		view.get_node("Piles").hide()
	view._on_piles_pressed("draw")
	var sorted_cards: Array = before.draw.duplicate(true)
	sorted_cards.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return a.card_id < b.card_id if a.card_id != b.card_id else a.copy_id < b.copy_id
	)
	var rendered: String = view.get_node("Piles/Text").text
	expect(
		(
			not sorted_cards.is_empty()
			and rendered.split("\n")[1] == app.data.card_details(sorted_cards[0]).replace("\n", "　")
		),
		"Draw viewer sorts a copy instead of revealing live order"
	)
	_expect_unchanged(before, rng_state, "Sorted draw preview")
	view.get_node("Piles").hide()


func _test_stable_hand_hover() -> void:
	await _restart()
	for viewport_size in [Vector2i(1200, 760), Vector2i(1440, 900)]:
		root.content_scale_size = viewport_size
		root.size = viewport_size
		view.clear_selection()
		for pile in Types.PILES:
			view.engine.state[pile] = []
		view.engine.state.hand = app.run.deck.slice(0, 10).duplicate(true)
		view.engine.state.draw = app.run.deck.slice(10).duplicate(true)
		view.refresh()
		await _layout()
		var before: Dictionary = view.engine.snapshot()
		var rng_state: int = view.engine.rng.state
		var cards: Array[Node] = view.hand.get_children()
		expect(cards.size() == 10, "Hover fixture uses a full overlapping hand")
		var previous_x: float = -INF
		for card in cards:
			var anchor: Rect2 = view.hand.help_anchor_rect(card)
			var point: Vector2 = anchor.get_center()
			expect(point.x > previous_x, "Stable slot centers keep deck order")
			previous_x = point.x
			_motion(point)
			await process_frame
			expect(
				view.hand.card_at_position(point) == card and view.hand.hovered_card() == card,
				"Horizontal movement switches directly to the neighboring slot"
			)
			await create_timer(float(view.hand.layout_duration) + 0.02).timeout
			expect(
				view.hand.card_at_position(point) == card and view.hand.hovered_card() == card,
				"Animation cannot move ownership away from a stationary pointer"
			)
			expect(
				view.hand.help_anchor_rect(card) == anchor,
				"Tooltip anchor does not move with raised card"
			)
			var hovered: Control = card as Control
			expect(hovered.scale.x > 1.0, "Stable hover raises the chosen card")
			# Synthetic native enter/exit changes must not override fixed slot ownership.
			card.mouse_exited.emit()
			cards[0].mouse_entered.emit()
			expect(
				view.hand.hovered_card() == card,
				"Native animation boundary signals do not change the hand selection"
			)
		cards.reverse()
		for card in cards:
			var point: Vector2 = view.hand.help_anchor_rect(card).get_center()
			_motion(point)
			expect(
				view.hand.hovered_card() == card,
				"Rapid reverse browsing is not captured by the previous raised face"
			)
		_motion(view.hand.hover_region().position - Vector2(20, 20))
		expect(view.hand.hovered_card() == null, "Leaving the hand clears stable hover")
		_expect_unchanged(before, rng_state, "Rapid hand browsing at " + str(viewport_size))


func _test_keyword_panels() -> void:
	await _restart()
	var selected: Array[Dictionary] = []
	for id in ["warden_command", "first_aid"]:
		await _hand(id)
		selected.append(view.engine.state.hand[0].duplicate(true))
	for pile in Types.PILES:
		view.engine.state[pile] = []
	view.engine.state.hand = selected.duplicate(true)
	for copy in app.run.deck:
		if copy.copy_id != selected[0].copy_id and copy.copy_id != selected[1].copy_id:
			view.engine.state.draw.append(copy.duplicate(true))
	view.refresh()
	await _layout()
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	var help: Node = app.get_node("HoverHelp")
	for viewport_size in [Vector2i(1200, 760), Vector2i(1440, 900)]:
		root.content_scale_size = viewport_size
		root.size = viewport_size
		await _layout()
		help.hide_help()
		var first: Control = view.hand.get_child(0)
		_motion(view.hand.help_anchor_rect(first).get_center())
		await create_timer(float(help.hover_delay) * 0.4).timeout
		expect(not help.panel.visible, "First hover waits before showing keyword panels")
		await create_timer(float(help.hover_delay) + 0.03).timeout
		var sections: Array = first.get_meta("help_sections")
		var rects: Array = help.visible_entry_rects()
		expect(
			help.panel.visible and rects.size() == sections.size() and rects.size() >= 2,
			"Each keyword gets an independent visible panel"
		)
		_expect_help_geometry(help)
		var shown_ids: Array[String] = []
		for frame in help.panel.get_children():
			shown_ids.append(str(frame.get_meta("help_section_id")))
			expect(
				frame.has_node("Blur") and frame.has_node("Border"),
				"Each keyword owns its blur backing and border"
			)
		for section in sections:
			expect(
				str(section.id) in shown_ids, "Independent panels retain stable mechanic identity"
			)
		var second: Control = view.hand.get_child(1)
		_motion(view.hand.help_anchor_rect(second).get_center())
		await create_timer(float(help.switch_delay) + 0.03).timeout
		expect(
			(
				float(help.switch_delay) < float(help.hover_delay)
				and help._candidate == second
				and help.panel.visible
			),
			"Switching within the same hand uses the short delay"
		)
		var next_sections: Array = second.get_meta("help_sections")
		var next_ids: Array[String] = []
		for section in next_sections:
			next_ids.append(str(section.id))
		for frame in help.panel.get_children():
			expect(
				str(frame.get_meta("help_section_id")) in next_ids,
				"Fast switch removes stale keyword panels"
			)
		_expect_help_geometry(help)
		view.locked = true
		view.hand.render(view.engine.state.hand, app.data, view.engine, true, -1)
		await _layout()
		second = view.hand.get_child(1)
		_motion(view.hand.help_anchor_rect(second).get_center())
		await create_timer(float(help.hover_delay) + 0.03).timeout
		expect(
			second.disabled and help.panel.visible, "Locked combat still permits keyword inspection"
		)
		_start_drag(_field_point())
		expect(
			not drag.has_pointer_capture(), "Presentation lock keeps inspected cards from dragging"
		)
		_button(_pointer, false)
		view.locked = false
		view.refresh()
		await _layout()
		_expect_unchanged(before, rng_state, "Keyword inspection at " + str(viewport_size))
	await _hand("slash")
	_motion(_card_center())
	await create_timer(float(help.hover_delay) + 0.03).timeout
	expect(
		not help.panel.visible and help.visible_entry_rects().is_empty(),
		"Keyword-free card produces no empty or repeated popup"
	)


func _expect_help_geometry(help: Node) -> void:
	var rects: Array = help.visible_entry_rects()
	var viewport: Rect2 = app.get_viewport_rect()
	var hand_bounds: Rect2 = view.hand.help_exclusion_rect()
	for index in range(rects.size()):
		var bounds: Rect2 = rects[index]
		expect(
			bounds.has_area() and viewport.encloses(bounds),
			"Keyword panel stays within the logical viewport"
		)
		expect(
			not bounds.intersects(hand_bounds),
			"Keyword panels avoid the whole hand, including raised faces"
		)
		for other in range(index):
			expect(not bounds.intersects(rects[other]), "Independent keyword panels do not overlap")
	_expect_mouse_ignored(help.panel)


func _expect_mouse_ignored(node: Node) -> void:
	if node is Control:
		expect(
			node.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"Ordinary help content passes pointer input through"
		)
	for child in node.get_children():
		_expect_mouse_ignored(child)


func _test_help_and_intents() -> void:
	for viewport_size in [Vector2i(1200, 760), Vector2i(1440, 900)]:
		root.content_scale_size = viewport_size
		root.size = viewport_size
		app.run._begin_battle("outpost_crossfire")
		await _settle()
		var before: Dictionary = view.engine.snapshot()
		var rng_state: int = view.engine.rng.state
		var preview: Dictionary = view.engine.intent_preview("enemy_0")
		expect(int(preview.effects[0].hits) == 2, "Structured intent retains multi-hit count")
		expect(
			_unit("enemy_0").get_node("Content/Intent").text.contains("× 2"),
			"Intent shows hit count without opening details"
		)
		var target_id: String = str(preview.target_ids[0])
		var target: Control = _unit(target_id)
		expect(target.get_node("Incoming").visible, "Targeted hero shows incoming mark")
		var mark_count: int = 0
		for enemy in view.engine.state.enemies:
			if target_id in view.engine.intent_preview(enemy.id).target_ids:
				mark_count += 1
		expect(
			target.get_node("Incoming/Count").text.contains(str(mark_count)),
			"Incoming mark counts all visible enemy intentions"
		)
		var help: Node = app.get_node("HoverHelp")
		expect(
			help._help_owner(_unit("enemy_0").get_node("Content/Details")) == null,
			"Ordinary enemy body without mechanics has no redundant basic tooltip"
		)
		var label: Control = target.get_node("Content/Details")
		expect(
			help._help_owner(label) == target,
			"Child label resolves structured unit help through its parent"
		)
		_motion(_unit("enemy_0").get_node("Content/Intent").get_global_rect().get_center())
		await _layout()
		expect(
			(
				target.get_node("RelatedHighlight").visible
				and _unit("enemy_0").get_node("RelatedHighlight").visible
			),
			"Intent hover highlights both its source enemy and related hero"
		)
		_motion(target.get_node("Incoming").get_global_rect().get_center())
		await _layout()
		expect(
			target.get_node("RelatedHighlight").visible,
			"Incoming mark hover retains its hero highlight"
		)
		for enemy in view.engine.state.enemies:
			expect(
				(
					_unit(enemy.id).get_node("RelatedHighlight").visible
					== (target_id in view.engine.intent_preview(enemy.id).target_ids)
				),
				"Hero hover highlights exactly the enemies currently aiming at it"
			)
		_expect_unchanged(before, rng_state, "Intent, incoming mark and hover help")
		for actor in view._unit_views().values():
			expect(
				app.get_viewport_rect().grow(1).encloses(actor.get_global_rect()),
				"Intent-bearing actor remains in viewport at " + str(viewport_size)
			)
		target.set_incoming_intents([])
		expect(
			not target.get_node("Incoming").visible, "Incoming mark clears when its list is empty"
		)
		view.refresh()
		await _hand("first_aid")
		var sections: Array = view.hand.get_child(0).get_meta("help_sections")
		var ids: Array[String] = []
		for section in sections:
			expect(str(section.id) not in ids, "Card hover keyword is listed once")
			ids.append(str(section.id))
		expect(
			not sections.is_empty() and not ids.has("card"),
			"Card help contains mechanics without repeating the card face"
		)
		var origin: Vector2 = _card_center()
		_start_drag(_unit("warden").get_global_rect().get_center())
		expect(help._dragging and not help.panel.visible, "Dragging closes contextual help")
		expect(
			app.get_viewport_rect().grow(1).encloses(drag.get_child(0).get_global_rect()),
			"Drag ghost fits logical viewport"
		)
		_motion(origin, true)
		_button(origin, false)
	app.run._begin_battle("outpost_laboratory")
	await _settle()
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	var preview: Dictionary = view.engine.intent_preview("enemy_0")
	expect(
		preview.all_targets and preview.target_ids.size() == 3,
		"Group intent identifies every living party member"
	)
	var summary: Dictionary = Summary.compact(preview, app.data)
	expect(
		summary.all_targets and summary.target_ids.size() == 3,
		"Group intent summary preserves target range"
	)
	for hero in view.engine.state.heroes:
		expect(_unit(hero.id).get_node("Incoming").visible, "Group intent marks each affected hero")
	_expect_unchanged(before, rng_state, "Group intent formatting")


func _test_help_content_and_threat() -> void:
	for definition in app.data.rows("cards"):
		var copy: Dictionary = {"card_id": definition.id, "copy_id": 99999, "upgraded": false}
		var sections: Array = app.data.card_sections(copy)
		var ids: Array[String] = []
		for section in sections:
			expect(
				str(section.id).begins_with("keyword.") and str(section.id) not in ids,
				"Card help contains unique mechanic sections only: " + str(definition.id)
			)
			expect(
				(
					str(section.id)
					not in [
						"keyword.damage",
						"keyword.heal",
						"keyword.shield",
						"keyword.draw",
						"keyword.energy"
					]
				),
				"Basic card values are not repeated as extra explanations"
			)
			ids.append(str(section.id))
	for id in ["heal", "first_aid", "mender_restore", "mender_mass_heal", "tactic_bandage"]:
		var sections: Array = app.data.card_sections(
			{"card_id": id, "copy_id": 99999, "upgraded": false}
		)
		for section in sections:
			expect(
				section.id != "keyword.threat",
				"Healing does not attach a generic threat explanation"
			)
	expect(
		(
			app
			. data
			. card_sections({"card_id": "slash", "copy_id": 99999, "upgraded": false})
			. is_empty()
		),
		"Plain damage card needs no repeated card-face popup"
	)
	await _restart()
	var warden: Dictionary = view.engine.find_unit("warden")
	var blade: Dictionary = view.engine.find_unit("blade")
	var mender: Dictionary = view.engine.find_unit("mender")
	warden.threat = 10
	blade.threat = 30
	mender.threat = 30
	view.refresh()
	await _layout()
	for hero in view.engine.state.heroes:
		var actor: Control = _unit(hero.id)
		expect(
			(
				not actor.get_node("Content/ThreatIcon").visible
				and not actor.get_node("Content/ThreatValue").visible
			),
			"Hero has no separate threat display"
		)
		var help_sections: Array = actor.get_meta("help_sections")
		for section in help_sections:
			expect(
				(
					section.id
					not in ["unit", "intent", "incoming", "keyword.threat", "keyword.shield"]
				),
				"Hero body help omits visible basics and unrelated threat rules"
			)
	var enemy: Dictionary = view.engine.find_unit("enemy_0")
	var before: Dictionary = view.engine.snapshot()
	var rng_state: int = view.engine.rng.state
	var sections: Array = app.data.threat_sections(enemy, view.engine)
	expect(
		(
			sections.size() == 2
			and sections[0].id == "threat.ranking"
			and sections[1].id == "threat.reason"
		),
		"Monster threat has separate current ranking and targeting reason"
	)
	var ranking: String = str(sections[0].body)
	var blade_name: String = app.data.text(blade.name_key)
	var mender_name: String = app.data.text(mender.name_key)
	var warden_name: String = app.data.text(warden.name_key)
	expect(
		(
			ranking.find(blade_name) < ranking.find(mender_name)
			and ranking.find(mender_name) < ranking.find(warden_name)
		),
		"Threat sorts descending and preserves original slot order for ties"
	)
	var icon: Control = _unit("enemy_0").get_node("Content/ThreatIcon")
	expect(
		icon.visible and icon.get_meta("help_sections") == sections,
		"Enemy threat icon exposes its live ranking and reason"
	)
	_expect_unchanged(before, rng_state, "Threat ranking inspection")
	enemy.target_id = "mender"
	before = view.engine.snapshot()
	sections = app.data.threat_sections(enemy, view.engine)
	expect(
		str(sections[1].body).contains(
			app.data.presentation_text("hover.threat.by_threat", {"target": mender_name})
		),
		"Tied threat describes the retained actual target rather than reselecting the first row"
	)
	_expect_unchanged(before, rng_state, "Tie explanation")
	# A special intent keeps its actual locked target even if current HP would choose another.
	enemy.intent.target_rule = "lowest_hp_ratio"
	enemy.target_id = "blade"
	mender.hp = 1
	warden.threat = 999
	before = view.engine.snapshot()
	sections = app.data.threat_sections(enemy, view.engine)
	expect(
		(
			sections[1].body
			== app.data.presentation_text("hover.threat.lowest_locked", {"target": blade_name})
		),
		"Special target explanation names the intent's actual locked unit"
	)
	_expect_unchanged(before, rng_state, "Special targeting explanation")
	mender.hp = 0
	before = view.engine.snapshot()
	sections = app.data.threat_sections(enemy, view.engine)
	expect(
		not str(sections[0].body).contains(mender_name),
		"Fallen heroes leave the displayed threat ranking"
	)
	_expect_unchanged(before, rng_state, "Dead hero threat filtering")


func _test_revive_quota() -> void:
	var hero: Dictionary = view.engine.find_unit("warden").duplicate(true)
	hero.revives_used = 1
	hero.revive_limit = 2
	for hp in [1, 0]:
		hero.hp = hp
		var quota: Dictionary = _section_by_id(
			app.data.unit_sections(hero, view.engine), "revive_quota"
		)
		expect(
			(
				not quota.is_empty()
				and quota.body == app.data.text("ui.revive_quota", {"used": 1, "limit": 2})
			),
			"Living and fallen hero help reads current per-unit revival usage and limit"
		)
	var enemy: Dictionary = view.engine.find_unit("enemy_0").duplicate(true)
	expect(
		_section_by_id(app.data.unit_sections(enemy, view.engine), "revive_quota").is_empty(),
		"Enemy inspection never shows a hero revival quota"
	)


func _section_by_id(sections: Array, id: String) -> Dictionary:
	for section in sections:
		if str(section.id) == id:
			return section
	return {}
