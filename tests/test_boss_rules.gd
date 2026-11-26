extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Battle = preload("res://scripts/core/battle_engine.gd")
const Models = preload("res://scripts/core/models.gd")
const Types = preload("res://scripts/core/enums.gd")
var data: RefCounted


class RevivalProbe:
	extends "res://scripts/core/battle_events.gd"
	# Test-only death reaction. The production death/revival primitives are used
	# unchanged; no unconfirmed automatic-revival relic is introduced by this test.
	var owner: WeakRef
	var kill_attacker_once := false
	var notified := 0
	var living_at_first_revival := -1

	func notify(kind: String, context: Dictionary) -> void:
		notified += 1
		super.notify(kind, context)
		var battle: RefCounted = owner.get_ref()
		if kind == "unit_died" and context.target.friendly:
			if living_at_first_revival < 0:
				living_at_first_revival = 0
				for unit in battle.state.heroes:
					living_at_first_revival += 1 if unit.hp > 0 else 0
			battle.resolver.revive({}, context.target, 0.5)
		if kind == "damage_resolved" and kill_attacker_once and context.source.get("id") == "blade":
			kill_attacker_once = false
			battle.resolver.damage({}, context.source, context.source.hp, 0, true)


func run_tests() -> void:
	data = Data.new()
	if not expect(data.load_directory(), str(data.errors)):
		return
	_add_fixtures()
	_test_restore_and_block()
	_test_saved_unit_normalization()
	_test_intent_numeric_round_trip()
	_test_bomb_saved_boundaries()
	_test_revive_and_cards()
	_test_death_interrupts_even_after_revival()
	_test_summon_lifecycle()
	_test_share_slots_and_rounding()
	_test_all_approved_cards()
	_test_relic_opening_and_first_cards()
	_test_success_relics_and_victory()
	_test_bomb_refresh_dispel_and_expiry()
	_test_bomb_chain_before_revival()
	_test_auto_revive_priority()
	_test_phase_boundaries_and_enrage()
	_test_multiple_phase_order_and_early_end()
	_test_periodic_snapshot_and_remainders()


func _add_fixtures() -> void:
	(
		data
		. books
		. encounters
		. sheets
		. enemies
		. append(
			{
				"id": "fixture_enemy",
				"name_key": "ui.enemies",
				"max_hp": 100,
				"strength": 0,
				"interrupt_threshold": 0,
				"immunity_count": 0,
			}
		)
	)
	data.books.encounters.sheets.main.append(
		{"id": "fixture_battle", "enemies": "fixture_enemy,fixture_enemy"}
	)
	(
		data
		. books
		. encounters
		. sheets
		. intents
		. append(
			{
				"id": "fixture_action",
				"enemy_id": "fixture_enemy",
				"kind": "normal",
				"order": 1,
				"amount": 5,
				"hits": 1,
				"status": "",
				"stacks": 0,
			}
		)
	)
	var card: Dictionary = data.definition("cards", "heal")
	card.id = "fixture_revive"
	card.target = "dead_ally"
	card.exhaust = true
	card.owner = ""
	card.role = ""
	data.books.cards.sheets.main.append(card)
	for upgraded in [false, true]:
		var effect: Dictionary = data.card_effects("heal", upgraded)[0]
		effect.id = "fixture_revive_%s" % str(upgraded)
		effect.card_id = "fixture_revive"
		effect.kind = "revive"
		effect.amount = 0.2
		data.books.cards.sheets.effects.append(effect)


func _fresh(
	relic_ids: Array = [], deck: Array = [], encounter_id: String = "fixture_battle"
) -> RefCounted:
	var party: Array = []
	for id in ["warden", "blade", "mender"]:
		party.append(Models.unit(data.definition("characters", id), id, true))
	var random := RandomNumberGenerator.new()
	random.seed = 261127
	var battle: RefCounted = Battle.new(data)
	battle.start(party, deck, encounter_id, random, relic_ids)
	return battle


