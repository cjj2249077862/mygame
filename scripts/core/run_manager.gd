extends RefCounted

signal changed
signal battle_created(engine: RefCounted)

const Types = preload("res://scripts/core/enums.gd")
const Models = preload("res://scripts/core/models.gd")
const Battle = preload("res://scripts/core/battle_engine.gd")
const Map = preload("res://scripts/core/map_generator.gd")
const Store = preload("res://scripts/core/save_manager.gd")
const SAVE_VERSION := 2
const ACTIVE_PHASES := [
	Types.RunPhase.BATTLE,
	Types.RunPhase.REWARD,
	Types.RunPhase.MAP,
	Types.RunPhase.CAMP,
	Types.RunPhase.SHOP,
	Types.RunPhase.EVENT
]
var data: RefCounted
var battle: RefCounted
var saves: RefCounted
var rng := RandomNumberGenerator.new()
var phase: int = Types.RunPhase.IDLE
var deck: Array = []
var party: Array = []
var relics: Array = []
var encounters: Array = []
var stage_index := 0
var gold := 0
var action_token := 0
var reward_token := 0
var reward_candidates: Array = []
var relic_candidates: Array = []
var reward_cards_done := true
var reward_relics_done := true
var reward_gold := 0
var chapter_map: Dictionary = {}
var current_node_id := ""
var visited: Array = []
var shop: Dictionary = {}
var event_state: Dictionary = {}
var remove_count := 0
var run_id := ""
var result: Dictionary = {}
var error := ""
var persistence_error := ""
var recovery_notice := false
var meta: Dictionary = {}
var _next_copy_id := 0
var _elapsed_base := 0.0
var _resume_tick := 0
var _load_error_slot := ""
var _pending_terminal_meta := false


func _init(game_data: RefCounted, save_directory: String = "") -> void:
	data = game_data
	# Core tests default to memory only; Main explicitly supplies its save path.
	if save_directory != "":
		saves = Store.new(save_directory)
	meta = _empty_meta()
	if saves != null and saves.has_slot("meta"):
		var loaded: Dictionary = saves.read_slot("meta", _valid_meta)
		if loaded.is_empty():
			persistence_error = saves.last_error
			_load_error_slot = "meta"
		else:
			meta = _restore_meta(loaded)
	if saves != null and _load_error_slot == "":
		_reconcile_terminal_record()


func start(seed_value: int, lineup: Array[String] = ["warden", "blade", "mender"]) -> bool:
	if persistence_error != "" or phase in ACTIVE_PHASES or has_saved_run():
		error = "error.active_run" if persistence_error == "" else "error.save"
		return false
	if lineup.size() != int(data.rule("party_size")):
		return false
	var seen: Dictionary = {}
	for id in lineup:
		if seen.has(id) or data.definition("characters", id).is_empty():
			return false
		seen[id] = true
	var chapter: Dictionary = data.chapter_definition()
	if chapter.is_empty():
		error = "error.config"
		return false
	rng.seed = seed_value
	chapter_map = Map.generate(chapter, data.map_pool(chapter.id), data.map_rules(chapter.id), rng)
	if not Map.validate(chapter_map, int(chapter.node_count)):
		error = "error.config"
		return false
	_disconnect_battle()
	deck.clear()
	party.clear()
	relics.clear()
	visited.clear()
	reward_candidates.clear()
	relic_candidates.clear()
	shop.clear()
	event_state.clear()
	result.clear()
	_next_copy_id = 0
	remove_count = 0
	gold = int(data.rule("starting_gold"))
	_elapsed_base = 0.0
	_resume_tick = Time.get_ticks_msec()
	run_id = "%d_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec(), seed_value]
	encounters = data.rows("encounters").duplicate(true)
	for id in lineup:
		party.append(Models.unit(data.definition("characters", id), id, true))
		for entry in data.rows("characters", "starter"):
			if entry.character_id == id:
				for i in range(int(entry.count)):
					_add_card(entry.card_id)
	_mark_started()
	phase = Types.RunPhase.MAP
	current_node_id = ""
	_bump_token()
	_enter_node(chapter_map.start_id)
	return true


func choose_node(node_id: String, token: int) -> String:
	var reason := _guard(Types.RunPhase.MAP, token)
	if reason != "":
		return reason
	if node_id not in _available_nodes():
		return "error.node"
	_enter_node(node_id)
	return ""


func camp_rest(token: int) -> String:
	var reason := _guard(Types.RunPhase.CAMP, token)
	if reason != "":
		return reason
	var ratio: float = (
		data.economy("camp_heal_ratio")
		+ data.relic_modifier(relics, "camp_rest", "camp_heal_ratio")
	)
	for hero in party:
		if hero.hp > 0:
			hero.hp = mini(int(hero.max_hp), int(hero.hp) + ceili(float(hero.max_hp) * ratio))
	_complete_node()
	return ""


func camp_upgrade(copy_id: int, token: int) -> String:
	var reason := _guard(Types.RunPhase.CAMP, token)
	if reason != "":
		return reason
	var copy := _find_copy(copy_id)
	if copy.is_empty() or copy.upgraded:
		return "error.upgraded"
	copy.upgraded = true
	_complete_node()
	return ""


func shop_buy(offer_id: String, token: int) -> String:
	var reason := _guard(Types.RunPhase.SHOP, token)
	if reason != "":
		return reason
	var offer: Dictionary = {}
	for candidate in shop.offers:
		if candidate.id == offer_id:
			offer = candidate
	if offer.is_empty() or offer.sold_out or offer.item_id == "":
		return "error.sold_out"
	if gold < offer.price:
		return "error.gold"
	if offer.kind == "relic" and offer.item_id in relics:
		return "error.sold_out"
	gold -= int(offer.price)
	if offer.kind == "card":
		_add_card(offer.item_id)
	else:
		relics.append(offer.item_id)
	offer.sold_out = true
	_commit()
	return ""


func shop_refresh(token: int) -> String:
	var reason := _guard(Types.RunPhase.SHOP, token)
	if reason != "":
		return reason
	var price := _refresh_price()
	if gold < price:
		return "error.gold"
	gold -= price
	shop.refresh_count += 1
	_generate_offers()
	_commit()
	return ""


func shop_remove(copy_id: int, token: int) -> String:
	var reason := _guard(Types.RunPhase.SHOP, token)
	if reason != "":
		return reason
	var copy := _find_copy(copy_id)
	if copy.is_empty():
		return "error.card"
	var price := _remove_price()
	if gold < price:
		return "error.gold"
	gold -= price
	remove_count += 1
	deck.erase(copy)
	_commit()
	return ""


