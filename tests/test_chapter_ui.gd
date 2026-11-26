extends "res://tests/test_suite.gd"

const MainScene = preload("res://scenes/main.tscn")
const MapScene = preload("res://scenes/run/map_view.tscn")
const NodeScene = preload("res://scenes/run/node_panel.tscn")
const RewardScene = preload("res://scenes/run/reward_panel.tscn")
const Types = preload("res://scripts/core/enums.gd")
var app: Control
var data: RefCounted


func run_tests() -> void:
	root.size = Vector2i(1440, 900)
	root.gui_embed_subwindows = true
	app = MainScene.instantiate()
	app.save_directory = "user://chapter_ui_%d" % Time.get_ticks_usec()
	root.add_child(app)
	await process_frame
	if not expect(app.run != null, "Chapter UI loads all configuration"):
		app.queue_free()
		return
	data = app.data
	app.get_node("Battle/Margin/Content/Actions/Fast").button_pressed = true
	await _test_continue_and_confirmations()
	app.hide()
	await _test_map()
	await _test_node_choices()
	await _test_reward_sections()
	app.queue_free()
	await process_frame


func _settle() -> void:
	for index in range(500):
		if not app.get_node("Battle").locked:
			await process_frame
			return
		await create_timer(0.01).timeout
	expect(false, "Presentation releases its lock")


func _test_continue_and_confirmations() -> void:
	expect(
		app.get_node("Menu/Content/Continue").disabled,
		"A fresh test directory has no continue slot"
	)
	app.get_node("Menu/Content/Start").pressed.emit()
	await _settle()
	await _test_chapter_overview()
	expect(app.run.has_saved_run(), "Opening battle is saved")
	expect(app.run.battle.end_turn() == "")
	await _settle()
	var saved: Dictionary = app.run.battle.snapshot()
	var random_state: int = app.run.rng.state
	app.get_node("Navigation/Actions/Menu").pressed.emit()
	expect(app.get_node("Menu").visible, "Save-and-menu returns to the menu")
	expect(
		not app.get_node("Menu/Content/Continue").disabled, "The menu exposes the current saved run"
	)
	app.get_node("Menu/Content/Start").pressed.emit()
	expect(app.get_node("Confirm").visible, "A new run asks before replacing existing progress")
	app.get_node("Confirm").get_cancel_button().pressed.emit()
	expect(app.run.has_saved_run(), "Cancelling replacement preserves the save")
	app.get_node("Menu/Content/Continue").pressed.emit()
	await _settle()
	expect(
		not app.get_node("ChapterMap").visible, "Continue does not force the chapter overview again"
	)
	expect(
		app.run.battle.snapshot() == saved,
		"Continue restores the last complete turn, not an opening battle"
	)
	expect(app.run.rng.state == random_state, "Continue does not draw or reroll")
	expect(app.get_node("Battle").visible, "Continue displays the restored battle")
	var before: Dictionary = app.run.battle.snapshot()
	app.run.persistence_error = "save_write_failed"
	app._on_run_changed()
	expect(app.get_node("SaveProblem").visible, "Save failure is visible with a retry action")
	expect(app.get_node("Battle").end_button.disabled, "Save failure disables combat input")
	app.get_node("Battle")._end_turn()
	expect(app.run.battle.snapshot() == before, "Blocked battle input cannot mutate state")
	app.run.persistence_error = ""
	app._on_run_changed()
	app.get_node("Navigation/Actions/Abandon").pressed.emit()
	app.get_node("Confirm").get_cancel_button().pressed.emit()
	expect(
		app.run.phase == Types.RunPhase.BATTLE and app.run.has_saved_run(),
		"Cancelling abandonment keeps the run"
	)
	app.get_node("Navigation/Actions/Abandon").pressed.emit()
	app.get_node("Confirm").get_ok_button().pressed.emit()
	expect(app.run.phase == Types.RunPhase.ABANDONED, "Confirmed abandonment has its own result")
	expect(
		app.get_node("Result").visible and not app.run.has_saved_run(),
		"Abandon clears only the active run and shows its summary"
	)