func _test_restore_and_block() -> void:
	var battle := _fresh()
	battle.state.relic_counters["fixture_counter"] = 3
	battle.state.next_mark_index = 7
	battle.state.action_serial = 11
	battle.state.hand = [Models.card(1, "guard")]
	var saved: Dictionary = battle.snapshot()
	var random := RandomNumberGenerator.new()
	random.seed = battle.rng.seed
	random.state = battle.rng.state
	var before_random: int = random.state
	var restored: RefCounted = Battle.new(data)
	var probe := RevivalProbe.new()
	probe.owner = weakref(restored)
	restored.events = probe
	var decoded: Dictionary = JSON.parse_string(JSON.stringify(saved))
	expect(decoded.phase is float, "Exercise JSON's floating-point representation of phase")
	if not expect(restored.restore(decoded, random), "Restore a valid JSON battle checkpoint"):
		return
	expect(probe.notified == 0 and restored.events.records.is_empty())
	expect(random.state == before_random, "Restore does not shuffle or advance RNG")
	expect(restored.snapshot() == saved, "Restore preserves the complete canonical battle state")
	expect(restored.state.turn == saved.turn and restored.state.hand == saved.hand)
	expect(restored.state.relic_counters == saved.relic_counters)
	expect(restored.state.next_mark_index == 7 and restored.state.action_serial == 11)
	var before: Dictionary = restored.snapshot()
	restored.external_block_reason = "error.save"
	expect(restored.validate_play(1, "warden", "warden") == "error.save")
	expect(restored.play_card(1, "warden", "warden") == "error.save")
	expect(restored.preview(1, "warden", "warden").error == "error.save")
	expect(restored.end_turn() == "error.save")
	expect(restored.snapshot() == before and random.state == before_random)
	var invalid: Dictionary = saved.duplicate(true)
	invalid.phase = Types.BattlePhase.RESOLVING
	expect(not restored.restore(invalid, random) and restored.snapshot() == before)
	for invalid_phase in [1.5, -1, "1", true, INF, NAN]:
		invalid = saved.duplicate(true)
		invalid.phase = invalid_phase
		expect(
			not restored.restore(invalid, random) and restored.snapshot() == before,
			"Reject invalid phase without truncation or partial state replacement"
		)
	invalid = saved.duplicate(true)
	invalid.relic_counters["invalid_object"] = RefCounted.new()
	expect(not restored.restore(invalid, random) and restored.snapshot() == before)
	invalid = saved.duplicate(true)
	invalid[&"invalid_key"] = 1
	expect(not restored.can_restore(invalid), "Save dictionaries still require String keys")
	invalid = saved.duplicate(true)
	invalid.enemies[0].intent.kind = "unknown_intent"
	expect(not restored.can_restore(invalid))
	invalid = saved.duplicate(true)
	invalid.enemies[0].intent.hits = 1.5
	expect(not restored.can_restore(invalid), "Intent counts are checked before normalization")
	invalid = saved.duplicate(true)
	invalid.heroes[0].hp = "invalid_hp"
	expect(not restored.can_restore(invalid))
	invalid = saved.duplicate(true)
	invalid.draw.append(invalid.hand[0].duplicate(true))
	expect(not restored.can_restore(invalid), "Duplicate card copies cannot be restored")
	invalid = saved.duplicate(true)
	invalid.enemies[0].target_id = "missing_hero"
	expect(not restored.can_restore(invalid))
	invalid = saved.duplicate(true)
	invalid.next_mark_index = 1
	invalid.heroes[0].marks = [
		{
			"id": 0,
			"kind": "bomb",
			"source_id": "missing_source",
			"amount": 5,
			"remaining": 1,
			"first_tick_turn": 2
		}
	]
	expect(not restored.can_restore(invalid), "Bomb sources must resolve in the saved battle")
	restored.external_block_reason = ""
	expect(restored.play_card(1, "warden", "warden") == "")


func _test_saved_unit_normalization() -> void:
	var battle := _fresh()
	var tank: Dictionary = battle.find_unit("warden")
	battle.resolver.add_status(battle.find_unit("enemy_0"), tank, "poison", 2, 1.0)
	tank.damage_reductions = [1.0, 0.25]
	var saved: Array = battle.state.heroes.duplicate(true)
	var decoded: Array = JSON.parse_string(JSON.stringify(saved))
	var decoded_before: Array = decoded.duplicate(true)
	var normalized: Array = Models.normalize_saved_units(decoded)
	expect(normalized == saved, "Unit normalization preserves canonical status and reduction types")
	expect(decoded == decoded_before, "Unit normalization never modifies the caller's snapshot")
	expect(
		Models.normalize_saved_units(normalized) == normalized, "Unit normalization is idempotent"
	)
	expect(normalized[0].statuses.poison[0].multiplier is float)
	expect(normalized[0].damage_reductions[0] is float)
	var invalid: Array = decoded.duplicate(true)
	invalid[0].hp = 1.5
	invalid[0].statuses.poison[0].stacks = 2.5
	var unchanged: Array = Models.normalize_saved_units(invalid)
	expect(unchanged[0].hp == 1.5 and unchanged[0].statuses.poison[0].stacks == 2.5)
	_round_trip_battle(battle)