func leave_shop(token: int) -> String:
	var reason := _guard(Types.RunPhase.SHOP, token)
	if reason != "":
		return reason
	_complete_node()
	return ""


func claim_reward(card_id: String, token: int) -> bool:
	if (
		_guard(Types.RunPhase.REWARD, token) != ""
		or reward_cards_done
		or card_id not in reward_candidates
	):
		return false
	_add_card(card_id)
	reward_cards_done = true
	_finish_reward_part()
	return true


func skip_reward(token: int) -> bool:
	if _guard(Types.RunPhase.REWARD, token) != "" or reward_cards_done:
		return false
	reward_cards_done = true
	_finish_reward_part()
	return true


func claim_relic(relic_id: String, token: int) -> bool:
	if (
		_guard(Types.RunPhase.REWARD, token) != ""
		or reward_relics_done
		or relic_id not in relic_candidates
		or relic_id in relics
	):
		return false
	relics.append(relic_id)
	reward_relics_done = true
	_finish_reward_part()
	return true


func skip_relic(token: int) -> bool:
	if _guard(Types.RunPhase.REWARD, token) != "" or reward_relics_done:
		return false
	reward_relics_done = true
	_finish_reward_part()
	return true


func choose_event_option(option_id: String, token: int, selection_id: String = "") -> String:
	var reason := _guard(Types.RunPhase.EVENT, token)
	if reason != "":
		return reason
	var option := _event_option(option_id)
	if option.is_empty():
		return "error.selection"
	reason = _event_error(option, selection_id)
	if reason != "":
		return reason
	var selected_hero := _find_hero(selection_id)
	var selected_card := _find_copy(int(selection_id)) if selection_id.is_valid_int() else {}
	var outcome: Dictionary = event_state.results[option_id]
	var resolved: Array[String] = []
	# Preconditions cover every possible outcome, before costs are consumed.
	gold -= int(option.cost_gold)
	if int(option.cost_gold) > 0:
		resolved.append(data.text("run.gold_cost", {"amount": option.cost_gold}))
	if int(option.cost_hp) > 0:
		selected_hero.hp -= int(option.cost_hp)
		resolved.append(
			(
				data.text(selected_hero.name_key)
				+ "："
				+ data.text("run.hp_cost", {"amount": option.cost_hp})
			)
		)
	for effect in data.event_effects(outcome.outcome_id):
		match effect.kind:
			"gold":
				gold += int(effect.amount)
				resolved.append(data.text("run.event.gold", {"amount": effect.amount}))
			"heal":
				var targets: Array = party if effect.target == "party" else [selected_hero]
				for hero in targets:
					if not hero.is_empty() and hero.hp > 0:
						var recovered := mini(int(hero.max_hp - hero.hp), int(effect.amount))
						hero.hp += recovered
						resolved.append(
							data.text(
								"run.event.heal_unit",
								{"name": data.text(hero.name_key), "amount": recovered}
							)
						)
			"hp_loss":
				selected_hero.hp -= int(effect.amount)
				resolved.append(
					(
						data.text(selected_hero.name_key)
						+ "："
						+ data.text("run.event.hp_loss", {"amount": effect.amount})
					)
				)
			"upgrade":
				var before: String = data.card_text(selected_card)
				selected_card.upgraded = true
				resolved.append(
					data.text(
						"run.upgrade_compare",
						{"before": before, "after": data.card_text(selected_card)}
					)
				)
			"remove":
				resolved.append(
					data.text("run.event.remove") + "：\n" + data.card_text(selected_card)
				)
				deck.erase(selected_card)
			"grant_relic":
				var awarded: String = outcome.relics[effect.id]
				if awarded not in relics:
					relics.append(awarded)
					resolved.append(
						data.text("run.event.grant_relic") + "：\n" + data.relic_text(awarded)
					)
	event_state["chosen_option"] = option_id
	event_state["chosen_selection"] = selection_id
	var event_definition: Dictionary = data.definition("events", event_state.event_id)
	event_state["resolution"] = {
		"title": data.text(event_definition.name_key),
		"details": data.text("run.event.leave") if resolved.is_empty() else "\n\n".join(resolved)
	}
	_complete_node()
	return ""


func has_saved_run() -> bool:
	if saves == null or not saves.has_slot("run"):
		return false
	var saved: Dictionary = saves.read_slot("run", _valid_snapshot)
	# An unreadable slot must not be silently overwritten by New Game.
	return saved.is_empty() or int(saved.phase) in ACTIVE_PHASES


func continue_run() -> bool:
	if saves == null:
		return false
	if _load_error_slot == "meta":
		error = "error.load"
		changed.emit()
		return false
	var saved: Dictionary = saves.read_slot("run", _valid_snapshot)
	if saved.is_empty():
		error = "error.load"
		persistence_error = saves.last_error
		_load_error_slot = "run"
		changed.emit()
		return false
	recovery_notice = saves.recovered_from_backup
	var restored_battle: RefCounted
	var restored_rng := RandomNumberGenerator.new()
	if int(saved.phase) == Types.RunPhase.BATTLE:
		restored_rng.seed = int(saved.rng_seed)
		restored_rng.state = int(saved.rng_state)
		restored_battle = Battle.new(data)
		if not restored_battle.restore(saved.battle, restored_rng, saved.relics):
			error = "error.load"
			persistence_error = "save_corrupt_or_incompatible"
			_load_error_slot = "run"
			if battle != null:
				battle.external_block_reason = "error.save"
			changed.emit()
			return false
	if _load_error_slot == "run":
		_load_error_slot = ""
	_disconnect_battle()
	rng = restored_rng
	_restore_fields(saved)
	if phase == Types.RunPhase.BATTLE:
		battle = restored_battle
		_connect_battle()
		battle_created.emit(battle)
		battle.settled.emit([], battle.snapshot())
	if phase not in ACTIVE_PHASES:
		_record_result()
	_commit()
	return persistence_error == ""


func return_to_menu() -> bool:
	# An idle load failure has no unsaved adventure in memory. Allow closing the
	# application while retaining the error and both files for a later retry.
	# Failed terminal metadata reconciliation is also recoverable from disk.
	if phase == Types.RunPhase.IDLE:
		return true
	if (phase in ACTIVE_PHASES or persistence_error != "") and not _checkpoint():
		changed.emit()
		return false
	_elapsed_base = elapsed_seconds()
	_resume_tick = 0
	_disconnect_battle()
	phase = Types.RunPhase.IDLE
	_bump_token()
	changed.emit()
	return true


