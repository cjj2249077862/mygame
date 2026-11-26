extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Store = preload("res://scripts/core/save_manager.gd")
const Map = preload("res://scripts/core/map_generator.gd")
const Types = preload("res://scripts/core/enums.gd")

var data: RefCounted
var directory_root := "user://chapter_flow_%d" % Time.get_ticks_usec()
var directory_index := 0
var terminal_payload: Dictionary = {}
var unfinished_meta: Dictionary = {}
var restored_phases: Array = []


class FailingMetaStore:
	extends "res://scripts/core/save_manager.gd"
	var reject_meta := true

	func _init(path: String) -> void:
		super(path)

	func write_slot(
		slot: String, payload: Dictionary, terminal: bool = false, validator: Callable = Callable()
	) -> bool:
		if reject_meta and slot == "meta":
			last_error = "save_write_failed"
			return false
		return super.write_slot(slot, payload, terminal, validator)


func run_tests() -> void:
	data = Data.new()
	if not expect(data.load_directory(), str(data.errors)):
		return
	_test_shop_and_camp()
	_test_failed_shop_commit()
	_test_event_costs_and_copies()
	_test_event_randomness()
	_test_rewards_and_terminals()
	_test_corruption_and_backup()
	_test_terminal_meta_repair()
	for phase in [
		Types.RunPhase.MAP,
		Types.RunPhase.CAMP,
		Types.RunPhase.SHOP,
		Types.RunPhase.EVENT,
		Types.RunPhase.REWARD,
		Types.RunPhase.WON,
		Types.RunPhase.LOST,
		Types.RunPhase.ABANDONED
	]:
		expect(phase in restored_phases, "Persistence was exercised for phase %d" % phase)


func _test_shop_and_camp() -> void:
	var run := _fixture_run("shop")
	if not _reach(run, "node_02_0"):
		return
	run.gold = 1000
	run = _reload(run)
	var bought_relic := ""
	for kind in ["card", "relic"]:
		var offer: Dictionary = {}
		for item in run.shop.offers:
			if item.kind == kind:
				offer = item.duplicate(true)
				break
		if not expect(not offer.is_empty(), "Shop has a " + kind + " offer"):
			return
		var before_gold: int = run.gold
		var before_count: int = run.deck.size() if kind == "card" else run.relics.size()
		var token: int = run.action_token
		expect(run.shop_buy(offer.id, token) == "", "Buy an available " + kind)
		expect(run.gold == before_gold - offer.price, "Purchase charges the displayed price once")
		expect((run.deck.size() if kind == "card" else run.relics.size()) == before_count + 1)
		var after := _stable(run)
		expect(run.shop_buy(offer.id, token) != "", "Old purchase token is rejected")
		expect(run.shop_buy(offer.id, run.action_token) != "", "Sold item cannot be bought again")
		expect(_stable(run) == after, "Both rejected purchases preserve all persistent state")
		if kind == "relic":
			bought_relic = offer.item_id
	var before_gold: int = run.gold
	var refresh_cost: int = run.view_snapshot().shop.refresh_cost
	var token: int = run.action_token
	expect(run.shop_refresh(token) == "")
	expect(run.gold == before_gold - refresh_cost and run.shop.refresh_count == 1)
	expect(
		run.view_snapshot().shop.refresh_cost == refresh_cost + int(data.economy("refresh_step"))
	)
	var refreshed := _stable(run)
	expect(
		run.shop_refresh(token) != "" and _stable(run) == refreshed,
		"Duplicate refresh cannot spend gold or reroll inventory"
	)
	for offer in run.shop.offers:
		expect(
			offer.kind != "relic" or offer.item_id != bought_relic,
			"Owned relics are removed from the refreshed pool"
		)
	var copies := _copies(run, "guard")
	if not expect(copies.size() >= 2, "Removal fixture has two identical cards"):
		return
	var remove_cost: int = run.view_snapshot().shop.remove_cost
	before_gold = run.gold
	token = run.action_token
	expect(run.shop_remove(copies[0], token) == "")
	expect(
		_copy(run, copies[0]).is_empty() and not _copy(run, copies[1]).is_empty(),
		"Removal changes exactly the selected copy"
	)
	expect(run.gold == before_gold - remove_cost and run.remove_count == 1)
	var removed := _stable(run)
	expect(
		run.shop_remove(copies[1], token) != "" and _stable(run) == removed,
		"Old deletion token cannot remove another copy"
	)
	run = _reload(run)
	if not _reach(run, "node_03_0"):
		return
	run = _reload(run)
	copies = _copies(run, "slash")
	if not expect(copies.size() >= 2, "Upgrade fixture has two identical cards"):
		return
	token = run.action_token
	expect(run.camp_upgrade(copies[0], token) == "")
	expect(
		_copy(run, copies[0]).upgraded and not _copy(run, copies[1]).upgraded,
		"Camp upgrades only the selected permanent copy"
	)
	var upgraded := _stable(run)
	expect(
		run.camp_rest(token) != "" and _stable(run) == upgraded,
		"A camp offers one action even when its old token is reused"
	)
	run = _reload(run)
	if not _reach(run, "node_05_0"):
		return
	expect(run.shop.refresh_count == 0, "A new shop resets its own refresh count")
	expect(run.view_snapshot().shop.refresh_cost == int(data.economy("refresh_base")))
	expect(
		(
			run.remove_count == 1
			and (
				run.view_snapshot().shop.remove_cost
				== int(data.economy("remove_base") + data.economy("remove_step"))
			)
		),
		"Removal price grows across shops in the same adventure"
	)
	var saved := _stable(run, true)
	expect(run.return_to_menu(), "Returning to menu saves the active shop")
	expect(run.phase == Types.RunPhase.IDLE and run.has_saved_run())
	var continued := Run.new(data, run.saves.directory)
	expect(continued.continue_run())
	expect(
		_stable(continued, true) == saved,
		"The menu cannot overwrite the saved shop with an idle snapshot"
	)
	# A one-card fixture verifies the approved absence of a minimum deck size.
	continued.deck = [continued.deck[0]]
	var last_copy: int = continued.deck[0].copy_id
	expect(continued.shop_remove(last_copy, continued.action_token) == "")
	expect(continued.deck.is_empty(), "Deleting the final copy is allowed")
	_reload(continued)


