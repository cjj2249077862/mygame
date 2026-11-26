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
	if context.target.id == context.caster.id:
		_apply_first_bonus(context, "first_shield", "shield")


func _first_heal(context: Dictionary) -> void:
	if context.definition.target in ["ally", "self"]:
		_apply_first_bonus(context, "first_heal", "heal")


func _apply_first_bonus(context: Dictionary, passive: String, effect_kind: String) -> void:
	var caster: Dictionary = context.caster
	if caster.passive_used or caster.passive != passive:
		return
	for effect in context.effects:
		if effect.kind == effect_kind:
			# Consume on successful casting, even if actual recovery/damage is zero.
			caster.passive_used = true
			effect["first_bonus"] = caster.passive_amount
			break