func _test_intent_numeric_round_trip() -> void:
	for encounter_id in ["fixture_battle", "outpost_gate", "outpost_iron_throne"]:
		var battle := _fresh([], [], encounter_id)
		for _turn in range(2):
			for enemy in battle.state.enemies:
				for key in ["hits", "stacks", "order"]:
					expect(enemy.intent[key] is int, "New intents use integer counts and order")
				expect(enemy.intent.amount is float, "Intent amount uses a stable numeric type")
			var restored: RefCounted = _round_trip_battle(battle)
			if restored == null:
				return
			if _round_trip_battle(restored) == null:
				return
			_skip_enemies(battle)
			expect(battle.end_turn() == "")
	var fractional_battle := _fresh()
	var saved: Dictionary = fractional_battle.snapshot()
	saved.enemies[0].intent.amount = 5.75
	var random := RandomNumberGenerator.new()
	if not expect(
		fractional_battle.restore(saved, random), "Fractional intent amounts remain valid"
	):
		return
	expect(
		fractional_battle.find_unit("enemy_0").intent.amount == 5.75, "Amounts are never truncated"
	)
	_round_trip_battle(fractional_battle)


func _test_bomb_saved_boundaries() -> void:
	var battle := _fresh([], [], "outpost_iron_throne")
	var source: Dictionary = battle.find_unit("enemy_0")
	var target: Dictionary = battle.find_unit("warden")
	expect(battle.apply_bomb(source, target, 18, 2))
	for key in target.marks[0]:
		expect(key is String, "New bomb fields keep String keys before JSON serialization")
	if _round_trip_battle(battle) == null:
		return
	expect(battle.apply_bomb(source, target, 22, 2))
	var restored: RefCounted = _round_trip_battle(battle)
	if restored == null:
		return
	for _turn in range(3):
		_skip_enemies(battle)
		_skip_enemies(restored)
		expect(battle.end_turn() == "" and restored.end_turn() == "")
		expect(
			battle.snapshot() == restored.snapshot(), "Restored bomb countdown resolves identically"
		)
		expect(
			battle.events.records == restored.events.records, "Restored bomb logs match live combat"
		)
		if _round_trip_battle(battle) == null:
			return
	expect(target.marks.is_empty(), "Bomb expiry leaves a valid complete checkpoint")


func _round_trip_battle(battle: RefCounted) -> RefCounted:
	var saved: Dictionary = battle.snapshot()
	if not expect(battle.can_restore(saved), "Live checkpoint passes the same validator as saving"):
		return null
	var decoded: Dictionary = JSON.parse_string(JSON.stringify(saved))
	var random := RandomNumberGenerator.new()
	random.seed = battle.rng.seed
	random.state = battle.rng.state
	var before_random: int = random.state
	var restored: RefCounted = Battle.new(data)
	if not expect(restored.restore(decoded, random), "JSON checkpoint restores successfully"):
		return null
	expect(restored.snapshot() == saved, "Save, restore and save again preserve the same state")
	expect(random.state == before_random, "Round-trip restoration preserves random progress")
	expect(restored.events.records.is_empty(), "Restoration does not replay historical events")
	return restored


func _test_revive_and_cards() -> void:
	var battle := _fresh()
	var target: Dictionary = battle.find_unit("blade")
	var healer: Dictionary = battle.find_unit("mender")
	target.max_hp = 53
	target.hp = 53
	target.passive_used = true
	battle.state.hand = [Models.card(1, "double_stab"), Models.card(2, "fixture_revive")]
	battle.state.draw = [Models.card(3, "stab"), Models.card(4, "slash")]
	battle.state.exhaust = [Models.card(5, "double_stab")]
	battle.resolver.damage({}, target, target.hp, 0, true)
	expect(target.death_serial == 1 and target.death_handled)
	expect(battle.state.removed.size() == 2)
	var before: Dictionary = battle.snapshot()
	expect(battle.play_card(2, "mender", "warden") == "error.target")
	expect(battle.snapshot() == before, "A living revival target costs no card or energy")
	var before_random: int = battle.rng.state
	var preview: Dictionary = battle.preview(2, "mender", "blade")
	expect(preview.error == "" and battle.snapshot() == before)
	expect(battle.rng.state == before_random)
	expect(battle.play_card(2, "mender", "blade") == "")
	expect(target.hp == 11 and target.revives_used == 1)
	expect(target.death_serial == 1 and not target.death_handled and target.passive_used)
	expect(target.threat == 0 and healer.threat == 0)
	expect(battle.state.removed.is_empty() and battle.state.draw.size() == 3)
	expect(battle.state.hand.is_empty() and battle.state.exhaust.size() == 2)
	expect(preview.records == battle.events.records)
	for copy in battle.state.draw:
		expect(copy.copy_id not in [2, 5], "Consumed cards are excluded from revival recovery")
	battle.resolver.damage({}, target, target.hp, 0, true)
	expect(target.death_serial == 2 and not battle.can_revive("blade"))
	battle.state.hand.append(Models.card(6, "fixture_revive"))
	before = battle.snapshot()
	expect(battle.play_card(6, "mender", "blade") == "error.target")
	expect(battle.snapshot() == before)
	expect(not battle.resolver.revive(healer, target, 1.0))
	expect(target.revives_used == 1 and target.hp == 0)