func _test_chapter_overview() -> void:
	var dialog = app.get_node("ChapterMap")
	var overview = app.get_node("ChapterMap/Map")
	expect(dialog.visible, "A new adventure immediately reveals the complete map and Boss")
	var boss: Dictionary = app.run.view_snapshot().boss
	var text: String = overview.get_node("Margin/Content/Boss").text
	expect(
		text.contains(boss.name) and text.contains(boss.description),
		"The first battle already exposes the Boss identity and introduction"
	)
	expect(
		overview._buttons.size() == app.run.chapter_map.nodes.size(),
		"The overview contains every generated chapter node"
	)
	var before: Dictionary = app.run.battle.snapshot()
	var token: int = app.run.action_token
	var calls: Array = []
	overview.node_chosen.connect(
		func(id: String, sent_token: int) -> void: calls.append([id, sent_token])
	)
	for button in overview._buttons.values():
		expect(button.disabled, "Overview nodes are inspection only")
		button.pressed.emit()
	expect(
		calls.is_empty() and app.run.action_token == token and app.run.battle.snapshot() == before,
		"Even synthetic clicks on overview nodes cannot change the active battle"
	)
	for logical_size in [Vector2i(1280, 800), Vector2i(1440, 900)]:
		await _set_logical_size(logical_size)
		var bounds: Rect2 = root.get_visible_rect().grow(1)
		expect(
			bounds.encloses(Rect2(Vector2(dialog.position), Vector2(dialog.size))),
			"The chapter overview window fits the tested logical viewport"
		)
		var inner: Rect2 = dialog.get_visible_rect().grow(1)
		for button in overview._buttons.values():
			expect(inner.encloses(button.get_global_rect()), "All ten map depths fit the overview")
	dialog.get_ok_button().pressed.emit()
	expect(not dialog.visible)
	app.get_node("Navigation/Actions/Map").pressed.emit()
	expect(dialog.visible, "Chapter overview can be reopened during the active battle")
	dialog.get_ok_button().pressed.emit()
	expect(app.run.battle.snapshot() == before and app.run.action_token == token)


func _test_map() -> void:
	var map = MapScene.instantiate()
	map.theme = app.theme
	root.add_child(map)
	var calls: Array = []
	map.node_chosen.connect(func(id: String, token: int) -> void: calls.append([id, token]))
	var state := {
		"token": 10,
		"persistence_error": "",
		"boss": {"name": "Boss", "description": "Public mechanism"},
		"map":
		{
			"nodes":
			[
				{
					"id": "start",
					"depth": 1,
					"column": 0,
					"kind": "battle",
					"next": ["next"],
					"visited": true,
					"available": false,
					"current": true
				},
				{
					"id": "next",
					"depth": 2,
					"column": 0,
					"kind": "event",
					"next": [],
					"visited": false,
					"available": true,
					"current": false
				}
			]
		}
	}
	map.render(state, data)
	map._buttons.start.pressed.emit()
	expect(calls.is_empty(), "Visited or unreachable nodes cannot be selected")
	var old_button: Button = map._buttons.next
	old_button.pressed.emit()
	old_button.pressed.emit()
	expect(calls == [["next", 10]], "One map choice submits once with its displayed token")
	state.token = 11
	map.render(state, data)
	old_button.pressed.emit()
	expect(calls.size() == 1, "A stale node button cannot choose a new-generation node")
	expect(map.get_node("Margin/Content/Boss").text.contains("Public mechanism"))
	# Use all actual generated depths for geometry, rather than the two-node input fixture.
	map.offset_top = 50.0
	map.render(app.run.view_snapshot(), data)
	await _check_layout_sizes(
		map, ["Margin/Content/Canvas", "Margin/Content/Boss"], map._buttons.values()
	)
	map.queue_free()
	await process_frame


