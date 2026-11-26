extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Types = preload("res://scripts/core/enums.gd")
var _sample_count := 32
var _turn_limit := 150
var _base_seed := 261126
var _log_directory := "user://phase_one_simulation"


func run_tests() -> void:
	for argument in OS.get_cmdline_user_args():
		var parts := argument.split("=", true, 1)
		if parts.size() != 2:
			continue
		match parts[0]:
			"--samples":
				_sample_count = int(parts[1])
			"--turn-limit":
				_turn_limit = int(parts[1])
			"--seed":
				_base_seed = int(parts[1])
			"--log-dir":
				_log_directory = parts[1]
	if not expect(_sample_count > 0 and _turn_limit > 0, "Simulation bounds must be positive"):
		return
	var data := Data.new()
	if not expect(data.load_directory(), str(data.errors)):
		return
	for offset in range(_sample_count):
		var seed_value := _base_seed + offset
		print("SIMULATION_SEED %d" % seed_value)
		var first := _simulate(data, seed_value)
		var second := _simulate(data, seed_value)
		expect(first == second, "Replay differs for seed %d" % seed_value)
		if not expect(first.error == "", "Seed %d: %s" % [seed_value, first.error]):
			_save_failure(seed_value, first)
		if first != second:
			_save_failure(
				seed_value, {"error": "replay_mismatch", "first": first, "second": second}
			)
	print(
		(
			"Simulation seeds %d..%d, each executed twice"
			% [_base_seed, _base_seed + _sample_count - 1]
		)
	)


func _simulate(data: RefCounted, seed_value: int) -> Dictionary:
	var run := Run.new(data)
	var policy := RandomNumberGenerator.new()
	policy.seed = seed_value
	var trace: Array = []
	if not run.start(seed_value):
		return {"error": "start_rejected", "trace": trace}
	var operations := 0
	while run.phase in [Types.RunPhase.BATTLE, Types.RunPhase.REWARD]:
		operations += 1
		if operations > _turn_limit * run.encounters.size() * 30:
			return {"error": "operation_limit", "trace": trace}
		var phase_error := _phase_invariant(run)
		if phase_error != "":
			return {"error": phase_error, "trace": trace, "state": run.battle.snapshot()}
		if run.phase == Types.RunPhase.REWARD:
			var token: int = run.reward_token
			var candidates: Array = run.reward_candidates.duplicate()
			var choice := ""
			if not candidates.is_empty() and policy.randi_range(0, 1) == 1:
				choice = candidates[policy.randi_range(0, candidates.size() - 1)]
			var accepted: bool = (
				run.skip_reward(token) if choice == "" else run.claim_reward(choice, token)
			)
			trace.append({"reward": choice, "candidates": candidates})
			if not accepted or run.skip_reward(token):
				return {"error": "reward_token", "trace": trace}
			continue
		var battle: RefCounted = run.battle
		var expected_cards: int = run.deck.size()
		if battle.state.turn > _turn_limit:
			return {"error": "turn_limit", "stage": run.stage_index, "trace": trace}
		var invariant_error := _invariants(battle, expected_cards)
		if invariant_error != "":
			return {"error": invariant_error, "trace": trace, "state": battle.snapshot()}
		var commands := _legal_commands(battle)
		if commands.is_empty():
			if battle.end_turn() != "":
				return {"error": "end_turn_rejected", "trace": trace}
			trace.append({"end_turn": true, "events": battle.events.records.duplicate(true)})
			invariant_error = _invariants(battle, expected_cards)
			if invariant_error != "":
				return {"error": invariant_error, "trace": trace, "state": battle.snapshot()}
			continue
		var command: Dictionary = commands[policy.randi_range(0, commands.size() - 1)]
		var before: Dictionary = battle.snapshot()
		var random_before: int = battle.rng.state
		var preview: Dictionary = battle.preview(
			command.copy, command.caster, command.target, command.status
		)
		if preview.error != "" or before != battle.snapshot() or random_before != battle.rng.state:
			return {"error": "preview_mutation", "command": command, "trace": trace}
		if battle.play_card(command.copy, command.caster, command.target, command.status) != "":
			return {"error": "legal_play_rejected", "command": command, "trace": trace}
		invariant_error = _invariants(battle, expected_cards)
		if invariant_error != "":
			return {"error": invariant_error, "trace": trace, "state": battle.snapshot()}
		if preview.records != battle.events.records or preview.energy != battle.state.energy:
			return {"error": "preview_result_mismatch", "command": command, "trace": trace}
		trace.append({"play": command, "events": battle.events.records.duplicate(true)})
	var terminal_error := _phase_invariant(run)
	if terminal_error != "" or run.phase not in [Types.RunPhase.WON, Types.RunPhase.LOST]:
		return {
			"error": terminal_error if terminal_error != "" else "invalid_terminal_phase",
			"trace": trace,
			"phase": run.phase,
			"state": run.battle.snapshot()
		}
	return {
		"error": "",
		"phase": run.phase,
		"gold": run.gold,
		"deck": run.deck.duplicate(true),
		"party": run.party.duplicate(true),
		"trace": trace
	}


