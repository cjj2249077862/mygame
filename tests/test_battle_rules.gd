extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Models = preload("res://scripts/core/models.gd")
const Types = preload("res://scripts/core/enums.gd")
const Battle = preload("res://scripts/core/battle_engine.gd")
var data: RefCounted


class RuleProbe:
	extends "res://scripts/core/battle_events.gd"
	# Test instrumentation only: all production responders still run unchanged.
	var notifications: Array[String] = []
	var responders: Array[String] = []
	var death_cleanup: Array[bool] = []
	var committed_bonus := 0

	func notify(kind: String, context: Dictionary) -> void:
		notifications.append(kind)
		super.notify(kind, context)
		if kind == "card_played":
			for effect in context.effects:
				committed_bonus += int(effect.get("first_bonus", 0))
		if kind == "unit_died":
			death_cleanup.append(
				(
					context.target.threat == 0
					and context.target.shield == 0
					and context.target.statuses.is_empty()
				)
			)

	func _first_damage(context: Dictionary) -> void:
		responders.append("first_damage")
		super._first_damage(context)

	func _first_shield(context: Dictionary) -> void:
		responders.append("first_shield")
		super._first_shield(context)

	func _first_heal(context: Dictionary) -> void:
		responders.append("first_heal")
		super._first_heal(context)


func run_tests() -> void:
	data = Data.new()
	expect(data.load_directory(), str(data.errors))
	_test_rejection_and_preview()
	_test_heal_rounding()
	_test_caster_ownership()
	_test_death_and_multihit()
	_test_turn_and_interrupt()
	_test_status_batch()
	_test_dispel_and_retain()
	_test_interrupt_only_validation()
	_test_passive_actual_target()
	_test_status_threat_by_source()
	_test_publish_reentry()
	_test_damage_pipeline_and_overkill()
	_test_periodic_effect_rules()
	_test_exhaust_cycle_and_next_battle()
	_test_interrupt_resistance_lifecycle()
	_test_rule_event_order()
	_test_rule_preview_and_lifetime()


func _fresh() -> RefCounted:
	var run := Run.new(data)
	expect(run.start(261126))
	_ensure_second_enemy(run.battle)
	return run


func _ensure_second_enemy(battle: RefCounted) -> void:
	# Production outpost_gate is the approved single-enemy tutorial. Rules tests
	# that need a surviving opponent declare that extra opponent explicitly.
	if battle.state.enemies.size() == 1:
		var first: Dictionary = battle.state.enemies[0]
		var second: Dictionary = Models.unit(
			data.definition("encounters", first.definition_id, "enemies"), "enemy_1", false
		)
		second.intent = first.intent.duplicate(true)
		second.intent_index = first.intent_index
		second.target_id = first.target_id
		battle.state.enemies.append(second)
		battle.state.next_enemy_index = 2


func _hand(battle: RefCounted, id: String) -> void:
	for pile in Types.PILES:
		battle.state[pile] = []
	battle.state.hand = [Models.card(1000, id)]
	battle.state.energy = 3


func _test_rejection_and_preview() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "slash")
	var before: Dictionary = b.snapshot()
	var random_state: int = b.rng.state
	expect(b.play_card(1000, "warden", "warden") == "error.target")
	expect(b.snapshot() == before)
	var preview: Dictionary = b.preview(1000, "warden", "enemy_0")
	expect(preview.error == "")
	expect(b.snapshot() == before and b.rng.state == random_state)
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	for change in preview.changes:
		var previous: Dictionary = {}
		for unit in before.heroes + before.enemies:
			if unit.id == change.id:
				previous = unit
		var actual: Dictionary = b.find_unit(change.id)
		expect(actual.hp - previous.hp == change.hp_delta)
		expect(actual.threat - previous.threat == change.threat_delta)
	_hand(b, "slash")
	b.state.energy = 0
	before = b.snapshot()
	expect(b.play_card(1000, "warden", "enemy_0") == "error.energy")
	expect(b.snapshot() == before)
	expect(b.play_card(-1, "warden", "enemy_0") == "error.card")