func _test_node_choices() -> void:
	var panel = NodeScene.instantiate()
	panel.theme = app.theme
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)
	_apply_node_margins(panel)
	var calls: Array = []
	panel.action_requested.connect(
		func(action: String, id: String, copy_id: int, token: int, selection: String) -> void:
			calls.append([action, id, copy_id, token, selection])
	)
	var state := {
		"phase": Types.RunPhase.CAMP,
		"token": 20,
		"gold": 100,
		"persistence_error": "",
		"camp":
		{
			"recoveries": [{"id": "warden", "name": "守卫", "amount": 24, "hp": 30, "max_hp": 80}],
			"upgrade_cards": [{"copy_id": 7, "before": "基础 8", "after": "升级 11"}]
		},
		"shop": {},
		"event": {}
	}
	panel.render(state, data)
	await _check_layout_sizes(panel, ["Margin/Content/Camp/Rest", "Margin/Content/Camp/Upgrade"])
	panel.get_node("Margin/Content/Camp/Upgrade").pressed.emit()
	expect(panel.get_node("Picker").get_ok_button().disabled, "Upgrade needs a selected card copy")
	panel.get_node("Picker/Content/Scroll/Cards").get_child(0).pressed.emit()
	expect(
		(
			panel.get_node("Picker/Content/Preview").text.contains("基础 8")
			and panel.get_node("Picker/Content/Preview").text.contains("升级 11")
		),
		"Upgrade shows both versions before committing"
	)
	panel.get_node("Picker").get_cancel_button().pressed.emit()
	expect(calls.is_empty(), "Cancelling upgrade consumes no camp action")
	panel.get_node("Margin/Content/Camp/Upgrade").pressed.emit()
	panel.get_node("Picker/Content/Scroll/Cards").get_child(0).pressed.emit()
	panel.get_node("Picker").get_ok_button().pressed.emit()
	panel._on_picker_confirmed()
	expect(
		calls == [["camp_upgrade", "", 7, 20, ""]], "Upgrade submits exactly the selected copy once"
	)
	state.phase = Types.RunPhase.SHOP
	state.token = 21
	state.shop = {
		"offers":
		[
			{
				"id": "a",
				"kind": "card",
				"item_id": "slash",
				"name": "挥砍",
				"description": "实际商品说明",
				"price": 35,
				"sold_out": false
			},
			{
				"id": "b",
				"kind": "card",
				"item_id": "guard",
				"name": "架盾",
				"description": "",
				"price": 35,
				"sold_out": true
			},
			{
				"id": "c",
				"kind": "relic",
				"item_id": "",
				"name": "",
				"description": "",
				"price": 0,
				"sold_out": false
			}
		],
		"refresh_cost": 120,
		"remove_cost": 40,
		"removable_cards": [{"copy_id": 7, "text": "同名卡"}, {"copy_id": 8, "text": "同名卡"}]
	}
	panel.render(state, data)
	var options = panel.get_node("Margin/Content/OptionsScroll/Options")
	await _check_layout_sizes(panel, ["Margin/Content/OptionsScroll", "Margin/Content/ShopActions"])
	expect(
		(
			not options.get_child(0).disabled
			and options.get_child(1).disabled
			and options.get_child(2).disabled
		),
		"Shop distinguishes purchasable, sold-out and empty positions"
	)
	expect(
		panel.get_node("Margin/Content/ShopActions/Refresh").disabled,
		"Unaffordable refresh is disabled"
	)
	panel.get_node("Margin/Content/ShopActions/Remove").pressed.emit()
	panel.get_node("Picker/Content/Scroll/Cards").get_child(1).pressed.emit()
	expect(
		panel.get_node("Picker/Content/Preview").text.contains("40"),
		"Delete confirmation shows current price"
	)
	panel.get_node("Picker").get_ok_button().pressed.emit()
	expect(
		calls.back() == ["shop_remove", "", 8, 21, ""],
		"Delete identifies a single copy among duplicates"
	)
	state.phase = Types.RunPhase.EVENT
	state.token = 22
	state.event = {
		"title": "事件",
		"body": "情境",
		"options":
		[
			{
				"id": "cost_hp",
				"text": "生命换金币",
				"details": "失去6点生命，获得20金币",
				"enabled": true,
				"error": "",
				"selection": "hero",
				"choices": [{"id": "warden", "text": "守卫", "details": "剩余生命 74/80"}]
			}
		]
	}
	panel.render(state, data)
	await _check_layout_sizes(panel, ["Margin/Content/Body", "Margin/Content/OptionsScroll"])
	options.get_child(0).pressed.emit()
	expect(
		panel.get_node("Picker").get_ok_button().disabled,
		"Life-cost events require an eligible selected hero"
	)
	panel.get_node("Picker/Content/Scroll/Cards").get_child(0).pressed.emit()
	expect(
		panel.get_node("Picker/Content/Preview").text.contains("74/80"),
		"Event confirmation shows the actual selected hero result"
	)
	var count_before := calls.size()
	panel.get_node("Picker").get_cancel_button().pressed.emit()
	expect(calls.size() == count_before, "Cancelling event selection submits nothing")
	options.get_child(0).pressed.emit()
	panel.get_node("Picker/Content/Scroll/Cards").get_child(0).pressed.emit()
	panel.get_node("Picker").get_ok_button().pressed.emit()
	expect(
		calls.back() == ["choose_event_option", "cost_hp", -1, 22, "warden"],
		"Event submits its selected target explicitly"
	)
	state.token = 23
	state.persistence_error = "save_write_failed"
	panel.render(state, data)
	options.get_child(0).pressed.emit()
	expect(
		not panel.get_node("Picker").visible,
		"Save-blocked event controls cannot open a mutation confirmation"
	)
	panel.queue_free()
	await process_frame


