extends RefCounted

const Rules = preload("res://scripts/core/enums.gd")
const BOOKS := ["cards", "characters", "encounters", "battle_rules", "texts_zh_cn"]
var books: Dictionary = {}
var errors: Array[String] = []


func load_directory(directory: String = "res://data") -> bool:
	var candidate: Dictionary = {}
	errors.clear()
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
	if not validate(candidate):
		return false
	books = candidate.duplicate(true)
	return true


func validate(candidate: Dictionary) -> bool:
	errors.clear()
	var required := {
		"cards": ["main", "effects"],
		"characters": ["main", "starter"],
		"encounters": ["main", "enemies", "intents"],
		"battle_rules": ["main", "statuses"],
		"texts_zh_cn": ["main"]
	}
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
	for c in rows("cards"):
		_numeric(c, "cost", 0, true)
		_check(c.get("target") in ["enemy", "ally", "self"], c, "target", "invalid target")
		_check(c.get("role") in ["", "tank", "healer", "assassin"], c, "role", "invalid role")
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
			var regex := RegEx.new()
			regex.compile("\\{(\\w+)\\}")
			for result in regex.search_all(text(c.get("description_key", ""))):
				_check(
					result.get_string(1) in parameters, c, "description_key", "unknown placeholder"
				)
	for e in rows("cards", "effects"):
		var c := definition("cards", str(e.get("card_id")))
		_check(not c.is_empty(), e, "card_id", "missing card")
		_check(e.get("kind") in Rules.EFFECTS, e, "kind", "unsupported effect")
		_check(e.get("upgraded") is bool, e, "upgraded", "must be boolean")
		_check(e.get("target") == "selected", e, "target", "unsupported target")
		for key in ["amount", "hits", "order"]:
			_numeric(e, key, 0 if key == "amount" else 1, true)
		_numeric(e, "threat_mult")
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
	for u in rows("characters"):
		_numeric(u, "max_hp", 1, true)
		_numeric(u, "strength", 0, true)
		_numeric(u, "passive_amount", 0, true)
		_check(u.get("role") in Rules.ROLES, u, "role", "unknown role")
		_check(
			u.get("passive") in ["first_damage", "first_heal", "first_shield"],
			u,
			"passive",
			"unsupported passive"
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
	var required_rules := [
		"party_size",
		"base_energy",
		"draw_count",
		"hand_limit",
		"initial_tank_threat",
		"initial_other_threat",
		"heal_threat",
		"post_battle_revive",
		"reward_count",
		"weak_multiplier",
		"vulnerable_multiplier",
		"starting_gold"
	]
	for key in required_rules:
		var row := definition("battle_rules", key)
		_check(not row.is_empty(), row, key, "missing rule")
		_numeric(
			row,
			"value",
			0,
			(
				key
				not in [
					"heal_threat", "post_battle_revive", "weak_multiplier", "vulnerable_multiplier"
				]
			)
		)
	_check(rule("party_size") == 3, {}, "party_size", "requires three heroes")
	_check(
		rule("post_battle_revive") > 0 and rule("post_battle_revive") <= 1,
		{},
		"post_battle_revive",
		"invalid ratio"
	)
	for row in rows("battle_rules", "statuses"):
		_check(
			row.id in ["poison", "burn", "regen", "weak", "vulnerable"],
			row,
			"id",
			"unsupported status"
		)
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
	var schemas := {
		"cards":
		{
			"main":
			"s:id,name_key,description_key,role,owner,target,rarity;b:reward,exhaust,retain;n:cost",
			"effects":
			"s:id,card_id,kind,status,target,parameter;b:upgraded;n:order,amount,hits,threat_mult"
		},
		"characters":
		{
			"main": "s:id,name_key,role,passive,portrait;n:max_hp,strength,passive_amount",
			"starter": "s:id,character_id,card_id;n:count"
		},
		"encounters":
		{
			"main": "s:id,name_key,enemies;n:order,gold",
			"enemies": "s:id,name_key;n:max_hp,strength,interrupt_threshold,immunity_count",
			"intents": "s:id,enemy_id,kind,status;n:order,amount,hits,stacks"
		},
		"battle_rules":
		{"main": "s:id;n:value", "statuses": "s:id,name_key;b:dispellable;n:per_stack,decay"},
		"texts_zh_cn": {"main": "s:id,text"}
	}
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