func _test_death_interrupts_even_after_revival() -> void:
	var battle := _fresh()
	var probe := RevivalProbe.new()
	probe.owner = weakref(battle)
	battle.events = probe
	var target: Dictionary = battle.find_unit("blade")
	target.hp = 1
	target.threat = 100
	battle.find_unit("enemy_0").intent.hits = 3
	battle.find_unit("enemy_1").interrupted = true
	expect(battle.end_turn() == "")
	expect(target.hp == ceili(target.max_hp * 0.5), "Revival cannot resume enemy multihit")
	expect(target.revives_used == 1 and target.death_serial == 1)
	battle = _fresh()
	probe = RevivalProbe.new()
	probe.owner = weakref(battle)
	probe.kill_attacker_once = true
	battle.events = probe
	var caster: Dictionary = battle.find_unit("blade")
	var enemy: Dictionary = battle.find_unit("enemy_0")
	battle.resolver.apply_card(
		caster, enemy, [{"kind": "damage", "amount": 3, "hits": 3, "threat_mult": 1.0}], ""
	)
	expect(enemy.hp == 97, "A revived caster cannot continue the interrupted attack")
	expect(caster.hp > 0 and caster.death_serial == 1)


func _test_summon_lifecycle() -> void:
	var battle := _fresh()
	for enemy in battle.state.enemies:
		enemy.interrupted = true
	var summoned: Dictionary = battle.spawn_enemy("fixture_enemy")
	expect(summoned.id == "enemy_2" and summoned.spawn_turn == 1)
	expect(summoned.intent.is_empty())
	expect(battle.end_turn() == "")
	expect(battle.state.turn == 2 and not summoned.intent.is_empty())
	for record in battle.events.records:
		expect(record.get("source", "") != summoned.id, "A summon skips its birth turn")
	for enemy in battle.state.enemies:
		if enemy.id != summoned.id:
			enemy.interrupted = true
	expect(battle.end_turn() == "")
	var acted := false
	for record in battle.events.records:
		acted = acted or (record.kind == "damage" and record.source == summoned.id)
	expect(acted)
	var restored: RefCounted = Battle.new(data)
	expect(restored.restore(battle.snapshot(), battle.rng))
	expect(restored.spawn_enemy("fixture_enemy").id == "enemy_3")


func _test_share_slots_and_rounding() -> void:
	var battle := _fresh()
	var tank: Dictionary = battle.find_unit("warden")
	var middle: Dictionary = battle.find_unit("blade")
	var healer: Dictionary = battle.find_unit("mender")
	var ids: Array[String] = []
	for unit in battle.share_participants("blade"):
		ids.append(unit.id)
	expect(ids == ["blade", "warden", "mender"])
	tank.damage_reductions = [0.2, 0.2]
	middle.statuses.vulnerable = [{"source": "enemy_0", "stacks": 1, "multiplier": 1}]
	middle.shield = 2
	healer.shield = 1
	var old_tank: int = tank.hp
	var old_middle: int = middle.hp
	var old_healer: int = healer.hp
	battle.resolver.shared_damage(battle.find_unit("enemy_0"), middle, 10)
	expect(tank.hp == old_tank - 1)
	expect(middle.hp == old_middle - 4 and middle.shield == 0)
	expect(healer.hp == old_healer - 2 and healer.shield == 0)
	battle.resolver.damage({}, middle, middle.hp, 0, true)
	expect(battle.share_participants("blade").is_empty())
	expect(battle.share_participants("warden").size() == 1, "Empty slots never compress")


func _put_card(
	battle: RefCounted, card_id: String, copy_id: int = 1000, upgraded: bool = false
) -> void:
	battle.state.hand = [Models.card(copy_id, card_id, upgraded)]
	battle.state.energy = 99


func _skip_enemies(battle: RefCounted) -> void:
	for enemy in battle.state.enemies:
		enemy.interrupted = true


