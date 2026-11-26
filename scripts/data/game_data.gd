extends RefCounted

const BOOKS := [
	"cards",
	"characters",
	"encounters",
	"battle_rules",
	"texts_zh_cn",
	"relics",
	"events",
	"maps",
	"economy",
	"difficulty"
]
const CONTRACT_PATH := "res://data/config_contract.json"
const PRESENTATION_PATH := "res://data/presentation.json"
var books: Dictionary = {}
var errors: Array[String] = []
var contract: Dictionary = {}
var _presentation_texts: Dictionary = {}
var _presentation_loaded := false


func _load_contract() -> bool:
	if not contract.is_empty():
		return true
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT_PATH))
	if not parsed is Dictionary or parsed.get("version") != 2:
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
			or parsed.get("version") != contract.version
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
			if (
				not rows is Array
				or (rows.is_empty() and book + "/" + sheet not in contract.empty_sheets)
			):
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
			for row in _source_rows(book, sheet):
				for key in row:
					if str(key).ends_with("_key"):
						_check(
							not definition("texts_zh_cn", str(row[key])).is_empty(),
							row,
							key,
							"missing text"
						)
	for row in _source_rows("texts_zh_cn"):
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
	for c in _source_rows("cards"):
		_numeric(c, "cost", 0, true)
		_check(c.get("target") in contract.card_targets, c, "target", "invalid target")
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
	for e in _source_rows("cards", "effects"):
		var c := definition("cards", str(e.get("card_id")))
		_check(not c.is_empty(), e, "card_id", "missing card")
		_check(e.get("upgraded") is bool, e, "upgraded", "must be boolean")
		_validate_effect(e, "cards", c.get("target", ""))
	for card in _source_rows("cards"):
		var base := card_effects(card.id, false)
		var upgraded := card_effects(card.id, true)
		_check(base.size() == upgraded.size(), card, "effects", "upgrade changes effect count")
		for i in range(mini(base.size(), upgraded.size())):
			for field in contract.fixed_upgrade_fields:
				_check(
					base[i][field] == upgraded[i][field],
					upgraded[i],
					field,
					"upgrade changes mechanism"
				)
			_check(
				upgraded[i].amount >= base[i].amount, upgraded[i], "amount", "upgrade reduces value"
			)
	_validate_starter_cards()
	for id in contract.initial_lineup:
		_check(
			not definition("characters", id).is_empty(),
			{"_source": "characters.xlsx/main"},
			"id",
			"missing initial character: " + id
		)
	for u in _source_rows("characters"):
		_numeric(u, "max_hp", 1, true)
		_numeric(u, "strength", 0, true)
		_numeric(u, "passive_amount", 0, true)
		_check(u.get("role") in contract.roles, u, "role", "unknown role")
		_check(u.get("passive") in contract.passives, u, "passive", "unsupported passive")
		var has_starter := false
		for entry in _source_rows("characters", "starter"):
			has_starter = has_starter or entry.character_id == u.id
		_check(has_starter, u, "starter", "character has no starting cards")
		if u.portrait != "":
			_check(
				u.portrait.begins_with("res://") and FileAccess.file_exists(u.portrait),
				u,
				"portrait",
				"missing portrait resource"
			)
	for row in _source_rows("characters", "starter"):
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
	for row in _source_rows("encounters", "enemies"):
		for key in ["max_hp", "strength", "interrupt_threshold", "immunity_count"]:
			_numeric(row, key, 1 if key == "max_hp" else 0, true)
		_check(
			(row.interrupt_threshold > 0) == (row.immunity_count > 0),
			row,
			"immunity_count",
			"threshold and immunity must be enabled together"
		)
		_check(not enemy_intents(row.id).is_empty(), row, "intents", "missing intent")
		var pools: Dictionary = {}
		for intent in _source_rows("encounters", "intents"):
			if intent.enemy_id == row.id:
				pools[intent.pool_id] = true
		for pool in pools:
			var ordered := enemy_intents(row.id, pool)
			for i in range(ordered.size()):
				_check(ordered[i].order == i + 1, ordered[i], "order", "non-contiguous intents")
	for row in _source_rows("encounters", "intents"):
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
	for row in _source_rows("encounters"):
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
	var ordered_encounters := _source_rows("encounters").duplicate(true)
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
	for row in _source_rows("battle_rules"):
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
	for row in _source_rows("battle_rules", "statuses"):
		status_ids.append(row.id)
	_check(
		_same_members(status_ids, contract.statuses),
		{"_source": "battle_rules.xlsx/statuses"},
		"id",
		"missing or unknown statuses"
	)
	for row in _source_rows("battle_rules", "statuses"):
		_check(row.id in contract.statuses, row, "id", "unsupported status")
		_check(row.get("dispellable") is bool, row, "dispellable", "must be boolean")
		_numeric(row, "per_stack", 1, true)
		_numeric(row, "decay", 1, true)
	for row in _source_rows("texts_zh_cn"):
		_check(
			row.get("text") is String and not str(row.get("text", "")).is_empty(),
			row,
			"text",
			"empty text"
		)
	_validate_phase_two()
	books = previous
	return errors.is_empty()


