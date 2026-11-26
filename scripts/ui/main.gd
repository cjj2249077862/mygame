extends Control

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Types = preload("res://scripts/core/enums.gd")
@export var save_directory := "user://raiddeck"
@export var chapter_map_preferred_size: Vector2i
@export var chapter_map_viewport_margin: Vector2i
@export var inspect_preferred_size: Vector2i
var data := Data.new()
var run: RefCounted
var _showing_menu := true
var _pending_menu_action := ""


func _ready() -> void:
	if not data.load_directory():
		$Menu/Content/Title.text = "配置加载失败"
		$Menu/Content/Subtitle.text = "\n".join(data.errors)
		$Menu/Content/Start.disabled = true
		return
	get_tree().auto_accept_quit = false
	run = Run.new(data, save_directory)
	run.changed.connect(_on_run_changed)
	run.battle_created.connect(_on_battle_created)
	$Battle.presentation_finished.connect(_on_run_changed)
	$Reward.claimed.connect(_on_claimed)
	$Reward.skipped.connect(_on_skipped)
	$Reward.relic_claimed.connect(_on_relic_claimed)
	$Reward.relic_skipped.connect(_on_relic_skipped)
	$Map.node_chosen.connect(_on_node_chosen)
	$NodePanel.action_requested.connect(_on_node_action)
	$Menu/Content/Start.pressed.connect(_on_start)
	$Menu/Content/Continue.pressed.connect(_on_continue)
	$Menu/Content/Quit.pressed.connect(_on_quit)
	$Result/Content/Restart.pressed.connect(_on_start)
	$Result/Content/Menu.pressed.connect(_on_return_menu)
	$Navigation/Actions/Menu.pressed.connect(_on_return_menu)
	$Navigation/Actions/Abandon.pressed.connect(_on_abandon)
	$Navigation/Actions/Inspect.pressed.connect(_on_inspect)
	$Navigation/Actions/Map.pressed.connect(_on_chapter_map_pressed)
	$Navigation/Actions/EventResult.pressed.connect(_on_event_result_pressed)
	$Confirm.confirmed.connect(_on_menu_confirmed)
	$Confirm.canceled.connect(_clear_menu_confirmation)
	$SaveProblem/Content/Retry.pressed.connect(_on_retry_save)
	$SaveProblem/Content/NewRun.pressed.connect(_on_start)
	$Menu/Content/Title.text = data.text("ui.chapter_title")
	$Menu/Content/Subtitle.text = data.text("ui.chapter_subtitle")
	$Menu/Content/Start.text = data.text("ui.start")
	$Menu/Content/Continue.text = data.text("ui.continue_run")
	$Menu/Content/Quit.text = data.text("ui.exit")
	$Result/Content/Restart.text = data.text("ui.restart")
	$Result/Content/Menu.text = data.text("ui.return_menu")
	$Navigation/Actions/Menu.text = data.text("ui.return_menu")
	$Navigation/Actions/Abandon.text = data.text("ui.abandon")
	$Navigation/Actions/Inspect.text = data.text("ui.inspect")
	$Navigation/Actions/Map.text = data.text("ui.chapter_map")
	$Confirm.ok_button_text = data.text("ui.confirm")
	$Confirm.cancel_button_text = data.text("ui.cancel")
	$Inspect.ok_button_text = data.text("ui.close")
	$Message.ok_button_text = data.text("ui.close")
	$ChapterMap.title = data.text("ui.chapter_map")
	$ChapterMap.ok_button_text = data.text("ui.close")
	resized.connect(_on_main_resized)
	$SaveProblem/Content/Retry.text = data.text("ui.retry_save")
	$SaveProblem/Content/NewRun.text = data.text("ui.discard_bad_run")
	_on_run_changed()


func _on_start() -> void:
	if run.has_saved_run():
		_pending_menu_action = "new_run"
		$Confirm.dialog_text = data.text("ui.replace_run_confirm")
		$Confirm.popup_centered()
	else:
		_start_new_run()


func _start_new_run() -> void:
	_dismiss_dialogs()
	_showing_menu = false
	var started: bool = run.start(int(Time.get_unix_time_from_system()))
	if not started:
		_showing_menu = true
		_show_error(str(run.view_snapshot().get("error", "error.config")))
	_on_run_changed()
	if started:
		_on_chapter_map_pressed()


func _on_continue() -> void:
	_dismiss_dialogs()
	_showing_menu = false
	if not run.continue_run():
		_showing_menu = true
		_show_error(str(run.view_snapshot().get("error", "ui.continue_failed")))
	elif run.view_snapshot().get("recovery_notice", false):
		_show_error("ui.recovered_backup")
	_on_run_changed()


func _on_return_menu() -> void:
	if not run.return_to_menu():
		_on_run_changed()
		return
	_showing_menu = true
	$Battle.leave_battle()
	_dismiss_dialogs()
	_on_run_changed()