func _test_all_approved_cards() -> void:
	var tested := 0
	for definition in data.rows("cards"):
		if definition.id.begins_with("fixture_"):
			continue
		for upgraded in [false, true]:
			var battle := _fresh()
			if definition.target == "dead_ally":
				var dead: Dictionary = battle.find_unit("blade")
				battle.resolver.damage({}, dead, dead.hp, 0, true)
			_put_card(battle, definition.id, 1000, upgraded)
			var casters: Array = battle.legal_casters(1000)
			if not expect(not casters.is_empty(), "Approved card has a caster: " + definition.id):
				continue
			var targets: Array = battle.legal_targets(1000, casters[0])
			if not expect(not targets.is_empty(), "Approved card has a target: " + definition.id):
				continue
			var before: Dictionary = battle.snapshot()
			var random_before: int = battle.rng.state
			var preview: Dictionary = battle.preview(1000, casters[0], targets[0])
			expect(preview.error == "", definition.id)
			expect(battle.snapshot() == before and battle.rng.state == random_before, definition.id)
			expect(battle.play_card(1000, casters[0], targets[0]) == "", definition.id)
			expect(
				preview.records == battle.events.records and preview.energy == battle.state.energy,
				definition.id
			)
			tested += 1
	expect(tested == 80, "Both versions of all forty approved cards execute through the same core")
	var battle := _fresh()
	_put_card(battle, "warden_wall")
	expect(battle.action_targets(1000, "warden", "warden") == ["warden", "blade", "mender"])
	expect(battle.preview(1000, "warden", "warden").target_ids.size() == 3)
	expect(battle.play_card(1000, "warden", "warden") == "")
	expect(battle.find_unit("warden").shield == 10)
	expect(battle.find_unit("blade").shield == 7 and battle.find_unit("mender").shield == 7)
	_put_card(battle, "mender_mass_heal")
	expect(battle.play_card(1000, "mender", "mender") == "")
	expect(
		not battle.find_unit("mender").passive_used,
		"Group healing is not a single-target first heal"
	)
	battle = _fresh()
	_put_card(battle, "blade_prepare")
	expect(battle.play_card(1000, "blade", "blade") == "")
	expect(
		battle.state.hand.is_empty() and battle.state.exhaust.size() == 1,
		"A card cannot draw itself while resolving"
	)


func _test_relic_opening_and_first_cards() -> void:
	var deck: Array = []
	for index in range(20):
		deck.append(Models.card(index, "slash"))
	var relics := [
		"iron_rivet",
		"vanguard_banner",
		"sentry_lens",
		"quiet_incense",
		"tank_buckle",
		"assassin_seal",
		"mercy_charm",
		"weapon_stone",
		"boss_furnace",
		"boss_tome",
		"boss_aegis"
	]
	var battle := _fresh(relics, deck)
	expect(battle.state.energy == 4 and battle.state.hand.size() == 6)
	expect(battle.state.card_damage_bonus == 1)
	for hero in battle.state.heroes:
		expect(hero.shield == 7 and battle.status_count(hero, "regen") == 2)
		expect(hero.statuses.regen[0].source == hero.id)
	expect(battle.find_unit("warden").threat == 16)
	_put_card(battle, "guard")
	expect(battle.play_card(1000, "warden", "warden") == "")
	expect(
		battle.find_unit("warden").shield == 21,
		"Opening shield survives and two first-card bonuses add"
	)
	_put_card(battle, "guard", 1001)
	expect(battle.play_card(1001, "warden", "warden") == "")
	expect(battle.find_unit("warden").shield == 30)
	_put_card(battle, "stab", 1002)
	expect(battle.play_card(1002, "blade", "enemy_0") == "")
	expect(battle.find_unit("enemy_0").hp == 85)
	_put_card(battle, "stab", 1003)
	expect(battle.play_card(1003, "blade", "enemy_0") == "")
	expect(
		battle.find_unit("enemy_0").hp == 75,
		"Per-hit stone bonus remains; first-card bonus does not"
	)
	_put_card(battle, "heal", 1004)
	expect(battle.play_card(1004, "mender", "warden") == "")
	battle.find_unit("warden").hp -= 30
	_put_card(battle, "heal", 1005)
	expect(battle.play_card(1005, "mender", "warden") == "")
	expect(
		battle.find_unit("warden").hp == battle.find_unit("warden").max_hp - 16,
		"A zero-recovery first heal spent both opportunities"
	)
	_skip_enemies(battle)
	expect(battle.end_turn() == "")
	for hero in battle.state.heroes:
		expect(hero.shield == 3)
	_put_card(battle, "guard", 1006)
	expect(battle.play_card(1006, "warden", "warden") == "")
	expect(
		battle.find_unit("warden").shield == 17,
		"Per-turn opportunities reset; opening shield does not repeat"
	)
	var saved: Dictionary = battle.snapshot()
	var restored: RefCounted = Battle.new(data)
	var random := RandomNumberGenerator.new()
	random.state = battle.rng.state
	expect(restored.restore(saved, random, relics))
	_put_card(restored, "guard", 1007)
	expect(restored.play_card(1007, "warden", "warden") == "")
	expect(
		restored.find_unit("warden").shield == 26, "Reloading does not refund a relic opportunity"
	)


