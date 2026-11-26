extends RefCounted

# Rule responders have a fixed registration order. Method names avoid retaining
# a battle or a bound Callable; preview instances initialize this same table.
const RULE_HANDLERS = {
	"battle_started": ["_reset_passives"],
	"turn_started": ["_reset_passives"],
	"card_played": ["_first_damage", "_first_shield", "_first_heal"],
}

# Presentation records are separate from synchronous rule notifications.
# UI receives this stream only after the entire action has settled.
var records: Array[Dictionary] = []
var _owner: WeakRef


func attach(engine: RefCounted) -> void:
	_owner = weakref(engine)


func clear() -> void:
	records.clear()


func append(kind: String, payload: Dictionary = {}) -> void:
	var record := payload.duplicate(true)
	record["kind"] = kind
	record["sequence"] = records.size()
	records.append(record)


func notify(kind: String, context: Dictionary) -> void:
	# Context is borrowed for this call only. A responder and any nested rule
	# notifications finish before the next responder or the publisher can run.
	for method in RULE_HANDLERS.get(kind, []):
		call(method, context)
	_dispatch_relics(kind, context)


func prepare_card(
	caster: Dictionary, target: Dictionary, definition: Dictionary, effects: Array
) -> Array:
	var resolved: Array = effects.duplicate(true)
	notify(
		"card_played",
		{"caster": caster, "target": target, "definition": definition, "effects": resolved}
	)
	return resolved


func _reset_passives(context: Dictionary) -> void:
	for unit in context.units:
		unit.passive_used = false


func _first_damage(context: Dictionary) -> void:
	if context.definition.target == "enemy":
		_apply_first_bonus(context, "first_damage", "damage")


func _first_shield(context: Dictionary) -> void:
	_apply_first_bonus(context, "first_shield", "shield")


func _first_heal(context: Dictionary) -> void:
	if context.definition.target in ["ally", "self"]:
		_apply_first_bonus(context, "first_heal", "heal")


func _apply_first_bonus(context: Dictionary, passive: String, effect_kind: String) -> void:
	var caster: Dictionary = context.caster
	if caster.passive_used or caster.passive != passive:
		return
	var index := _eligible_first_effect(context, effect_kind)
	if index < 0:
		return
	# Consume on successful casting, even if actual recovery/damage is zero.
	caster.passive_used = true
	_add_first_bonus(context, index, int(caster.passive_amount))


func _eligible_first_effect(context: Dictionary, effect_kind: String) -> int:
	for index in range(context.effects.size()):
		var effect: Dictionary = context.effects[index]
		if effect.kind != effect_kind:
			continue
		var scope: String = effect.get("target", "selected")
		if effect_kind == "shield":
			if (
				scope in ["self", "all_allies"]
				or (scope == "selected" and context.target.id == context.caster.id)
			):
				return index
		elif (
			effect_kind == "damage" and context.definition.target == "enemy" and scope == "selected"
		):
			return index
		elif (
			effect_kind == "heal"
			and context.definition.target in ["ally", "self"]
			and scope in ["selected", "self"]
		):
			return index
	return -1


func _add_first_bonus(context: Dictionary, index: int, amount: int) -> void:
	var effect: Dictionary = context.effects[index]
	effect["first_bonus"] = int(effect.get("first_bonus", 0)) + amount
	if effect.kind == "shield":
		effect["first_bonus_target"] = context.caster.id


func _dispatch_relics(kind: String, context: Dictionary) -> void:
	if _owner == null:
		return
	var engine: RefCounted = _owner.get_ref()
	if engine == null:
		return
	for trigger in engine.data.relic_triggers(engine.state.get("relic_ids", []), kind):
		if not _qualifies(trigger, context, engine):
			continue
		var effects: Array = engine.data.relic_effects(trigger.effect_group)
		var bonus_indices: Dictionary = {}
		var eligible := true
		for effect in effects:
			if (
				effect.kind == "revive"
				and not engine.can_revive(context.get("target", {}).get("id", ""))
			):
				eligible = false
				break
			if effect.kind in ["first_damage_bonus", "first_shield_bonus", "first_heal_bonus"]:
				var effect_kind: String = effect.kind.trim_prefix("first_").trim_suffix("_bonus")
				var index := _eligible_first_effect(context, effect_kind)
				if index < 0:
					eligible = false
					break
				bonus_indices[effect.id] = index
		if not eligible or not _take_opportunity(trigger, context, engine):
			continue
		for effect in effects:
			match effect.kind:
				"first_damage_bonus", "first_shield_bonus", "first_heal_bonus":
					_add_first_bonus(context, int(bonus_indices[effect.id]), int(effect.amount))
				"base_energy":
					context.energy += int(effect.amount)
				"base_draw":
					context.draw += int(effect.amount)
				"base_damage_bonus":
					context.damage_bonus += int(effect.amount)
				_:
					var source: Dictionary = context.get("source", context.get("caster", {}))
					var target: Dictionary = context.get("target", {})
					var effect_context: Dictionary = context.duplicate()
					if trigger.qualifier.begins_with("role:") and kind != "card_played":
						effect_context["target_role"] = trigger.qualifier.trim_prefix("role:")
					engine.resolver.apply_effects(
						source, target, [effect], "", "relic", effect_context
					)


func _qualifies(trigger: Dictionary, context: Dictionary, engine: RefCounted) -> bool:
	var qualifier: String = trigger.qualifier
	if qualifier == "first_turn":
		return engine.state.turn == 1
	if qualifier == "victory":
		return bool(context.get("victory", false))
	if qualifier == "card_success":
		var source: Dictionary = context.get("source", {})
		return (
			context.get("origin", "") == "card"
			and context.get("success", false)
			and source.get("friendly", false)
		)
	if qualifier.begins_with("role:") and trigger.event == "card_played":
		return context.caster.role == qualifier.trim_prefix("role:")
	return qualifier == "all" or qualifier.begins_with("role:")


func _take_opportunity(trigger: Dictionary, context: Dictionary, engine: RefCounted) -> bool:
	if trigger.limit_scope == "none" or int(trigger.limit_count) == 0:
		return true
	var key: String = trigger.id
	match trigger.limit_scope:
		"turn":
			key += "|turn:%d" % int(engine.state.turn)
		"actor_turn":
			key += "|turn:%d|actor:%s" % [int(engine.state.turn), context.caster.id]
		"card_target":
			key += "|action:%d|target:%s" % [int(engine.state.action_serial), context.target.id]
	var count: int = int(engine.state.relic_counters.get(key, 0))
	if count >= int(trigger.limit_count):
		return false
	engine.state.relic_counters[key] = count + 1
	return true
