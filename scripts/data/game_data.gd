extends RefCounted

const BOOKS := ["cards", "characters", "encounters", "battle_rules", "texts_zh_cn"]
const CONTRACT_PATH := "res://data/config_contract.json"
var books: Dictionary = {}
var errors: Array[String] = []
var contract: Dictionary = {}


func _load_contract() -> bool:
	if not contract.is_empty():
		return true
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT_PATH))
	if not parsed is Dictionary or parsed.get("version") != 1:
		errors.append(CONTRACT_PATH + ": invalid contract")
		return false
	contract = parsed
	return true


func load_directory(directory: String = "res://data") -> bool:
	var candidate: Dictionary = {}
	errors.clear()
	if not _load_contract():
		return false
	for book in BOOKS:
		var path := directory.path_join(book + ".json")
		if not FileAccess.file_exists(path):
			errors.append(path + ": missing file")
			continue
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if (
			not parsed is Dictionary
			or parsed.get("version") != 1
			or not parsed.get("sheets") is Dictionary
		):
			errors.append(path + ": invalid schema")
			continue
		candidate[book] = parsed
	if not errors.is_empty():
		return false
	var bundle_id = candidate[BOOKS[0]].get("bundle_id", "")
	if not bundle_id is String or bundle_id.is_empty():
		errors.append(directory + ": missing bundle_id; export the tables again")
		return false
	for book in BOOKS:
		if candidate[book].get("bundle_id") != bundle_id:
			errors.append(directory + "/" + book + ": mixed export bundles")
	if not errors.is_empty():
		return false
	if not validate(candidate):
		return false
	books = candidate.duplicate(true)
	return true