func _validate_effect(row: Dictionary, book: String, card_target: String = "") -> void:
	var kinds: Array = (
		contract.effects
		if book == "cards"
		else contract.relic_effects if book == "relics" else contract.encounter_effects
	)
	_check(row.kind in kinds, row, "kind", "unknown effect")
	var targets: Array = (
		contract.effect_targets + (["event_source", "event_target"] if book == "relics" else [])
	)
	_check(row.target in targets, row, "target", "unknown effect target")
	_numeric(
		row,
		"amount",
		-INF if row.kind in ["base_energy", "base_draw"] else 0,
		row.kind not in ["revive", "camp_heal_ratio"]
	)
	for key in ["hits", "order"]:
		_numeric(row, key, 1, true)
	_numeric(row, "duration", 0, true)
	_numeric(row, "threat_mult")
	_check(row.kind == "damage" or row.hits == 1, row, "hits", "non-damage effects settle once")
	var global_effects := [
		"draw",
		"energy",
		"base_energy",
		"base_draw",
		"base_damage_bonus",
		"first_damage_bonus",
		"first_shield_bonus",
		"first_heal_bonus",
		"camp_heal_ratio"
	]
	_check(
		(row.target == "none") == (row.kind in global_effects),
		row,
		"target",
		"unit/global effect target mismatch"
	)
	_check(row.kind == "bomb" or row.duration == 0, row, "duration", "only bombs have a countdown")
	if row.kind in ["interrupt", "dispel", "clear_status"]:
		_check(
			row.amount == 1 and row.parameter == "",
			row,
			"amount",
			"single clear/interrupt has no numeric parameter"
		)
	if row.kind in ["revive", "camp_heal_ratio"]:
		_check(row.amount > 0 and row.amount <= 1, row, "amount", "ratio must be in (0,1]")
	if row.kind in ["apply_status", "clear_status", "bomb"]:
		_check(row.status in contract.statuses, row, "status", "unknown status")
		_check(
			row.kind == "bomb" or row.status != "bomb",
			row,
			"status",
			"bomb requires its own mechanism"
		)
		if row.kind == "apply_status":
			_check(row.amount > 0, row, "amount", "status must be positive")
	else:
		_check(row.status == "", row, "status", "effect does not accept a status")
	if row.kind == "bomb":
		_check(
			row.status == "bomb" and row.duration > 0,
			row,
			"duration",
			"bomb needs a positive countdown"
		)
	if card_target == "":
		return
	var valid := true
	match row.kind:
		"damage", "interrupt":
			valid = (
				row.target == "all_enemies" or (row.target == "selected" and card_target == "enemy")
			)
		"heal", "shield", "dispel":
			valid = (
				row.target in ["self", "all_allies"]
				or (row.target == "selected" and card_target in ["ally", "self"])
			)
		"revive":
			valid = row.target == "selected" and card_target == "dead_ally"
		"draw", "energy":
			valid = row.target == "none"
		"taunt":
			valid = row.target == "self" and row.amount > 0
		"apply_status":
			var friendly: bool = row.status == "regen"
			valid = (
				row.target in (["self", "all_allies"] if friendly else ["all_enemies"])
				or (
					row.target == "selected"
					and card_target in (["ally", "self"] if friendly else ["enemy"])
				)
			)
	_check(valid, row, "target", "effect and card target disagree")


