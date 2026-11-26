extends SceneTree

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Models = preload("res://scripts/core/models.gd")
const Types = preload("res://scripts/core/enums.gd")


func _initialize() -> void:
	var data := Data.new()
	assert(data.load_directory(), str(data.errors))
	var run := Run.new(data)
	assert(not run.start(42, ["warden", "warden", "mender"]))
	assert(run.start(42))
	assert(run.deck.size() == 15 and run.battle.state.hand.size() == 5)
	var initial: Dictionary = run.battle.snapshot()
	assert(run.start(42))
	assert(run.battle.snapshot() == initial, "Identical seed reproduces opening")
	run.battle.find_unit("mender").hp = 0
	run.battle.handle_death(run.battle.find_unit("mender"))
	run.battle.find_unit("blade").hp = 7
	_win(run)
	assert(run.phase == Types.RunPhase.REWARD)
	assert(run.party[2].hp == 12 and run.party[1].hp == 7)
	var candidates: Array = run.reward_candidates.duplicate()
	var token: int = run.reward_token
	var random_state: int = run.rng.state
	assert(run.reward_candidates == candidates and run.rng.state == random_state)
	assert(not run.claim_reward("not_a_candidate", token))
	assert(run.claim_reward(candidates[0], token))
	assert(run.deck.size() == 16 and run.stage_index == 1 and run.gold == 15)
	assert(not run.claim_reward(candidates[0], token))
	assert(not run.skip_reward(token))
	_win(run)
	var deck_before: Array = run.deck.duplicate(true)
	token = run.reward_token
	assert(run.skip_reward(token))
	assert(run.deck == deck_before and run.stage_index == 2 and run.gold == 35)
	assert(not run.skip_reward(token))
	_win(run)
	assert(run.phase == Types.RunPhase.WON and run.reward_candidates.is_empty())
	assert(run.start(44))
	for hero in run.battle.state.heroes:
		hero.hp = 1
		hero.statuses = {"poison": [{"source": "enemy_0", "stacks": 100, "multiplier": 1}]}
	run.battle.end_turn()
	assert(run.phase == Types.RunPhase.LOST)
	assert(run.start(45))
	assert(run.deck.size() == 15 and run.gold == 0 and run.stage_index == 0)
	print("test_run_flow: passed")
	quit()


func _win(run: RefCounted) -> void:
	var battle: RefCounted = run.battle
	for enemy in battle.state.enemies:
		if enemy.hp <= 0:
			continue
		enemy.hp = 1
		battle.state.energy = 10
		battle.state.hand = [Models.card(9000, "slash")]
		assert(battle.play_card(9000, "warden", enemy.id) == "")