func _test_success_relics_and_victory() -> void:
	var battle := _fresh(["purge_charm"])
	var tank: Dictionary = battle.find_unit("warden")
	battle.resolver.add_status(battle.find_unit("enemy_0"), tank, "poison", 2)
	_put_card(battle, "first_aid")
	expect(battle.play_card(1000, "mender", "warden") == "")
	expect(tank.shield == 4)
	_put_card(battle, "first_aid", 1001)
	expect(battle.play_card(1001, "mender", "warden") == "")
	expect(tank.shield == 4, "An empty dispel cannot trigger the relic")
	battle = _fresh(["shock_ring"])
	for index in range(2):
		_put_card(battle, "shield_bash", 1000 + index)
		battle.state.draw = [Models.card(2000 + index, "guard")]
		battle.find_unit("enemy_%d" % index).intent.kind = "interruptible"
		expect(battle.play_card(1000 + index, "warden", "enemy_%d" % index) == "")
		expect(battle.state.hand.size() == (1 if index == 0 else 0))
	battle = _fresh(["medical_kit"])
	tank = battle.find_unit("warden")
	tank.hp -= 10
	var fallen: Dictionary = battle.find_unit("blade")
	battle.resolver.damage({}, fallen, fallen.hp, 0, true)
	for enemy in battle.state.enemies:
		battle.resolver.damage({}, enemy, enemy.hp, 0, true)
	expect(battle.settle_boundary())
	expect(tank.hp == tank.max_hp - 7 and tank.threat == 0)
	expect(fallen.hp == 0, "Victory heal precedes Run's post-battle revival")
	expect(battle.settle_boundary() and tank.hp == tank.max_hp - 7)


func _test_bomb_refresh_dispel_and_expiry() -> void:
	var battle := _fresh()
	var tank: Dictionary = battle.find_unit("warden")
	var source: Dictionary = battle.find_unit("enemy_0")
	expect(battle.apply_bomb(source, tank, 18, 2))
	_skip_enemies(battle)
	expect(battle.end_turn() == "" and tank.marks[0].remaining == 2)
	_skip_enemies(battle)
	expect(battle.end_turn() == "" and tank.marks[0].remaining == 1)
	expect(battle.apply_bomb(source, tank, 22, 2))
	expect(
		(
			tank.marks.size() == 1
			and tank.marks[0].remaining == 2
			and tank.marks[0].first_tick_turn == 4
		)
	)
	expect(battle.apply_bomb(battle.find_unit("enemy_1"), tank, 9, 1))
	expect(tank.marks.size() == 2)
	_put_card(battle, "first_aid")
	expect(battle.dispel_options(1000, "warden") == ["bomb"])
	expect(battle.play_card(1000, "mender", "warden") == "")
	expect(tank.marks.is_empty())
	battle = _fresh()
	tank = battle.find_unit("warden")
	source = battle.find_unit("enemy_0")
	source.strength = 1000
	source.statuses.weak = [{"source": "warden", "stacks": 5, "multiplier": 1}]
	tank.statuses.vulnerable = [{"source": "enemy_0", "stacks": 5, "multiplier": 1}]
	expect(battle.apply_bomb(source, tank, 18, 2))
	for turn in range(3):
		_skip_enemies(battle)
		if turn == 2:
			tank.shield = 5
		expect(battle.end_turn() == "")
	expect(tank.hp == tank.max_hp - 22)
	expect(battle.find_unit("blade").hp == battle.find_unit("blade").max_hp - 18)
	expect(tank.marks.is_empty(), "Expiry consumes the bomb before damage, exactly once")
	var explosions := 0
	for record in battle.events.records:
		if record.kind == "bomb_explode":
			explosions += 1
	expect(explosions == 1)


func _test_bomb_chain_before_revival() -> void:
	var battle := _fresh()
	var probe := RevivalProbe.new()
	probe.owner = weakref(battle)
	battle.events = probe
	for hero in battle.state.heroes:
		hero.hp = 5
	var source: Dictionary = battle.find_unit("enemy_0")
	expect(battle.apply_bomb(source, battle.find_unit("warden"), 10, 2))
	expect(battle.apply_bomb(source, battle.find_unit("blade"), 10, 2))
	battle.resolver.damage({}, battle.find_unit("warden"), 5, 0, true)
	expect(probe.living_at_first_revival == 0, "All triggered explosions precede the revival batch")
	var carriers: Array[String] = []
	for record in battle.events.records:
		if record.kind == "bomb_explode":
			carriers.append(record.target)
	expect(carriers == ["warden", "blade"])
	for hero in battle.state.heroes:
		expect(hero.hp > 0 and hero.revives_used == 1 and hero.marks.is_empty())
	expect(battle.state.pending_explosions.is_empty() and battle.state.pending_deaths.is_empty())