func _validate_phase_two() -> void:
	var groups := {"encounters": {}, "relics": {}}
	for book in groups:
		for effect in _source_rows(book, "effects"):
			_validate_effect(effect, book)
			_check(effect.group_id != "", effect, "group_id", "empty effect group")
			groups[book][effect.group_id] = true
		for group in groups[book]:
			var list := _ordered_effects(book, group)
			for i in range(list.size()):
				_check(list[i].order == i + 1, list[i], "order", "non-contiguous group")
	for enemy in _source_rows("encounters", "enemies"):
		_check(enemy.kind in ["normal", "elite", "boss"], enemy, "kind", "unknown enemy kind")
		_numeric(enemy, "enrage_turn", 0, true)
		_numeric(enemy, "enrage_mult", 1)
	var used_encounter_groups: Dictionary = {}
	for intent in _source_rows("encounters", "intents"):
		_check(
			intent.target_rule in ["threat", "lowest_hp_ratio"],
			intent,
			"target_rule",
			"unknown target rule"
		)
		if intent.effect_group != "":
			_check(
				groups.encounters.has(intent.effect_group),
				intent,
				"effect_group",
				"missing intent effects"
			)
			_check(
				intent.amount == 0 and intent.status == "" and intent.stacks == 0,
				intent,
				"effect_group",
				"composite intent duplicates legacy values"
			)
			used_encounter_groups[intent.effect_group] = true
	var thresholds: Dictionary = {}
	for phase in _source_rows("encounters", "phases"):
		var enemy := definition("encounters", phase.enemy_id, "enemies")
		_check(enemy.get("kind") == "boss", phase, "enemy_id", "phase must belong to a boss")
		_check(
			phase.threshold > 0 and phase.threshold < 1,
			phase,
			"threshold",
			"phase ratio must be in (0,1)"
		)
		var pair := str(phase.enemy_id) + ":" + str(phase.threshold)
		_check(not thresholds.has(pair), phase, "threshold", "duplicate phase threshold")
		thresholds[pair] = true
		_check(
			groups.encounters.has(phase.enter_effect_group),
			phase,
			"enter_effect_group",
			"missing stage effects"
		)
		_check(
			(
				phase.intent_pool != ""
				and not enemy_intents(phase.enemy_id, phase.intent_pool).is_empty()
			),
			phase,
			"intent_pool",
			"missing stage intent pool"
		)
		used_encounter_groups[phase.enter_effect_group] = true
	_check(
		_same_members(groups.encounters.keys(), used_encounter_groups.keys()),
		{},
		"encounters.effects",
		"unreferenced encounter effect group"
	)
	for row in _source_rows("encounters"):
		_check(row.kind in ["normal", "elite", "boss"], row, "kind", "unknown encounter kind")
		_numeric(row, "min_depth", 1, true)
		_numeric(row, "max_depth", 1, true)
		_check(
			row.min_depth <= row.max_depth and row.max_depth <= 10,
			row,
			"max_depth",
			"invalid encounter depth"
		)
		var contains_boss := false
		for id in row.enemies.split(","):
			contains_boss = (
				contains_boss or definition("encounters", id, "enemies").get("kind") == "boss"
			)
		_check((row.kind == "boss") == contains_boss, row, "kind", "boss classification mismatch")
	var used_relic_groups: Dictionary = {}
	for relic in _source_rows("relics"):
		_check(relic.pool in ["normal", "boss"], relic, "pool", "unknown relic pool")
		_check(
			(
				relic.role in contract.roles + [""]
				and (relic.owner == "" or not definition("characters", relic.owner).is_empty())
				and (relic.role == "" or relic.owner == "")
			),
			relic,
			"role/owner",
			"invalid eligibility"
		)
		_check(relic.rarity in ["common", "rare", "epic"], relic, "rarity", "unknown rarity")
		var triggers := relic_triggers([relic.id])
		_check(not triggers.is_empty(), relic, "triggers", "missing relic trigger")
		var parameters: Array = []
		var unique: Dictionary = {}
		for trigger in triggers:
			_check(
				groups.relics.has(trigger.effect_group),
				trigger,
				"effect_group",
				"missing relic effects"
			)
			for effect in relic_effects(trigger.effect_group):
				if effect.parameter != "":
					_check(
						not unique.has(effect.parameter),
						relic,
						"parameter",
						"duplicate relic parameter"
					)
					unique[effect.parameter] = true
					parameters.append(effect.parameter)
		_check(
			_same_members(parameters, _placeholders(text(relic.description_key), relic)),
			relic,
			"description_key",
			"relic template mismatch"
		)
	for trigger in _source_rows("relics", "triggers"):
		_check(
			not definition("relics", trigger.relic_id).is_empty(),
			trigger,
			"relic_id",
			"missing relic"
		)
		_check(trigger.event in contract.relic_events, trigger, "event", "unknown relic event")
		_check(
			trigger.qualifier in contract.relic_qualifiers,
			trigger,
			"qualifier",
			"unknown relic qualifier"
		)
		_check(
			trigger.limit_scope in contract.relic_scopes,
			trigger,
			"limit_scope",
			"unknown counter scope"
		)
		for field in ["priority", "order", "limit_count"]:
			_numeric(trigger, field, 0, true)
		_check(
			(trigger.limit_scope == "none") == (trigger.limit_count == 0),
			trigger,
			"limit_count",
			"limit and scope disagree"
		)
		_check(
			groups.relics.has(trigger.effect_group),
			trigger,
			"effect_group",
			"missing relic effects"
		)
		_check(
			trigger.limit_scope != "actor_turn" or trigger.event == "card_played",
			trigger,
			"limit_scope",
			"event has no caster context"
		)
		_check(
			(
				trigger.limit_scope != "card_target"
				or trigger.event in ["card_played", "status_dispelled", "interrupt_resolved"]
			),
			trigger,
			"limit_scope",
			"event has no card target context"
		)
		for effect in relic_effects(trigger.effect_group):
			if effect.kind in ["first_damage_bonus", "first_shield_bonus", "first_heal_bonus"]:
				_check(
					trigger.event == "card_played",
					trigger,
					"event",
					"first bonuses require card events"
				)
			if effect.kind in ["base_energy", "base_draw", "base_damage_bonus"]:
				_check(
					trigger.event == "base_resources",
					trigger,
					"event",
					"base modifiers require resource initialization"
				)
			if effect.kind == "camp_heal_ratio":
				_check(
					trigger.event == "camp_rest", trigger, "event", "camp modifier requires rest"
				)
			if effect.target in ["event_source", "event_target"]:
				_check(
					trigger.event in ["card_played", "status_dispelled", "interrupt_resolved"],
					trigger,
					"event",
					"event has no unit context"
				)
		used_relic_groups[trigger.effect_group] = true
	_check(
		_same_members(groups.relics.keys(), used_relic_groups.keys()),
		{},
		"relics.effects",
		"unreferenced relic effect group"
	)
	for event in _source_rows("events"):
		_numeric(event, "weight", 1)
		var choices := event_options(event.id)
		var has_leave := false
		for i in range(choices.size()):
			_check(choices[i].order == i + 1, choices[i], "order", "non-contiguous choices")
			has_leave = has_leave or choices[i].leave
		_check(has_leave, event, "options", "missing free leave option")
	for option in _source_rows("events", "options"):
		_check(
			not definition("events", option.event_id).is_empty(),
			option,
			"event_id",
			"missing event"
		)
		_check(
			option.selection in ["none", "hero", "card", "unupgraded_card"],
			option,
			"selection",
			"unknown selection"
		)
		_check(
			option.required_relic_pool in ["", "normal", "boss"],
			option,
			"required_relic_pool",
			"unknown relic pool"
		)
		for field in ["cost_gold", "cost_hp", "min_hp", "order"]:
			_numeric(option, field, 0, true)
		_check(
			option.cost_hp == 0 or (option.selection == "hero" and option.min_hp > option.cost_hp),
			option,
			"cost_hp",
			"life costs may not kill"
		)
		var outcomes := event_outcomes(option.id)
		_check(not outcomes.is_empty(), option, "outcomes", "missing outcome")
		if option.leave:
			_check(
				(
					option.selection == "none"
					and option.cost_gold == 0
					and option.cost_hp == 0
					and option.required_relic_pool == ""
				),
				option,
				"leave",
				"leave must be unconditional and free"
			)
			for outcome in outcomes:
				_check(
					event_effects(outcome.id).is_empty(),
					option,
					"leave",
					"leave may not grant effects"
				)
	for outcome in _source_rows("events", "outcomes"):
		_check(
			not definition("events", outcome.option_id, "options").is_empty(),
			outcome,
			"option_id",
			"missing option"
		)
		_numeric(outcome, "weight", 1)
		var effects := event_effects(outcome.id)
		for i in range(effects.size()):
			_check(effects[i].order == i + 1, effects[i], "order", "non-contiguous outcome")
		var option := definition("events", outcome.option_id, "options")
		if not option.is_empty():
			var life_cost: int = int(option.cost_hp)
			for effect in effects:
				if effect.kind == "hp_loss":
					life_cost += int(effect.amount)
			_check(
				life_cost == 0 or (option.selection == "hero" and option.min_hp > life_cost),
				option,
				"min_hp",
				"total branch life costs may not kill"
			)
	var event_targets := {
		"heal": ["party", "selected_hero"],
		"hp_loss": ["selected_hero"],
		"gold": ["none"],
		"upgrade": ["selected_card"],
		"remove": ["selected_card"],
		"grant_relic": ["none"]
	}
	for effect in _source_rows("events", "effects"):
		var outcome := definition("events", effect.outcome_id, "outcomes")
		_check(not outcome.is_empty(), effect, "outcome_id", "missing outcome")
		if outcome.is_empty():
			continue
		var option := definition("events", outcome.option_id, "options")
		if option.is_empty():
			continue
		_check(
			effect.target in event_targets.get(effect.kind, []),
			effect,
			"kind/target",
			"invalid event effect"
		)
		_numeric(effect, "amount", 1, true)
		if effect.kind in ["hp_loss", "heal"] and effect.target == "selected_hero":
			_check(option.selection == "hero", effect, "target", "missing hero selection")
		if effect.kind == "hp_loss":
			_check(
				option.min_hp > effect.amount + option.cost_hp,
				effect,
				"amount",
				"random life cost may not kill"
			)
		if effect.kind in ["upgrade", "remove"]:
			_check(
				option.selection in ["card", "unupgraded_card"] and effect.amount == 1,
				effect,
				"target",
				"must select one card copy"
			)
		if effect.kind == "grant_relic":
			_check(
				(
					effect.content_pool in ["normal", "boss"]
					and effect.amount == 1
					and option.required_relic_pool == effect.content_pool
				),
				effect,
				"content_pool",
				"missing relic pool prerequisite"
			)
		else:
			_check(effect.content_pool == "", effect, "content_pool", "non-relic effect has a pool")
	var economy_ids: Array = []
	for row in _source_rows("economy"):
		economy_ids.append(row.id)
	_check(
		_same_members(economy_ids, contract.economy_rules.keys()),
		{},
		"economy",
		"missing or unknown economy rule"
	)
	for id in contract.economy_rules:
		var row := definition("economy", id)
		if row.is_empty():
			continue
		var spec: Dictionary = contract.economy_rules[id]
		_numeric(row, "value", spec.min, spec.get("integer", false))
		_check(
			not spec.has("max") or row.value <= spec.max, row, "value", "exceeds economy maximum"
		)
	for sheet in ["card_prices", "relic_prices"]:
		var rarities: Array = []
		for row in _source_rows("economy", sheet):
			rarities.append(row.rarity)
			_numeric(row, "price", 0, true)
		_check(
			_same_members(rarities, ["common", "rare", "epic"]),
			{},
			sheet,
			"missing or repeated price rarity"
		)
	var weight_keys: Dictionary = {}
	for weight in _source_rows("economy", "weights"):
		var key := str(weight.kind) + ":" + str(weight.source) + ":" + str(weight.rarity)
		_check(not weight_keys.has(key), weight, "id", "duplicate rarity weight")
		weight_keys[key] = true
		_check(
			(
				weight.kind in ["card", "relic"]
				and weight.source in ["battle", "elite", "boss", "shop"]
				and weight.rarity in ["common", "rare", "epic"]
			),
			weight,
			"source",
			"unknown weight category"
		)
		_numeric(weight, "weight", 0)
	_check(weight_keys.size() == 24, {}, "weights", "missing source rarity weight")
	for kind in ["card", "relic"]:
		for source in ["battle", "elite", "boss", "shop"]:
			var total := 0.0
			for weight in _source_rows("economy", "weights"):
				if weight.kind == kind and weight.source == source:
					total += float(weight.weight)
			_check(total > 0, {}, "weights", "source weight total must be positive")
	for pair in [["base_draw", "draw_count"], ["base_energy", "base_energy"]]:
		var worst: float = rule(pair[1])
		for effect in _source_rows("relics", "effects"):
			if effect.kind == pair[0]:
				worst += minf(0, float(effect.amount))
		_check(worst >= 0, {}, pair[0], "combined negative modifiers invalidate base resource")
	for map in _source_rows("maps"):
		_numeric(map, "node_count", 10, true)
		_check(map.node_count == 10, map, "node_count", "chapter requires ten nodes")
		_numeric(map, "width", 2, true)
		_check(
			definition("encounters", map.first_encounter_id).get("kind") == "normal",
			map,
			"first_encounter_id",
			"start must be a normal battle"
		)
		_check(
			definition("encounters", map.boss_encounter_id).get("kind") == "boss",
			map,
			"boss_encounter_id",
			"end must be a boss"
		)
	for rule_row in _source_rows("maps", "node_rules"):
		_check(
			(
				not definition("maps", rule_row.map_id).is_empty()
				and rule_row.kind in ["battle", "elite", "camp", "shop", "event"]
			),
			rule_row,
			"kind",
			"invalid map rule"
		)
		_numeric(rule_row, "weight", 1)
		_numeric(rule_row, "min_depth", 2, true)
		_numeric(rule_row, "max_depth", 2, true)
		_check(
			rule_row.min_depth <= rule_row.max_depth and rule_row.max_depth <= 8,
			rule_row,
			"max_depth",
			"invalid map rule depth"
		)
	for entry in _source_rows("maps", "pools"):
		_check(
			(
				not definition("maps", entry.map_id).is_empty()
				and entry.kind in ["battle", "elite", "event"]
			),
			entry,
			"map_id",
			"invalid map pool category"
		)
		_numeric(entry, "weight", 1)
		if entry.kind == "event":
			_check(
				not definition("events", entry.content_id).is_empty(),
				entry,
				"content_id",
				"missing event"
			)
		else:
			_check(
				(
					definition("encounters", entry.content_id).get("kind")
					== ("normal" if entry.kind == "battle" else "elite")
				),
				entry,
				"content_id",
				"encounter category mismatch"
			)
	for map in _source_rows("maps"):
		var pool := map_pool(map.id)
		var rules := map_rules(map.id)
		var seen: Dictionary = {}
		for entry in pool:
			var key := str(entry.kind) + ":" + str(entry.content_id)
			_check(not seen.has(key), map, "pools", "duplicate map content")
			seen[key] = true
		for depth in range(2, 9):
			var safe := false
			for rule_row in rules:
				if depth < rule_row.min_depth or depth > rule_row.max_depth:
					continue
				safe = safe or rule_row.kind != "elite"
				if rule_row.kind not in ["battle", "elite", "event"]:
					continue
				var available := false
				for entry in pool:
					if entry.kind != rule_row.kind:
						continue
					if (
						entry.kind == "event"
						or (
							entry.get("min_depth", 1) <= depth
							and depth <= entry.get("max_depth", 10)
						)
					):
						available = true
				_check(available, rule_row, "pools", "no content for depth %d" % depth)
			_check(safe, map, "node_rules", "no non-elite candidate for depth %d" % depth)
	for difficulty in _source_rows("difficulty"):
		_check(
			not difficulty.enabled or difficulty.id == "difficulty_1",
			difficulty,
			"enabled",
			"only difficulty one is enabled"
		)
	_check(
		definition("difficulty", "difficulty_1").get("enabled", false),
		{},
		"difficulty",
		"difficulty one must be enabled"
	)
	_check(
		_source_rows("difficulty", "modifiers").is_empty(),
		{},
		"difficulty.modifiers",
		"other difficulty mechanics are not defined"
	)


