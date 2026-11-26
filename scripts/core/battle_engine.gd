extends RefCounted

signal settled(records: Array, snapshot: Dictionary)
signal battle_ended(victory: bool)

const Types = preload("res://scripts/core/enums.gd")
const Models = preload("res://scripts/core/models.gd")
const Events = preload("res://scripts/core/battle_events.gd")
const Resolver = preload("res://scripts/core/effect_resolver.gd")
const STATE_INTEGERS = [
	"phase",
	"turn",
	"energy",
	"action_serial",
	"next_enemy_index",
	"next_mark_index",
	"card_damage_bonus"
]
const UNIT_INTEGERS = [
	"hp",
	"max_hp",
	"strength",
	"shield",
	"threat",
	"passive_amount",
	"death_serial",
	"revives_used",
	"revive_limit",
	"spawn_turn",
	"interrupt_streak",
	"immunity",
	"interrupt_threshold",
	"immunity_count",
	"intent_index"
]

var data: RefCounted
var rng := RandomNumberGenerator.new()
var events := Events.new()
var resolver: RefCounted
var state: Dictionary = {"phase": Types.BattlePhase.IDLE}
var external_block_reason := ""
var _publishing := false
var _draining_deaths := false


func _init(game_data: RefCounted) -> void:
	data = game_data
	events.attach(self)
	resolver = Resolver.new(self)


func start(
	party: Array,
	deck: Array,
	encounter_id: String,
	random: RandomNumberGenerator,
	relic_ids: Array = []
) -> void:
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
		"encounter_id": encounter_id,
		"relic_ids": relic_ids.duplicate(),
		"relic_counters": {},
		"action_serial": 0,
		"next_enemy_index": 0,
		"next_mark_index": 0,
		"pending_explosions": [],
		"pending_deaths": [],
		"card_damage_bonus": 0,
	}
	for pile in Types.PILES:
		state[pile] = []
	state.draw = deck.duplicate(true)
	for hero in state.heroes:
		hero.shield = 0
		hero.statuses = {}
		hero.damage_reductions = []
		hero.marks = []
		hero.death_serial = 0
		hero.death_handled = false
		hero.revives_used = 0
		hero.revive_limit = int(
			data.definition("battle_rules", "combat_revive_limit").get("value", 1)
		)
		hero.spawn_turn = 0
		hero.phases_triggered = []
		hero.phases_pending = []
		hero.intent_pool = ""
		hero.pending_intent_pool = ""
		hero.intent_index = 0
		hero.enraged = false
		hero.threat = int(
			data.rule("initial_tank_threat" if hero.role == "tank" else "initial_other_threat")
		)
	var encounter: Dictionary = data.definition("encounters", encounter_id)
	for enemy_id in encounter.enemies.split(","):
		var definition: Dictionary = data.definition("encounters", enemy_id, "enemies")
		state.enemies.append(Models.unit(definition, "enemy_%d" % state.enemies.size(), false))
	state.next_enemy_index = state.enemies.size()
	shuffle(state.draw)
	_begin_turn()
	_publish()


func snapshot() -> Dictionary:
	return state.duplicate(true)


func restore(saved_state: Dictionary, random: RandomNumberGenerator, relic_ids: Array = []) -> bool:
	# SaveManager owns file/version validation and RNG restoration. Accept only
	# complete action boundaries, never replay initialization, rules or rewards.
	if _publishing or not can_restore(saved_state):
		return false
	if not relic_ids.is_empty() and saved_state.relic_ids != relic_ids:
		return false
	var restored: Dictionary = saved_state.duplicate(true)
	for key in STATE_INTEGERS:
		restored[key] = int(restored[key])
	for unit in restored.heroes + restored.enemies:
		if not unit.has("damage_reductions"):
			unit["damage_reductions"] = []
		for key in UNIT_INTEGERS:
			unit[key] = int(unit[key])
		for status in unit.statuses:
			for contribution in unit.statuses[status]:
				contribution.stacks = int(contribution.stacks)
				if contribution.has("per_stack"):
					contribution.per_stack = int(contribution.per_stack)
		for mark in unit.marks:
			for key in ["id", "remaining", "first_tick_turn", "amount"]:
				mark[key] = int(mark[key])
		for key in ["hits", "stacks", "order"]:
			if unit.intent.has(key):
				unit.intent[key] = int(unit.intent[key])
	for pile in Types.PILES:
		for copy in restored[pile]:
			copy.copy_id = int(copy.copy_id)
	for key in restored.relic_counters:
		restored.relic_counters[key] = int(restored.relic_counters[key])
	state = restored
	rng = random
	events.clear()
	return true