func _test_failed_shop_commit() -> void:
	var run := _fixture_run("failed_shop_commit")
	if not _reach(run, "node_02_0"):
		return
	run.gold = 100
	expect(run._checkpoint())
	var failing := FailingMetaStore.new(run.saves.directory)
	run.saves = failing
	var price: int = run.view_snapshot().shop.refresh_cost
	var token: int = run.action_token
	run.shop_refresh(token)
	expect(
		run.persistence_error != "" and run.gold == 100 - price and run.shop.refresh_count == 1,
		"A failed checkpoint retains the one completed in-memory transaction"
	)
	var after := _stable(run)
	expect(
		run.shop_refresh(run.action_token) != "" and not run.return_to_menu(),
		"Unwritten progress blocks subsequent purchases and leaving the view"
	)
	expect(
		not run.retry_save() and _stable(run) == after,
		"A failed save retry cannot repeat the payment or random draw"
	)
	failing.reject_meta = false
	expect(run.retry_save() and run.persistence_error == "")
	expect(
		_stable(run) == after and run.gold == 100 - price,
		"Successful retry saves the existing result without replaying the action"
	)
	_reload(run)


func _test_event_costs_and_copies() -> void:
	var run := _fixture_run("events")
	if not _reach(run, "node_04_0"):
		return
	run.gold = 24
	run = _reload(run)
	var before := _stable(run)
	expect(not _option(run, "infirmary_treat").enabled)
	expect(run.choose_event_option("infirmary_treat", run.action_token) == "error.gold")
	expect(_stable(run) == before, "Unaffordable treatment spends nothing")
	run.gold = 100
	for hero in run.party:
		hero.hp = hero.max_hp - 2
	var scavenge := _fork(run, "scavenge")
	var token: int = run.action_token
	expect(run.choose_event_option("infirmary_treat", token) == "")
	expect(run.gold == 75, "Treatment charges its configured cost once")
	for hero in run.party:
		expect(hero.hp == hero.max_hp, "Treatment applies actual missing health without overflow")
	before = _stable(run)
	expect(run.choose_event_option("infirmary_treat", token) != "" and _stable(run) == before)
	scavenge.party[0].hp = 6
	before = _stable(scavenge)
	expect(
		scavenge.choose_event_option("infirmary_scavenge", scavenge.action_token, "warden") != ""
	)
	expect(_stable(scavenge) == before, "Life-cost selection cannot reduce a hero to zero")
	scavenge.party[0].hp = 7
	var gold_before: int = scavenge.gold
	expect(
		scavenge.choose_event_option("infirmary_scavenge", scavenge.action_token, "warden") == ""
	)
	expect(
		scavenge.party[0].hp == 1 and scavenge.gold == gold_before + 20,
		"Minimum eligible health pays exactly six HP for twenty gold"
	)
	if not _reach(run, "node_07_0"):
		return
	var copies := _copies(run, "slash")
	if not expect(copies.size() >= 2):
		return
	run.gold = 29
	before = _stable(run)
	expect(
		run.choose_event_option("anvil_reforge", run.action_token, str(copies[0])) == "error.gold"
	)
	expect(_stable(run) == before)
	run.gold = 100
	var salvage := _fork(run, "salvage")
	token = run.action_token
	expect(run.choose_event_option("anvil_reforge", token, str(copies[0])) == "")
	expect(run.gold == 70 and _copy(run, copies[0]).upgraded and not _copy(run, copies[1]).upgraded)
	before = _stable(run)
	expect(
		(
			run.choose_event_option("anvil_reforge", token, str(copies[1])) != ""
			and _stable(run) == before
		)
	)
	expect(salvage.choose_event_option("anvil_salvage", salvage.action_token, str(copies[1])) == "")
	expect(
		(
			salvage.gold == 115
			and _copy(salvage, copies[1]).is_empty()
			and not _copy(salvage, copies[0]).is_empty()
		),
		"Salvage removes the selected duplicate and pays once"
	)