func _validate_shapes(candidate: Dictionary) -> bool:
	var schemas: Dictionary = contract.schemas
	for book in schemas:
		_check(
			candidate[book].get("version") == contract.version,
			{},
			book,
			"unsupported schema version"
		)
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
						if valid and parts[0] == "n":
							_check(is_finite(float(value)), row, field, "number must be finite")
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
	return _source_rows(book, sheet).duplicate(true)


# Internal readers borrow these rows; only public query results are copied.
func _source_rows(book: String, sheet: String = "main") -> Array:
	return books.get(book, {}).get("sheets", {}).get(sheet, [])


func definition(book: String, id: String, sheet: String = "main") -> Dictionary:
	for row in _source_rows(book, sheet):
		if row.id == id:
			return row.duplicate(true)
	return {}


func rule(id: String) -> float:
	return float(definition("battle_rules", id).get("value", 0))


func economy(id: String) -> float:
	return float(definition("economy", id).get("value", 0))


func price_for(kind: String, item_id: String) -> int:
	var item := definition("cards" if kind == "card" else "relics", item_id)
	for price in _source_rows("economy", "card_prices" if kind == "card" else "relic_prices"):
		if price.rarity == item.get("rarity", ""):
			return int(price.price)
	return 0


func weight_for(kind: String, item_id: String, source: String) -> float:
	var item := definition("cards" if kind == "card" else "relics", item_id)
	var origin := "battle" if source == "reward" else source
	for weight in _source_rows("economy", "weights"):
		if (
			weight.kind == kind
			and weight.source == origin
			and weight.rarity == item.get("rarity", "")
		):
			return float(weight.weight)
	return 0.0


