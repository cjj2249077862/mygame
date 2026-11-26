extends RefCounted

# One ordered record stream per operation. UI receives it only after settlement.
var records: Array[Dictionary] = []


func clear() -> void:
	records.clear()


func append(kind: String, payload: Dictionary = {}) -> void:
	var record := payload.duplicate(true)
	record["kind"] = kind
	record["sequence"] = records.size()
	records.append(record)


func prepare_card(caster: Dictionary, definition: Dictionary, effects: Array) -> Array:
	var resolved: Array = effects.duplicate(true)
	if caster.passive_used:
		return resolved
	for effect in resolved:
		var eligible: bool = (
			(
				caster.passive == "first_damage"
				and definition.target == "enemy"
				and effect.kind == "damage"
			)
			or (
				caster.passive == "first_shield"
				and definition.target == "self"
				and effect.kind == "shield"
			)
			or (
				caster.passive == "first_heal"
				and definition.target == "ally"
				and effect.kind == "heal"
			)
		)
		if eligible:
			# Consume on successful casting, even if actual recovery/damage is zero.
			caster.passive_used = true
			effect["first_bonus"] = caster.passive_amount
			break
	return resolved
