extends RefCounted


# Read-only formatting of the preview's structured values, never of localized prose.
static func compact(preview: Dictionary, data: RefCounted) -> Dictionary:
	var damage: Array[String] = []
	var extras: Array[Dictionary] = []
	var main_effects: Array = []
	for effect in preview.get("effects", []):
		var kind: String = str(effect.get("kind", ""))
		if kind == "damage":
			damage.append("%s × %d" % [_amount(effect), int(effect.get("hits", 1))])
			main_effects.append(effect)
		else:
			var icon: String = str(effect.get("status", "")) if kind == "apply_status" else kind
			if kind == "clear_status":
				icon = "dispel"
			(
				extras
				. append(
					{
						"icon": icon,
						"value":
						"" if kind == "clear_status" else str(int(effect.get("amount", 0))),
						"details": data.effect_text(effect),
					}
				)
			)
	var icon := "attack"
	var value: String = " + ".join(damage)
	if value.is_empty() and not extras.is_empty():
		var first: Dictionary = extras.pop_front()
		icon = first.icon
		value = "—" if str(first.value).is_empty() else str(first.value)
	if value.is_empty():
		value = data.presentation_text("presentation.intent.no_action")
	var effects: Array = preview.get("effects", [])
	if main_effects.is_empty() and not effects.is_empty():
		main_effects.append(effects[0])
	var target_ids: Array[String] = []
	var all_targets := false
	for effect in main_effects:
		all_targets = all_targets or str(effect.get("target", "")) in ["all_allies", "all_enemies"]
		for id in effect.get("target_ids", []):
			if str(id) not in target_ids:
				target_ids.append(str(id))
	return {
		"icon": icon,
		"value": value,
		"extras": extras,
		"target_ids": target_ids,
		"all_targets": all_targets,
	}


static func _amount(effect: Dictionary) -> String:
	var amounts: Dictionary = effect.get("amounts", {})
	if amounts.is_empty():
		return str(int(effect.get("amount", 0)))
	var values: Array = amounts.values()
	values.sort()
	var low: int = int(values.front())
	var high: int = int(values.back())
	return str(low) if low == high else "%d–%d" % [low, high]