func chapter_definition() -> Dictionary:
	var chapters := _source_rows("maps")
	return chapters[0].duplicate(true) if not chapters.is_empty() else {}


func map_rules(map_id: String) -> Array:
	return _matching_rows("maps", "node_rules", "map_id", map_id)


func map_pool(map_id: String) -> Array:
	var result := _matching_rows("maps", "pools", "map_id", map_id)
	for entry in result:
		if entry.kind in ["battle", "elite", "boss"]:
			var encounter := definition("encounters", entry.content_id)
			entry.min_depth = int(encounter.get("min_depth", 1))
			entry.max_depth = int(encounter.get("max_depth", 10))
	return result


func event_options(event_id: String) -> Array:
	var result := _matching_rows("events", "options", "event_id", event_id)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order)
	return result


func event_outcomes(option_id: String) -> Array:
	return _matching_rows("events", "outcomes", "option_id", option_id)


func event_effects(outcome_id: String) -> Array:
	var result := _matching_rows("events", "effects", "outcome_id", outcome_id)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order)
	return result


func relic_text(id: String) -> String:
	var relic := definition("relics", id)
	if relic.is_empty():
		return id
	var values: Dictionary = {}
	var all_effects: Array = []
	for trigger in _matching_rows("relics", "triggers", "relic_id", id):
		for effect in relic_effects(trigger.effect_group):
			all_effects.append(effect)
			if effect.get("parameter", "") != "":
				values[effect.parameter] = (
					effect.amount * contract.get("parameter_scales", {}).get(effect.kind, 1)
				)
	var lines: Array[String] = [text(relic.name_key), text(relic.description_key, values)]
	lines.append_array(_effect_details(all_effects))
	return "\n".join(lines)