func abandon_run() -> String:
	if _load_error_slot == "meta":
		return "error.save"
	if phase not in ACTIVE_PHASES and has_saved_run():
		var saved: Dictionary = saves.read_slot("run", _valid_snapshot)
		if saved.is_empty():
			# Explicit discard can retire a corrupt slot without fabricating its data.
			_disconnect_battle()
			deck.clear()
			party.clear()
			relics.clear()
			chapter_map.clear()
			visited.clear()
			shop.clear()
			event_state.clear()
			reward_candidates.clear()
			relic_candidates.clear()
			reward_cards_done = true
			reward_relics_done = true
			current_node_id = ""
			_elapsed_base = 0.0
			_resume_tick = 0
			phase = Types.RunPhase.ABANDONED
			run_id = "discarded_%d" % Time.get_ticks_usec()
			result = {
				"outcome": "abandoned",
				"difficulty": 1,
				"party": [],
				"depth": 0,
				"elapsed_seconds": 0,
				"deck": [],
				"relics": []
			}
			persistence_error = ""
			if _load_error_slot == "run":
				_load_error_slot = ""
			_commit()
			return "" if persistence_error == "" else "error.save"
		_restore_fields(saved)
	if phase not in ACTIVE_PHASES:
		return ""
	_disconnect_battle()
	phase = Types.RunPhase.ABANDONED
	_finalize("abandoned")
	_commit()
	return "" if persistence_error == "" else "error.save"


func retry_save() -> bool:
	if _load_error_slot == "run":
		return continue_run()
	if _load_error_slot == "meta":
		var loaded: Dictionary = saves.read_slot("meta", _valid_meta)
		if loaded.is_empty():
			persistence_error = saves.last_error
			changed.emit()
			return false
		meta = _restore_meta(loaded)
		_load_error_slot = ""
		persistence_error = ""
		_reconcile_terminal_record()
	if _pending_terminal_meta:
		var saved: bool = saves.write_slot("meta", meta, false, _valid_meta)
		persistence_error = "" if saved else saves.last_error
		_pending_terminal_meta = not saved
		changed.emit()
		return saved
	var ok := _checkpoint()
	changed.emit()
	return ok


func elapsed_seconds() -> float:
	return (
		_elapsed_base
		+ (float(Time.get_ticks_msec() - _resume_tick) / 1000.0 if _resume_tick > 0 else 0.0)
	)


func result_snapshot() -> Dictionary:
	return result.duplicate(true)


func _guard(expected_phase: int, token: int) -> String:
	if persistence_error != "":
		return "error.save"
	if phase != expected_phase:
		return "error.phase"
	if token != action_token:
		return "error.token"
	return ""


func _enter_node(node_id: String) -> void:
	var node := _node(node_id)
	current_node_id = node_id
	visited.append(node_id)
	stage_index = int(node.depth) - 1
	shop.clear()
	event_state.clear()
	reward_candidates.clear()
	relic_candidates.clear()
	reward_cards_done = true
	reward_relics_done = true
	reward_gold = 0
	match node.kind:
		"battle", "elite", "boss":
			_begin_battle(node.content_id)
			return
		"camp":
			phase = Types.RunPhase.CAMP
		"shop":
			phase = Types.RunPhase.SHOP
			shop = {"refresh_count": 0, "offers": []}
			_generate_offers()
		"event":
			phase = Types.RunPhase.EVENT
			_generate_event(node.content_id)
	_commit()


func _complete_node() -> void:
	if _node(current_node_id).kind == "boss":
		phase = Types.RunPhase.WON
		_finalize("chapter_complete")
	else:
		phase = Types.RunPhase.MAP
	_commit()


func _begin_battle(encounter_id: String) -> void:
	_disconnect_battle()
	phase = Types.RunPhase.BATTLE
	battle = Battle.new(data)
	_connect_battle()
	battle_created.emit(battle)
	battle.start(party, deck, encounter_id, rng, relics)


func _connect_battle() -> void:
	battle.settled.connect(_on_battle_settled)
	battle.battle_ended.connect(_on_battle_ended)


func _disconnect_battle() -> void:
	if battle != null:
		if battle.settled.is_connected(_on_battle_settled):
			battle.settled.disconnect(_on_battle_settled)
		if battle.battle_ended.is_connected(_on_battle_ended):
			battle.battle_ended.disconnect(_on_battle_ended)
	battle = null


func _on_battle_settled(_records: Array, snapshot: Dictionary) -> void:
	# Save terminal transitions only after rewards and party recovery are decided.
	if phase == Types.RunPhase.BATTLE and snapshot.phase == Types.BattlePhase.PLAYER:
		party = snapshot.heroes.duplicate(true)
		_commit()


func _on_battle_ended(victory: bool) -> void:
	if phase != Types.RunPhase.BATTLE:
		return
	party = battle.state.heroes.duplicate(true)
	if not victory:
		phase = Types.RunPhase.LOST
		_finalize("lost")
		_commit()
		return
	for hero in party:
		if hero.hp <= 0:
			hero.hp = mini(
				int(hero.max_hp),
				maxi(1, ceili(float(hero.max_hp) * data.rule("post_battle_revive")))
			)
	var node := _node(current_node_id)
	var encounter: Dictionary = data.definition("encounters", node.content_id)
	reward_gold = int(encounter.gold)
	gold += reward_gold
	reward_candidates = _draw_items("card", "", int(data.rule("reward_count")), node.kind)
	relic_candidates = []
	if node.kind in ["elite", "boss"]:
		var count: int = int(
			data.economy("boss_relic_choices" if node.kind == "boss" else "elite_relic_choices")
		)
		relic_candidates = _draw_items(
			"relic", "boss" if node.kind == "boss" else "normal", count, node.kind
		)
	reward_cards_done = reward_candidates.is_empty()
	reward_relics_done = relic_candidates.is_empty()
	phase = Types.RunPhase.REWARD
	_finish_reward_part()


func _finish_reward_part() -> void:
	if reward_cards_done and reward_relics_done:
		reward_candidates.clear()
		relic_candidates.clear()
		_complete_node()
	else:
		_commit()


func _find_copy(copy_id: int) -> Dictionary:
	for copy in deck:
		if int(copy.copy_id) == copy_id:
			return copy
	return {}


func _find_hero(id: String) -> Dictionary:
	for hero in party:
		if hero.id == id:
			return hero
	return {}