func can_restore(saved: Dictionary) -> bool:
	if not _serializable(saved):
		return false
	if (
		saved.get("phase", -1)
		not in [Types.BattlePhase.PLAYER, Types.BattlePhase.WON, Types.BattlePhase.LOST]
	):
		return false
	for key in ["heroes", "enemies"] + Types.PILES:
		if not saved.get(key) is Array:
			return false
	for key in STATE_INTEGERS:
		if not _whole_number(saved.get(key), 0):
			return false
	if (
		saved.turn < 1
		or saved.heroes.size() != int(data.rule("party_size"))
		or saved.enemies.is_empty()
	):
		return false
	if not saved.get("relic_ids") is Array or not saved.get("relic_counters") is Dictionary:
		return false
	for key in ["pending_explosions", "pending_deaths"]:
		if not saved.get(key) is Array or not saved[key].is_empty():
			return false
	for count in saved.relic_counters.values():
		if not _whole_number(count, 0):
			return false
	if (
		not saved.get("encounter_id") is String
		or data.definition("encounters", saved.encounter_id).is_empty()
	):
		return false
	var unit_ids: Dictionary = {}
	var living_heroes := 0
	var living_enemies := 0
	var highest_enemy_index := -1
	var seen_heroes: Dictionary = {}
	for units in [saved.heroes, saved.enemies]:
		var friendly: bool = units == saved.heroes
		for unit in units:
			if not unit is Dictionary or not _valid_saved_unit(unit, friendly):
				return false
			if unit_ids.has(unit.id):
				return false
			unit_ids[unit.id] = unit
			if friendly:
				if seen_heroes.has(unit.definition_id):
					return false
				seen_heroes[unit.definition_id] = true
				living_heroes += 1 if unit.hp > 0 else 0
			else:
				if (
					not unit.id.begins_with("enemy_")
					or not unit.id.trim_prefix("enemy_").is_valid_int()
				):
					return false
				highest_enemy_index = maxi(highest_enemy_index, int(unit.id.trim_prefix("enemy_")))
				living_enemies += 1 if unit.hp > 0 else 0
	if saved.next_enemy_index <= highest_enemy_index:
		return false
	if saved.phase == Types.BattlePhase.PLAYER and (living_heroes == 0 or living_enemies == 0):
		return false
	if saved.phase == Types.BattlePhase.WON and (living_heroes == 0 or living_enemies > 0):
		return false
	if saved.phase == Types.BattlePhase.LOST and living_heroes > 0:
		return false
	var mark_ids: Dictionary = {}
	for unit in unit_ids.values():
		if unit.spawn_turn > saved.turn:
			return false
		if (
			unit.target_id != ""
			and (not unit_ids.has(unit.target_id) or not unit_ids[unit.target_id].friendly)
		):
			return false
		for status in unit.statuses:
			for contribution in unit.statuses[status]:
				if not unit_ids.has(contribution.source):
					return false
		for mark in unit.marks:
			if (
				not mark is Dictionary
				or mark.get("kind") != "bomb"
				or not mark.get("source_id") is String
			):
				return false
			for key in ["id", "remaining", "first_tick_turn", "amount"]:
				if not _whole_number(
					mark.get(key), 1 if key in ["remaining", "first_tick_turn"] else 0
				):
					return false
			if (
				mark_ids.has(int(mark.id))
				or mark.id >= saved.next_mark_index
				or not unit_ids.has(mark.source_id)
			):
				return false
			if not unit.friendly or unit.hp <= 0 or unit_ids[mark.source_id].friendly:
				return false
			mark_ids[int(mark.id)] = true
		if (
			not unit.friendly
			and unit.hp > 0
			and unit.spawn_turn < saved.turn
			and unit.intent.is_empty()
		):
			return false
	var copy_ids: Dictionary = {}
	for pile in Types.PILES:
		for copy in saved[pile]:
			if not copy is Dictionary or not _whole_number(copy.get("copy_id"), 0):
				return false
			if (
				copy_ids.has(int(copy.copy_id))
				or not copy.get("card_id") is String
				or not copy.get("upgraded") is bool
			):
				return false
			if data.definition("cards", copy.card_id).is_empty():
				return false
			copy_ids[int(copy.copy_id)] = true
	var seen_relics: Dictionary = {}
	for relic_id in saved.relic_ids:
		if (
			not relic_id is String
			or seen_relics.has(relic_id)
			or data.definition("relics", relic_id).is_empty()
		):
			return false
		seen_relics[relic_id] = true
	return true