func _on_abandon() -> void:
	_pending_menu_action = "abandon"
	$Confirm.dialog_text = data.text("ui.abandon_confirm")
	$Confirm.popup_centered()


func _on_menu_confirmed() -> void:
	var action := _pending_menu_action
	_clear_menu_confirmation()
	if action not in ["new_run", "abandon"]:
		return
	var error: String = run.abandon_run()
	if error != "":
		_show_error(error)
		_on_run_changed()
		return
	if action == "new_run":
		_start_new_run()
	else:
		_showing_menu = false
		$Battle.leave_battle()
		_on_run_changed()


func _clear_menu_confirmation() -> void:
	_pending_menu_action = ""


func _on_quit() -> void:
	if run != null and not run.return_to_menu():
		_on_run_changed()
		return
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_quit()


func _on_battle_created(engine: RefCounted) -> void:
	_showing_menu = false
	_dismiss_dialogs()
	$Battle.bind_battle(engine, data, run.deck)
	$Battle.gold = run.gold
	$Battle.show()
	$Reward.hide()
	$Map.hide()
	$NodePanel.hide()
	$Result.hide()
	$Menu.hide()


func _on_run_changed() -> void:
	if run == null:
		return
	var state: Dictionary = run.view_snapshot()
	var blocked: bool = state.get("persistence_error", "") != ""
	$SaveProblem.visible = blocked
	$SaveProblem/Content/NewRun.visible = state.get("can_discard_saved_run", false)
	$SaveProblem/Content/Message.text = data.text(
		"ui.save_failed", {"reason": data.text("save." + str(state.get("persistence_error", "")))}
	)
	$Menu/Content/Continue.disabled = not run.has_saved_run() or blocked
	$Menu/Content/Start.disabled = blocked
	$Result/Content/Restart.disabled = blocked
	$Result/Content/Menu.disabled = blocked
	$Navigation/Actions/Abandon.disabled = blocked
	var receipt: Dictionary = state.get("event_result", {})
	$Navigation/Actions/EventResult.visible = (
		state.phase == Types.RunPhase.MAP and not receipt.is_empty()
	)
	$Navigation/Actions/EventResult.text = str(receipt.get("title", ""))
	$Navigation/Actions/EventResult.tooltip_text = str(receipt.get("details", ""))
	$Battle.set_external_blocked(blocked)
	$Navigation.visible = (
		not _showing_menu
		and (
			state.phase
			not in [
				Types.RunPhase.IDLE,
				Types.RunPhase.WON,
				Types.RunPhase.LOST,
				Types.RunPhase.ABANDONED
			]
		)
	)
	$Navigation/Actions/Status.text = data.text(
		"ui.run_header", {"depth": state.depth, "gold": state.gold}
	)
	if $ChapterMap.visible:
		if _showing_menu or state.phase not in Run.ACTIVE_PHASES:
			$ChapterMap.hide()
		else:
			_render_chapter_map(state)
	if $Battle.locked and not _showing_menu:
		return
	$Menu.visible = _showing_menu
	$Battle.visible = not _showing_menu and state.phase == Types.RunPhase.BATTLE
	$Reward.visible = not _showing_menu and state.phase == Types.RunPhase.REWARD
	$Map.visible = not _showing_menu and state.phase == Types.RunPhase.MAP
	$NodePanel.visible = (
		not _showing_menu
		and state.phase in [Types.RunPhase.CAMP, Types.RunPhase.SHOP, Types.RunPhase.EVENT]
	)
	$Result.visible = (
		not _showing_menu
		and state.phase in [Types.RunPhase.WON, Types.RunPhase.LOST, Types.RunPhase.ABANDONED]
	)
	if not $Battle.visible:
		$Battle.leave_battle()
	else:
		$Battle.gold = state.gold
		$Battle.refresh()
	if $Map.visible:
		$Map.render(state, data)
	if $NodePanel.visible:
		$NodePanel.render(state, data)
	else:
		$NodePanel.deactivate()
	if $Reward.visible:
		$Reward.render_rewards(data, state.rewards, int(state.token), blocked)
	if $Result.visible:
		_render_result(state.result, state.phase)


func _render_result(result: Dictionary, phase: int) -> void:
	var key := (
		"ui.result_trial"
		if phase == Types.RunPhase.WON
		else ("ui.result_abandoned" if phase == Types.RunPhase.ABANDONED else "ui.loss")
	)
	$Result/Content/Title.text = data.text(key)
	var names: Array[String] = []
	for hero in result.party:
		names.append(data.text(hero.name_key))
	var seconds := int(result.elapsed_seconds)
	$Result/Content/Hint.text = data.text(
		"ui.result_details",
		{
			"difficulty": result.difficulty,
			"depth": result.depth,
			"elapsed": "%02d:%02d" % [seconds / 60, seconds % 60],
			"party": " / ".join(names)
		}
	)
	$Result/Content/Build.text = _build_text(result.deck, result.relics)