func _test_reward_sections() -> void:
	var reward = RewardScene.instantiate()
	reward.theme = app.theme
	root.add_child(reward)
	_apply_node_margins(reward)
	var calls: Array = []
	reward.claimed.connect(func(id: String, token: int) -> void: calls.append(["card", id, token]))
	reward.relic_claimed.connect(
		func(id: String, token: int) -> void: calls.append(["relic", id, token])
	)
	var relic_id: String = data.rows("relics")[0].id
	var choices := {
		"cards": ["slash"],
		"relics": [relic_id],
		"cards_done": false,
		"relics_done": false,
		"gold_granted": 40
	}
	reward.render_rewards(data, choices, 30)
	await _check_layout_sizes(
		reward,
		[
			"Margin/Content/Cards",
			"Margin/Content/Relics",
			"Margin/Content/Skip",
			"Margin/Content/SkipRelic"
		]
	)
	var old: Button = reward.get_node("Margin/Content/Cards").get_child(0)
	old.pressed.emit()
	old.pressed.emit()
	expect(calls == [["card", "slash", 30]])
	choices.cards_done = true
	reward.render_rewards(data, choices, 31)
	old.pressed.emit()
	expect(
		calls.size() == 1 and reward.get_node("Margin/Content/Skip").disabled,
		"Processed card reward cannot be claimed again after redraw"
	)
	var relic: Button = reward.get_node("Margin/Content/Relics").get_child(0)
	relic.pressed.emit()
	relic.pressed.emit()
	expect(
		calls.back() == ["relic", relic_id, 31] and calls.size() == 2,
		"Relic reward is independent and also single-submit"
	)
	reward.queue_free()
	await process_frame


func _apply_node_margins(control: Control) -> void:
	# Match the actual Main scene's usable area below navigation.
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	control.offset_left = 48.0
	control.offset_top = 75.0
	control.offset_right = -48.0
	control.offset_bottom = -35.0


func _set_logical_size(value: Vector2i) -> void:
	root.content_scale_size = value
	root.size = value
	await process_frame
	await process_frame
	expect(
		root.get_visible_rect().size == Vector2(value),
		"Layout coverage actually changes the logical viewport to %s" % value
	)


func _check_layout_sizes(control: Control, paths: Array, extras: Array = []) -> void:
	for value in [Vector2i(1280, 800), Vector2i(1440, 900)]:
		await _set_logical_size(value)
		var bounds: Rect2 = root.get_visible_rect().grow(1)
		expect(
			bounds.encloses(control.get_global_rect()), "Chapter surface stays inside the viewport"
		)
		for path in paths:
			var child: Control = control.get_node(path)
			expect(
				child.is_visible_in_tree() and bounds.encloses(child.get_global_rect()),
				"Chapter control fits at %s: %s" % [value, path]
			)
		for child in extras:
			expect(
				bounds.encloses(child.get_global_rect()), "Generated map node fits at %s" % value
			)