func _test_heal_rounding() -> void:
	var original: Dictionary = data.books.duplicate(true)
	for effect in data.books.cards.sheets.effects:
		if effect.card_id == "heal" and not effect.upgraded:
			effect.amount = 18
	expect("18" in data.card_text(Models.card(1, "heal")))
	for missing in [20, 2]:
		var run := _fresh()
		var b: RefCounted = run.battle
		_hand(b, "heal")
		var caster: Dictionary = b.find_unit("mender")
		caster.passive_used = true
		var target: Dictionary = b.find_unit("warden")
		target.hp -= missing
		var old_hp: int = target.hp
		var preview: Dictionary = b.preview(1000, "mender", "warden")
		expect(preview.error == "")
		expect(b.play_card(1000, "mender", "warden") == "")
		expect(target.hp - old_hp == (18 if missing == 20 else 2))
		expect(caster.threat == (7 if missing == 20 else 1))
	data.books = original


func _test_caster_ownership() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	var second: Dictionary = Models.unit(data.definition("characters", "warden"), "tank_2", true)
	second.definition_id = "other_tank_fixture"
	b.state.heroes[1] = second
	_hand(b, "guard")
	expect(b.legal_casters(1000) == ["warden", "tank_2"])
	expect(b.play_card(1000, "tank_2", "tank_2") == "")
	expect(second.shield == 12 and second.threat == 0)
	expect(b.find_unit("warden").shield == 0)
	_hand(b, "slash")
	expect(b.play_card(1000, "tank_2", "enemy_0") == "")
	expect(second.threat == 12)
	_hand(b, "shield_bash")
	expect(b.legal_casters(1000) == ["warden"])
	expect(b.play_card(1000, "tank_2", "enemy_0") == "error.caster")
	# Tie keeps the original target; a missing target falls back to leftmost slot.
	second.threat = 20
	b.find_unit("warden").threat = 20
	b.find_unit("enemy_0").target_id = "tank_2"
	b.refresh_targets()
	expect(b.find_unit("enemy_0").target_id == "tank_2")
	b.find_unit("enemy_0").target_id = ""
	b.refresh_targets()
	expect(b.find_unit("enemy_0").target_id == "warden")


func _test_death_and_multihit() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "double_stab")
	b.find_unit("enemy_0").hp = 1
	var other_hp: int = b.find_unit("enemy_1").hp
	expect(b.play_card(1000, "blade", "enemy_0") == "")
	expect(b.find_unit("enemy_1").hp == other_hp)
	expect(b.find_unit("blade").threat == 1)
	_hand(b, "stab")
	b.state.draw = [Models.card(1001, "double_stab"), Models.card(1002, "slash")]
	var blade: Dictionary = b.find_unit("blade")
	b.resolver.damage({}, blade, blade.hp, 0, true)
	expect(b.state.hand.is_empty() and b.state.removed.size() == 2)
	expect(b.state.draw.size() == 1 and run.deck.size() == 15)
	expect(blade.threat == 0 and blade.statuses.is_empty())
	expect(b.resolver.heal(b.find_unit("mender"), blade, 100) == 0)


func _test_turn_and_interrupt() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "shield_bash")
	var enemy: Dictionary = b.find_unit("enemy_0")
	enemy.intent.kind = "interruptible"
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	expect(enemy.interrupted)
	_hand(b, "shield_bash")
	enemy.interrupted = false
	enemy.immunity = 1
	var hp: int = enemy.hp
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	expect(not enemy.interrupted and enemy.hp < hp)
	_hand(b, "guard")
	expect(b.play_card(1000, "warden", "warden") == "")
	expect(b.find_unit("warden").shield == 12)
	b.end_turn()
	expect(b.state.energy == data.rule("base_energy"))
	expect(b.find_unit("warden").shield == 0)
	expect(not b.find_unit("warden").passive_used)
	b.state.hand = []
	b.state.draw = [Models.card(2000, "guard")]
	b.state.discard = [Models.card(2001, "slash")]
	b.draw_cards(5)
	expect(b.state.hand.size() == 2)
	for i in range(20):
		b.state.draw.append(Models.card(3000 + i, "slash"))
	b.draw_cards(20)
	expect(b.state.hand.size() == data.rule("hand_limit") and not b.state.draw.is_empty())


