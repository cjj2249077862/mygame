extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Models = preload("res://scripts/core/models.gd")
const Types = preload("res://scripts/core/enums.gd")


func run_tests() -> void:
	var data := Data.new()
	expect(data.load_directory(), str(data.errors))
	var run := Run.new(data)
	expect(not run.start(42, ["warden", "warden", "mender"]))
	expect(run.start(42))
	expect(run.deck.size() == 15 and run.battle.state.hand.size() == 5)
	var initial: Dictionary = run.battle.snapshot()
	expect(run.start(42))
	expect(run.battle.snapshot() == initial, "Identical seed reproduces opening")
	run.battle.find_unit("mender").hp = 0
	run.battle.handle_death(run.battle.find_unit("mender"))
	run.battle.find_unit("blade").hp = 7
	_win(run)
	expect(run.phase == Types.RunPhase.REWARD)
	expect(run.party[2].hp == 12 and run.party[1].hp == 7)
	var candidates: Array = run.reward_candidates.duplicate()
	var token: int = run.reward_token
	var random_state: int = run.rng.state
	expect(run.reward_candidates == candidates and run.rng.state == random_state)
	expect(not run.claim_reward("not_a_candidate", token))
	expect(run.claim_reward(candidates[0], token))
	expect(run.deck.size() == 16 and run.stage_index == 1 and run.gold == 15)
	expect(not run.claim_reward(candidates[0], token))
	expect(not run.skip_reward(token))
	_win(run)
	var deck_before: Array = run.deck.duplicate(true)
	token = run.reward_token
	expect(run.skip_reward(token))
	expect(run.deck == deck_before and run.stage_index == 2 and run.gold == 35)
	expect(not run.skip_reward(token))
	_win(run)
	expect(run.phase == Types.RunPhase.WON and run.reward_candidates.is_empty())
	expect(run.start(44))
	for hero in run.battle.state.heroes:
		hero.hp = 1
		hero.statuses = {"poison": [{"source": "enemy_0", "stacks": 100, "multiplier": 1}]}
	run.battle.end_turn()
	expect(run.phase == Types.RunPhase.LOST)
	expect(run.start(45))
	expect(run.deck.size() == 15 and run.gold == 0 and run.stage_index == 0)
	_test_character_extension(data)


func _win(run: RefCounted) -> void:
	var battle: RefCounted = run.battle
	for enemy in battle.state.enemies:
		if enemy.hp <= 0:
			continue
		enemy.hp = 1
		battle.state.energy = 10
		battle.state.hand = [Models.card(9000, "slash")]
		expect(battle.play_card(9000, "warden", enemy.id) == "")


func _test_character_extension(data: RefCounted) -> void:
	var original: Dictionary = data.books.duplicate(true)
	var hero: Dictionary = data.definition("characters", "warden")
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
		"New character must validate without a new script: " + str(data.errors)
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
		battle.find_unit("warden").shield == 0, "First tank must not receive second tank's shield"
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
