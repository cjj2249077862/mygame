extends RefCounted


static func sorted_cards(cards: Array, data: RefCounted, heroes: Array) -> Array:
	# Sort a view copy only: draw order, saved battle state and RNG stay untouched.
	var ordered: Array = cards.duplicate()
	var keys: Dictionary = {}
	for copy in ordered:
		var definition: Dictionary = data.definition("cards", str(copy.card_id))
		var owner: String = str(definition.get("owner", ""))
		var role: String = str(definition.get("role", ""))
		var position: int = heroes.size()
		for index in range(heroes.size()):
			var hero: Dictionary = heroes[index]
			if (
				(owner != "" and str(hero.definition_id) == owner)
				or (owner == "" and role != "" and str(hero.role) == role)
			):
				# A defeated hero keeps their slot; shared role cards use its first slot.
				position = index
				break
		keys[int(copy.copy_id)] = {
			"position": position,
			"name": data.text(str(definition.name_key)),
		}
	ordered.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var a_key: Dictionary = keys[int(a.copy_id)]
			var b_key: Dictionary = keys[int(b.copy_id)]
			if a_key.position != b_key.position:
				return a_key.position < b_key.position
			var comparison: int = str(a_key.name).naturalnocasecmp_to(str(b_key.name))
			if comparison != 0:
				return comparison < 0
			return int(a.copy_id) < int(b.copy_id)
	)
	return ordered
