extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Types = preload("res://scripts/core/enums.gd")


func run_tests() -> void:
	var data := Data.new()
	if not expect(data.load_directory(), str(data.errors)):
		return
	_test_idle_load_error_exit(data)
	var run := Run.new(data)
	expect(not run.start(42, ["warden", "warden", "mender"]))
	expect(run.start(42))
	expect(run.deck.size() == 15 and run.battle.state.hand.size() == 5)
	var initial: Dictionary = run.battle.snapshot()
	expect(not run.start(42), "An active adventure cannot be silently replaced")
	expect(run.battle.snapshot() == initial, "Rejected replacement preserves combat")
	expect(run.abandon_run() == "")
	expect(run.start(42))
	expect(run.battle.snapshot() == initial, "Identical seed reproduces the map and opening")
	run.battle.find_unit("mender").hp = 0
	run.battle.handle_death(run.battle.find_unit("mender"))
	run.battle.find_unit("blade").hp = 7
	_win(run)
	expect(run.phase == Types.RunPhase.REWARD)
	expect(
		run.party[2].hp == 12 and run.party[1].hp == 7,
		"Only fallen allies receive post-battle revival"
	)
	var candidates: Array = run.reward_candidates.duplicate()
	var token: int = run.action_token
	var random_state: int = run.rng.state
	run.view_snapshot()
	run.view_snapshot()
	expect(
		run.reward_candidates == candidates and run.rng.state == random_state,
		"Repeated view snapshots preserve generated rewards"
	)
	expect(not run.claim_reward("not_a_candidate", token))
	expect(run.claim_reward(candidates[0], token))
	expect(
		(
			run.deck.size() == 16
			and run.phase == Types.RunPhase.MAP
			and run.stage_index == 0
			and run.gold == 15
		)
	)
	expect(not run.claim_reward(candidates[0], token))
	expect(not run.skip_reward(token))
	if not _advance_to_battle(run):
		return
	var reward_gold_before: int = run.gold
	var encounter: Dictionary = data.definition("encounters", run.battle.state.encounter_id)
	_win(run)
	expect(
		run.gold == reward_gold_before + int(encounter.gold),
		"Each encountered battle grants its configured gold once"
	)
	var deck_before: Array = run.deck.duplicate(true)
	token = run.action_token
	expect(run.skip_reward(token))
	expect(run.deck == deck_before, "Skipping a card preserves the master deck")
	expect(not run.skip_reward(token))
	_skip_rewards(run)
	for step in range(10):
		if run.phase == Types.RunPhase.WON:
			break
		if not _advance_to_battle(run):
			break
		_win(run)
		_skip_rewards(run)
	expect(
		run.phase == Types.RunPhase.WON and run.visited.size() == 10,
		"Complete ten connected nodes before finishing the trial"
	)
	expect(
		run.reward_candidates.is_empty() and run.relic_candidates.is_empty(),
		"All final reward parts are settled"
	)
	expect(
		run.result.outcome == "chapter_complete",
		"The trial does not count as full three-chapter completion"
	)
	expect(run.start(44))
	for hero in run.battle.state.heroes:
		hero.hp = 1
		hero.statuses = {"poison": [{"source": "enemy_0", "stacks": 100, "multiplier": 1}]}
	expect(run.battle.end_turn() == "")
	expect(run.phase == Types.RunPhase.LOST)
	expect(run.start(45))
	expect(run.deck.size() == 15 and run.gold == 0 and run.stage_index == 0)
	_test_character_extension(data)


func _test_idle_load_error_exit(data: RefCounted) -> void:
	var directory := "user://phase2_meta_exit_%d" % Time.get_ticks_usec()
	var original := Run.new(data, directory)
	if not expect(original.start(420) and original.return_to_menu()):
		return
	var meta_path: String = directory.path_join("meta.json")
	var run_path: String = directory.path_join("run.json")
	var valid_meta: String = FileAccess.get_file_as_string(meta_path)
	var active_run: String = FileAccess.get_file_as_string(run_path)
	var active_backup: String = FileAccess.get_file_as_string(run_path + ".bak")
	for path in [meta_path, meta_path + ".bak"]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		if not expect(file != null):
			return
		file.store_string("unreadable meta fixture")
		file.close()
	var loaded := Run.new(data, directory)
	expect(loaded.phase == Types.RunPhase.IDLE and loaded.persistence_error != "")
	var before: Dictionary = loaded.snapshot()
	for attempt in range(2):
		expect(loaded.return_to_menu(), "Idle read failures do not trap Quit or window close")
		expect(loaded.snapshot() == before and loaded.persistence_error != "")
		expect(not loaded.start(421) and loaded.abandon_run() == "error.save")
		expect(not loaded.retry_save(), "Retry still reports unreadable permanent records")
		expect(FileAccess.get_file_as_string(meta_path) == "unreadable meta fixture")
		expect(FileAccess.get_file_as_string(meta_path + ".bak") == "unreadable meta fixture")
		expect(FileAccess.get_file_as_string(run_path) == active_run)
		expect(FileAccess.get_file_as_string(run_path + ".bak") == active_backup)
	# Restoring a valid copy externally must still work without replacing the run.
	var repaired := FileAccess.open(meta_path, FileAccess.WRITE)
	if not expect(repaired != null):
		return
	repaired.store_string(valid_meta)
	repaired.close()
	expect(loaded.retry_save() and loaded.persistence_error == "")
	expect(loaded.meta == original.meta and loaded.has_saved_run())
	expect(loaded.continue_run() and loaded.run_id == original.run_id)
	expect(loaded.meta.adventures == 1 and loaded.meta.abandoned == 0)


