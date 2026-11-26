extends RefCounted

signal settled(records: Array, snapshot: Dictionary)
signal battle_ended(victory: bool)

const Types = preload("res://scripts/core/enums.gd")
const Models = preload("res://scripts/core/models.gd")
const Events = preload("res://scripts/core/battle_events.gd")
const Resolver = preload("res://scripts/core/effect_resolver.gd")

var data: RefCounted
var rng := RandomNumberGenerator.new()
var events := Events.new()
var resolver: RefCounted
var state: Dictionary = {"phase": Types.BattlePhase.IDLE}
var _publishing := false


func _init(game_data: RefCounted) -> void:
	data = game_data
	resolver = Resolver.new(self)


func start(party: Array, deck: Array, encounter_id: String, random: RandomNumberGenerator) -> void:
	if _publishing:
		return
	rng = random
	events.clear()
	state = {
		"phase": Types.BattlePhase.RESOLVING,
		"turn": 0,
		"energy": 0,
		"heroes": party.duplicate(true),
		"enemies": [],
		"encounter_id": encounter_id
	}
	for pile in Types.PILES:
		state[pile] = []
	state.draw = deck.duplicate(true)
	for hero in state.heroes:
		hero.shield = 0
		hero.statuses = {}
		hero.threat = int(
			data.rule("initial_tank_threat" if hero.role == "tank" else "initial_other_threat")
		)
	var encounter: Dictionary = data.definition("encounters", encounter_id)
	for enemy_id in encounter.enemies.split(","):
		var definition: Dictionary = data.definition("encounters", enemy_id, "enemies")
		state.enemies.append(Models.unit(definition, "enemy_%d" % state.enemies.size(), false))
	shuffle(state.draw)
	events.notify("battle_started", {"units": state.heroes + state.enemies})
	_begin_turn()
	_publish()


func snapshot() -> Dictionary:
	return state.duplicate(true)


func find_unit(id: String) -> Dictionary:
	for unit in state.get("heroes", []) + state.get("enemies", []):
		if unit.id == id:
			return unit
	return {}


func find_card(copy_id: int) -> Dictionary:
	for card in state.get("hand", []):
		if card.copy_id == copy_id:
			return card
	return {}


func legal_casters(copy_id: int) -> Array[String]:
	var copy := find_card(copy_id)
	if copy.is_empty():
		return []
	return _casters_for_definition(data.definition("cards", copy.card_id))


func legal_targets(copy_id: int, caster_id: String) -> Array[String]:
	var result: Array[String] = []
	if caster_id not in legal_casters(copy_id):
		return result
	var c: Dictionary = data.definition("cards", find_card(copy_id).card_id)
	var candidates: Array = state.enemies if c.target == "enemy" else state.heroes
	var interrupt_only := _is_pure_interrupt(find_card(copy_id))
	for unit in candidates:
		if unit.hp > 0 and (c.target != "self" or unit.id == caster_id):
			if interrupt_only and not can_interrupt(unit.id):
				continue
			result.append(unit.id)
	return result


func can_interrupt(unit_id: String) -> bool:
	var unit := find_unit(unit_id)
	return (
		not unit.is_empty()
		and not unit.friendly
		and unit.hp > 0
		and unit.intent.get("kind") == "interruptible"
		and unit.immunity == 0
		and not unit.interrupted
	)


func dispel_options(copy_id: int, target_id: String) -> Array[String]:
	var result: Array[String] = []
	var copy := find_card(copy_id)
	var target := find_unit(target_id)
	if copy.is_empty() or target.is_empty():
		return result
	var has_dispel := false
	for effect in data.card_effects(copy.card_id, copy.upgraded):
		has_dispel = has_dispel or effect.kind == "dispel"
	if not has_dispel:
		return result
	for status in target.statuses:
		if data.definition("battle_rules", status, "statuses").get("dispellable", false):
			result.append(status)
	return result


func validate_play(
	copy_id: int, caster_id: String, target_id: String, chosen_status: String = ""
) -> String:
	if _publishing or state.phase != Types.BattlePhase.PLAYER:
		return "error.phase"
	var copy := find_card(copy_id)
	if copy.is_empty():
		return "error.card"
	var c: Dictionary = data.definition("cards", copy.card_id)
	if state.energy < c.cost:
		return "error.energy"
	if caster_id not in legal_casters(copy_id):
		return "error.caster"
	if target_id not in legal_targets(copy_id, caster_id):
		return "error.target"
	var choices := dispel_options(copy_id, target_id)
	if (
		(choices.size() > 1 and chosen_status not in choices)
		or (chosen_status != "" and chosen_status not in choices)
	):
		return "error.dispel"
	return ""


