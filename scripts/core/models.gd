extends RefCounted


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