func validate(candidate: Dictionary) -> bool:
	errors.clear()
	if not _load_contract():
		return false
	var required: Dictionary = contract.schemas
	for book in required:
		if (
			not candidate.has(book)
			or not candidate[book] is Dictionary
			or not candidate[book].get("sheets") is Dictionary
		):
			errors.append(book + ": missing book")
			continue
		for sheet in required[book]:
			var rows = candidate[book].sheets.get(sheet)
			if not rows is Array or rows.is_empty():
				errors.append(book + "/" + sheet + ": missing rows")
				continue
			var ids: Dictionary = {}
			for row in rows:
				if not row is Dictionary or not row.get("id") is String or row.id.is_empty():
					errors.append(book + "/" + sheet + ": invalid id")
					continue
				_check(not ids.has(row.id), row, "id", "duplicate id")
				ids[row.id] = true
	if not errors.is_empty():
		return false
	if not _validate_shapes(candidate):
		return false
	var previous: Dictionary = books
	books = candidate
	for book in BOOKS:
		for sheet in books[book].sheets:
			for row in rows(book, sheet):
				for key in row:
					if str(key).ends_with("_key"):
						_check(
							not definition("texts_zh_cn", str(row[key])).is_empty(),
							row,
							key,
							"missing text"
						)
	for row in rows("texts_zh_cn"):
		_placeholders(row.text, row)
	for key in contract.required_texts:
		var row := definition("texts_zh_cn", key)
		_check(
			not row.is_empty(), {"_source": "texts_zh_cn.xlsx/main"}, key, "missing required text"
		)
		if not row.is_empty():
			_check(
				_same_members(_placeholders(row.text, row), contract.required_texts[key]),
				row,
				"text",
				"text/program placeholder mismatch"
			)
	for c in rows("cards"):
		_numeric(c, "cost", 0, true)
		_check(c.get("target") in ["enemy", "ally", "self"], c, "target", "invalid target")
		_check(c.get("role") in contract.roles + [""], c, "role", "invalid role")
		_check(
			c.get("owner") == "" or not definition("characters", str(c.get("owner"))).is_empty(),
			c,
			"owner",
			"missing owner"
		)
		_check(
			c.get("role") == "" or c.get("owner") == "", c, "owner", "conflicting caster filters"
		)
		_check(c.get("rarity") in ["common", "rare", "epic"], c, "rarity", "unknown rarity")
		for flag in ["reward", "exhaust", "retain"]:
			_check(c.get(flag) is bool, c, flag, "must be boolean")
		for upgraded in [false, true]:
			var list := card_effects(c.id, upgraded)
			_check(not list.is_empty(), c, "effects", "missing upgrade or base effects")
			var parameters: Array = []
			for i in range(list.size()):
				_check(list[i].order == i + 1, list[i], "order", "non-contiguous effects")
				if list[i].get("parameter", "") != "":
					parameters.append(list[i].parameter)
			var unique: Dictionary = {}
			for parameter in parameters:
				_check(
					not unique.has(parameter),
					c,
					"effects.parameter",
					"duplicate parameter overwrites card value"
				)
				unique[parameter] = true
			_check(
				_same_members(_placeholders(text(c.description_key), c), parameters),
				c,
				"description_key",
				"effect/template parameter mismatch"
			)
	for e in rows("cards", "effects"):
		var c := definition("cards", str(e.get("card_id")))
		_check(not c.is_empty(), e, "card_id", "missing card")
		_check(e.get("kind") in contract.effects, e, "kind", "unsupported effect")
		_check(e.get("upgraded") is bool, e, "upgraded", "must be boolean")
		_check(e.get("target") == "selected", e, "target", "unsupported target")
		_check(e.status == "", e, "status", "card status effects not supported")
		for key in ["amount", "hits", "order"]:
			_numeric(e, key, 0 if key == "amount" else 1, true)
		_numeric(e, "threat_mult")
		_check(e.kind == "damage" or e.hits == 1, e, "hits", "non-damage effects settle once")
		_check(
			e.kind not in ["interrupt", "dispel"] or (e.amount == 1 and e.parameter == ""),
			e,
			"amount",
			"interrupt/dispel has no numeric display parameter and settles once"
		)
		if not c.is_empty():
			_check(
				(
					(e.kind in ["damage", "interrupt"] and c.target == "enemy")
					or (e.kind in ["heal", "shield", "dispel"] and c.target in ["ally", "self"])
				),
				e,
				"kind",
				"effect/target mismatch"
			)
	_validate_starter_cards()
	for id in contract.initial_lineup:
		_check(
			not definition("characters", id).is_empty(),
			{"_source": "characters.xlsx/main"},
			"id",
			"missing initial character: " + id
		)
	for u in rows("characters"):
		_numeric(u, "max_hp", 1, true)
		_numeric(u, "strength", 0, true)
		_numeric(u, "passive_amount", 0, true)
		_check(u.get("role") in contract.roles, u, "role", "unknown role")
		_check(u.get("passive") in contract.passives, u, "passive", "unsupported passive")
		var has_starter := false
		for entry in rows("characters", "starter"):
			has_starter = has_starter or entry.character_id == u.id
		_check(has_starter, u, "starter", "character has no starting cards")
		if u.portrait != "":
			_check(
				u.portrait.begins_with("res://") and FileAccess.file_exists(u.portrait),
				u,
				"portrait",
				"missing portrait resource"
			)
	for row in rows("characters", "starter"):
		var c := definition("cards", str(row.get("card_id")))
		var u := definition("characters", str(row.get("character_id")))
		_check(not c.is_empty() and not u.is_empty(), row, "card_id", "missing reference")
		if not c.is_empty() and not u.is_empty():
			_check(
				(c.owner == "" or c.owner == u.id) and (c.role == "" or c.role == u.role),
				row,
				"card_id",
				"unusable starter"
			)
		_numeric(row, "count", 1, true)
	for row in rows("encounters", "enemies"):
		for key in ["max_hp", "strength", "interrupt_threshold", "immunity_count"]:
			_numeric(row, key, 1 if key == "max_hp" else 0, true)
		_check(
			(row.interrupt_threshold > 0) == (row.immunity_count > 0),
			row,
			"immunity_count",
			"threshold and immunity must be enabled together"
		)
		_check(not enemy_intents(row.id).is_empty(), row, "intents", "missing intent")
		var ordered := enemy_intents(row.id)
		for i in range(ordered.size()):
			_check(ordered[i].order == i + 1, ordered[i], "order", "non-contiguous intents")
	for row in rows("encounters", "intents"):
		_check(
			not definition("encounters", str(row.get("enemy_id")), "enemies").is_empty(),
			row,
			"enemy_id",
			"missing enemy"
		)
		_check(
			row.get("kind") in ["normal", "interruptible", "uninterruptible"],
			row,
			"kind",
			"unknown intent"
		)
		_check(
			(
				row.get("status") == ""
				or not definition("battle_rules", str(row.get("status")), "statuses").is_empty()
			),
			row,
			"status",
			"unknown status"
		)
		for key in ["amount", "stacks", "hits", "order"]:
			_numeric(row, key, 1 if key in ["hits", "order"] else 0, true)
		_check((row.status != "") == (row.stacks > 0), row, "stacks", "status and stacks disagree")
	for row in rows("encounters"):
		_check(
			row.get("enemies") is String and not row.get("enemies", "").is_empty(),
			row,
			"enemies",
			"missing enemies"
		)
		for enemy_id in str(row.get("enemies", "")).split(","):
			_check(
				not definition("encounters", enemy_id, "enemies").is_empty(),
				row,
				"enemies",
				"missing enemy"
			)
		_numeric(row, "order", 1, true)
		_numeric(row, "gold", 0, true)
	var ordered_encounters := rows("encounters").duplicate(true)
	ordered_encounters.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order
	)
	for i in range(ordered_encounters.size()):
		_check(
			ordered_encounters[i].order == i + 1,
			ordered_encounters[i],
			"order",
			"non-contiguous encounters"
		)
	var rule_ids: Array = []
	for row in rows("battle_rules"):
		rule_ids.append(row.id)
	_check(
		_same_members(rule_ids, contract.rules.keys()),
		{"_source": "battle_rules.xlsx/main"},
		"id",
		"missing or unknown rules"
	)
	for key in contract.rules:
		var row := definition("battle_rules", key)
		_check(not row.is_empty(), row, key, "missing rule")
		if row.is_empty():
			continue
		var spec: Dictionary = contract.rules[key]
		_numeric(row, "value", spec.min, spec.get("integer", false))
		_check(not spec.has("max") or row.value <= spec.max, row, "value", "exceeds maximum")
		_check(
			not spec.get("exclusive_min", false) or row.value > spec.min,
			row,
			"value",
			"must exceed minimum"
		)
	var status_ids: Array = []
	for row in rows("battle_rules", "statuses"):
		status_ids.append(row.id)
	_check(
		_same_members(status_ids, contract.statuses),
		{"_source": "battle_rules.xlsx/statuses"},
		"id",
		"missing or unknown statuses"
	)
	for row in rows("battle_rules", "statuses"):
		_check(row.id in contract.statuses, row, "id", "unsupported status")
		_check(row.get("dispellable") is bool, row, "dispellable", "must be boolean")
		_numeric(row, "per_stack", 1, true)
		_numeric(row, "decay", 1, true)
	for row in rows("texts_zh_cn"):
		_check(
			row.get("text") is String and not str(row.get("text", "")).is_empty(),
			row,
			"text",
			"empty text"
		)
	books = previous
	return errors.is_empty()