func _phase_invariant(run: RefCounted) -> String:
	var state: Dictionary = run.battle.state
	var heroes_alive: bool = state.heroes.any(func(unit: Dictionary) -> bool: return unit.hp > 0)
	var enemies_alive: bool = state.enemies.any(func(unit: Dictionary) -> bool: return unit.hp > 0)
	match run.phase:
		Types.RunPhase.BATTLE:
			if state.phase != Types.BattlePhase.PLAYER or not heroes_alive or not enemies_alive:
				return "invalid_active_battle"
		Types.RunPhase.REWARD, Types.RunPhase.WON:
			if state.phase != Types.BattlePhase.WON or not heroes_alive or enemies_alive:
				return "invalid_victory"
			if run.phase == Types.RunPhase.REWARD and run.stage_index >= run.encounters.size() - 1:
				return "reward_after_final_battle"
			if run.phase == Types.RunPhase.WON and run.stage_index != run.encounters.size() - 1:
				return "premature_run_victory"
		Types.RunPhase.LOST:
			if state.phase != Types.BattlePhase.LOST or heroes_alive:
				return "invalid_defeat"
		_:
			return "unexpected_run_phase"
	if run.phase != Types.RunPhase.REWARD and not run.reward_candidates.is_empty():
		return "stale_reward_candidates"
	return ""


func _legal_commands(battle: RefCounted) -> Array:
	var commands: Array = []
	for card in battle.state.hand:
		for caster in battle.legal_casters(card.copy_id):
			for target in battle.legal_targets(card.copy_id, caster):
				var options: Array = battle.dispel_options(card.copy_id, target)
				if options.is_empty():
					options = [""]
				for status in options:
					if battle.validate_play(card.copy_id, caster, target, status) == "":
						commands.append(
							{
								"copy": card.copy_id,
								"caster": caster,
								"target": target,
								"status": status
							}
						)
	return commands


func _invariants(battle: RefCounted, expected_cards: int) -> String:
	if battle.state.energy < 0 or battle.state.hand.size() > int(battle.data.rule("hand_limit")):
		return "invalid_resources"
	var ids: Dictionary = {}
	for pile in Types.PILES:
		for card in battle.state[pile]:
			if ids.has(card.copy_id):
				return "duplicate_card_copy"
			ids[card.copy_id] = true
	if ids.size() != expected_cards:
		return "lost_card_copy"
	for unit in battle.state.heroes + battle.state.enemies:
		if unit.hp < 0 or unit.hp > unit.max_hp or unit.shield < 0 or unit.threat < 0:
			return "invalid_unit_resources"
		if unit.hp == 0 and (unit.shield != 0 or unit.threat != 0 or not unit.statuses.is_empty()):
			return "dead_unit_state"
	return ""


func _save_failure(seed_value: int, detail: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(_log_directory)
	var output := FileAccess.open(
		_log_directory.path_join("seed_%d.json" % seed_value), FileAccess.WRITE
	)
	if output == null:
		expect(false, "Cannot write simulation failure log")
		return
	output.store_string(
		JSON.stringify({"seed": seed_value, "turn_limit": _turn_limit, "detail": detail}, "\t")
	)