func _valid_saved_unit(unit: Dictionary, friendly: bool) -> bool:
	for key in [
		"id",
		"definition_id",
		"name_key",
		"role",
		"passive",
		"portrait",
		"target_id",
		"intent_pool",
		"pending_intent_pool"
	]:
		if not unit.get(key) is String:
			return false
	for key in ["friendly", "passive_used", "interrupted", "death_handled", "enraged"]:
		if not unit.get(key) is bool:
			return false
	if unit.friendly != friendly or unit.id == "":
		return false
	var definition: Dictionary = (
		data.definition("characters", unit.definition_id)
		if friendly
		else data.definition("encounters", unit.definition_id, "enemies")
	)
	if definition.is_empty():
		return false
	for key in UNIT_INTEGERS:
		if not _whole_number(unit.get(key), 0):
			return false
	if unit.max_hp < 1 or unit.hp > unit.max_hp or unit.revives_used > unit.revive_limit:
		return false
	if unit.death_handled != (unit.hp == 0):
		return false
	for key in ["marks", "phases_triggered", "phases_pending"]:
		if not unit.get(key) is Array:
			return false
	if not unit.phases_pending.is_empty():
		return false
	var phase_ids: Array[String] = []
	for phase in data.enemy_phases(unit.definition_id):
		phase_ids.append(phase.id)
	var seen_phases: Dictionary = {}
	for phase_id in unit.phases_triggered:
		if not phase_id is String or phase_id not in phase_ids or seen_phases.has(phase_id):
			return false
		seen_phases[phase_id] = true
	for key in ["statuses", "intent"]:
		if not unit.get(key) is Dictionary:
			return false
	for status in unit.statuses:
		if (
			data.definition("battle_rules", status, "statuses").is_empty()
			or not unit.statuses[status] is Array
		):
			return false
		for contribution in unit.statuses[status]:
			if (
				not contribution is Dictionary
				or not contribution.get("source") is String
				or not _whole_number(contribution.get("stacks"), 1)
			):
				return false
			if not _nonnegative_number(contribution.get("multiplier")):
				return false
			if contribution.has("per_stack") and not _whole_number(contribution.per_stack, 0):
				return false
	if unit.has("damage_reductions"):
		if not unit.damage_reductions is Array:
			return false
		for reduction in unit.damage_reductions:
			if not _nonnegative_number(reduction) or reduction > 1:
				return false
	if not unit.intent.is_empty():
		if unit.intent.get("kind") not in ["normal", "interruptible", "uninterruptible"]:
			return false
		for key in ["hits", "order"]:
			if not _whole_number(unit.intent.get(key), 1):
				return false
		if (
			not _whole_number(unit.intent.get("stacks"), 0)
			or not _nonnegative_number(unit.intent.get("amount"))
		):
			return false
		if not unit.intent.get("status") is String:
			return false
		if (
			unit.intent.status != ""
			and data.definition("battle_rules", unit.intent.status, "statuses").is_empty()
		):
			return false
		if (unit.intent.status == "") != (unit.intent.stacks == 0):
			return false
		for key in ["pool_id", "target_rule", "effect_group"]:
			if unit.intent.has(key) and not unit.intent[key] is String:
				return false
		if unit.intent.get("target_rule", "threat") not in ["threat", "lowest_hp_ratio"]:
			return false
		if (
			unit.intent.get("effect_group", "") != ""
			and data.encounter_effects(unit.intent.effect_group).is_empty()
		):
			return false
	if not friendly:
		if data.enemy_intents(unit.definition_id, unit.intent_pool).is_empty():
			return false
		if (
			unit.pending_intent_pool != ""
			and data.enemy_intents(unit.definition_id, unit.pending_intent_pool).is_empty()
		):
			return false
	return true