func _validate_shapes(candidate: Dictionary) -> bool:
	var schemas: Dictionary = contract.schemas
	for book in schemas:
		_check(candidate[book].get("version") == 1, {}, book, "unsupported schema version")
		for sheet in candidate[book].sheets:
			if not schemas[book].has(sheet):
				errors.append(book + "/" + sheet + ": unsupported sheet")
				continue
			for row in candidate[book].sheets[sheet]:
				for group in schemas[book][sheet].split(";"):
					var parts: PackedStringArray = group.split(":")
					for field in parts[1].split(","):
						var value = row.get(field)
						var valid: bool = (
							value is String
							if parts[0] == "s"
							else (
								value is bool
								if parts[0] == "b"
								else (value is int or value is float)
							)
						)
						_check(valid, row, field, "missing field or wrong type")
	return errors.is_empty()


func _validate_starter_cards() -> void:
	for id in contract.starter_cards:
		var card := definition("cards", id)
		_check(
			not card.is_empty(),
			{"_source": "cards.xlsx/main"},
			id,
			"missing confirmed starter card"
		)
		if card.is_empty():
			continue
		var spec: Dictionary = contract.starter_cards[id]
		for field in ["role", "owner", "target"]:
			_check(
				card[field] == spec[field],
				card,
				field,
				"starter card caster/target differs from confirmed rule"
			)
		var base := card_effects(id, false)
		var upgraded := card_effects(id, true)
		var count_valid: bool = (
			base.size() == upgraded.size() and base.size() == spec.effects.size()
		)
		_check(count_valid, card, "effects", "starter base/upgrade effect count mismatch")
		if not count_valid:
			continue
		for i in range(base.size()):
			for field in spec.effects[i]:
				_check(
					base[i][field] == spec.effects[i][field],
					base[i],
					field,
					"starter effect differs from confirmed rule"
				)
			for field in contract.fixed_upgrade_fields:
				_check(
					base[i][field] == upgraded[i][field],
					upgraded[i],
					field,
					"upgrade changes confirmed mechanism"
				)
			_check(
				upgraded[i].amount >= base[i].amount,
				upgraded[i],
				"amount",
				"upgrade must not reduce base value"
			)