func _on_inspect() -> void:
	var state: Dictionary = run.view_snapshot()
	$Inspect.title = data.text("ui.inspect")
	$Inspect/Text.text = _build_text(state.deck, state.relics)
	_popup_sized($Inspect, inspect_preferred_size)


func _on_event_result_pressed() -> void:
	var receipt: Dictionary = run.view_snapshot().get("event_result", {})
	if _showing_menu or run.phase != Types.RunPhase.MAP or receipt.is_empty():
		return
	$Inspect.title = str(receipt.title)
	$Inspect/Text.text = str(receipt.details)
	_popup_sized($Inspect, inspect_preferred_size)


func _on_chapter_map_pressed() -> void:
	if run == null or _showing_menu or run.phase not in Run.ACTIVE_PHASES:
		return
	var state: Dictionary = run.view_snapshot()
	if state.map.is_empty():
		return
	_render_chapter_map(state)
	_fit_chapter_map()


func _render_chapter_map(state: Dictionary) -> void:
	# Keep the current node active; this copy reveals no hidden encounter IDs.
	var overview := state.duplicate(true)
	for node in overview.map.nodes:
		node.available = false
	$ChapterMap/Map.render(overview, data)
	$ChapterMap/Map/Margin/Content/Hint.text = data.text("ui.map_readonly_hint")


func _on_main_resized() -> void:
	if $ChapterMap.visible:
		_fit_chapter_map()
	if $Inspect.visible:
		_popup_sized($Inspect, inspect_preferred_size)


func _fit_chapter_map() -> void:
	_popup_sized($ChapterMap, chapter_map_preferred_size)


func _popup_sized(dialog: Window, preferred_size: Vector2i) -> void:
	var available: Vector2i = Vector2i(get_viewport_rect().size) - chapter_map_viewport_margin
	var window_size := Vector2i(
		mini(preferred_size.x, available.x), mini(preferred_size.y, available.y)
	)
	# AcceptDialog resets to its content minimum during popup. Apply the scene's
	# desired size afterward and preserve the popup's parent/screen centre.
	dialog.popup_centered()
	var center: Vector2i = dialog.position + dialog.size / 2
	dialog.size = window_size
	dialog.position = center - dialog.size / 2


func _build_text(deck: Array, relics: Array) -> String:
	var lines: Array[String] = [data.text("ui.pile.deck")]
	for copy in deck:
		lines.append(data.card_details(copy))
	lines.append("\n" + data.text("ui.relics"))
	for id in relics:
		lines.append(data.relic_text(id))
	return "\n\n".join(lines)


func _on_node_chosen(node_id: String, token: int) -> void:
	_finish_action(run.choose_node(node_id, token))


func _on_node_action(
	action: String, item_id: String, copy_id: int, token: int, selection_id: String = ""
) -> void:
	var error := "error.phase"
	match action:
		"camp_rest":
			error = run.camp_rest(token)
		"camp_upgrade":
			error = run.camp_upgrade(copy_id, token)
		"shop_buy":
			error = run.shop_buy(item_id, token)
		"shop_refresh":
			error = run.shop_refresh(token)
		"shop_remove":
			error = run.shop_remove(copy_id, token)
		"leave_shop":
			error = run.leave_shop(token)
		"choose_event_option":
			error = run.choose_event_option(item_id, token, selection_id)
	_finish_action(error)
	if action == "choose_event_option" and error == "" and run.persistence_error == "":
		_on_event_result_pressed()


func _finish_action(error: String) -> void:
	_on_run_changed()
	if error != "":
		_show_error(error)


func _on_claimed(card_id: String, token: int) -> void:
	_finish_action("" if run.claim_reward(card_id, token) else "ui.action_rejected")


func _on_skipped(token: int) -> void:
	_finish_action("" if run.skip_reward(token) else "ui.action_rejected")


func _on_relic_claimed(relic_id: String, token: int) -> void:
	_finish_action("" if run.claim_relic(relic_id, token) else "ui.action_rejected")


func _on_relic_skipped(token: int) -> void:
	_finish_action("" if run.skip_relic(token) else "ui.action_rejected")


func _on_retry_save() -> void:
	if run.retry_save():
		_showing_menu = run.phase == Types.RunPhase.IDLE
		if run.phase == Types.RunPhase.BATTLE and run.battle != null:
			# A retry may have recovered a previously unreadable battle checkpoint.
			_on_battle_created(run.battle)
		if run.view_snapshot().get("recovery_notice", false):
			_show_error("ui.recovered_backup")
	_on_run_changed()


func _show_error(error: String) -> void:
	$Message.dialog_text = data.text(error if error != "" else "ui.action_rejected")
	$Message.popup_centered()


func _dismiss_dialogs() -> void:
	$Confirm.hide()
	$Inspect.hide()
	$Message.hide()
	$ChapterMap.hide()
	_clear_menu_confirmation()
	$NodePanel.deactivate()