func _whole_number(value: Variant, minimum: int) -> bool:
	return (
		_nonnegative_number(value)
		and value >= minimum
		and value <= 9007199254740991
		and int(value) == value
	)


func _nonnegative_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= 0


func _serializable(value: Variant) -> bool:
	if value == null or value is bool or value is int or value is String:
		return true
	if value is float:
		return is_finite(value)
	if value is Array:
		for item in value:
			if not _serializable(item):
				return false
		return true
	if value is Dictionary:
		for key in value:
			if not key is String or not _serializable(value[key]):
				return false
		return true
	return false


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
	if c.target == "none":
		return [caster_id]
	var candidates: Array = state.enemies if c.target == "enemy" else state.heroes
	var interrupt_only := _is_pure_interrupt(find_card(copy_id))
	for unit in candidates:
		if c.target == "dead_ally":
			if can_revive(unit.id):
				result.append(unit.id)
			continue
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


func can_revive(unit_id: String) -> bool:
	var unit := find_unit(unit_id)
	return (
		not unit.is_empty()
		and unit.friendly
		and unit.hp <= 0
		and unit.death_handled
		and int(unit.revives_used) < int(unit.revive_limit)
	)


func restore_removed_cards() -> void:
	var restored := false
	for copy in state.removed.duplicate():
		if not _casters_for_definition(data.definition("cards", copy.card_id)).is_empty():
			state.removed.erase(copy)
			state.draw.append(copy)
			restored = true
	if restored:
		shuffle(state.draw)


func spawn_enemy(enemy_id: String) -> Dictionary:
	var definition: Dictionary = data.definition("encounters", enemy_id, "enemies")
	if (
		definition.is_empty()
		or state.phase in [Types.BattlePhase.IDLE, Types.BattlePhase.WON, Types.BattlePhase.LOST]
	):
		return {}
	var unit: Dictionary = Models.unit(definition, "enemy_%d" % int(state.next_enemy_index), false)
	state.next_enemy_index += 1
	unit.spawn_turn = state.turn
	state.enemies.append(unit)
	refresh_targets()
	events.append("summon", {"target": unit.id})
	events.notify("unit_summoned", {"target": unit})
	return unit