func play_card(
	copy_id: int, caster_id: String, target_id: String, chosen_status: String = ""
) -> String:
	var error := validate_play(copy_id, caster_id, target_id, chosen_status)
	if error != "":
		return error
	_execute_card(copy_id, caster_id, target_id, chosen_status)
	_publish()
	return ""


func preview(
	copy_id: int, caster_id: String, target_id: String, chosen_status: String = ""
) -> Dictionary:
	var error := validate_play(copy_id, caster_id, target_id, chosen_status)
	if error != "":
		return {"error": error}
	var clone: RefCounted = get_script().new(data)
	clone.state = state.duplicate(true)
	clone.rng.seed = rng.seed
	clone.rng.state = rng.state
	clone._execute_card(copy_id, caster_id, target_id, chosen_status)
	var changes: Array = []
	for unit in state.heroes + state.enemies:
		var after: Dictionary = clone.find_unit(unit.id)
		if after != unit:
			changes.append(
				{
					"id": unit.id,
					"name_key": unit.name_key,
					"hp_delta": after.hp - unit.hp,
					"shield_delta": after.shield - unit.shield,
					"threat_delta": after.threat - unit.threat
				}
			)
	return {
		"error": "",
		"changes": changes,
		"records": clone.events.records.duplicate(true),
		"energy": clone.state.energy
	}


func has_playable_card() -> bool:
	if state.phase != Types.BattlePhase.PLAYER:
		return false
	for copy in state.hand:
		for caster_id in legal_casters(copy.copy_id):
			for target_id in legal_targets(copy.copy_id, caster_id):
				var choices := dispel_options(copy.copy_id, target_id)
				if (
					validate_play(
						copy.copy_id,
						caster_id,
						target_id,
						choices[0] if not choices.is_empty() else ""
					)
					== ""
				):
					return true
	return false


func end_turn() -> String:
	if _publishing or state.phase != Types.BattlePhase.PLAYER:
		return "error.phase"
	events.clear()
	state.phase = Types.BattlePhase.RESOLVING
	events.notify("turn_ended", {"turn": state.turn, "units": state.heroes + state.enemies})
	for copy in state.hand.duplicate():
		if not data.definition("cards", copy.card_id).retain:
			state.hand.erase(copy)
			state.discard.append(copy)
	for enemy in state.enemies:
		if enemy.hp <= 0 or enemy.interrupted:
			continue
		refresh_targets()
		var target := find_unit(enemy.target_id)
		if target.is_empty():
			break
		for hit in range(int(enemy.intent.hits)):
			if enemy.hp <= 0 or target.hp <= 0:
				break
			resolver.damage(
				enemy, target, resolver.damage_value(enemy, target, enemy.intent.amount)
			)
		if target.hp > 0 and enemy.intent.status != "":
			resolver.add_status(enemy, target, enemy.intent.status, int(enemy.intent.stacks))
		enemy.interrupt_streak = 0
		if enemy.intent.kind == "interruptible" and enemy.immunity > 0:
			enemy.immunity -= 1
		if _check_end():
			_publish()
			return ""
	# Damage batch completes on both sides before checking defeat or allowing regen.
	for unit in state.heroes + state.enemies:
		for status in ["poison", "burn"]:
			resolver.tick_status(unit, status)
	if not _check_end():
		for unit in state.heroes + state.enemies:
			resolver.tick_status(unit, "regen")
			for status in ["weak", "vulnerable"]:
				if status_count(unit, status) > 0:
					resolver.decay_status(
						unit, status, int(data.definition("battle_rules", status, "statuses").decay)
					)
		_begin_turn()
	_publish()
	return ""


func handle_death(unit: Dictionary) -> void:
	unit.threat = 0
	unit.shield = 0
	unit.statuses.clear()
	events.append("death", {"target": unit.id})
	if unit.friendly:
		for pile in ["hand", "draw", "discard"]:
			for copy in state[pile].duplicate():
				if _casters_for_definition(data.definition("cards", copy.card_id)).is_empty():
					state[pile].erase(copy)
					state.removed.append(copy)
	events.notify("unit_died", {"target": unit})


func refresh_targets() -> void:
	var heroes: Array = state.heroes.filter(func(u: Dictionary) -> bool: return u.hp > 0)
	if heroes.is_empty():
		return
	var highest := 0
	var has_tank := false
	for hero in heroes:
		highest = maxi(highest, int(hero.threat))
		has_tank = has_tank or hero.role == "tank"
	for enemy in state.enemies:
		if enemy.hp <= 0:
			continue
		var previous := find_unit(enemy.target_id)
		if not previous.is_empty() and previous.hp > 0 and previous.threat == highest:
			continue
		for hero in heroes:
			if hero.threat == highest:
				enemy.target_id = hero.id
				if (
					has_tank
					and not previous.is_empty()
					and previous.role == "tank"
					and hero.role != "tank"
				):
					events.append("ot", {"target": hero.id})
				break