func _node(node_id: String) -> Dictionary:
	for node in chapter_map.get("nodes", []):
		if node.id == node_id:
			return node
	return {}


func _available_nodes() -> Array:
	if current_node_id == "":
		return [chapter_map.get("start_id", "")]
	return _node(current_node_id).get("next", []).duplicate()


func _add_card(card_id: String) -> void:
	deck.append(Models.card(_next_copy_id, card_id))
	_next_copy_id += 1


func _bump_token() -> void:
	action_token += 1
	reward_token = action_token


func _commit() -> void:
	error = ""
	_bump_token()
	_checkpoint()
	changed.emit()


func _eligible(definition: Dictionary, lineup: Array) -> bool:
	for hero in lineup:
		if (
			(definition.get("role", "") == "" or definition.role == hero.role)
			and (definition.get("owner", "") == "" or definition.owner == hero.definition_id)
		):
			return true
	return false


func _item_pool(kind: String, pool: String = "") -> Array:
	var candidates: Array = []
	for definition in data.rows("cards" if kind == "card" else "relics"):
		if not _eligible(definition, party):
			continue
		if kind == "card" and not definition.reward:
			continue
		if kind == "relic" and (definition.pool != pool or definition.id in relics):
			continue
		candidates.append(definition)
	return candidates


func _draw_items(kind: String, pool: String, count: int, source: String) -> Array:
	var candidates := _item_pool(kind, pool)
	var result_ids: Array = []
	for index in range(count):
		if candidates.is_empty():
			break
		var rarity_counts: Dictionary = {}
		if kind == "card":
			for item in candidates:
				rarity_counts[item.rarity] = int(rarity_counts.get(item.rarity, 0)) + 1
		var weights: Array = []
		for item in candidates:
			var weight: float = data.weight_for(kind, item.id, source)
			if kind == "card":
				weight /= float(rarity_counts[item.rarity])
			weights.append({"id": item.id, "weight": weight})
		var id := Map.weighted_pick(weights, rng)
		if id == "":
			break
		result_ids.append(id)
		candidates = candidates.filter(func(item: Dictionary) -> bool: return item.id != id)
	return result_ids


func _generate_offers() -> void:
	shop.offers = []
	for kind in ["card", "relic"]:
		var count: int = int(
			data.economy("shop_card_slots" if kind == "card" else "shop_relic_slots")
		)
		var items := _draw_items(kind, "normal", count, "shop")
		for index in range(count):
			var item_id: String = items[index] if index < items.size() else ""
			shop.offers.append(
				{
					"id": "%s_%d_%d" % [kind, shop.refresh_count, index],
					"kind": kind,
					"item_id": item_id,
					"price": data.price_for(kind, item_id) if item_id != "" else 0,
					"sold_out": item_id == ""
				}
			)


func _refresh_price() -> int:
	return int(
		(
			data.economy("refresh_base")
			+ int(shop.get("refresh_count", 0)) * data.economy("refresh_step")
		)
	)


func _remove_price() -> int:
	return int(data.economy("remove_base") + remove_count * data.economy("remove_step"))


func _generate_event(event_id: String) -> void:
	event_state = {"event_id": event_id, "results": {}, "chosen_option": "", "chosen_selection": ""}
	for option in data.event_options(event_id):
		var outcomes: Array = data.event_outcomes(option.id)
		var choices: Array = []
		for outcome in outcomes:
			choices.append({"id": outcome.id, "weight": outcome.weight})
		var selected := Map.weighted_pick(choices, rng)
		var generated: Dictionary = {"outcome_id": selected, "relics": {}}
		for effect in data.event_effects(selected):
			if effect.kind == "grant_relic":
				var reward := _draw_items("relic", effect.content_pool, 1, "battle")
				generated.relics[effect.id] = "" if reward.is_empty() else reward[0]
		event_state.results[option.id] = generated


func _event_option(option_id: String) -> Dictionary:
	for option in data.event_options(event_state.get("event_id", "")):
		if option.id == option_id:
			return option
	return {}


func _event_choices(option: Dictionary) -> Array:
	var choices: Array = []
	if option.selection == "hero":
		var maximum_hp_cost := int(option.cost_hp)
		for outcome in data.event_outcomes(option.id):
			var branch_cost := int(option.cost_hp)
			for effect in data.event_effects(outcome.id):
				if effect.kind == "hp_loss":
					branch_cost += int(effect.amount)
			maximum_hp_cost = maxi(maximum_hp_cost, branch_cost)
		for hero in party:
			if hero.hp < option.min_hp or hero.hp <= maximum_hp_cost:
				continue
			choices.append(
				{
					"id": hero.id,
					"text": data.text(hero.name_key),
					"details":
					data.text(
						"run.hero_cost",
						{
							"name": data.text(hero.name_key),
							"hp": hero.hp,
							"after": int(hero.hp) - maximum_hp_cost,
							"cost": maximum_hp_cost
						}
					)
				}
			)
	elif option.selection in ["card", "unupgraded_card"]:
		for copy in deck:
			if option.selection == "unupgraded_card" and copy.upgraded:
				continue
			var detail: String = data.card_text(copy)
			if option.selection == "unupgraded_card":
				var upgraded: Dictionary = copy.duplicate(true)
				upgraded.upgraded = true
				detail = data.text(
					"run.upgrade_compare", {"before": detail, "after": data.card_text(upgraded)}
				)
			(
				choices
				. append(
					{
						"id": str(copy.copy_id),
						"copy_id": copy.copy_id,
						"card_id": copy.card_id,
						"upgraded": copy.upgraded,
						"text": data.card_text(copy),
						"details": detail,
					}
				)
			)
	return choices


func _event_card_mode(option: Dictionary) -> String:
	if option.selection not in ["card", "unupgraded_card"]:
		return ""
	# A definite preview must hold for every public branch, never the stored random result.
	var mode := ""
	for outcome in data.event_outcomes(option.id):
		if float(outcome.weight) <= 0.0:
			continue
		var count := 0
		var branch_mode := ""
		for effect in data.event_effects(outcome.id):
			if effect.target != "selected_card":
				continue
			count += 1
			if effect.kind not in ["upgrade", "remove"]:
				return "select"
			branch_mode = str(effect.kind)
		if count != 1 or (mode != "" and mode != branch_mode):
			return "select"
		mode = branch_mode
	return mode if mode != "" else "select"