func share_participants(target_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var target := find_unit(target_id)
	if target.is_empty() or not target.friendly or target.hp <= 0:
		return result
	var slot: int = state.heroes.find(target)
	result.append(target)
	# Keep the three physical slots, including dead occupants. The named target
	# receives the first remainder; other participants follow left-to-right order.
	for index in range(maxi(0, slot - 1), mini(state.heroes.size(), slot + 2)):
		var ally: Dictionary = state.heroes[index]
		if ally.id != target_id and ally.hp > 0:
			result.append(ally)
	return result


func effect_targets(
	source: Dictionary, selected: Dictionary, effect: Dictionary, context: Dictionary = {}
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var candidates: Array = []
	match effect.get("target", "selected"):
		"selected":
			candidates = [selected]
		"self":
			candidates = [source]
		"all_allies":
			candidates = state.heroes if source.get("friendly", true) else state.enemies
		"all_enemies":
			candidates = state.enemies if source.get("friendly", true) else state.heroes
		"event_source":
			candidates = [context.get("source", source)]
		"event_target":
			candidates = [context.get("target", selected)]
	for unit in candidates:
		if unit.is_empty():
			continue
		if context.has("target_role") and unit.role != context.target_role:
			continue
		if unit.hp > 0 or (effect.kind == "revive" and can_revive(unit.id)):
			result.append(unit)
	return result


func action_targets(copy_id: int, caster_id: String, target_id: String) -> Array[String]:
	var result: Array[String] = []
	var copy := find_card(copy_id)
	if copy.is_empty() or caster_id not in legal_casters(copy_id):
		return result
	var caster := find_unit(caster_id)
	var selected := find_unit(target_id)
	for effect in data.card_effects(copy.card_id, copy.upgraded):
		for target in effect_targets(caster, selected, effect):
			if target.id not in result:
				result.append(target.id)
	return result


func intent_preview(enemy_id: String) -> Dictionary:
	var enemy := find_unit(enemy_id)
	if enemy.is_empty() or enemy.friendly:
		return {}
	var description: Array[String] = []
	var target_ids: Array[String] = []
	var target := find_unit(enemy.target_id)
	for effect in _enemy_effects(enemy):
		var preview_effect: Dictionary = effect.duplicate(true)
		var targets := effect_targets(enemy, target, effect)
		for unit in targets:
			if unit.id not in target_ids:
				target_ids.append(unit.id)
		if effect.kind == "damage":
			for unit in targets:
				preview_effect.amount = resolver.damage_value(enemy, unit, effect.amount)
				description.append(
					data.text(unit.name_key) + "：" + data.effect_text(preview_effect)
				)
		else:
			description.append(data.effect_text(preview_effect))
	var definition: Dictionary = data.definition("encounters", enemy.definition_id, "enemies")
	return {
		"kind": enemy.intent.get("kind", "normal"),
		"target_ids": target_ids,
		"description": "；".join(description),
		"interruptible": enemy.intent.get("kind") == "interruptible",
		"immune": enemy.immunity > 0,
		"boss_phase": enemy.phases_triggered.size() + 1 if definition.get("kind") == "boss" else 0,
		"enrage_turn": int(definition.get("enrage_turn", 0)),
		"enraged": enemy.enraged,
	}


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
	for mark in target.marks:
		if mark.kind == "bomb" and "bomb" not in result:
			result.append("bomb")
	return result


func validate_play(
	copy_id: int, caster_id: String, target_id: String, chosen_status: String = ""
) -> String:
	if external_block_reason != "":
		return external_block_reason
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
		"target_ids": action_targets(copy_id, caster_id, target_id),
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
	if external_block_reason != "":
		return external_block_reason
	if _publishing or state.phase != Types.BattlePhase.PLAYER:
		return "error.phase"
	events.clear()
	state.phase = Types.BattlePhase.RESOLVING
	events.notify("turn_ended", {"turn": state.turn, "units": state.heroes + state.enemies})
	for copy in state.hand.duplicate():
		if not data.definition("cards", copy.card_id).retain:
			state.hand.erase(copy)
			state.discard.append(copy)
	for enemy in state.enemies.duplicate():
		if enemy.hp <= 0 or enemy.interrupted or enemy.spawn_turn >= state.turn:
			continue
		state.action_serial += 1
		refresh_targets()
		var target := find_unit(enemy.target_id)
		if target.is_empty():
			break
		var source_death: int = enemy.death_serial
		resolver.apply_effects(enemy, target, _enemy_effects(enemy), "", "enemy")
		if enemy.hp > 0 and enemy.death_serial == source_death:
			enemy.interrupt_streak = 0
			if enemy.intent.kind == "interruptible" and enemy.immunity > 0:
				enemy.immunity -= 1
		if settle_boundary():
			_publish()
			return ""
	# Damage batch completes on both sides before checking defeat or allowing regen.
	state.action_serial += 1
	for unit in state.heroes + state.enemies:
		for status in ["poison", "burn"]:
			resolver.tick_status(unit, status)
	_tick_bombs()
	if not settle_boundary():
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
	if unit.hp > 0 or unit.death_handled:
		return
	unit.death_handled = true
	unit.death_serial += 1
	unit.threat = 0
	unit.shield = 0
	unit.statuses.clear()
	unit.damage_reductions.clear()
	unit.phases_pending.clear()
	for mark in unit.marks:
		if mark.kind == "bomb":
			state.pending_explosions.append({"carrier_id": unit.id, "mark": mark.duplicate(true)})
	unit.marks.clear()
	events.append("death", {"target": unit.id})
	if unit.friendly:
		for pile in ["hand", "draw", "discard"]:
			for copy in state[pile].duplicate():
				if _casters_for_definition(data.definition("cards", copy.card_id)).is_empty():
					state[pile].erase(copy)
					state.removed.append(copy)
	state.pending_deaths.append({"id": unit.id, "death_serial": unit.death_serial})
	_flush_death_chain()


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
		if enemy.intent.get("target_rule", "threat") == "lowest_hp_ratio":
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
	state.action_serial += 1
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
	if not settle_boundary():
		state.phase = Types.BattlePhase.PLAYER


func _begin_turn() -> void:
	state.turn += 1
	var resources: Dictionary = {
		"energy": int(data.rule("base_energy")),
		"draw": int(data.rule("draw_count")),
		"damage_bonus": 0,
	}
	events.notify("base_resources", resources)
	state.energy = maxi(0, int(resources.energy))
	state.card_damage_bonus = int(resources.damage_bonus)
	for unit in state.heroes + state.enemies:
		unit.shield = 0
		unit.passive_used = false
	if state.turn == 1:
		events.notify("battle_started", {"units": state.heroes + state.enemies})
	events.notify("turn_started", {"turn": state.turn, "units": state.heroes + state.enemies})
	for enemy in state.enemies:
		if enemy.hp <= 0 or enemy.spawn_turn >= state.turn:
			continue
		enemy.interrupted = false
		if enemy.pending_intent_pool != "":
			enemy.intent_pool = enemy.pending_intent_pool
			enemy.pending_intent_pool = ""
			enemy.intent_index = 0
		var definition: Dictionary = data.definition("encounters", enemy.definition_id, "enemies")
		var enrage_turn: int = int(definition.get("enrage_turn", 0))
		if enrage_turn > 0 and state.turn >= enrage_turn and not enemy.enraged:
			enemy.enraged = true
			events.append("enrage", {"target": enemy.id})
		var intents: Array = data.enemy_intents(enemy.definition_id, enemy.intent_pool)
		enemy.intent = intents[int(enemy.intent_index) % intents.size()].duplicate(true)
		enemy.intent_index += 1
		if enemy.intent.get("target_rule", "threat") == "lowest_hp_ratio":
			enemy.target_id = _lowest_health_target()
	draw_cards(maxi(0, int(resources.draw)))
	events.notify("cards_drawn", {"turn": state.turn})
	refresh_targets()
	state.phase = Types.BattlePhase.PLAYER
	events.append("start", {"turn": state.turn})


func _lowest_health_target() -> String:
	var chosen := ""
	var lowest := 2.0
	for hero in state.heroes:
		if hero.hp <= 0:
			continue
		var ratio: float = float(hero.hp) / hero.max_hp
		if ratio < lowest:
			lowest = ratio
			chosen = hero.id
	return chosen


func _enemy_effects(enemy: Dictionary) -> Array:
	if enemy.intent.is_empty():
		return []
	var effects: Array = []
	if enemy.intent.get("effect_group", "") != "":
		effects = data.encounter_effects(enemy.intent.effect_group)
	else:
		effects.append(
			{
				"kind": "damage",
				"target": "selected",
				"amount": enemy.intent.amount,
				"hits": enemy.intent.hits,
				"threat_mult": 1.0,
				"status": "",
				"duration": 0
			}
		)
		if enemy.intent.get("status", "") != "":
			effects.append(
				{
					"kind": "apply_status",
					"target": "selected",
					"amount": enemy.intent.stacks,
					"hits": 1,
					"threat_mult": 1.0,
					"status": enemy.intent.status,
					"duration": 0
				}
			)
	if enemy.enraged:
		var definition: Dictionary = data.definition("encounters", enemy.definition_id, "enemies")
		for effect in effects:
			if effect.kind in ["damage", "bomb"]:
				effect.amount = floori(
					float(effect.amount) * float(definition.get("enrage_mult", 1.0))
				)
	return effects


func mark_boss_thresholds(unit: Dictionary) -> void:
	if unit.friendly:
		return
	for phase in data.enemy_phases(unit.definition_id):
		if (
			unit.hp <= unit.max_hp * phase.threshold
			and phase.id not in unit.phases_triggered
			and phase.id not in unit.phases_pending
		):
			unit.phases_pending.append(phase.id)


func settle_boundary() -> bool:
	_flush_death_chain()
	if _check_end():
		return true
	for enemy in state.enemies.duplicate():
		while enemy.hp > 0 and not enemy.phases_pending.is_empty():
			var next_phase: Dictionary = {}
			for phase in data.enemy_phases(enemy.definition_id):
				if phase.id in enemy.phases_pending:
					next_phase = phase
					break
			if next_phase.is_empty():
				break
			enemy.phases_pending.erase(next_phase.id)
			enemy.phases_triggered.append(next_phase.id)
			if next_phase.intent_pool != "":
				enemy.pending_intent_pool = next_phase.intent_pool
			events.append("phase", {"target": enemy.id, "phase": enemy.phases_triggered.size() + 1})
			resolver.apply_effects(
				enemy, enemy, data.encounter_effects(next_phase.enter_effect_group), "", "phase"
			)
			_flush_death_chain()
			if _check_end():
				return true
	return false


func apply_bomb(source: Dictionary, target: Dictionary, amount: int, duration: int) -> bool:
	if (
		source.is_empty()
		or source.friendly
		or target.hp <= 0
		or not target.friendly
		or duration <= 0
	):
		return false
	var mark: Dictionary = {}
	for existing in target.marks:
		if existing.kind == "bomb" and existing.source_id == source.id:
			mark = existing
			break
	if mark.is_empty():
		mark = {"id": int(state.next_mark_index), "kind": "bomb", "source_id": source.id}
		state.next_mark_index += 1
		target.marks.append(mark)
	mark.remaining = duration
	mark.first_tick_turn = int(state.turn) + 1
	mark.amount = amount
	events.append("bomb", {"target": target.id, "amount": amount, "remaining": duration})
	return true


func _tick_bombs() -> void:
	for hero in state.heroes:
		if hero.hp <= 0:
			continue
		for mark in hero.marks.duplicate():
			if mark.kind != "bomb" or state.turn < mark.first_tick_turn:
				continue
			mark.remaining -= 1
			if mark.remaining <= 0:
				hero.marks.erase(mark)
				state.pending_explosions.append(
					{"carrier_id": hero.id, "mark": mark.duplicate(true)}
				)
	_flush_death_chain()


func _flush_death_chain() -> void:
	if _draining_deaths:
		return
	_draining_deaths = true
	while not state.pending_explosions.is_empty() or not state.pending_deaths.is_empty():
		if not state.pending_explosions.is_empty():
			state.pending_explosions.sort_custom(
				func(left: Dictionary, right: Dictionary) -> bool:
					var left_slot: int = _unit_order(left.carrier_id)
					var right_slot: int = _unit_order(right.carrier_id)
					return (
						left.mark.id < right.mark.id
						if left_slot == right_slot
						else left_slot < right_slot
					)
			)
			var explosion: Dictionary = state.pending_explosions.pop_front()
			_explode_bomb(explosion.carrier_id, explosion.mark)
			continue
		# Death notifications (including automatic revival candidates) only run
		# after every already-triggered bomb has completed its death chain.
		state.pending_deaths.sort_custom(
			func(left: Dictionary, right: Dictionary) -> bool:
				return _unit_order(left.id) < _unit_order(right.id)
		)
		var death: Dictionary = state.pending_deaths.pop_front()
		var target := find_unit(death.id)
		events.notify("unit_died", {"target": target, "death_serial": death.death_serial})
	_draining_deaths = false


func _unit_order(unit_id: String) -> int:
	var units: Array = state.heroes + state.enemies
	for index in range(units.size()):
		if units[index].id == unit_id:
			return index
	return units.size()


func _explode_bomb(carrier_id: String, mark: Dictionary) -> void:
	events.append("bomb_explode", {"target": carrier_id, "amount": int(mark.amount)})
	var source := find_unit(mark.source_id)
	var targets: Array = state.heroes.filter(func(unit: Dictionary) -> bool: return unit.hp > 0)
	for target in targets:
		if target.hp > 0:
			resolver.damage(
				source,
				target,
				resolver.target_damage_value(target, mark.amount),
				0,
				false,
				"mechanic"
			)


func _check_end() -> bool:
	if state.phase in [Types.BattlePhase.WON, Types.BattlePhase.LOST]:
		return true
	var living_heroes: Array = state.heroes.filter(func(u: Dictionary) -> bool: return u.hp > 0)
	var living_enemies: Array = state.enemies.filter(func(u: Dictionary) -> bool: return u.hp > 0)
	if not living_heroes.is_empty() and not living_enemies.is_empty():
		return false
	var victory := not living_heroes.is_empty()
	state.phase = Types.BattlePhase.WON if victory else Types.BattlePhase.LOST
	for unit in state.heroes + state.enemies:
		unit.shield = 0
		unit.statuses.clear()
		unit.damage_reductions.clear()
		unit.marks.clear()
		unit.phases_pending.clear()
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