func _test_event_randomness() -> void:
	var run := _fixture_run("cache")
	if not _reach(run, "node_08_0"):
		return
	var generated: Dictionary = run.event_state.duplicate(true)
	var random_state: int = run.rng.state
	var visible: Dictionary = run.view_snapshot().event
	run.view_snapshot()
	expect(
		run.event_state == generated and run.rng.state == random_state,
		"Reading event text does not reroll its stored result"
	)
	expect(
		not visible.has("results") and not visible.has("outcome_id"),
		"The public event view does not reveal its selected branch"
	)
	for option in visible.options:
		expect(not option.has("outcome_id") and not option.has("relics"))
	expect(
		(
			_option(run, "cache_force").details.contains("70")
			and _option(run, "cache_force").details.contains("30")
		),
		"Risky choice shows both branch probabilities"
	)
	run = _reload(run)
	expect(run.event_state == generated and run.rng.state == random_state)
	var identical := _fork(run, "same_cache")
	var leave := _fork(run, "leave_cache")
	var exhausted := _fork(run, "empty_relic_pool")
	var invalid := _fork(run, "cache_health")
	invalid.party[0].hp = 8
	var before := _stable(invalid)
	expect(invalid.choose_event_option("cache_force", invalid.action_token, "warden") != "")
	expect(_stable(invalid) == before, "Risk eligibility accounts for the worst branch")
	expect(run.choose_event_option("cache_force", run.action_token, "warden") == "")
	expect(identical.choose_event_option("cache_force", identical.action_token, "warden") == "")
	expect(
		_stable(run, true) == _stable(identical, true),
		"Reloading the same event produces the same gold, HP, relic and random state"
	)
	var resources := _resources(leave)
	var token: int = leave.action_token
	expect(leave.choose_event_option("cache_leave", token) == "")
	expect(
		leave.phase == Types.RunPhase.MAP and _resources(leave) == resources,
		"The free exit consumes neither money nor health nor cards nor random draws"
	)
	before = _stable(leave)
	expect(leave.choose_event_option("cache_leave", token) != "" and _stable(leave) == before)
	for relic in data.rows("relics"):
		if relic.pool == "normal":
			exhausted.relics.append(relic.id)
	expect(
		(
			not _option(exhausted, "cache_force").enabled
			and not _option(exhausted, "cache_unlock").enabled
		),
		"An empty required relic pool disables the whole risky transaction"
	)
	expect(_option(exhausted, "cache_leave").enabled)
	resources = _resources(exhausted)
	expect(exhausted.choose_event_option("cache_leave", exhausted.action_token) == "")
	expect(_resources(exhausted) == resources)