func _event_error(
	option: Dictionary, selection_id: String = "", check_selection: bool = true
) -> String:
	if gold < option.cost_gold:
		return "error.gold"
	if (
		option.required_relic_pool != ""
		and _item_pool("relic", option.required_relic_pool).is_empty()
	):
		return "error.empty_pool"
	if option.selection != "none":
		var choices := _event_choices(option)
		if choices.is_empty():
			return "error.selection"
		if (
			check_selection
			and not choices.any(func(choice: Dictionary) -> bool: return choice.id == selection_id)
		):
			return "error.selection"
	elif selection_id != "":
		return "error.selection"
	var stored: Dictionary = event_state.results.get(option.id, {})
	if stored.is_empty():
		return "error.config"
	for effect in data.event_effects(stored.outcome_id):
		if effect.kind == "grant_relic":
			var id: String = stored.relics.get(effect.id, "")
			if id == "" or id in relics:
				return "error.empty_pool"
	return ""


func _event_details(option: Dictionary) -> String:
	var lines: Array[String] = []
	if option.cost_gold > 0:
		lines.append(data.text("run.gold_cost", {"amount": option.cost_gold}))
	if option.cost_hp > 0:
		lines.append(data.text("run.hp_cost", {"amount": option.cost_hp}))
	var outcomes: Array = data.event_outcomes(option.id)
	var total := 0.0
	for outcome in outcomes:
		total += float(outcome.weight)
	for outcome in outcomes:
		var benefits: Array[String] = []
		for effect in data.event_effects(outcome.id):
			if effect.kind == "heal" and effect.target == "party":
				for hero in party:
					var actual: int = (
						mini(int(hero.max_hp - hero.hp), int(effect.amount)) if hero.hp > 0 else 0
					)
					benefits.append(
						data.text(
							"run.event.heal_unit",
							{"name": data.text(hero.name_key), "amount": actual}
						)
					)
			else:
				benefits.append(data.text("run.event." + effect.kind, {"amount": effect.amount}))
		var description: String = (
			data.text("run.event.leave") if benefits.is_empty() else "；".join(benefits)
		)
		lines.append(
			data.text(
				"run.probability",
				{"percent": float(outcome.weight) / total * 100.0, "effects": description}
			)
		)
	return "\n".join(lines)


func view_snapshot() -> Dictionary:
	var view := {
		"phase": phase,
		"token": action_token,
		"gold": gold,
		"deck": deck.duplicate(true),
		"party": party.duplicate(true),
		"relics": relics.duplicate(),
		"node_id": current_node_id,
		"depth": visited.size(),
		"map": {},
		"boss": {},
		"camp": {},
		"shop": {},
		"event": {},
		"event_result": {},
		"rewards": {},
		"result": result_snapshot(),
		"error": error,
		"persistence_error": persistence_error,
		"recovery_notice": recovery_notice,
		"can_discard_saved_run":
		_load_error_slot == "run" and saves != null and saves.has_slot("run")
	}
	if not chapter_map.is_empty():
		var public_nodes: Array = []
		for node in chapter_map.nodes:
			# No content_id is exposed for unentered normal/elite/event nodes.
			public_nodes.append(
				{
					"id": node.id,
					"depth": node.depth,
					"column": node.column,
					"kind": node.kind,
					"next": node.next.duplicate(),
					"visited": node.id in visited,
					"available": phase == Types.RunPhase.MAP and node.id in _available_nodes(),
					"current": node.id == current_node_id
				}
			)
		view.map = {"nodes": public_nodes, "chapter_id": chapter_map.chapter_id}
		var encounter: Dictionary = data.definition("encounters", chapter_map.boss_encounter_id)
		var boss_name: String = encounter.get("name_key", "")
		var enemy_ids: PackedStringArray = str(encounter.get("enemies", "")).split(",", false)
		if not enemy_ids.is_empty():
			boss_name = data.definition("encounters", enemy_ids[0], "enemies").get(
				"name_key", boss_name
			)
		view.boss = {
			"name": data.text(boss_name),
			"description": data.text(encounter.get("description_key", "chapter.boss_description"))
		}
	if phase == Types.RunPhase.CAMP:
		var recoveries: Array = []
		var upgrades: Array = []
		var ratio: float = (
			data.economy("camp_heal_ratio")
			+ data.relic_modifier(relics, "camp_rest", "camp_heal_ratio")
		)
		for hero in party:
			recoveries.append(
				{
					"id": hero.id,
					"name": data.text(hero.name_key),
					"hp": hero.hp,
					"max_hp": hero.max_hp,
					"amount":
					(
						mini(int(hero.max_hp - hero.hp), ceili(float(hero.max_hp) * ratio))
						if hero.hp > 0
						else 0
					)
				}
			)
		for copy in deck:
			if copy.upgraded:
				continue
			var after: Dictionary = copy.duplicate(true)
			after.upgraded = true
			upgrades.append(
				{
					"copy_id": copy.copy_id,
					"card_id": copy.card_id,
					"upgraded": copy.upgraded,
					"before": data.card_text(copy),
					"after": data.card_text(after)
				}
			)
		view.camp = {"recoveries": recoveries, "upgrade_cards": upgrades}
	if phase == Types.RunPhase.SHOP:
		var offers: Array = []
		var removable: Array = []
		for source in shop.offers:
			var offer: Dictionary = source.duplicate(true)
			if offer.item_id == "":
				offer["name"] = ""
				offer["description"] = ""
				offers.append(offer)
				continue
			var definition: Dictionary = data.definition(
				"cards" if offer.kind == "card" else "relics", offer.item_id
			)
			offer["name"] = data.text(definition.name_key)
			offer["description"] = (
				data.card_details(Models.card(-1, offer.item_id))
				if offer.kind == "card"
				else data.relic_text(offer.item_id)
			)
			offers.append(offer)
		for copy in deck:
			(
				removable
				. append(
					{
						"copy_id": copy.copy_id,
						"card_id": copy.card_id,
						"upgraded": copy.upgraded,
						"text": data.card_text(copy),
					}
				)
			)
		view.shop = {
			"offers": offers,
			"refresh_cost": _refresh_price(),
			"remove_cost": _remove_price(),
			"removable_cards": removable
		}
	if phase == Types.RunPhase.EVENT:
		var definition: Dictionary = data.definition("events", event_state.event_id)
		var options: Array = []
		for option in data.event_options(event_state.event_id):
			var reason := _event_error(option, "", false)
			options.append(
				{
					"id": option.id,
					"text": data.text(option.text_key),
					"details": _event_details(option),
					"enabled": reason == "",
					"error": reason,
					"selection": option.selection,
					"card_mode": _event_card_mode(option),
					"choices": _event_choices(option)
				}
			)
		view.event = {
			"title": data.text(definition.name_key),
			"body": data.text(definition.description_key),
			"options": options
		}
	if phase == Types.RunPhase.MAP and event_state.get("chosen_option", "") != "":
		view.event_result = event_state.get("resolution", {}).duplicate(true)
	if phase == Types.RunPhase.REWARD:
		view.rewards = {
			"cards": reward_candidates.duplicate(),
			"relics": relic_candidates.duplicate(),
			"cards_done": reward_cards_done,
			"relics_done": reward_relics_done,
			"gold_granted": reward_gold
		}
	return view


