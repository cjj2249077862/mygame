extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Battle = preload("res://scripts/core/battle_engine.gd")
const Models = preload("res://scripts/core/models.gd")
const BattleLog = preload("res://scripts/ui/battle/battle_log.gd")


func run_tests() -> void:
	var data := Data.new()
	expect(data.load_directory(), str(data.errors))
	expect(data.rows("cards").size() == 40)
	expect(data.card_effects("double_stab", true)[0].hits == 2)
	var good := data.books.duplicate(true)
	var bad := good.duplicate(true)
	bad.cards.sheets.main.append(bad.cards.sheets.main[0].duplicate(true))
	expect(not data.validate(bad))
	expect(data.books == good, "Rejected data must preserve the working set")
	bad = good.duplicate(true)
	bad.cards.sheets.main[0].cost = "1"
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.effects[0].kind = "unknown"
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.main[0].name_key = "missing"
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.effects[0].amount = -1
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.effects[0].erase("amount")
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.characters.sheets.starter[0].card_id = "missing"
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.encounters.sheets.intents[0].order = 3
	expect(not data.validate(bad))
	expect(data.validate(good), str(data.errors))
	_test_additional_validation(data, good)
	_test_keyword_details(data)
	_test_number_presentation(data)
	_test_phase_two_data(data, good)
	_test_bundle_rejection(data, good)
	_test_heal_export_to_presentation(good)


func _test_phase_two_data(data: RefCounted, good: Dictionary) -> void:
	expect(data.rows("relics").size() == 15)
	expect(data.rows("events").size() == 3)
	expect(data.rows("encounters", "enemies").size() == 11)
	expect(data.chapter_definition().node_count == 10)
	expect(data.price_for("card", "slash") == 35)
	expect(data.weight_for("card", "slash", "battle") == 70)
	expect(data.weight_for("card", "slash", "reward") == 70)
	expect(data.event_options("event_sealed_cache").size() == 3)
	expect(data.event_outcomes("cache_force").size() == 2)
	expect(data.event_effects("cache_force.2").size() == 2)
	expect(data.relic_modifier(["camp_kettle"], "camp_rest", "camp_heal_ratio") == 0.1)
	expect(data.relic_text("camp_kettle").contains("10 个百分点"))
	expect(data.card_text(Models.card(1, "mender_resuscitate")).contains("30%"))
	expect(data.enemy_phases("boss_iron_warden")[0].threshold == 0.5)
	expect(data.enemy_intents("boss_iron_warden", "iron_phase2").size() == 3)
	var copy: Array = data.event_options("event_sealed_cache")
	copy[0].cost_gold = 999
	expect(
		data.event_options("event_sealed_cache")[0].cost_gold == 0,
		"Queries do not expose mutable configuration"
	)
	var bad := good.duplicate(true)
	bad.relics.sheets.triggers[0].event = "missing"
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.encounters.sheets.phases[0].threshold = 1
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.maps.sheets.main[0].boss_encounter_id = "outpost_gate"
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	for option in bad.events.sheets.options:
		if option.id == "cache_force":
			option.min_hp = 8
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.economy.sheets.weights.pop_back()
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.relics.sheets.triggers[0].limit_scope = "actor_turn"
	expect(not data.validate(bad), "Battle-start notifications have no acting-card context")
	bad = good.duplicate(true)
	bad.relics.sheets.effects[0].target = "event_target"
	expect(not data.validate(bad), "Battle-start notifications have no card target")
	bad = good.duplicate(true)
	for effect in bad.relics.sheets.effects:
		if effect.kind == "base_draw" and effect.amount < 0:
			effect.amount = -99
	expect(not data.validate(bad), "Combined relic modifiers cannot make base draw negative")
	bad = good.duplicate(true)
	for weight in bad.economy.sheets.weights:
		if weight.kind == "card" and weight.source == "battle":
			weight.weight = 0
	expect(not data.validate(bad), "Each reward source needs a positive weight total")
	bad = good.duplicate(true)
	for encounter in bad.encounters.sheets.main:
		if encounter.kind == "normal" and encounter.id != "outpost_gate":
			encounter.min_depth = 3
	expect(not data.validate(bad), "A valid ID alone does not make depth-two content available")
	bad = good.duplicate(true)
	for effect in bad.events.sheets.effects:
		if effect.kind == "hp_loss":
			var extra: Dictionary = effect.duplicate(true)
			extra.id = "additional_life_cost_fixture"
			extra.order = 3
			bad.events.sheets.effects.append(extra)
			break
	expect(not data.validate(bad), "Life affordability covers the sum of every effect in a branch")
	expect(data.books == good, "Invalid phase-two content does not replace the active bundle")