func _test_rewards_and_terminals() -> void:
	var run := _fixture_run("rewards")
	if not _reach(run, "node_06_1") or not _win(run):
		return
	if not expect(
		(
			run.phase == Types.RunPhase.REWARD
			and not run.reward_candidates.is_empty()
			and not run.relic_candidates.is_empty()
		)
	):
		return
	run = _reload(run)
	var card_id: String = run.reward_candidates[0]
	var token: int = run.action_token
	var deck_count: int = run.deck.size()
	expect(run.claim_reward(card_id, token))
	expect(
		(
			run.phase == Types.RunPhase.REWARD
			and run.reward_cards_done
			and not run.reward_relics_done
			and run.deck.size() == deck_count + 1
		),
		"Elite card selection leaves the separate relic decision open"
	)
	var before := _stable(run)
	expect(
		not run.claim_relic(run.relic_candidates[0], token) and _stable(run) == before,
		"The remaining reward part requires the updated token"
	)
	run = _reload(run)
	before = _stable(run)
	expect(
		not run.claim_reward(card_id, run.action_token) and _stable(run) == before,
		"Reload cannot claim the completed reward part again"
	)
	var relics_before: Array = run.relics.duplicate()
	expect(run.skip_relic(run.action_token))
	expect(run.phase == Types.RunPhase.MAP and run.relics == relics_before)
	if not _reach(run, "node_10_0"):
		return
	var gold_before: int = run.gold
	var encounter: Dictionary = data.definition("encounters", run.battle.state.encounter_id)
	unfinished_meta = run.meta.duplicate(true)
	if not _win(run):
		return
	expect(
		run.phase == Types.RunPhase.REWARD and run.result.is_empty(),
		"Defeating the Boss opens rewards before recording chapter completion"
	)
	expect(run.gold == gold_before + int(encounter.gold))
	if not expect(not run.relic_candidates.is_empty()):
		return
	token = run.action_token
	expect(run.claim_relic(run.relic_candidates[0], token))
	expect(
		run.phase == Types.RunPhase.REWARD and run.reward_relics_done,
		"Boss relic may be chosen before the card"
	)
	before = _stable(run)
	expect(not run.skip_reward(token) and _stable(run) == before)
	run = _reload(run)
	expect(run.skip_reward(run.action_token))
	expect(run.phase == Types.RunPhase.WON and run.visited.size() == 10)
	expect(
		(
			run.result.outcome == "chapter_complete"
			and run.meta.chapter_completions == 1
			and run.meta.full_completions == 0
			and run.meta.highest_difficulty == 1
		),
		"The trial records one chapter, without unlocking a full-run difficulty"
	)
	expect(run.reward_candidates.is_empty() and run.relic_candidates.is_empty())
	terminal_payload = run.snapshot().duplicate(true)
	_reload(run)
	var lost := _fixture_run("loss")
	for hero in lost.battle.state.heroes:
		hero.hp = 1
		hero.statuses = {"poison": [{"source": "enemy_0", "stacks": 100, "multiplier": 1}]}
	expect(lost.battle.end_turn() == "")
	expect(lost.phase == Types.RunPhase.LOST and lost.meta.losses == 1)
	_reload(lost)
	var abandoned := _fixture_run("abandon")
	expect(abandoned.abandon_run() == "")
	expect(abandoned.phase == Types.RunPhase.ABANDONED and abandoned.meta.abandoned == 1)
	_reload(abandoned)