func snapshot() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"data_bundle": data.books.cards.bundle_id,
		"run_id": run_id,
		"phase": phase,
		"gold": gold,
		"deck": deck.duplicate(true),
		"party": party.duplicate(true),
		"relics": relics.duplicate(),
		"map": chapter_map.duplicate(true),
		"current_node_id": current_node_id,
		"visited": visited.duplicate(),
		"action_token": action_token,
		"next_copy_id": _next_copy_id,
		"remove_count": remove_count,
		"shop": shop.duplicate(true),
		"event": event_state.duplicate(true),
		"reward_cards": reward_candidates.duplicate(),
		"reward_relics": relic_candidates.duplicate(),
		"reward_cards_done": reward_cards_done,
		"reward_relics_done": reward_relics_done,
		"reward_gold": reward_gold,
		"rng_seed": str(rng.seed),
		"rng_state": str(rng.state),
		"elapsed_seconds": elapsed_seconds(),
		"result": result_snapshot(),
		"battle": battle.snapshot() if phase == Types.RunPhase.BATTLE and battle != null else {}
	}


func _checkpoint() -> bool:
	if _load_error_slot != "":
		return false
	if saves == null:
		return true
	if phase == Types.RunPhase.IDLE:
		return persistence_error == ""
	var terminal := phase in [Types.RunPhase.WON, Types.RunPhase.LOST, Types.RunPhase.ABANDONED]
	var ok: bool = saves.write_slot("run", snapshot(), terminal, _valid_snapshot)
	if ok:
		ok = saves.write_slot("meta", meta, false, _valid_meta)
	persistence_error = "" if ok else saves.last_error
	if battle != null:
		battle.external_block_reason = "" if ok else "error.save"
	return ok


func _restore_fields(saved: Dictionary) -> void:
	phase = int(saved.phase)
	run_id = saved.run_id
	gold = int(saved.gold)
	deck = _restore_numbers(saved.deck)
	party = Models.normalize_saved_units(saved.party)
	relics = saved.relics.duplicate()
	chapter_map = _restore_numbers(saved.map)
	current_node_id = saved.current_node_id
	visited = saved.visited.duplicate()
	stage_index = maxi(0, visited.size() - 1)
	action_token = int(saved.action_token)
	reward_token = action_token
	_next_copy_id = int(saved.next_copy_id)
	remove_count = int(saved.remove_count)
	shop = _restore_numbers(saved.shop)
	event_state = _restore_numbers(saved.event)
	reward_candidates = saved.reward_cards.duplicate()
	relic_candidates = saved.reward_relics.duplicate()
	reward_cards_done = saved.reward_cards_done
	reward_relics_done = saved.reward_relics_done
	reward_gold = int(saved.reward_gold)
	rng.seed = int(saved.rng_seed)
	rng.state = int(saved.rng_state)
	_elapsed_base = float(saved.elapsed_seconds)
	_resume_tick = Time.get_ticks_msec() if phase in ACTIVE_PHASES else 0
	result = _restore_result(saved.result)
	encounters = data.rows("encounters").duplicate(true)
	persistence_error = ""
	error = ""
	_mark_started()


func _restore_numbers(value: Variant) -> Variant:
	if value is Dictionary:
		var restored: Dictionary = {}
		for key in value:
			restored[key] = _restore_numbers(value[key])
		return restored
	if value is Array:
		var restored: Array = []
		for entry in value:
			restored.append(_restore_numbers(entry))
		return restored
	if value is float and is_finite(value) and value == floorf(value):
		return int(value)
	return value


func _restore_result(saved: Dictionary) -> Dictionary:
	if saved.is_empty():
		return {}
	var restored: Dictionary = _restore_numbers(saved)
	restored.party = Models.normalize_saved_units(saved.party)
	restored.elapsed_seconds = float(saved.elapsed_seconds)
	return restored


func _restore_meta(saved: Dictionary) -> Dictionary:
	var restored: Dictionary = _restore_numbers(saved)
	for index in range(saved.records.size()):
		restored.records[index] = _restore_result(saved.records[index])
	return restored


func _empty_meta() -> Dictionary:
	return {
		"version": 1,
		"started_ids": [],
		"finished_ids": [],
		"records": [],
		"character_uses": {},
		"adventures": 0,
		"chapter_completions": 0,
		"losses": 0,
		"abandoned": 0,
		"full_completions": 0,
		"highest_difficulty": 1,
		"unlocked_characters": ["warden", "blade", "mender"]
	}


func _reconcile_terminal_record() -> void:
	if not saves.has_slot("run"):
		return
	var saved: Dictionary = saves.read_slot("run", _valid_snapshot)
	if (
		saved.is_empty()
		or int(saved.phase) in ACTIVE_PHASES
		or saved.run_id in meta.finished_ids
		or saved.run_id.begins_with("discarded_")
	):
		return
	# The run checkpoint is committed before meta. Recover a crash between the
	# two writes even when Continue is hidden because the adventure has ended.
	_restore_fields(saved)
	_record_result()
	var ok: bool = saves.write_slot("meta", meta, false, _valid_meta)
	_pending_terminal_meta = not ok
	persistence_error = "" if ok else saves.last_error
	phase = Types.RunPhase.IDLE


func _mark_started() -> void:
	if run_id.begins_with("discarded_") or run_id in meta.started_ids:
		return
	meta.started_ids.append(run_id)
	meta.adventures += 1
	for hero in party:
		meta.character_uses[hero.definition_id] = (
			int(meta.character_uses.get(hero.definition_id, 0)) + 1
		)


func _finalize(outcome: String) -> void:
	_elapsed_base = elapsed_seconds()
	_resume_tick = 0
	result = {
		"outcome": outcome,
		"difficulty": 1,
		"party": party.duplicate(true),
		"depth": visited.size(),
		"elapsed_seconds": _elapsed_base,
		"deck": deck.duplicate(true),
		"relics": relics.duplicate()
	}
	_record_result()