func _test_auto_revive_priority() -> void:
	var original: Dictionary = data.books.duplicate(true)
	for entry in [
		{"id": "fixture_auto_high", "priority": 10, "ratio": 0.5},
		{"id": "fixture_auto_low", "priority": 20, "ratio": 0.25}
	]:
		data.books.relics.sheets.main.append({"id": entry.id})
		(
			data
			. books
			. relics
			. sheets
			. triggers
			. append(
				{
					"id": entry.id,
					"relic_id": entry.id,
					"event": "unit_died",
					"qualifier": "all",
					"priority": entry.priority,
					"order": 1,
					"limit_scope": "battle",
					"limit_count": 1,
					"effect_group": entry.id,
				}
			)
		)
		(
			data
			. books
			. relics
			. sheets
			. effects
			. append(
				{
					"id": entry.id,
					"group_id": entry.id,
					"order": 1,
					"kind": "revive",
					"amount": entry.ratio,
					"target": "event_target",
					"hits": 1,
					"duration": 0,
					"status": "",
					"threat_mult": 1.0,
					"parameter": "",
				}
			)
		)
	var battle := _fresh(["fixture_auto_low", "fixture_auto_high"])
	var tank: Dictionary = battle.find_unit("warden")
	battle.resolver.damage({}, tank, tank.hp, 0, true)
	expect(tank.hp == ceili(tank.max_hp * 0.5) and tank.revives_used == 1)
	expect(battle.state.relic_counters.get("fixture_auto_high", 0) == 1)
	expect(
		battle.state.relic_counters.get("fixture_auto_low", 0) == 0,
		"An unused revival source keeps its charge"
	)
	var blade: Dictionary = battle.find_unit("blade")
	battle.resolver.damage({}, blade, blade.hp, 0, true)
	expect(blade.hp == ceili(blade.max_hp * 0.25))
	expect(battle.state.relic_counters.get("fixture_auto_low", 0) == 1)
	data.books = original


func _test_phase_boundaries_and_enrage() -> void:
	var battle := _fresh([], [], "outpost_iron_throne")
	var boss: Dictionary = battle.find_unit("enemy_0")
	boss.statuses.weak = [{"source": "warden", "stacks": 3, "multiplier": 1}]
	boss.statuses.vulnerable = [{"source": "warden", "stacks": 3, "multiplier": 1}]
	boss.statuses.poison = [{"source": "blade", "stacks": 2, "multiplier": 1, "per_stack": 1}]
	boss.interrupted = true
	boss.interrupt_streak = 1
	boss.immunity = 1
	var original_intent: Dictionary = boss.intent.duplicate(true)
	var original_target: String = boss.target_id
	battle.resolver.damage({}, boss, 101, 0, true)
	expect(boss.phases_pending.size() == 1 and boss.phases_triggered.is_empty())
	expect(boss.shield == 0, "Crossing a threshold only marks it within the current action")
	expect(not battle.settle_boundary())
	expect(boss.shield == 18 and boss.phases_triggered.size() == 1)
	expect(not boss.statuses.has("weak") and not boss.statuses.has("vulnerable"))
	expect(boss.statuses.has("poison"))
	expect(boss.intent == original_intent and boss.target_id == original_target)
	expect(boss.interrupted and boss.interrupt_streak == 1 and boss.immunity == 1)
	var next_pool: String = boss.pending_intent_pool
	expect(next_pool != "")
	expect(battle.end_turn() == "")
	expect(
		boss.intent_pool == next_pool and boss.intent.order == 1 and boss.pending_intent_pool == ""
	)
	expect(boss.shield == 0 and boss.phases_triggered.size() == 1)
	battle = _fresh([], [], "outpost_iron_throne")
	boss = battle.find_unit("enemy_0")
	battle.resolver.damage({}, boss, boss.hp, 0, true)
	expect(battle.settle_boundary())
	expect(
		boss.phases_triggered.is_empty() and boss.phases_pending.is_empty(),
		"A dead Boss never enters a phase to save itself"
	)
	battle = _fresh([], [], "outpost_iron_throne")
	boss = battle.find_unit("enemy_0")
	battle.state.turn = 8
	expect(battle.apply_bomb(boss, battle.find_unit("warden"), 18, 2))
	battle._begin_turn()
	expect(battle.state.turn == 9 and boss.enraged)
	expect(battle.find_unit("warden").marks[0].amount == 18)
	boss.intent = data.enemy_intents(boss.definition_id, "")[2]
	boss.target_id = "blade"
	battle.resolver.apply_effects(
		boss, battle.find_unit("blade"), battle._enemy_effects(boss), "", "enemy"
	)
	expect(battle.find_unit("blade").marks[0].amount == 27)
	var before: Dictionary = battle.snapshot()
	var random_before: int = battle.rng.state
	var intent: Dictionary = battle.intent_preview("enemy_0")
	expect(intent.enraged and intent.enrage_turn == 9)
	expect(battle.snapshot() == before and battle.rng.state == random_before)


