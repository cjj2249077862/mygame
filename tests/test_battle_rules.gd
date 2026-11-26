extends SceneTree

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Models = preload("res://scripts/core/models.gd")
const Types = preload("res://scripts/core/enums.gd")
var data: RefCounted


func _initialize() -> void:
	data = Data.new()
	assert(data.load_directory(), str(data.errors))
	_test_rejection_and_preview()
	_test_heal_rounding()
	_test_caster_ownership()
	_test_death_and_multihit()
	_test_turn_and_interrupt()
	_test_status_batch()
	_test_dispel_and_retain()
	print("test_battle_rules: passed")
	quit()


func _fresh() -> RefCounted:
	var run := Run.new(data)
	assert(run.start(261126))
	return run


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
	assert(b.play_card(1000, "warden", "warden") == "error.target")
	assert(b.snapshot() == before)
	var preview: Dictionary = b.preview(1000, "warden", "enemy_0")
	assert(preview.error == "")
	assert(b.snapshot() == before and b.rng.state == random_state)
	assert(b.play_card(1000, "warden", "enemy_0") == "")
	for change in preview.changes:
		var previous: Dictionary = {}
		for unit in before.heroes + before.enemies:
			if unit.id == change.id:
				previous = unit
		var actual: Dictionary = b.find_unit(change.id)
		assert(actual.hp - previous.hp == change.hp_delta)
		assert(actual.threat - previous.threat == change.threat_delta)
	_hand(b, "slash")
	b.state.energy = 0
	before = b.snapshot()
	assert(b.play_card(1000, "warden", "enemy_0") == "error.energy")
	assert(b.snapshot() == before)
	assert(b.play_card(-1, "warden", "enemy_0") == "error.card")


func _test_heal_rounding() -> void:
	var original: Dictionary = data.books.duplicate(true)
	for effect in data.books.cards.sheets.effects:
		if effect.card_id == "heal" and not effect.upgraded:
			effect.amount = 18
	assert("18" in data.card_text(Models.card(1, "heal")))
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
		assert(preview.error == "")
		assert(b.play_card(1000, "mender", "warden") == "")
		assert(target.hp - old_hp == (18 if missing == 20 else 2))
		assert(caster.threat == (7 if missing == 20 else 1))
	data.books = original


func _test_caster_ownership() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	var second: Dictionary = Models.unit(data.definition("characters", "warden"), "tank_2", true)
	second.definition_id = "other_tank_fixture"
	b.state.heroes[1] = second
	_hand(b, "guard")
	assert(b.legal_casters(1000) == ["warden", "tank_2"])
	assert(b.play_card(1000, "tank_2", "tank_2") == "")
	assert(second.shield == 12 and second.threat == 0)
	assert(b.find_unit("warden").shield == 0)
	_hand(b, "slash")
	assert(b.play_card(1000, "tank_2", "enemy_0") == "")
	assert(second.threat == 12)
	_hand(b, "shield_bash")
	assert(b.legal_casters(1000) == ["warden"])
	assert(b.play_card(1000, "tank_2", "enemy_0") == "error.caster")
	# Tie keeps the original target; a missing target falls back to leftmost slot.
	second.threat = 20
	b.find_unit("warden").threat = 20
	b.find_unit("enemy_0").target_id = "tank_2"
	b.refresh_targets()
	assert(b.find_unit("enemy_0").target_id == "tank_2")
	b.find_unit("enemy_0").target_id = ""
	b.refresh_targets()
	assert(b.find_unit("enemy_0").target_id == "warden")


func _test_death_and_multihit() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "double_stab")
	b.find_unit("enemy_0").hp = 1
	var other_hp: int = b.find_unit("enemy_1").hp
	assert(b.play_card(1000, "blade", "enemy_0") == "")
	assert(b.find_unit("enemy_1").hp == other_hp)
	assert(b.find_unit("blade").threat == 1)
	_hand(b, "stab")
	b.state.draw = [Models.card(1001, "double_stab"), Models.card(1002, "slash")]
	var blade: Dictionary = b.find_unit("blade")
	b.resolver.damage({}, blade, blade.hp, 0, true)
	assert(b.state.hand.is_empty() and b.state.removed.size() == 2)
	assert(b.state.draw.size() == 1 and run.deck.size() == 15)
	assert(blade.threat == 0 and blade.statuses.is_empty())
	assert(b.resolver.heal(b.find_unit("mender"), blade, 100) == 0)


func _test_turn_and_interrupt() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "shield_bash")
	var enemy: Dictionary = b.find_unit("enemy_0")
	enemy.intent.kind = "interruptible"
	assert(b.play_card(1000, "warden", "enemy_0") == "")
	assert(enemy.interrupted)
	_hand(b, "shield_bash")
	enemy.interrupted = false
	enemy.immunity = 1
	var hp: int = enemy.hp
	assert(b.play_card(1000, "warden", "enemy_0") == "")
	assert(not enemy.interrupted and enemy.hp < hp)
	_hand(b, "guard")
	assert(b.play_card(1000, "warden", "warden") == "")
	assert(b.find_unit("warden").shield == 12)
	b.end_turn()
	assert(b.state.energy == data.rule("base_energy"))
	assert(b.find_unit("warden").shield == 0)
	assert(not b.find_unit("warden").passive_used)
	b.state.hand = []
	b.state.draw = [Models.card(2000, "guard")]
	b.state.discard = [Models.card(2001, "slash")]
	b.draw_cards(5)
	assert(b.state.hand.size() == 2)
	for i in range(20):
		b.state.draw.append(Models.card(3000 + i, "slash"))
	b.draw_cards(20)
	assert(b.state.hand.size() == data.rule("hand_limit") and not b.state.draw.is_empty())


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
	assert(
		b.state.phase == Types.BattlePhase.LOST, "Simultaneous wipe loses; regen cannot resurrect"
	)
	assert(run.phase == Types.RunPhase.LOST)


func _test_dispel_and_retain() -> void:
	var run := _fresh()
	var b: RefCounted = run.battle
	_hand(b, "first_aid")
	var target: Dictionary = b.find_unit("warden")
	b.resolver.add_status(b.find_unit("enemy_0"), target, "poison", 2)
	b.resolver.add_status(b.find_unit("enemy_0"), target, "weak", 1)
	var before: Dictionary = b.snapshot()
	assert(b.play_card(1000, "mender", "warden") == "error.dispel")
	assert(b.snapshot() == before)
	assert(b.play_card(1000, "mender", "warden", "poison") == "")
	assert(not target.statuses.has("poison") and target.statuses.has("weak"))
	assert(b.find_unit("mender").passive_used, "Full-health heal consumes first-card passive")
	var original: Dictionary = data.books.duplicate(true)
	for c in data.books.cards.sheets.main:
		if c.id == "guard":
			c.retain = true
	_hand(b, "guard")
	b.end_turn()
	assert(not b.find_card(1000).is_empty())
	data.books = original