func relic_triggers(relic_ids: Array, event: String = "") -> Array:
	var result: Array = []
	for trigger in _source_rows("relics", "triggers"):
		if trigger.relic_id in relic_ids and (event == "" or trigger.event == event):
			result.append(trigger.duplicate(true))
	result.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if a.priority != b.priority:
				return a.priority < b.priority
			if a.order != b.order:
				return a.order < b.order
			return a.id < b.id
	)
	return result


func relic_effects(group_id: String) -> Array:
	return _ordered_effects("relics", group_id)


func relic_modifier(relic_ids: Array, event: String, kind: String) -> float:
	var total := 0.0
	for trigger in relic_triggers(relic_ids, event):
		for effect in relic_effects(trigger.effect_group):
			if effect.kind == kind:
				total += float(effect.amount)
	return total


func encounter_effects(group_id: String) -> Array:
	return _ordered_effects("encounters", group_id)


func enemy_phases(enemy_id: String) -> Array:
	var result := _matching_rows("encounters", "phases", "enemy_id", enemy_id)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.threshold > b.threshold)
	return result


func _matching_rows(book: String, sheet: String, field: String, value: String) -> Array:
	var result: Array = []
	for row in _source_rows(book, sheet):
		if row.get(field) == value:
			result.append(row.duplicate(true))
	return result


func _ordered_effects(book: String, group_id: String) -> Array:
	var result := _matching_rows(book, "effects", "group_id", group_id)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order)
	return result


func text(key: String, values: Dictionary = {}) -> String:
	var rendered_values := values.duplicate()
	for parameter in rendered_values:
		var value: Variant = rendered_values[parameter]
		# JSON numbers load as floats. Display whole counts without a decimal
		# suffix while keeping fractional percentages and other values intact.
		if value is float and is_finite(value) and value == floorf(value):
			rendered_values[parameter] = int(value)
	return str(definition("texts_zh_cn", key).get("text", key)).format(rendered_values)


func card_effects(id: String, upgraded: bool) -> Array:
	var result: Array = []
	for effect in _source_rows("cards", "effects"):
		if effect.get("card_id") == id and effect.get("upgraded") == upgraded:
			result.append(effect.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order)
	return result


func card_text(copy: Dictionary) -> String:
	var c := definition("cards", copy.card_id)
	var values: Dictionary = {}
	for effect in card_effects(c.id, copy.upgraded):
		if effect.parameter != "":
			values[effect.parameter] = (
				effect.amount * contract.get("parameter_scales", {}).get(effect.kind, 1)
			)
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
	lines.append_array(_effect_details(card_effects(card.id, copy.get("upgraded", false))))
	return "\n".join(lines)