func _test_corruption_and_backup() -> void:
	var directory := _directory("broken")
	_write_raw(directory.path_join("run.json"), "broken primary")
	_write_raw(directory.path_join("run.json.bak"), "broken backup")
	var run := Run.new(data, directory)
	var initial_meta: Dictionary = run.meta.duplicate(true)
	expect(run.has_saved_run() and not run.start(600), "A bad slot cannot be silently replaced")
	expect(not run.continue_run() and run.persistence_error != "")
	for attempt in range(2):
		expect(not run.retry_save(), "Retry of an unreadable slot must reread it")
		expect(FileAccess.get_file_as_string(directory.path_join("run.json")) == "broken primary")
		expect(
			FileAccess.get_file_as_string(directory.path_join("run.json.bak")) == "broken backup"
		)
	expect(run.view_snapshot().can_discard_saved_run)
	expect(run.abandon_run() == "", "Explicit abandonment can retire a corrupt run slot")
	expect(
		run.run_id.begins_with("discarded_") and run.meta == initial_meta,
		"A corrupt-slot tombstone cannot invent an adventure or a result"
	)
	expect(not run.has_saved_run())
	for attempt in range(2):
		run = Run.new(data, directory)
		expect(
			run.meta == initial_meta and not run.has_saved_run(),
			"Restarting does not turn a discarded tombstone into statistics"
		)
	expect(
		run.start(601) and run.meta.adventures == 1,
		"Only the subsequent real new run increments adventures"
	)
	var backup := _fixture_run("backup")
	if not _reach(backup, "node_02_0"):
		return
	# Two identical checkpoints make both revisions valid versions of this shop.
	expect(backup._checkpoint() and backup._checkpoint())
	var saved := _stable(backup, true)
	_write_raw(backup.saves.directory.path_join("run.json"), "interrupted primary")
	var recovered := Run.new(data, backup.saves.directory)
	expect(
		recovered.continue_run() and recovered.recovery_notice,
		"A valid backup recovers an invalid primary"
	)
	expect(
		_stable(recovered, true) == saved, "Backup preserves offers and RNG without regeneration"
	)
	# Exercise corrupt-slot abandonment on an object that still has an old run in memory.
	expect(recovered.return_to_menu())
	_write_raw(recovered.saves.directory.path_join("run.json"), "late primary corruption")
	_write_raw(recovered.saves.directory.path_join("run.json.bak"), "late backup corruption")
	initial_meta = recovered.meta.duplicate(true)
	expect(not recovered.continue_run())
	expect(recovered.abandon_run() == "")
	expect(
		(
			recovered.party.is_empty()
			and recovered.deck.is_empty()
			and recovered.chapter_map.is_empty()
			and recovered.meta == initial_meta
		),
		"Discard clears stale in-memory run fields without fabricating a loss"
	)
	expect(not Run.new(data, recovered.saves.directory).has_saved_run())


func _test_terminal_meta_repair() -> void:
	if not expect(
		not terminal_payload.is_empty(), "A real completed run supplies the crash fixture"
	):
		return
	var directory := _directory("terminal_gap")
	var store := Store.new(directory)
	expect(store.write_slot("run", terminal_payload, true))
	expect(store.write_slot("meta", unfinished_meta))
	var repaired := Run.new(data, directory)
	expect(
		(
			repaired.meta.adventures == unfinished_meta.adventures
			and repaired.meta.chapter_completions == unfinished_meta.chapter_completions + 1
		),
		"Startup repairs the crash between terminal-run and metadata writes"
	)
	expect(repaired.meta.finished_ids.count(terminal_payload.run_id) == 1)
	var repaired_meta: Dictionary = repaired.meta.duplicate(true)
	expect(Run.new(data, directory).meta == repaired_meta, "Terminal repair is idempotent")
	expect(not repaired.has_saved_run())
	directory = _directory("terminal_retry")
	store = Store.new(directory)
	expect(store.write_slot("run", terminal_payload, true))
	expect(store.write_slot("meta", unfinished_meta))
	var terminal_file := FileAccess.get_file_as_string(directory.path_join("run.json"))
	# Inject only an I/O failure; run and meta payloads came from public real flow.
	var failing := FailingMetaStore.new(directory)
	var blocked := Run.new(data)
	blocked.saves = failing
	blocked.meta = unfinished_meta.duplicate(true)
	blocked._reconcile_terminal_record()
	expect(
		blocked.persistence_error != "" and not blocked.start(602),
		"Unwritten terminal statistics prevent a new adventure from replacing recovery state"
	)
	failing.reject_meta = false
	expect(blocked.retry_save() and blocked.persistence_error == "")
	expect(
		FileAccess.get_file_as_string(directory.path_join("run.json")) == terminal_file,
		"Metadata retry cannot overwrite the terminal run with an idle snapshot"
	)
	expect(
		Run.new(data, directory).meta == repaired_meta,
		"A failed then retried repair records the same result exactly once"
	)