func _test_status_batch() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	for enemy in b.state.enemies:
		enemy.interrupted = true
	for unit in b.state.heroes + b.state.enemies:
		unit.hp = 1
		unit.statuses = {
			"poison": [{"source": "mender", "stacks": 2, "multiplier": 1}],
			"regen": [{"source": "mender", "stacks": 50, "multiplier": 1}]
		}
	b.end_turn()
	expect(
		b.state.phase == Types.BattlePhase.LOST, "Simultaneous wipe loses; regen cannot resurrect"
	)
	expect(run.phase == Types.RunPhase.LOST)


func _test_dispel_and_retain() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "first_aid")
	var target: Dictionary = b.find_unit("warden")
	b.resolver.add_status(b.find_unit("enemy_0"), target, "poison", 2)
	b.resolver.add_status(b.find_unit("enemy_0"), target, "weak", 1)
	var before: Dictionary = b.snapshot()
	expect(b.play_card(1000, "mender", "warden") == "error.dispel")
	expect(b.snapshot() == before)
	expect(b.play_card(1000, "mender", "warden", "poison") == "")
	expect(not target.statuses.has("poison") and target.statuses.has("weak"))
	expect(b.find_unit("mender").passive_used, "Full-health heal consumes first-card passive")
	var original: Dictionary = data.books.duplicate(true)
	for c in data.books.cards.sheets.main:
		if c.id == "guard":
			c.retain = true
	_hand(b, "guard")
	b.end_turn()
	expect(not b.find_card(1000).is_empty())
	data.books = original


func _test_interrupt_only_validation() -> void:
	var original: Dictionary = data.books.duplicate(true)
	_add_card_fixture("fixture_interrupt", "shield_bash", "enemy", true)
	expect(data.validate(data.books), str(data.errors))
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "fixture_interrupt")
	var enemy: Dictionary = b.find_unit("enemy_0")
	for kind in ["normal", "uninterruptible", "interruptible"]:
		enemy.intent.kind = kind
		enemy.immunity = 1 if kind == "interruptible" else 0
		var before: Dictionary = b.snapshot()
		expect("enemy_0" not in b.legal_targets(1000, "warden"))
		expect(b.play_card(1000, "warden", "enemy_0") == "error.target")
		expect(b.snapshot() == before)
	enemy.immunity = 0
	enemy.interrupted = true
	expect(b.play_card(1000, "warden", "enemy_0") == "error.target")
	enemy.interrupted = false
	expect(b.can_interrupt("enemy_0"))
	expect("enemy_0" in b.legal_targets(1000, "warden"))
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	expect(enemy.interrupted and b.state.energy == 2)
	data.books = original


func _test_passive_actual_target() -> void:
	var original: Dictionary = data.books.duplicate(true)
	_add_card_fixture("fixture_ally_shield", "guard", "ally")
	_add_card_fixture("fixture_self_heal", "heal", "self")
	expect(data.validate(data.books), str(data.errors))
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "fixture_ally_shield")
	expect(b.play_card(1000, "warden", "blade") == "")
	expect(b.find_unit("blade").shield == 9)
	expect(not b.find_unit("warden").passive_used)
	_hand(b, "fixture_ally_shield")
	expect(b.play_card(1000, "warden", "warden") == "")
	expect(b.find_unit("warden").shield == 12)
	expect(b.find_unit("warden").passive_used)
	_hand(b, "fixture_ally_shield")
	expect(b.play_card(1000, "warden", "warden") == "")
	expect(b.find_unit("warden").shield == 21)
	_hand(b, "fixture_self_heal")
	var healer: Dictionary = b.find_unit("mender")
	healer.hp = 20
	expect(b.play_card(1000, "mender", "mender") == "")
	expect(healer.hp == 37 and healer.passive_used)
	data.books = original


