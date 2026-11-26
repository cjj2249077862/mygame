extends RefCounted

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


static func normalize_saved_units(saved: Array) -> Array:
	# This copies known field types only; callers still own schema/phase validation.
	# Never normalize every whole float: multipliers and damage reductions are floats.
	var units := saved.duplicate(true)
	for entry in units:
		if not entry is Dictionary:
			continue
		var unit: Dictionary = entry
		_normalize_integer_fields(unit, UNIT_INTEGERS)
		if unit.get("intent") is Dictionary:
			unit["intent"] = normalize_intent(unit.intent)
		if unit.get("statuses") is Dictionary:
			for contributions in unit.statuses.values():
				if not contributions is Array:
					continue
				for contribution in contributions:
					if not contribution is Dictionary:
						continue
					_normalize_integer_fields(contribution, ["stacks", "per_stack"])
					_normalize_float_field(contribution, "multiplier")
		if unit.get("marks") is Array:
			for mark in unit.marks:
				if mark is Dictionary:
					_normalize_integer_fields(
						mark, ["id", "remaining", "first_tick_turn", "amount"]
					)
		if not unit.has("damage_reductions"):
			unit["damage_reductions"] = []
		if unit.damage_reductions is Array:
			for index in range(unit.damage_reductions.size()):
				var reduction: Variant = unit.damage_reductions[index]
				if reduction is int or reduction is float:
					unit.damage_reductions[index] = float(reduction)
	return units


static func normalize_intent(definition: Dictionary) -> Dictionary:
	# Both new intents and restored intents use this representation. Amount may
	# remain fractional; normalization must not truncate invalid integer fields.
	var intent := definition.duplicate(true)
	_normalize_integer_fields(intent, ["hits", "stacks", "order"])
	_normalize_float_field(intent, "amount")
	return intent


static func _normalize_integer_fields(record: Dictionary, fields: Array) -> void:
	for key in fields:
		var value: Variant = record.get(key)
		if (
			(value is int or value is float)
			and is_finite(float(value))
			and absf(float(value)) <= 9007199254740991
			and floorf(float(value)) == float(value)
		):
			record[key] = int(value)


static func _normalize_float_field(record: Dictionary, key: String) -> void:
	var value: Variant = record.get(key)
	if value is int or value is float:
		record[key] = float(value)


static func card(copy_id: int, definition_id: String, upgraded: bool = false) -> Dictionary:
	return {"copy_id": copy_id, "card_id": definition_id, "upgraded": upgraded}


static func unit(definition: Dictionary, instance_id: String, friendly: bool) -> Dictionary:
	return {
		"id": instance_id,
		"definition_id": definition.id,
		"friendly": friendly,
		"role": definition.get("role", ""),
		"name_key": definition.name_key,
		"max_hp": int(definition.max_hp),
		"hp": int(definition.max_hp),
		"strength": int(definition.strength),
		"shield": 0,
		"threat": 0,
		"statuses": {},
		"damage_reductions": [],
		"marks": [],
		"death_serial": 0,
		"death_handled": false,
		"revives_used": 0,
		"revive_limit": 1,
		"spawn_turn": 0,
		"phases_triggered": [],
		"phases_pending": [],
		"intent_pool": "",
		"pending_intent_pool": "",
		"intent_index": 0,
		"enraged": false,
		"passive": definition.get("passive", ""),
		"passive_amount": int(definition.get("passive_amount", 0)),
		"passive_used": false,
		"portrait": definition.get("portrait", ""),
		"intent": {},
		"target_id": "",
		"interrupted": false,
		"interrupt_streak": 0,
		"immunity": 0,
		"interrupt_threshold": int(definition.get("interrupt_threshold", 0)),
		"immunity_count": int(definition.get("immunity_count", 0))
	}