func _effect_details(effects: Array) -> Array[String]:
	var lines: Array[String] = []
	for section in _effect_sections(effects):
		lines.append(str(section.title) + "：" + str(section.body))
	return lines


func status_details(status: String) -> String:
	var spec := definition("battle_rules", status, "statuses")
	if spec.is_empty():
		return status
	var values := {"per_stack": spec.per_stack, "decay": spec.decay}
	if status in ["weak", "vulnerable"]:
		values["percent"] = rule(status + "_multiplier") * 100.0
	return text("status_desc." + status, values)


func effect_text(effect: Dictionary) -> String:
	var values := effect.duplicate(true)
	values["amount"] = (
		float(effect.get("amount", 0))
		* contract.get("parameter_scales", {}).get(effect.get("kind", ""), 1)
	)
	values["status"] = (
		text("status." + str(effect.get("status", ""))) if effect.get("status", "") != "" else ""
	)
	return text("effect." + str(effect.get("kind", "")), values)


func enemy_intents(id: String, pool_id: String = "") -> Array:
	var result: Array = []
	for row in _source_rows("encounters", "intents"):
		if row.enemy_id == id and row.get("pool_id", "") == pool_id:
			result.append(row.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order)
	return result


# Presentation text is deliberately independent of gameplay validation/bundle IDs.
func presentation_text(key: String, values: Dictionary = {}) -> String:
	if not _presentation_loaded:
		_presentation_loaded = true
		if FileAccess.file_exists(PRESENTATION_PATH):
			var parsed: Variant = JSON.parse_string(
				FileAccess.get_file_as_string(PRESENTATION_PATH)
			)
			if (
				parsed is Dictionary
				and parsed.get("version") == 1
				and parsed.get("texts") is Dictionary
			):
				for text_key in parsed.texts:
					if text_key is String and parsed.texts[text_key] is String:
						_presentation_texts[text_key] = parsed.texts[text_key]
	var rendered: Dictionary = values.duplicate()
	for parameter in rendered:
		var value: Variant = rendered[parameter]
		if value is float and is_finite(value) and value == floorf(value):
			rendered[parameter] = int(value)
	return str(_presentation_texts.get(key, key)).format(rendered)


func card_sections(copy: Dictionary) -> Array[Dictionary]:
	var card: Dictionary = definition("cards", str(copy.get("card_id", "")))
	if card.is_empty():
		return []
	var result: Array[Dictionary] = []
	for flag in ["retain", "exhaust"]:
		if bool(card.get(flag, false)):
			_append_help(result, _keyword_section(flag))
	for section in _effect_sections(card_effects(card.id, bool(copy.get("upgraded", false)))):
		_append_help(result, section)
	return result


func status_sections(status: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_append_help(result, _keyword_section(status))
	return result


func relic_sections(id: String) -> Array[Dictionary]:
	var relic: Dictionary = definition("relics", id)
	if relic.is_empty():
		return [_help_section("relic", id, "", "main")]
	var values: Dictionary = {}
	var effects: Array = []
	for trigger in _matching_rows("relics", "triggers", "relic_id", id):
		for effect in relic_effects(trigger.effect_group):
			effects.append(effect)
			if effect.get("parameter", "") != "":
				values[effect.parameter] = (
					effect.amount * contract.get("parameter_scales", {}).get(effect.kind, 1)
				)
	var result: Array[Dictionary] = [
		_help_section("relic", text(relic.name_key), text(relic.description_key, values), "main")
	]
	for section in _effect_sections(effects):
		_append_help(result, section)
	return result


func unit_sections(unit: Dictionary, _engine: RefCounted = null) -> Array[Dictionary]:
	if unit.is_empty():
		return []
	var result: Array[Dictionary] = []
	var character: Dictionary = definition("characters", str(unit.get("definition_id", "")))
	if not character.is_empty() and str(character.get("passive", "")) != "":
		var passive_key: String = "hover.passive." + str(character.passive)
		var passive_text: String = presentation_text(
			passive_key, {"amount": character.passive_amount}
		)
		if passive_text != passive_key:
			result.append(
				_help_section(
					"passive", presentation_text("hover.title.passive"), passive_text, "main"
				)
			)
	if bool(unit.get("friendly", false)):
		result.append(
			_help_section(
				"revive_quota",
				"",
				text(
					"ui.revive_quota",
					{
						"used": unit.get("revives_used", 0),
						"limit": unit.get("revive_limit", rule("combat_revive_limit"))
					}
				),
				"main"
			)
		)
	for status in unit.get("statuses", {}):
		var count := 0
		for contribution in unit.statuses[status]:
			count += int(contribution.get("stacks", 0))
		var section: Dictionary = _keyword_section(str(status))
		if not section.is_empty():
			section.title = presentation_text(
				"hover.status.count", {"name": section.title, "count": count}
			)
			_append_help(result, section)
	for mark in unit.get("marks", []):
		if mark.get("kind") == "bomb":
			var section: Dictionary = _keyword_section("bomb")
			section.body = (
				text("ui.bomb_snapshot", {"remaining": mark.remaining, "amount": mark.amount})
				+ "\n"
				+ str(section.body)
			)
			_append_help(result, section)
	return result


func threat_sections(enemy: Dictionary, engine: RefCounted) -> Array[Dictionary]:
	if engine == null or enemy.is_empty() or bool(enemy.get("friendly", false)):
		return []
	# Sort a display copy; never reorder the party used by combat tie-breaking.
	var ranked: Array[Dictionary] = []
	var slot := 0
	for hero in engine.state.heroes:
		if int(hero.hp) > 0:
			ranked.append({"name": text(hero.name_key), "threat": int(hero.threat), "slot": slot})
		slot += 1
	ranked.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return (
				left.slot < right.slot
				if left.threat == right.threat
				else left.threat > right.threat
			)
	)
	var lines: Array[String] = [presentation_text("hover.threat.shared")]
	for index in range(ranked.size()):
		var entry: Dictionary = ranked[index]
		lines.append(
			presentation_text(
				"hover.threat.row", {"rank": index + 1, "name": entry.name, "threat": entry.threat}
			)
		)
	if ranked.is_empty():
		lines.append(presentation_text("hover.threat.empty"))
	return [
		_help_section(
			"threat.ranking", presentation_text("hover.threat.title"), "\n".join(lines), "main"
		),
		_help_section(
			"threat.reason",
			presentation_text("hover.threat.reason_title"),
			_threat_reason(enemy, engine),
			"main"
		),
	]