func _test_status_threat_by_source() -> void:
	for second_multiplier in [1.0, 1.5]:
		var run := _fresh()
		var b: RefCounted = run.battle
		var target: Dictionary = b.find_unit("enemy_0")
		target.hp = 1
		# Keep fragmented contributions to cover states created by earlier applications.
		target.statuses.poison = [
			{"source": "blade", "stacks": 1, "multiplier": 1.0},
			{"source": "blade", "stacks": 1, "multiplier": second_multiplier}
		]
		b.resolver.tick_status(target, "poison")
		expect(b.find_unit("blade").threat == 1, "Round the caster's weighted total once")
	var run := _fresh()
	var b: RefCounted = run.battle
	var target: Dictionary = b.find_unit("enemy_0")
	var source: Dictionary = b.find_unit("blade")
	b.resolver.add_status(source, target, "poison", 1)
	b.resolver.add_status(source, target, "poison", 1)
	expect(target.statuses.poison.size() == 1 and b.status_count(target, "poison") == 2)
	target.hp = 1
	target.statuses.poison = [
		{"source": "blade", "stacks": 1, "multiplier": 1.0},
		{"source": "mender", "stacks": 1, "multiplier": 1.0}
	]
	b.resolver.tick_status(target, "poison")
	expect(
		source.threat == 1 and b.find_unit("mender").threat == 0,
		"C6 assigns the one actual damage point by largest remainder and fixed source order"
	)
	run = _fresh()
	b = run.battle
	target = b.find_unit("enemy_0")
	target.hp = 1
	b.find_unit("mender").hp = 0
	target.statuses.poison = [
		{"source": "blade", "stacks": 1, "multiplier": 1.0},
		{"source": "mender", "stacks": 1, "multiplier": 1.0}
	]
	b.resolver.tick_status(target, "poison")
	expect(b.find_unit("blade").threat == 1 and b.find_unit("mender").threat == 0)


func _test_publish_reentry() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "slash")
	b.state.hand.append(Models.card(1001, "guard"))
	var attempts: Array = []
	var callback := _attempt_publish_reentry.bind(b, attempts)
	b.settled.connect(callback)
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	b.settled.disconnect(callback)
	expect(attempts == ["error.phase", "error.phase", true, true])
	expect(b.state.turn == 1 and not b.find_card(1001).is_empty())
	expect(b.play_card(1001, "warden", "warden") == "", "Unlock after publishing")
	run = _fresh()
	b = run.battle
	_hand(b, "slash")
	b.find_unit("enemy_0").hp = 1
	b.find_unit("enemy_1").hp = 0
	b.handle_death(b.find_unit("enemy_1"))
	b.settled.connect(_mutate_emitted_snapshot)
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	b.settled.disconnect(_mutate_emitted_snapshot)
	expect(b.state.phase == Types.BattlePhase.WON and run.phase == Types.RunPhase.REWARD)


func _attempt_publish_reentry(
	_records: Array, _snapshot: Dictionary, battle: RefCounted, attempts: Array
) -> void:
	var before: Dictionary = battle.snapshot()
	var random_state: int = battle.rng.state
	attempts.append(battle.end_turn())
	attempts.append(battle.play_card(1001, "warden", "warden"))
	battle.start(before.heroes, [], before.encounter_id, battle.rng)
	attempts.append(battle.snapshot() == before)
	attempts.append(battle.rng.state == random_state)


func _mutate_emitted_snapshot(records: Array, snapshot: Dictionary) -> void:
	records.clear()
	snapshot.phase = Types.BattlePhase.PLAYER


func _add_card_fixture(
	fixture_id: String, base_id: String, target: String, interrupt_only: bool = false
) -> void:
	var definition: Dictionary = data.definition("cards", base_id)
	definition.id = fixture_id
	definition.target = target
	definition.reward = false
	definition["_source"] = "test_battle_rules/" + fixture_id
	if interrupt_only:
		definition.description_key = "ui.cast"
	data.books.cards.sheets.main.append(definition)
	for upgraded in [false, true]:
		var order := 0
		for effect in data.card_effects(base_id, upgraded):
			if interrupt_only and effect.kind != "interrupt":
				continue
			order += 1
			effect.card_id = fixture_id
			effect.order = order
			effect.id = "%s.%s.%d" % [fixture_id, str(upgraded), order]
			effect["_source"] = definition._source
			data.books.cards.sheets.effects.append(effect)