func status_count(unit: Dictionary, status: String) -> int:
	var total := 0
	for contribution in unit.get("statuses", {}).get(status, []):
		total += int(contribution.stacks)
	return total


func shuffle(items: Array) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var value = items[i]
		items[i] = items[j]
		items[j] = value


func draw_cards(count: int) -> void:
	for i in range(count):
		if state.hand.size() >= int(data.rule("hand_limit")):
			break
		if state.draw.is_empty():
			state.draw = state.discard
			state.discard = []
			shuffle(state.draw)
		if state.draw.is_empty():
			break
		state.hand.append(state.draw.pop_back())


func _casters_for_definition(c: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for hero in state.heroes:
		if (
			hero.hp > 0
			and (c.owner == "" or c.owner == hero.definition_id)
			and (c.role == "" or c.role == hero.role)
		):
			result.append(hero.id)
	return result


func _is_pure_interrupt(copy: Dictionary) -> bool:
	var effects: Array = data.card_effects(copy.card_id, copy.upgraded)
	if effects.is_empty():
		return false
	for effect in effects:
		if effect.kind != "interrupt":
			return false
	return true


func _execute_card(
	copy_id: int, caster_id: String, target_id: String, chosen_status: String
) -> void:
	events.clear()
	state.phase = Types.BattlePhase.RESOLVING
	var copy := find_card(copy_id)
	var c: Dictionary = data.definition("cards", copy.card_id)
	var caster := find_unit(caster_id)
	var target := find_unit(target_id)
	var options := dispel_options(copy_id, target_id)
	if options.size() == 1:
		chosen_status = options[0]
	state.energy -= int(c.cost)
	state.hand.erase(copy)
	var effects: Array = events.prepare_card(
		caster, target, c, data.card_effects(c.id, copy.upgraded)
	)
	resolver.apply_card(caster, target, effects, chosen_status)
	# Played cards cannot be drawn again until their whole action has finished.
	if c.exhaust:
		state.exhaust.append(copy)
	else:
		state.discard.append(copy)
	if not c.exhaust and _casters_for_definition(c).is_empty():
		state.discard.erase(copy)
		state.removed.append(copy)
	events.notify(
		"card_resolved", {"caster": caster, "target": target, "definition": c, "copy": copy}
	)
	if not _check_end():
		state.phase = Types.BattlePhase.PLAYER


func _begin_turn() -> void:
	state.turn += 1
	state.energy = int(data.rule("base_energy"))
	for unit in state.heroes + state.enemies:
		unit.shield = 0
	for enemy in state.enemies:
		if enemy.hp <= 0:
			continue
		enemy.interrupted = false
		var intents: Array = data.enemy_intents(enemy.definition_id)
		enemy.intent = intents[(state.turn - 1) % intents.size()].duplicate(true)
	draw_cards(int(data.rule("draw_count")))
	refresh_targets()
	events.notify("turn_started", {"turn": state.turn, "units": state.heroes + state.enemies})
	state.phase = Types.BattlePhase.PLAYER
	events.append("start", {"turn": state.turn})


func _check_end() -> bool:
	var living_heroes: Array = state.heroes.filter(func(u: Dictionary) -> bool: return u.hp > 0)
	var living_enemies: Array = state.enemies.filter(func(u: Dictionary) -> bool: return u.hp > 0)
	if not living_heroes.is_empty() and not living_enemies.is_empty():
		return false
	var victory := not living_heroes.is_empty()
	state.phase = Types.BattlePhase.WON if victory else Types.BattlePhase.LOST
	for unit in state.heroes + state.enemies:
		unit.shield = 0
		unit.statuses.clear()
		unit.threat = 0
	events.notify("battle_ended", {"victory": victory, "units": state.heroes + state.enemies})
	events.append("win" if victory else "loss")
	return true


func _publish() -> void:
	if _publishing:
		return
	var result := snapshot()
	var records := events.records.duplicate(true)
	var result_phase: int = result.phase
	# Signal callbacks can replace the run's battle. Publish this action's captured
	# result once and reject new commands on this engine until callbacks return.
	_publishing = true
	settled.emit(records, result)
	if result_phase in [Types.BattlePhase.WON, Types.BattlePhase.LOST]:
		battle_ended.emit(result_phase == Types.BattlePhase.WON)
	_publishing = false