func _record_result() -> void:
	if run_id.begins_with("discarded_"):
		return
	if run_id in meta.finished_ids or result.is_empty():
		return
	_mark_started()
	meta.finished_ids.append(run_id)
	var counter: String = {
		"chapter_complete": "chapter_completions", "lost": "losses", "abandoned": "abandoned"
	}[result.outcome]
	meta[counter] += 1
	var record := result.duplicate(true)
	record["run_id"] = run_id
	meta.records.push_front(record)
	while meta.records.size() > maxi(1, int(data.economy("recent_run_limit"))):
		meta.records.pop_back()


func _integer(value: Variant, minimum: int = 0) -> bool:
	return (
		(value is int or value is float)
		and is_finite(float(value))
		and value >= minimum
		and float(value) == floorf(float(value))
	)


func _valid_meta(candidate: Dictionary) -> bool:
	if candidate.get("version") != 1:
		return false
	for key in ["started_ids", "finished_ids", "records", "unlocked_characters"]:
		if not candidate.get(key) is Array:
			return false
	for key in [
		"adventures",
		"chapter_completions",
		"losses",
		"abandoned",
		"full_completions",
		"highest_difficulty"
	]:
		if not _integer(candidate.get(key)):
			return false
	if not candidate.get("character_uses") is Dictionary:
		return false
	for value in candidate.character_uses.values():
		if not _integer(value):
			return false
	for key in ["started_ids", "finished_ids", "unlocked_characters"]:
		for id in candidate[key]:
			if not id is String:
				return false
	for record in candidate.records:
		if not record is Dictionary or not _valid_result(record):
			return false
	return true