func _test_damage_pipeline_and_overkill() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "slash")
	var caster: Dictionary = b.find_unit("warden")
	var target: Dictionary = b.find_unit("enemy_0")
	caster.strength = 3
	caster.statuses.weak = [{"source": "enemy_0", "stacks": 1, "multiplier": 1}]
	target.statuses.vulnerable = [{"source": "warden", "stacks": 1, "multiplier": 1}]
	target.shield = 4
	target.hp = 20
	# floor((8 + 3) * 0.75 * 1.5) = 12, then absorb four with the shield.
	expect(b.resolver.damage_value(caster, target, 8) == 12)
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	expect(target.shield == 0 and target.hp == 12)
	expect(caster.threat == 28)
	run = _fresh()
	b = run.battle
	_hand(b, "slash")
	caster = b.find_unit("warden")
	target = b.find_unit("enemy_0")
	target.shield = 3
	target.hp = 2
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	expect(target.hp == 0 and target.shield == 0)
	expect(caster.threat == 18, "Only actual 3 shield + 2 HP produce threat, rounded once")
	expect(b.events.records[0].kind == "damage" and b.events.records[0].amount == 5)


func _test_periodic_effect_rules() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	var caster: Dictionary = b.find_unit("blade")
	var target: Dictionary = b.find_unit("enemy_0")
	caster.strength = 100
	caster.statuses.weak = [{"source": "enemy_0", "stacks": 1, "multiplier": 1}]
	target.statuses.vulnerable = [{"source": "blade", "stacks": 1, "multiplier": 1}]
	target.shield = 10
	target.hp = 30
	b.resolver.add_status(caster, target, "poison", 4, 1.5)
	b.resolver.tick_status(target, "poison")
	expect(
		target.hp == 26 and target.shield == 10, "Poison ignores shield and direct-damage modifiers"
	)
	expect(caster.threat == 6 and b.status_count(target, "poison") == 3)
	run = _fresh()
	b = run.battle
	caster = b.find_unit("blade")
	target = b.find_unit("enemy_0")
	target.shield = 3
	target.hp = 30
	b.resolver.add_status(caster, target, "burn", 4)
	b.resolver.tick_status(target, "burn")
	expect(target.shield == 0 and target.hp == 29)
	expect(caster.threat == 4 and b.status_count(target, "burn") == 3)
	var healer: Dictionary = b.find_unit("mender")
	var ally: Dictionary = b.find_unit("warden")
	ally.hp = ally.max_hp - 2
	ally.statuses.regen = [
		{"source": "mender", "stacks": 5, "multiplier": 1},
		{"source": "mender", "stacks": 5, "multiplier": 1}
	]
	b.resolver.tick_status(ally, "regen")
	expect(ally.hp == ally.max_hp and healer.threat == 1)
	expect(b.status_count(ally, "regen") == 9)
	b.resolver.damage({}, ally, ally.hp, 0, true)
	b.resolver.add_status(healer, ally, "regen", 20)
	b.resolver.tick_status(ally, "regen")
	expect(ally.hp == 0 and ally.statuses.is_empty(), "Regen cannot revive a dead ally")


