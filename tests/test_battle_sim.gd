extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Types = preload("res://scripts/core/enums.gd")
var _sample_count := 32
var _turn_limit := 150
var _base_seed := 261126
var _log_directory := "user://phase_two_simulation"


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
	var outcomes: Dictionary = {"chapter_complete": 0, "lost": 0}
	var nodes_seen: Dictionary = {}
	for offset in range(_sample_count):
		var seed_value := _base_seed + offset
		print("SIMULATION_SEED %d" % seed_value)
		var first := _simulate(data, seed_value)
		var second := _simulate(data, seed_value)
		expect(first == second, "Replay differs for seed %d" % seed_value)
		if not expect(first.error == "", "Seed %d: %s" % [seed_value, first.error]):
			_save_failure(seed_value, first)
		else:
			outcomes[first.outcome] += 1
			for kind in first.nodes_seen:
				nodes_seen[kind] = true
		if first != second:
			_save_failure(
				seed_value, {"error": "replay_mismatch", "first": first, "second": second}
			)
	print(
		(
			"SIMULATION_COVERAGE "
			+ JSON.stringify({"outcomes": outcomes, "node_kinds": nodes_seen.keys()})
		)
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
	var nodes_seen: Dictionary = {}
	var shop_actions: Dictionary = {}
	if not run.start(seed_value):
		return {"error": "start_rejected", "trace": trace}
	var operations := 0
	while run.phase in Run.ACTIVE_PHASES:
		operations += 1
		if operations > _turn_limit * 10 * 30:
			return {"error": "operation_limit", "trace": trace}
		var state_error := _run_invariant(run)
		if state_error != "":
			return {"error": state_error, "trace": trace, "state": run.snapshot()}
		for node in run.chapter_map.nodes:
			if node.id == run.current_node_id:
				nodes_seen[node.kind] = true
		if run.phase != Types.RunPhase.BATTLE:
			var step: Dictionary = _progress_node(run, policy, shop_actions)
			trace.append(step)
			if step.error != "":
				return {"error": step.error, "trace": trace, "state": run.snapshot()}
			continue
		var battle: RefCounted = run.battle
		if battle.state.turn > _turn_limit:
			return {"error": "turn_limit", "node": run.current_node_id, "trace": trace}
		var commands := _legal_commands(battle)
		if commands.is_empty():
			if battle.end_turn() != "":
				return {"error": "end_turn_rejected", "trace": trace}
			trace.append({"end_turn": true, "events": battle.events.records.duplicate(true)})
			continue
		var command: Dictionary = _choose_command(battle, commands, policy, seed_value % 4 == 0)
		var before: Dictionary = battle.snapshot()
		var random_before: int = battle.rng.state
		var preview: Dictionary = battle.preview(
			command.copy, command.caster, command.target, command.status
		)
		if preview.error != "" or before != battle.snapshot() or random_before != battle.rng.state:
			return {"error": "preview_mutation", "command": command, "trace": trace}
		if battle.play_card(command.copy, command.caster, command.target, command.status) != "":
			return {"error": "legal_play_rejected", "command": command, "trace": trace}
		if preview.records != battle.events.records or preview.energy != battle.state.energy:
			return {"error": "preview_result_mismatch", "command": command, "trace": trace}
		trace.append({"play": command, "events": battle.events.records.duplicate(true)})
	var terminal_error := _run_invariant(run)
	if terminal_error != "" or run.phase not in [Types.RunPhase.WON, Types.RunPhase.LOST]:
		return {
			"error": terminal_error if terminal_error != "" else "invalid_terminal_phase",
			"trace": trace,
			"state": run.snapshot()
		}
	return {
		"error": "",
		"outcome": run.result.outcome,
		"gold": run.gold,
		"deck": run.deck.duplicate(true),
		"party": run.party.duplicate(true),
		"relics": run.relics.duplicate(),
		"map": run.chapter_map.duplicate(true),
		"visited": run.visited.duplicate(),
		"rng": str(run.rng.state),
		"nodes_seen": nodes_seen.keys(),
		"trace": trace
	}


func _progress_node(
	run: RefCounted, policy: RandomNumberGenerator, shop_actions: Dictionary
) -> Dictionary:
	var view: Dictionary = run.view_snapshot()
	var token: int = run.action_token
	var step := {"phase": run.phase, "node": run.current_node_id, "error": ""}
	match run.phase:
		Types.RunPhase.MAP:
			var choices: Array = view.map.nodes.filter(
				func(node: Dictionary) -> bool: return node.available
			)
			if choices.is_empty():
				step.error = "map_without_exit"
				return step
			# Exercise varied paths; three quarters of runs avoid elites when possible.
			if policy.seed % 4 != 0:
				var safer: Array = choices.filter(
					func(node: Dictionary) -> bool: return node.kind != "elite"
				)
				if not safer.is_empty():
					choices = safer
			var node: Dictionary = choices[policy.randi_range(0, choices.size() - 1)]
			step["choice"] = node.id
			step.error = run.choose_node(node.id, token)
		Types.RunPhase.REWARD:
			var is_card: bool = not run.reward_cards_done
			var candidates: Array = run.reward_candidates if is_card else run.relic_candidates
			var choice: String = (
				""
				if candidates.is_empty() or policy.randi_range(0, 4) == 0
				else candidates[policy.randi_range(0, candidates.size() - 1)]
			)
			var accepted: bool
			if is_card:
				accepted = (
					run.skip_reward(token) if choice == "" else run.claim_reward(choice, token)
				)
			else:
				accepted = run.skip_relic(token) if choice == "" else run.claim_relic(choice, token)
			step["choice"] = choice
			step["kind"] = "card" if is_card else "relic"
			if not accepted or run.skip_reward(token) or run.skip_relic(token):
				step.error = "reward_token"
		Types.RunPhase.CAMP:
			var hurt: bool = run.party.any(
				func(hero: Dictionary) -> bool: return hero.hp < hero.max_hp * 0.8
			)
			if hurt or view.camp.upgrade_cards.is_empty():
				step["choice"] = "rest"
				step.error = run.camp_rest(token)
			else:
				var upgrades: Array = view.camp.upgrade_cards
				var copy_id: int = upgrades[policy.randi_range(0, upgrades.size() - 1)].copy_id
				step["choice"] = copy_id
				step.error = run.camp_upgrade(copy_id, token)
		Types.RunPhase.SHOP:
			var used: int = shop_actions.get(run.current_node_id, 0)
			shop_actions[run.current_node_id] = used + 1
			var offers: Array = view.shop.offers.filter(
				func(offer: Dictionary) -> bool:
					return not offer.sold_out and offer.item_id != "" and offer.price <= run.gold
			)
			var action := policy.randi_range(0, 5)
			if used >= 3 or action == 0:
				step.error = run.leave_shop(token)
				step["choice"] = "leave"
			elif action == 1 and run.gold >= view.shop.refresh_cost:
				step.error = run.shop_refresh(token)
				step["choice"] = "refresh"
			elif action == 2 and run.gold >= view.shop.remove_cost and not run.deck.is_empty():
				var copy_id: int = run.deck[policy.randi_range(0, run.deck.size() - 1)].copy_id
				step.error = run.shop_remove(copy_id, token)
				step["choice"] = copy_id
			elif not offers.is_empty():
				var offer: Dictionary = offers[policy.randi_range(0, offers.size() - 1)]
				step.error = run.shop_buy(offer.id, token)
				step["choice"] = offer.item_id
			else:
				step.error = run.leave_shop(token)
				step["choice"] = "leave"
		Types.RunPhase.EVENT:
			var options: Array = view.event.options.filter(
				func(option: Dictionary) -> bool: return option.enabled
			)
			if options.is_empty():
				step.error = "event_without_exit"
				return step
			var option: Dictionary = options[policy.randi_range(0, options.size() - 1)]
			var selection := ""
			if option.selection != "none":
				selection = option.choices[policy.randi_range(0, option.choices.size() - 1)].id
			step["choice"] = option.id
			step["selection"] = selection
			step.error = run.choose_event_option(option.id, token, selection)
	return step


func _run_invariant(run: RefCounted) -> String:
	if run.gold < 0 or not run._valid_snapshot(run.snapshot()):
		return "invalid_checkpoint"
	if (
		run.phase == Types.RunPhase.WON
		and (run.visited.size() != 10 or run.result.outcome != "chapter_complete")
	):
		return "premature_chapter_completion"
	if (
		run.meta.full_completions != 0
		or run.meta.highest_difficulty != 1
		or run.meta.unlocked_characters.size() != 3
	):
		return "phase_three_progress_leaked"
	if run.phase != Types.RunPhase.BATTLE:
		return ""
	var battle: RefCounted = run.battle
	if battle.state.phase != Types.BattlePhase.PLAYER:
		return "invalid_active_battle"
	if battle.state.energy < 0 or battle.state.hand.size() > int(battle.data.rule("hand_limit")):
		return "invalid_resources"
	var ids: Dictionary = {}
	for pile in Types.PILES:
		for card in battle.state[pile]:
			if ids.has(card.copy_id):
				return "duplicate_card_copy"
			ids[card.copy_id] = true
	if ids.size() != run.deck.size():
		return "lost_card_copy"
	for unit in battle.state.heroes + battle.state.enemies:
		if unit.hp < 0 or unit.hp > unit.max_hp or unit.shield < 0 or unit.threat < 0:
			return "invalid_unit_resources"
		if unit.hp == 0 and (unit.shield != 0 or unit.threat != 0 or not unit.statuses.is_empty()):
			return "dead_unit_state"
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


func _choose_command(
	battle: RefCounted, commands: Array, policy: RandomNumberGenerator, random_policy: bool
) -> Dictionary:
	if random_policy:
		return commands[policy.randi_range(0, commands.size() - 1)]
	# A small deterministic policy improves completion coverage without changing game data.
	# The acceptance checks remain on the public commands and their real previews.
	var best: Array = []
	var best_score := -INF
	for command in commands:
		var preview: Dictionary = battle.preview(
			command.copy, command.caster, command.target, command.status
		)
		var score := 0.0
		for record in preview.records:
			if record.kind == "damage":
				score += float(record.get("hp_damage", record.get("amount", 0)))
			elif record.kind == "heal":
				score += float(record.get("amount", 0)) * 1.3
			elif record.kind == "revive":
				score += 50.0
			elif record.kind == "interrupt":
				score += 8.0
			elif record.kind == "draw":
				score += 2.0
			elif record.kind == "shield":
				score += float(record.get("amount", 0)) * 0.35
		if score > best_score:
			best_score = score
			best = [command]
		elif is_equal_approx(score, best_score):
			best.append(command)
	return best[policy.randi_range(0, best.size() - 1)]


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