func _threat_reason(enemy: Dictionary, engine: RefCounted) -> String:
	if int(enemy.get("hp", 0)) <= 0 or enemy.get("intent", {}).is_empty():
		return presentation_text("hover.threat.inactive")
	if bool(enemy.get("interrupted", false)):
		return presentation_text("hover.threat.interrupted")
	var preview: Dictionary = engine.intent_preview(str(enemy.id))
	var selected := false
	var all_heroes := false
	for effect in preview.get("effects", []):
		selected = selected or str(effect.get("target", "selected")) == "selected"
		all_heroes = all_heroes or str(effect.get("target", "")) == "all_enemies"
	if not selected:
		return presentation_text("hover.threat.all" if all_heroes else "hover.threat.support")
	var target: Dictionary = engine.find_unit(str(enemy.get("target_id", "")))
	var reason: String
	if target.is_empty():
		reason = presentation_text("hover.threat.missing_target")
	elif enemy.intent.get("target_rule", "threat") == "lowest_hp_ratio":
		reason = presentation_text(
			"hover.threat.fixed_dead" if int(target.hp) <= 0 else "hover.threat.lowest_locked",
			{"target": text(target.name_key)}
		)
	else:
		reason = presentation_text("hover.threat.by_threat", {"target": text(target.name_key)})
		reason += "\n" + presentation_text("hover.threat.taunt_rule")
	if all_heroes:
		reason += "\n" + presentation_text("hover.threat.additional_all")
	return reason


func _effect_sections(effects: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for effect in effects:
		var keywords: Array = []
		match str(effect.get("kind", "")):
			"threat":
				keywords = ["threat"]
			"dispel", "interrupt", "revive":
				keywords = [effect.kind]
			"clear_status":
				keywords = ["dispel"]
			"taunt":
				keywords = ["taunt", "threat"]
			"apply_status":
				keywords = [effect.get("status", "")]
			"bomb":
				keywords = ["bomb"]
		for keyword in keywords:
			_append_help(result, _keyword_section(str(keyword)))
	return result


func _keyword_section(keyword: String) -> Dictionary:
	var status: Dictionary = definition("battle_rules", keyword, "statuses")
	var title: String
	var body: String
	if not status.is_empty():
		title = text(status.name_key)
		body = status_details(keyword).trim_prefix(title + "：")
		body += (
			"\n"
			+ presentation_text(
				(
					"hover.status.dispellable"
					if bool(status.dispellable)
					else "hover.status.not_dispellable"
				)
			)
		)
	else:
		title = presentation_text("hover.keyword.title." + keyword)
		if title == "hover.keyword.title." + keyword:
			return {}
		if keyword in ["retain", "exhaust", "interrupt", "revive"]:
			body = text("keyword." + keyword, {"limit": rule("combat_revive_limit")}).trim_prefix(
				title + "："
			)
		else:
			var dispellable: Array[String] = []
			for row in _source_rows("battle_rules", "statuses"):
				if bool(row.dispellable):
					dispellable.append(text(row.name_key))
			body = presentation_text(
				"hover.keyword." + keyword,
				{
					"heal_percent": rule("heal_threat") * 100.0,
					"hand_limit": rule("hand_limit"),
					"base_energy": rule("base_energy"),
					"statuses": "、".join(dispellable)
				}
			)
	return _help_section("keyword." + keyword, title, body, "keyword")


func _help_section(id: String, title: String, body: String, kind: String) -> Dictionary:
	return {"id": id, "title": title, "body": body, "kind": kind}


func _append_help(sections: Array[Dictionary], section: Dictionary) -> void:
	if section.is_empty():
		return
	for existing in sections:
		if existing.id == section.id:
			return
	sections.append(section)


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