func _test_exhaust_cycle_and_next_battle() -> void:
	var original: Dictionary = data.books.duplicate(true)
	_add_card_fixture("fixture_exhaust", "slash", "enemy")
	for card in data.books.cards.sheets.main:
		if card.id == "fixture_exhaust":
			card.exhaust = true
	expect(data.validate(data.books), str(data.errors))
	var run := _fresh()
	var b: RefCounted = run.battle
	var fixture := Models.card(1000, "fixture_exhaust")
	run.deck.append(fixture.duplicate(true))
	b.state.hand.append(fixture.duplicate(true))
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	expect(b.state.exhaust.size() == 1 and b.state.exhaust[0].copy_id == 1000)
	for cycle in range(5):
		b.state.discard.append_array(b.state.hand)
		b.state.hand.clear()
		b.draw_cards(100)
		expect(b.find_card(1000).is_empty() and b.state.exhaust.size() == 1)
	for enemy in b.state.enemies:
		if enemy.hp <= 0:
			continue
		enemy.hp = 1
		_hand_preserving_exhaust(b, "slash")
		expect(b.play_card(2000, "warden", enemy.id) == "")
	expect(run.phase == Types.RunPhase.REWARD)
	expect(run.skip_reward(run.reward_token))
	var next_battle: RefCounted = Battle.new(data)
	next_battle.start(run.party, run.deck, b.state.encounter_id, run.rng)
	var restored_count := 0
	for pile in Types.PILES:
		for card in next_battle.state[pile]:
			if card.copy_id == 1000:
				restored_count += 1
				expect(pile in ["hand", "draw"])
	expect(restored_count == 1 and next_battle.state.exhaust.is_empty())
	data.books = original


func _hand_preserving_exhaust(battle: RefCounted, card_id: String) -> void:
	for pile in ["hand", "draw", "discard"]:
		battle.state[pile] = []
	battle.state.hand = [Models.card(2000, card_id)]
	battle.state.energy = 3


func _test_interrupt_resistance_lifecycle() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	var enemy: Dictionary = b.find_unit("enemy_0")
	enemy.max_hp = 1000
	enemy.hp = 1000
	enemy.interrupt_threshold = 2
	enemy.immunity_count = 2
	for successful_interrupt in range(2):
		_hand(b, "shield_bash")
		enemy.intent.kind = "interruptible"
		expect(b.play_card(1000, "warden", "enemy_0") == "")
		expect(enemy.interrupted)
		b.find_unit("enemy_1").interrupted = true
		expect(b.end_turn() == "")
		expect(enemy.immunity == (0 if successful_interrupt == 0 else 2))
	expect(enemy.interrupt_streak == 0)
	enemy.intent.kind = "normal"
	b.find_unit("enemy_1").interrupted = true
	expect(b.end_turn() == "")
	expect(enemy.immunity == 2, "Ordinary actions cannot spend interruptible-cast immunity")
	for expected_remaining in [1, 0]:
		_hand(b, "shield_bash")
		enemy.intent.kind = "interruptible"
		var hp_before: int = enemy.hp
		expect(b.play_card(1000, "warden", "enemy_0") == "")
		expect(not enemy.interrupted and enemy.hp < hp_before)
		b.find_unit("enemy_1").interrupted = true
		expect(b.end_turn() == "")
		expect(enemy.immunity == expected_remaining)
	_hand(b, "shield_bash")
	enemy.intent.kind = "interruptible"
	expect(b.play_card(1000, "warden", "enemy_0") == "")
	expect(enemy.interrupted and enemy.interrupt_streak == 1)
	enemy.interrupted = false
	enemy.intent.kind = "normal"
	b.find_unit("enemy_1").interrupted = true
	expect(b.end_turn() == "")
	expect(enemy.interrupt_streak == 0)