func _valid_snapshot(candidate: Dictionary) -> bool:
	if (
		candidate.get("version") != SAVE_VERSION
		or candidate.get("data_bundle") != data.books.cards.bundle_id
	):
		return false
	for key in ["run_id", "current_node_id", "rng_seed", "rng_state"]:
		if not candidate.get(key) is String:
			return false
	if (
		candidate.run_id == ""
		or not candidate.rng_seed.is_valid_int()
		or not candidate.rng_state.is_valid_int()
	):
		return false
	for key in ["phase", "gold", "action_token", "next_copy_id", "remove_count", "reward_gold"]:
		if not _integer(candidate.get(key)):
			return false
	# JSON decodes integer fields as floats; enum membership is type-sensitive.
	# Validate first so fractional/string/bool phases cannot be coerced into a valid one.
	var saved_phase := int(candidate.phase)
	if (
		saved_phase
		not in ACTIVE_PHASES + [Types.RunPhase.WON, Types.RunPhase.LOST, Types.RunPhase.ABANDONED]
	):
		return false
	if not (candidate.get("elapsed_seconds") is int or candidate.get("elapsed_seconds") is float):
		return false
	if candidate.elapsed_seconds < 0 or not is_finite(float(candidate.elapsed_seconds)):
		return false
	for key in ["deck", "party", "relics", "visited", "reward_cards", "reward_relics"]:
		if not candidate.get(key) is Array:
			return false
	for key in ["map", "shop", "event", "battle", "result"]:
		if not candidate.get(key) is Dictionary:
			return false
	# Older completed-event checkpoints do not contain display-only resolution text.
	if candidate.event.has("resolution"):
		var resolution: Variant = candidate.event.resolution
		if (
			not resolution is Dictionary
			or not resolution.get("title") is String
			or not resolution.get("details") is String
		):
			return false
	for key in ["reward_cards_done", "reward_relics_done"]:
		if not candidate.get(key) is bool:
			return false
	if saved_phase in ACTIVE_PHASES and not candidate.result.is_empty():
		return false
	if saved_phase == Types.RunPhase.ABANDONED and candidate.map.is_empty():
		return (
			candidate.run_id.begins_with("discarded_")
			and _valid_result(candidate.result)
			and candidate.result.get("outcome") == "abandoned"
			and candidate.party.is_empty()
			and candidate.deck.is_empty()
		)
	var chapter: Dictionary = data.chapter_definition()
	if (
		candidate.map.get("chapter_id") != chapter.id
		or candidate.map.get("boss_encounter_id") != chapter.boss_encounter_id
		or not Map.validate(candidate.map, int(chapter.node_count))
	):
		return false
	var nodes: Dictionary = {}
	var map_pool: Array = data.map_pool(chapter.id)
	var used_events: Dictionary = {}
	for node in candidate.map.nodes:
		nodes[node.id] = node
		if int(node.column) >= int(chapter.width):
			return false
		if node.depth == 1:
			if node.content_id != chapter.first_encounter_id:
				return false
		elif node.kind == "boss":
			if node.content_id != chapter.boss_encounter_id:
				return false
		elif node.kind in ["battle", "elite", "event"]:
			var eligible := false
			for entry in map_pool:
				if (
					entry.kind == node.kind
					and entry.content_id == node.content_id
					and node.depth >= entry.get("min_depth", 2)
					and node.depth <= entry.get("max_depth", int(chapter.node_count) - 2)
				):
					eligible = true
					break
			if not eligible:
				return false
			if node.kind == "event":
				if used_events.has(node.content_id):
					return false
				used_events[node.content_id] = true
		elif node.content_id != "":
			return false
	if not nodes.has(candidate.current_node_id) or candidate.visited.is_empty():
		return false
	if (
		candidate.visited[0] != candidate.map.start_id
		or candidate.visited.back() != candidate.current_node_id
	):
		return false
	for index in range(candidate.visited.size()):
		var id: Variant = candidate.visited[index]
		if not id is String or not nodes.has(id) or nodes[id].depth != index + 1:
			return false
		if index > 0 and id not in nodes[candidate.visited[index - 1]].next:
			return false
	var current: Dictionary = nodes[candidate.current_node_id]
	if saved_phase == Types.RunPhase.MAP and current.next.is_empty():
		return false
	var node_phases := {
		"camp": Types.RunPhase.CAMP, "shop": Types.RunPhase.SHOP, "event": Types.RunPhase.EVENT
	}
	if saved_phase in node_phases.values() and node_phases.get(current.kind, -1) != saved_phase:
		return false
	if (
		saved_phase in [Types.RunPhase.BATTLE, Types.RunPhase.REWARD]
		and current.kind not in ["battle", "elite", "boss"]
	):
		return false
	if (
		saved_phase == Types.RunPhase.WON
		and (current.kind != "boss" or candidate.visited.size() != int(chapter.node_count))
	):
		return false
	var party_ids: Dictionary = {}
	if candidate.party.size() != int(data.rule("party_size")):
		return false
	for hero in candidate.party:
		if (
			not hero is Dictionary
			or not hero.get("id") is String
			or not hero.get("definition_id") is String
		):
			return false
		var definition: Dictionary = data.definition("characters", hero.definition_id)
		if definition.is_empty() or hero.id != hero.definition_id or party_ids.has(hero.id):
			return false
		party_ids[hero.id] = true
		var template := Models.unit(definition, hero.id, true)
		for key in template:
			if not hero.has(key):
				return false
			if template[key] is String and not hero[key] is String:
				return false
			if template[key] is bool and not hero[key] is bool:
				return false
			if template[key] is Array and not hero[key] is Array:
				return false
			if template[key] is Dictionary and not hero[key] is Dictionary:
				return false
			if template[key] is int and not _integer(hero[key]):
				return false
		if (
			hero.max_hp <= 0
			or hero.hp > hero.max_hp
			or hero.role != definition.role
			or hero.passive != definition.passive
		):
			return false
		if (
			not hero.statuses is Dictionary
			or not hero.intent is Dictionary
			or not hero.passive_used is bool
		):
			return false
	var copies: Dictionary = {}
	for copy in candidate.deck:
		if (
			not copy is Dictionary
			or not _integer(copy.get("copy_id"))
			or not copy.get("card_id") is String
			or not copy.get("upgraded") is bool
		):
			return false
		if (
			copies.has(int(copy.copy_id))
			or copy.copy_id >= candidate.next_copy_id
			or data.definition("cards", copy.card_id).is_empty()
		):
			return false
		copies[int(copy.copy_id)] = copy
	for key in ["relics", "reward_cards", "reward_relics"]:
		var seen: Dictionary = {}
		for id in candidate[key]:
			if (
				not id is String
				or seen.has(id)
				or data.definition("cards" if key == "reward_cards" else "relics", id).is_empty()
			):
				return false
			seen[id] = true
	if saved_phase == Types.RunPhase.REWARD:
		if candidate.reward_cards_done and candidate.reward_relics_done:
			return false
		if not candidate.reward_cards_done and candidate.reward_cards.is_empty():
			return false
		if not candidate.reward_relics_done and candidate.reward_relics.is_empty():
			return false
		for card_id in candidate.reward_cards:
			if not _eligible(data.definition("cards", card_id), candidate.party):
				return false
		for relic_id in candidate.reward_relics:
			var relic: Dictionary = data.definition("relics", relic_id)
			if current.kind not in ["elite", "boss"] or not _eligible(relic, candidate.party):
				return false
			if relic.pool != ("boss" if current.kind == "boss" else "normal"):
				return false
			if not candidate.reward_relics_done and relic_id in candidate.relics:
				return false
	if saved_phase == Types.RunPhase.BATTLE:
		var engine := Battle.new(data)
		if (
			not engine.can_restore(candidate.battle)
			or candidate.battle.phase != Types.BattlePhase.PLAYER
		):
			return false
		if (
			candidate.battle.encounter_id != current.content_id
			or candidate.battle.heroes != candidate.party
			or candidate.battle.relic_ids != candidate.relics
		):
			return false
		var battle_ids: Dictionary = {}
		for pile in Types.PILES:
			for copy in candidate.battle[pile]:
				if (
					not copies.has(int(copy.copy_id))
					or battle_ids.has(int(copy.copy_id))
					or copy != copies[int(copy.copy_id)]
				):
					return false
				battle_ids[int(copy.copy_id)] = true
		if battle_ids.size() != copies.size():
			return false
	if saved_phase == Types.RunPhase.SHOP:
		if (
			not _integer(candidate.shop.get("refresh_count"))
			or not candidate.shop.get("offers") is Array
		):
			return false
		var offer_ids: Dictionary = {}
		for offer in candidate.shop.offers:
			if not offer is Dictionary or not offer.get("id") is String or offer_ids.has(offer.id):
				return false
			if (
				offer.get("kind") not in ["card", "relic"]
				or not offer.get("item_id") is String
				or not offer.get("sold_out") is bool
				or not _integer(offer.get("price"))
			):
				return false
			offer_ids[offer.id] = true
			if offer.item_id == "":
				if not offer.sold_out or offer.price != 0:
					return false
				continue
			var definition: Dictionary = data.definition(
				"cards" if offer.kind == "card" else "relics", offer.item_id
			)
			if definition.is_empty() or not _eligible(definition, candidate.party):
				return false
	if saved_phase == Types.RunPhase.EVENT:
		if (
			candidate.event.get("event_id") != current.content_id
			or not candidate.event.get("results") is Dictionary
		):
			return false
		for option in data.event_options(current.content_id):
			var stored: Variant = candidate.event.results.get(option.id)
			if not stored is Dictionary or not stored.get("relics") is Dictionary:
				return false
			var outcomes: Array = data.event_outcomes(option.id)
			if not outcomes.any(
				func(outcome: Dictionary) -> bool: return outcome.id == stored.get("outcome_id")
			):
				return false
			for effect in data.event_effects(stored.outcome_id):
				if effect.kind != "grant_relic":
					continue
				var reward: Variant = stored.relics.get(effect.id)
				if (
					not reward is String
					or (reward != "" and data.definition("relics", reward).is_empty())
				):
					return false
	if saved_phase not in ACTIVE_PHASES:
		var expected: String = {
			Types.RunPhase.WON: "chapter_complete",
			Types.RunPhase.LOST: "lost",
			Types.RunPhase.ABANDONED: "abandoned"
		}[saved_phase]
		if not _valid_result(candidate.result) or candidate.result.get("outcome") != expected:
			return false
		if (
			candidate.result.party != candidate.party
			or candidate.result.deck != candidate.deck
			or candidate.result.relics != candidate.relics
			or candidate.result.depth != candidate.visited.size()
		):
			return false
	return true


func _valid_result(record: Dictionary) -> bool:
	if record.get("outcome") not in ["chapter_complete", "lost", "abandoned"]:
		return false
	if not _integer(record.get("difficulty"), 1) or not _integer(record.get("depth")):
		return false
	var seconds: Variant = record.get("elapsed_seconds")
	if not (seconds is int or seconds is float) or not is_finite(float(seconds)) or seconds < 0:
		return false
	for key in ["party", "deck", "relics"]:
		if not record.get(key) is Array:
			return false
	return true