func _test_multiple_phase_order_and_early_end() -> void:
	var original: Dictionary = data.books.duplicate(true)
	for entry in [
		{"id": "fixture_high", "threshold": 0.75, "shield": 4},
		{"id": "fixture_low", "threshold": 0.5, "shield": 7}
	]:
		(
			data
			. books
			. encounters
			. sheets
			. phases
			. append(
				{
					"id": entry.id,
					"enemy_id": "fixture_enemy",
					"threshold": entry.threshold,
					"enter_effect_group": entry.id,
					"intent_pool": "",
				}
			)
		)
		(
			data
			. books
			. encounters
			. sheets
			. effects
			. append(
				{
					"id": entry.id,
					"group_id": entry.id,
					"order": 1,
					"kind": "shield",
					"target": "self",
					"amount": entry.shield,
					"hits": 1,
					"status": "",
					"duration": 0,
					"threat_mult": 1.0,
					"parameter": "",
				}
			)
		)
	var battle := _fresh()
	var boss: Dictionary = battle.find_unit("enemy_0")
	battle.resolver.damage({}, boss, 60, 0, true)
	battle.resolver.heal(boss, boss, 50)
	expect(boss.hp == 90 and boss.phases_pending.size() == 2)
	expect(not battle.settle_boundary())
	expect(
		boss.phases_triggered == ["fixture_high", "fixture_low"] and boss.shield == 11,
		"Threshold crossings persist through later healing in the same action"
	)
	battle.resolver.damage({}, boss, 1)
	expect(not battle.settle_boundary() and boss.shield == 10)
	(
		data
		. books
		. encounters
		. sheets
		. effects
		. append(
			{
				"id": "fixture_phase_wipe",
				"group_id": "fixture_high",
				"order": 2,
				"kind": "damage",
				"target": "all_enemies",
				"amount": 999,
				"hits": 1,
				"status": "",
				"duration": 0,
				"threat_mult": 1.0,
				"parameter": "",
			}
		)
	)
	battle = _fresh()
	boss = battle.find_unit("enemy_0")
	battle.resolver.damage({}, boss, 60, 0, true)
	expect(battle.settle_boundary() and battle.state.phase == Types.BattlePhase.LOST)
	expect(
		boss.phases_triggered == ["fixture_high"],
		"Check victory after every phase chain before proceeding"
	)
	data.books = original


func _test_periodic_snapshot_and_remainders() -> void:
	var original: Dictionary = data.books.duplicate(true)
	var battle := _fresh()
	var target: Dictionary = battle.find_unit("enemy_0")
	var caster: Dictionary = battle.find_unit("blade")
	battle.resolver.add_status(caster, target, "poison", 1)
	for row in data.books.battle_rules.sheets.statuses:
		if row.id == "poison":
			row.per_stack = 2
	battle.resolver.add_status(caster, target, "poison", 1)
	expect(target.statuses.poison.size() == 2)
	battle.resolver.tick_status(target, "poison")
	expect(
		target.hp == 97 and caster.threat == 3,
		"Each application retains its own per-stack snapshot"
	)
	expect(
		target.statuses.poison.size() == 1 and target.statuses.poison[0].per_stack == 2,
		"Equal decay remainders remove a stack from the first source"
	)
	battle.resolver.tick_status(target, "poison")
	expect(target.hp == 95, "The retained source fragment keeps its own snapshot")
	data.books = original
	battle = _fresh()
	target = battle.find_unit("enemy_0")
	target.hp = 1
	target.statuses.poison = [
		{"source": "blade", "stacks": 1, "multiplier": 1, "per_stack": 1},
		{"source": "mender", "stacks": 1, "multiplier": 1, "per_stack": 2},
	]
	battle.resolver.tick_status(target, "poison")
	expect(battle.find_unit("blade").threat == 0 and battle.find_unit("mender").threat == 1)
	target = battle.find_unit("enemy_1")
	target.statuses.weak = [
		{"source": "warden", "stacks": 4, "multiplier": 1},
		{"source": "blade", "stacks": 1, "multiplier": 1},
		{"source": "mender", "stacks": 2, "multiplier": 1},
	]
	battle.resolver.decay_status(target, "weak", 1)
	expect(
		(
			target.statuses.weak[0].stacks == 3
			and target.statuses.weak[1].stacks == 1
			and target.statuses.weak[2].stacks == 2
		)
	)