func _test_additional_validation(data: RefCounted, good: Dictionary) -> void:
	var bad := good.duplicate(true)
	for effect in bad.cards.sheets.effects:
		if effect.card_id == "double_stab" and effect.upgraded:
			effect.hits = 3
	expect(not data.validate(bad), "Upgrade hit count must retain the confirmed mechanism")
	bad = good.duplicate(true)
	for effect in bad.cards.sheets.effects:
		if effect.card_id == "slash" and effect.upgraded:
			effect.amount = 0
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.effects = bad.cards.sheets.effects.filter(
		func(e: Dictionary) -> bool:
			return not (e.card_id == "first_aid" and e.upgraded and e.kind == "dispel")
	)
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.texts_zh_cn.sheets.main = bad.texts_zh_cn.sheets.main.filter(
		func(row: Dictionary) -> bool: return row.id != "ui.end_turn"
	)
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	for row in bad.texts_zh_cn.sheets.main:
		if row.id == "log.damage":
			row.text = "{missing}"
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	for effect in bad.cards.sheets.effects:
		if effect.card_id == "shield_bash" and effect.kind == "interrupt":
			effect.parameter = "amount"
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.characters.sheets.starter = bad.characters.sheets.starter.filter(
		func(row: Dictionary) -> bool: return row.character_id != "mender"
	)
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.characters.sheets.main[0].portrait = "res://assets/missing.png"
	expect(not data.validate(bad))
	for rule_name in ["weak_multiplier", "vulnerable_multiplier", "hand_limit"]:
		bad = good.duplicate(true)
		for rule in bad.battle_rules.sheets.main:
			if rule.id == rule_name:
				rule.value = {"weak_multiplier": 1.5, "vulnerable_multiplier": 0.5, "hand_limit": 0}[rule_name]
		expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.battle_rules.sheets.main.append({"id": "unknown_rule", "value": 1})
	expect(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.main.append(3)
	expect(not data.validate(bad), "Malformed rows return validation errors instead of crashing")
	expect(data.books == good, "Every failed candidate must preserve the active set")
	# Generic additions reuse the contract; starter count is configurable, not fixed at five.
	var expanded := good.duplicate(true)
	var hero: Dictionary = expanded.characters.sheets.main[0].duplicate(true)
	hero.id = "other_tank_fixture"
	expanded.characters.sheets.main.append(hero)
	expanded.characters.sheets.starter.append(
		{"id": "other.starter", "character_id": hero.id, "card_id": "guard", "count": 2}
	)
	expect(data.validate(expanded), str(data.errors))


func _test_keyword_details(data: RefCounted) -> void:
	var shield_bash := {"card_id": "shield_bash", "upgraded": false}
	expect(data.card_details(shield_bash).contains(data.text("keyword.interrupt")))
	expect(data.status_details("poison").contains("1"))
	expect(not data.status_details("weak").contains("{percent}"))
	expect(data.status_details("weak").contains("75"))
	expect(
		data.card_details(Models.card(1, "assassin_toxin")).contains(data.status_details("poison")),
		"Status cards explain their keyword before the status has been applied"
	)
	expect(
		data.relic_text("quiet_incense").contains(data.status_details("regen")),
		"Relic tooltips explain applied statuses"
	)
	expect(
		data.card_details(Models.card(1, "mender_resuscitate")).contains(
			data.text("keyword.revive", {"limit": data.rule("combat_revive_limit")})
		),
		"Revive cards explain the configured shared quota and recovery rounding"
	)


func _test_number_presentation(data: RefCounted) -> void:
	var values := {"cost": 1.0, "energy": 0.0}
	expect(
		(
			data.text("ui.preview_cost", values)
			== data.text("ui.preview_cost", {"cost": "1", "energy": "0"})
		),
		"Whole JSON numbers render without a decimal suffix"
	)
	expect(
		(
			data.text("status_desc.weak", {"percent": 75.5, "decay": 1.0})
			== data.text("status_desc.weak", {"percent": "75.5", "decay": "1"})
		),
		"Fractional percentages retain their configured value"
	)
	expect(
		values.cost is float and values.energy is float,
		"Presentation does not modify caller-owned numeric values"
	)


func _test_bundle_rejection(data: RefCounted, good: Dictionary) -> void:
	var directory := "user://phase1_data_fixture_%d" % Time.get_ticks_usec()
	expect(DirAccess.make_dir_recursive_absolute(directory) == OK)
	for book in Data.BOOKS:
		var file := FileAccess.open(directory.path_join(book + ".json"), FileAccess.WRITE)
		expect(file != null)
		var payload: Dictionary = good[book].duplicate(true)
		if book == "cards":
			payload.bundle_id = "different_export_batch"
		file.store_string(JSON.stringify(payload))
		file.close()
	expect(not data.load_directory(directory), "Mixed export batches must never become active")
	expect(data.books == good)
	for book in Data.BOOKS:
		DirAccess.remove_absolute(directory.path_join(book + ".json"))
	DirAccess.remove_absolute(directory)


func _test_heal_export_to_presentation(good: Dictionary) -> void:
	# The Python suite changes the real XLSX cell in a temporary copy. Here the
	# equivalent exported value must survive JSON loading and every game consumer.
	var adjusted := good.duplicate(true)
	var changed := 0
	for effect in adjusted.cards.sheets.effects:
		if effect.card_id == "heal" and not effect.upgraded:
			expect(effect.amount == 14, "The delivered starting heal remains 14")
			effect.amount = 18
			changed += 1
	if not expect(changed == 1, "Only one base-heal effect is changed"):
		return
	var directory := "user://phase1_heal_fixture_%d" % Time.get_ticks_usec()
	if not expect(DirAccess.make_dir_recursive_absolute(directory) == OK):
		return
	for book in Data.BOOKS:
		adjusted[book].bundle_id = "phase1_heal_18_fixture"
		var file := FileAccess.open(directory.path_join(book + ".json"), FileAccess.WRITE)
		if not expect(file != null, "Write the temporary exported configuration"):
			_remove_data_fixture(directory)
			return
		file.store_string(JSON.stringify(adjusted[book]))
		file.close()
	var loaded := Data.new()
	if not expect(loaded.load_directory(directory), str(loaded.errors)):
		_remove_data_fixture(directory)
		return
	var card := Models.card(9000, "heal")
	var face := loaded.card_text(card)
	expect(
		face.contains("最多 18 点"),
		"Card face uses the reloaded source value, not the old 14-point value: %s" % face
	)
	for missing_hp in [20, 2]:
		var expected_heal: int = 18 if missing_hp == 20 else 2
		var expected_threat: int = 7 if missing_hp == 20 else 1
		var party: Array = []
		for id in ["warden", "blade", "mender"]:
			party.append(Models.unit(loaded.definition("characters", id), id, true))
		var random := RandomNumberGenerator.new()
		random.seed = 261126
		var battle := Battle.new(loaded)
		battle.start(party, [card.duplicate(true)], "outpost_gate", random)
		var caster: Dictionary = battle.find_unit("mender")
		var target: Dictionary = battle.find_unit("warden")
		# The acceptance example excludes the first-heal passive bonus.
		caster.passive_used = true
		target.hp -= missing_hp
		var before := battle.snapshot()
		var random_before: int = battle.rng.state
		var preview := battle.preview(card.copy_id, caster.id, target.id)
		if not expect(preview.error == "", "Healing fixture has a legal preview"):
			continue
		expect(battle.snapshot() == before, "Preview does not mutate the real battle")
		expect(battle.rng.state == random_before, "Preview does not advance real randomness")
		var target_preview := _find_preview_change(preview, target.id)
		var caster_preview := _find_preview_change(preview, caster.id)
		expect(
			target_preview.get("hp_delta", -1) == expected_heal,
			"Preview clamps healing to missing HP"
		)
		expect(
			caster_preview.get("threat_delta", -1) == expected_threat,
			"Preview rounds actual-healing threat"
		)
		var hp_before: int = target.hp
		var threat_before: int = caster.threat
		if not expect(battle.play_card(card.copy_id, caster.id, target.id) == ""):
			continue
		expect(target.hp - hp_before == expected_heal, "Actual healing equals preview")
		expect(caster.threat - threat_before == expected_threat, "Actual threat equals preview")
		expect(
			battle.state.energy == preview.energy, "Preview and actual resource consumption agree"
		)
		var healing_records: Array = battle.events.records.filter(
			func(record: Dictionary) -> bool: return record.kind == "heal"
		)
		expect(healing_records.size() == 1, "One play emits exactly one healing event")
		if healing_records.size() == 1:
			expect(
				healing_records[0].amount == expected_heal,
				"Event uses actual healing, not base or overheal"
			)
			expect(
				healing_records[0].source == caster.id and healing_records[0].target == target.id
			)
		var log_view := BattleLog.new()
		root.add_child(log_view)
		log_view.append_records(battle.events.records, loaded, battle)
		var expected_line := loaded.text(
			"log.heal",
			{
				"source": loaded.text(caster.name_key),
				"target": loaded.text(target.name_key),
				"amount": expected_heal
			}
		)
		expect(
			log_view.get_parsed_text() == expected_line + "\n",
			"Player-visible log names and healing match the actual action"
		)
		log_view.free()
	_remove_data_fixture(directory)
	for effect in good.cards.sheets.effects:
		if effect.card_id == "heal" and not effect.upgraded:
			expect(effect.amount == 14, "Fixture did not change the original loaded configuration")


func _find_preview_change(preview: Dictionary, unit_id: String) -> Dictionary:
	for change in preview.changes:
		if change.id == unit_id:
			return change
	return {}


func _remove_data_fixture(directory: String) -> void:
	for book in Data.BOOKS:
		var path := directory.path_join(book + ".json")
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(directory)