func _same_members(left: Array, right: Array) -> bool:
	var a := left.duplicate()
	var b := right.duplicate()
	a.sort()
	b.sort()
	return a == b


func _placeholders(template: String, row: Dictionary) -> Array:
	_check(not template.strip_edges().is_empty(), row, "text", "empty text")
	var pattern := RegEx.new()
	pattern.compile("\\{(\\w+)\\}")
	var names: Dictionary = {}
	for found in pattern.search_all(template):
		names[found.get_string(1)] = true
	var rest := pattern.sub(template, "", true)
	_check(not rest.contains("{") and not rest.contains("}"), row, "text", "malformed placeholder")
	return names.keys()


func rows(book: String, sheet: String = "main") -> Array:
	return books.get(book, {}).get("sheets", {}).get(sheet, [])


func definition(book: String, id: String, sheet: String = "main") -> Dictionary:
	for row in rows(book, sheet):
		if row.id == id:
			return row.duplicate(true)
	return {}


func rule(id: String) -> float:
	return float(definition("battle_rules", id).get("value", 0))


func text(key: String, values: Dictionary = {}) -> String:
	return str(definition("texts_zh_cn", key).get("text", key)).format(values)


func card_effects(id: String, upgraded: bool) -> Array:
	var result: Array = []
	for effect in rows("cards", "effects"):
		if effect.get("card_id") == id and effect.get("upgraded") == upgraded:
			result.append(effect.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order)
	return result


func card_text(copy: Dictionary) -> String:
	var c := definition("cards", copy.card_id)
	var values: Dictionary = {}
	for effect in card_effects(c.id, copy.upgraded):
		if effect.parameter != "":
			values[effect.parameter] = effect.amount
	return text(
		"ui.card",
		{
			"name": text(c.name_key) + (" +" if copy.upgraded else ""),
			"cost": c.cost,
			"description": text(c.description_key, values)
		}
	)


func card_details(copy: Dictionary) -> String:
	var card := definition("cards", copy.get("card_id", ""))
	if card.is_empty():
		return text("error.card")
	var lines: Array[String] = [card_text(copy)]
	for flag in ["retain", "exhaust"]:
		if card[flag]:
			lines.append(text("keyword." + flag))
	for effect in card_effects(card.id, copy.get("upgraded", false)):
		if effect.kind == "interrupt":
			lines.append(text("keyword.interrupt"))
			break
	return "\n".join(lines)


func status_details(status: String) -> String:
	var spec := definition("battle_rules", status, "statuses")
	if spec.is_empty():
		return status
	var values := {"per_stack": spec.per_stack, "decay": spec.decay}
	if status in ["weak", "vulnerable"]:
		values["percent"] = rule(status + "_multiplier") * 100.0
	return text("status_desc." + status, values)


func enemy_intents(id: String) -> Array:
	var result: Array = []
	for row in rows("encounters", "intents"):
		if row.enemy_id == id:
			result.append(row.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order)
	return result


func _check(ok: bool, row: Dictionary, field: String, reason: String) -> void:
	if not ok:
		errors.append("%s [%s]: %s" % [row.get("_source", "data"), field, reason])


func _numeric(row: Dictionary, field: String, minimum: float = 0, integer: bool = false) -> void:
	var value = row.get(field)
	var valid: bool = value is float or value is int
	if valid:
		valid = (
			is_finite(float(value))
			and float(value) >= minimum
			and (not integer or float(value) == floorf(float(value)))
		)
	_check(valid, row, field, "invalid number")