func _win(run: RefCounted) -> void:
	var battle: RefCounted = run.battle
	for enemy in battle.state.enemies:
		if enemy.hp <= 0:
			continue
		enemy.hp = 1
		battle.state.energy = 10
		var copy_id := _put_in_hand(battle, "slash")
		if copy_id < 0:
			return
		expect(battle.play_card(copy_id, "warden", enemy.id) == "")


func _skip_rewards(run: RefCounted) -> void:
	if run.phase == Types.RunPhase.REWARD and not run.reward_cards_done:
		expect(run.skip_reward(run.action_token))
	if run.phase == Types.RunPhase.REWARD and not run.reward_relics_done:
		expect(run.skip_relic(run.action_token))


func _advance_to_battle(run: RefCounted) -> bool:
	for step in range(30):
		match run.phase:
			Types.RunPhase.BATTLE:
				return true
			Types.RunPhase.WON:
				return false
			Types.RunPhase.MAP:
				var next_id := ""
				for node in run.view_snapshot().map.nodes:
					if node.available:
						next_id = str(node.id)
						break
				if not expect(next_id != "", "The map has a reachable next node"):
					return false
				if not expect(run.choose_node(next_id, run.action_token) == ""):
					return false
			Types.RunPhase.CAMP:
				expect(run.camp_rest(run.action_token) == "")
			Types.RunPhase.SHOP:
				expect(run.leave_shop(run.action_token) == "")
			Types.RunPhase.EVENT:
				var leave_id := ""
				for option in run.view_snapshot().event.options:
					if str(option.id).ends_with("_leave"):
						leave_id = str(option.id)
						break
				if not expect(leave_id != "", "Every event offers free departure"):
					return false
				expect(run.choose_event_option(leave_id, run.action_token) == "")
			Types.RunPhase.REWARD:
				_skip_rewards(run)
			_:
				expect(false, "Unexpected phase while traversing the chapter")
				return false
	expect(false, "Chapter navigation must be bounded")
	return false


func _test_character_extension(data: RefCounted) -> void:
	var original: Dictionary = data.books.duplicate(true)
	var hero: Dictionary = data.definition("characters", "warden").duplicate(true)
	hero.id = "fixture_tank"
	hero._source = "test fixture/characters/main"
	data.books.characters.sheets.main.append(hero)
	for definition in [{"card_id": "guard", "count": 2}, {"card_id": "slash", "count": 3}]:
		data.books.characters.sheets.starter.append(
			{
				"id": "fixture_tank." + definition.card_id,
				"character_id": "fixture_tank",
				"card_id": definition.card_id,
				"count": definition.count,
				"_source": "test fixture/characters/starter"
			}
		)
	if not expect(
		data.validate(data.books),
		"New character validates without a new script: " + str(data.errors)
	):
		data.books = original
		return
	var run := Run.new(data)
	if not expect(
		run.start(46, ["warden", "fixture_tank", "mender"]), "Start a valid two-tank party"
	):
		data.books = original
		return
	expect(run.deck.size() == 15, "New character brings its configured starter counts")
	var battle: RefCounted = run.battle
	var guard_id := _put_in_hand(battle, "guard")
	expect(
		battle.legal_casters(guard_id) == ["warden", "fixture_tank"],
		"Both tanks can cast a role card"
	)
	expect(battle.play_card(guard_id, "fixture_tank", "fixture_tank") == "")
	expect(battle.find_unit("fixture_tank").shield == 12, "Second tank owns its shield and passive")
	expect(
		battle.find_unit("warden").shield == 0, "First tank does not receive second tank's shield"
	)
	var slash_id := _put_in_hand(battle, "slash")
	var threat_before: int = battle.find_unit("fixture_tank").threat
	expect(battle.play_card(slash_id, "fixture_tank", "enemy_0") == "")
	expect(
		battle.find_unit("fixture_tank").threat > threat_before,
		"Threat belongs to the actual second tank caster"
	)
	var exclusive_id := _put_in_hand(battle, "shield_bash")
	expect(
		battle.legal_casters(exclusive_id) == ["warden"],
		"Original exclusive card remains owner-bound"
	)
	data.books = original


func _put_in_hand(battle: RefCounted, card_id: String) -> int:
	for pile in ["hand", "draw", "discard"]:
		for copy in battle.state[pile]:
			if copy.card_id == card_id:
				if pile != "hand":
					battle.state[pile].erase(copy)
					battle.state.hand.append(copy)
				return int(copy.copy_id)
	expect(false, "Fixture starter card is missing: " + card_id)
	return -1