func _directory(label: String) -> String:
	directory_index += 1
	return directory_root.path_join("%02d_%s" % [directory_index, label])


func _fixture_run(label: String) -> RefCounted:
	var run := Run.new(data, _directory(label))
	if not expect(run.start(410), "Start isolated fixture " + label):
		return run
	# Deterministic, valid connected route separates transaction tests from map sampling.
	# Depth six has an optional elite plus a normal bypass; no source tables are edited.
	var chapter: Dictionary = data.chapter_definition()
	var kinds := [
		"battle", "shop", "camp", "event", "shop", "battle", "event", "event", "camp", "boss"
	]
	var content := [
		chapter.first_encounter_id,
		"",
		"",
		"event_abandoned_infirmary",
		"",
		"outpost_crossfire",
		"event_forgotten_anvil",
		"event_sealed_cache",
		"",
		chapter.boss_encounter_id
	]
	var nodes: Array = []
	for index in range(10):
		nodes.append(
			{
				"id": "node_%02d_0" % (index + 1),
				"depth": index + 1,
				"column": 0,
				"kind": kinds[index],
				"content_id": content[index],
				"next": ["node_%02d_0" % (index + 2)] if index < 9 else []
			}
		)
	nodes[4].next.append("node_06_1")
	nodes.append(
		{
			"id": "node_06_1",
			"depth": 6,
			"column": 1,
			"kind": "elite",
			"content_id": "outpost_trial",
			"next": ["node_07_0"]
		}
	)
	run.chapter_map = {
		"chapter_id": chapter.id,
		"start_id": "node_01_0",
		"boss_encounter_id": chapter.boss_encounter_id,
		"nodes": nodes
	}
	expect(
		Map.validate(run.chapter_map, int(chapter.node_count)),
		"Transaction fixture is a valid chapter map"
	)
	expect(run._valid_snapshot(run.snapshot()), "Fixture keeps the complete save contract")
	expect(run._checkpoint())
	return run


func _reach(run: RefCounted, target: String) -> bool:
	for step in range(50):
		if run.current_node_id == target:
			return true
		match run.phase:
			Types.RunPhase.BATTLE:
				if not _win(run):
					return false
			Types.RunPhase.REWARD:
				if not run.reward_cards_done:
					expect(run.skip_reward(run.action_token))
				if run.phase == Types.RunPhase.REWARD and not run.reward_relics_done:
					expect(run.skip_relic(run.action_token))
			Types.RunPhase.MAP:
				var next_id := "node_%02d_0" % (run.visited.size() + 1)
				if target == "node_06_1" and run.visited.size() == 5:
					next_id = target
				if not expect(run.choose_node(next_id, run.action_token) == "", "Visit " + next_id):
					return false
			Types.RunPhase.CAMP:
				expect(run.camp_rest(run.action_token) == "")
			Types.RunPhase.SHOP:
				expect(run.leave_shop(run.action_token) == "")
			Types.RunPhase.EVENT:
				var leave_id := ""
				for option in run.view_snapshot().event.options:
					if str(option.id).ends_with("_leave"):
						leave_id = option.id
				if not expect(
					leave_id != "" and run.choose_event_option(leave_id, run.action_token) == ""
				):
					return false
			_:
				expect(false, "Unexpected phase while navigating to " + target)
				return false
	expect(false, "Navigation to " + target + " exceeded its bound")
	return false