func _test_rule_event_order() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	var probe := RuleProbe.new()
	b.events = probe
	var party: Array = run.party.duplicate(true)
	for hero in party:
		hero.passive_used = true
	b.start(party, run.deck, b.state.encounter_id, b.rng)
	_ensure_second_enemy(b)
	expect(
		probe.notifications == ["base_resources", "battle_started", "turn_started", "cards_drawn"]
	)
	for hero in b.state.heroes:
		expect(not hero.passive_used, "Lifecycle responders reset each actual caster")
	probe.notifications.clear()
	# Presentation records cannot fire rules or consume a first-card opportunity.
	probe.append("shield", {"target": "warden", "amount": 99})
	expect(probe.notifications.is_empty() and not b.find_unit("warden").passive_used)
	_hand(b, "guard")
	var before: Dictionary = b.snapshot()
	expect(b.play_card(1000, "warden", "blade") == "error.target")
	expect(b.snapshot() == before and probe.notifications.is_empty())
	expect(b.play_card(1000, "warden", "warden") == "")
	expect(probe.notifications == ["card_played", "shield_granted", "card_resolved"])
	expect(probe.responders == ["first_damage", "first_shield", "first_heal"])
	expect(probe.committed_bonus == b.find_unit("warden").passive_amount)
	expect(b.find_unit("warden").shield == 12)
	probe.notifications.clear()
	for enemy in b.state.enemies:
		enemy.interrupted = true
	expect(b.end_turn() == "")
	expect(probe.notifications == ["turn_ended", "base_resources", "turn_started", "cards_drawn"])
	expect(not b.find_unit("warden").passive_used)
	# The lethal transition, death cleanup, card completion and win all settle
	# before either presentation signal can observe the action.
	b.find_unit("enemy_0").hp = 1
	b.find_unit("enemy_1").hp = 0
	b.handle_death(b.find_unit("enemy_1"))
	probe.notifications.clear()
	probe.death_cleanup.clear()
	_hand(b, "double_stab")
	var publications: Array = []
	var callback := _capture_rule_publication.bind(probe, publications)
	b.settled.connect(callback)
	expect(b.play_card(1000, "blade", "enemy_0") == "")
	b.settled.disconnect(callback)
	var expected := ["card_played", "damage_resolved", "unit_died", "card_resolved", "battle_ended"]
	expect(probe.notifications == expected, "A lethal first hit skips later hits")
	expect(probe.death_cleanup == [true])
	expect(publications.size() == 1)
	if publications.size() == 1:
		expect(publications[0].notifications == expected)
		expect(publications[0].phase == Types.BattlePhase.WON)
		expect(publications[0].records == ["damage", "death", "win"])


func _capture_rule_publication(
	records: Array, snapshot: Dictionary, probe: RefCounted, publications: Array
) -> void:
	var kinds: Array[String] = []
	for record in records:
		kinds.append(record.kind)
	(
		publications
		. append(
			{
				"notifications": probe.notifications.duplicate(),
				"phase": snapshot.phase,
				"records": kinds,
			}
		)
	)


func _test_rule_preview_and_lifetime() -> void:
	for scenario in [
		["guard", "warden", "warden"],
		["double_stab", "blade", "enemy_0"],
		["heal", "mender", "warden"],
	]:
		var run := _fresh()
		var b: RefCounted = run.battle
		_hand(b, scenario[0])
		if scenario[0] == "heal":
			b.find_unit("warden").hp -= 20
		var before: Dictionary = b.snapshot()
		var records_before: Array = b.events.records.duplicate(true)
		var rng_before: int = b.rng.state
		var preview: Dictionary = b.preview(1000, scenario[1], scenario[2])
		expect(preview.error == "")
		expect(b.snapshot() == before and b.events.records == records_before)
		expect(b.rng.state == rng_before)
		expect(b.play_card(1000, scenario[1], scenario[2]) == "")
		expect(b.find_unit(scenario[1]).passive_used)
		expect(preview.records == b.events.records, "Preview uses the same fixed rule responders")
		for change in preview.changes:
			var previous: Dictionary = {}
			for unit in before.heroes + before.enemies:
				if unit.id == change.id:
					previous = unit
			var after: Dictionary = b.find_unit(change.id)
			expect(after.hp - previous.hp == change.hp_delta)
			expect(after.shield - previous.shield == change.shield_delta)
			expect(after.threat - previous.threat == change.threat_delta)
	# Keep the components alive after dropping the battle, proving neither stores
	# a strong owner or the borrowed event contexts from real/preview settlement.
	var run := _fresh()
	var detached: RefCounted = Battle.new(data)
	var random := RandomNumberGenerator.new()
	random.seed = 261126
	detached.start(run.party, run.deck, run.battle.state.encounter_id, random)
	_hand(detached, "guard")
	expect(detached.preview(1000, "warden", "warden").error == "")
	expect(detached.play_card(1000, "warden", "warden") == "")
	var events: RefCounted = detached.events
	var resolver: RefCounted = detached.resolver
	var owner: WeakRef = weakref(detached)
	detached = null
	expect(owner.get_ref() == null and resolver.engine == null)
	expect(not events.records.is_empty())