func _win(run: RefCounted) -> bool:
	if not expect(run.phase == Types.RunPhase.BATTLE and run.battle != null):
		return false
	var battle: RefCounted = run.battle
	# Lower enemy HP only: use real master-deck copies and normal battle completion.
	for enemy in battle.state.enemies:
		if enemy.hp <= 0:
			continue
		enemy.hp = 1
		enemy.shield = 0
		battle.state.energy = 10
		var copy_id := -1
		for pile in ["hand", "draw", "discard"]:
			for copy in battle.state[pile]:
				if copy.card_id == "slash":
					if pile != "hand":
						battle.state[pile].erase(copy)
						battle.state.hand.append(copy)
					copy_id = int(copy.copy_id)
					break
			if copy_id >= 0:
				break
		if not expect(copy_id >= 0 and battle.play_card(copy_id, "warden", enemy.id) == ""):
			return false
	return expect(run.phase == Types.RunPhase.REWARD, "Winning enters reward resolution")


func _stable(run: RefCounted, ignore_token: bool = false) -> Dictionary:
	var value: Dictionary = run.snapshot().duplicate(true)
	value.erase("elapsed_seconds")
	if ignore_token:
		value.erase("action_token")
	return value


func _resources(run: RefCounted) -> Dictionary:
	return {
		"gold": run.gold,
		"party": run.party.duplicate(true),
		"deck": run.deck.duplicate(true),
		"relics": run.relics.duplicate(),
		"random_state": str(run.rng.state)
	}


func _reload(run: RefCounted) -> RefCounted:
	var before := _stable(run, true)
	var meta_before: Dictionary = run.meta.duplicate(true)
	expect(
		run._valid_snapshot(run.snapshot()), "Checkpoint satisfies its phase-specific save contract"
	)
	expect(run._checkpoint(), "Write isolated checkpoint")
	var restored := Run.new(data, run.saves.directory)
	if expect(
		restored.continue_run(), "Reload phase %d: %s" % [run.phase, restored.persistence_error]
	):
		expect(
			_stable(restored, true) == before,
			"Reload preserves all persistent fields except the fresh action token"
		)
		expect(restored.meta == meta_before, "Reload cannot increment statistics twice")
		expect(restored.action_token > run.action_token, "Reload invalidates pre-load UI tokens")
		restored_phases.append(restored.phase)
		return restored
	return run


func _fork(run: RefCounted, label: String) -> RefCounted:
	var directory := _directory(label)
	var store := Store.new(directory)
	expect(run._valid_snapshot(run.snapshot()), "Branch fixture is a valid checkpoint")
	expect(store.write_slot("run", run.snapshot()))
	expect(store.write_slot("meta", run.meta))
	var forked := Run.new(data, directory)
	expect(forked.continue_run(), "Load isolated event branch " + label)
	expect(_stable(forked, true) == _stable(run, true), "Fork keeps event results and random state")
	return forked


func _copies(run: RefCounted, card_id: String) -> Array:
	var result: Array = []
	for copy in run.deck:
		if copy.card_id == card_id:
			result.append(int(copy.copy_id))
	return result


func _copy(run: RefCounted, copy_id: int) -> Dictionary:
	for copy in run.deck:
		if copy.copy_id == copy_id:
			return copy
	return {}


func _option(run: RefCounted, id: String) -> Dictionary:
	for option in run.view_snapshot().event.options:
		if option.id == id:
			return option
	expect(false, "Missing event option " + id)
	return {}


func _write_raw(path: String, contents: String) -> void:
	if not expect(
		path.begins_with(directory_root + "/"), "Corruption fixtures stay in this test's directory"
	):
		return
	expect(DirAccess.make_dir_recursive_absolute(path.get_base_dir()) == OK)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not expect(file != null, "Create isolated corrupt fixture"):
		return
	file.store_string(contents)
	file.close()
