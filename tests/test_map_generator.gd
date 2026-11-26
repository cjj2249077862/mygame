extends "res://tests/test_suite.gd"

const Map = preload("res://scripts/core/map_generator.gd")
const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Types = preload("res://scripts/core/enums.gd")


func run_tests() -> void:
	var definition := {
		"id": "fixture",
		"node_count": 10,
		"width": 3,
		"first_encounter_id": "first",
		"boss_encounter_id": "boss",
	}
	var rules: Array = []
	var pools: Array = []
	for kind in ["battle", "elite", "camp", "shop", "event"]:
		rules.append(
			{"map_id": "fixture", "kind": kind, "weight": 1, "min_depth": 2, "max_depth": 8}
		)
		if kind in ["battle", "elite", "event"]:
			for index in range(2):
				pools.append(
					{
						"map_id": "fixture",
						"kind": kind,
						"content_id": kind + str(index),
						"weight": 1
					}
				)
	var previous: Dictionary = {}
	var varied := false
	for seed_value in range(80):
		var random := RandomNumberGenerator.new()
		random.seed = seed_value
		var first := Map.generate(definition, pools, rules, random)
		var after: int = random.state
		random.seed = seed_value
		var second := Map.generate(definition, pools, rules, random)
		expect(
			first == second and random.state == after, "Map and RNG replay for seed %d" % seed_value
		)
		expect(
			Map.validate(first), "Reachability, shop and elite-free path for seed %d" % seed_value
		)
		for node in first.nodes:
			if node.kind in ["battle", "elite", "event", "boss"]:
				expect(node.content_id != "", "Every content node has a persisted encounter")
		if not previous.is_empty() and previous != first:
			varied = true
		previous = first
	expect(varied, "New seeds vary routes and contents")
	var bad := previous.duplicate(true)
	bad.nodes[0].next = []
	expect(not Map.validate(bad), "Reject dead ends")
	bad = previous.duplicate(true)
	bad.nodes[0].next = [bad.nodes[0].id]
	expect(not Map.validate(bad), "Reject cycles/backward edges")
	bad = previous.duplicate(true)
	for node in bad.nodes:
		if node.kind == "shop":
			node.kind = "battle"
	expect(not Map.validate(bad), "Reject maps without a shop route")
	bad = previous.duplicate(true)
	for node in bad.nodes:
		if node.depth == 2:
			node.kind = "elite"
	expect(not Map.validate(bad), "Reject mandatory-elite maps")
	_test_run_snapshot_validation()


func _test_run_snapshot_validation() -> void:
	var data := Data.new()
	if not expect(data.load_directory(), str(data.errors)):
		return
	var run: RefCounted
	var saved: Dictionary = {}
	var event_indices: Array[int] = []
	# Select a real generated map with two different events; no production data changes.
	for seed_value in range(261126, 261158):
		run = Run.new(data)
		if not expect(run.start(seed_value), "Start the real chapter for save validation"):
			return
		saved = JSON.parse_string(JSON.stringify(run.snapshot()))
		if not expect(run._valid_snapshot(saved), "Accept an actual JSON-decoded checkpoint"):
			return
		event_indices.clear()
		for index in range(saved.map.nodes.size()):
			if saved.map.nodes[index].kind == "event":
				event_indices.append(index)
		if event_indices.size() >= 2:
			break
	if not expect(event_indices.size() >= 2, "Fixture must include two independently drawn events"):
		return
	var bad := saved.duplicate(true)
	_node_at(bad, 10, 0).content_id = "outpost_gate"
	expect(Map.validate(bad.map), "Replacing Boss content leaves map topology intact")
	expect(not run._valid_snapshot(bad), "Reject normal encounter substituted for final Boss")
	bad = saved.duplicate(true)
	var early := _node_at(bad, 2, 1)
	early.kind = "elite"
	early.content_id = "outpost_trial"
	expect(Map.validate(bad.map), "Early elite fixture retains an elite-free route")
	expect(not run._valid_snapshot(bad), "Reject elite encounter before its configured depth")
	bad = saved.duplicate(true)
	var mismatch := _node_at(bad, 4, 1)
	mismatch.kind = "battle"
	mismatch.content_id = "outpost_trial"
	expect(Map.validate(bad.map), "Encounter-kind mismatch leaves map topology intact")
	expect(not run._valid_snapshot(bad), "Reject encounter outside the node's configured pool")
	bad = saved.duplicate(true)
	bad.map.nodes[event_indices[1]].content_id = bad.map.nodes[event_indices[0]].content_id
	expect(Map.validate(bad.map), "Repeated event fixture remains structurally valid")
	expect(not run._valid_snapshot(bad), "Reject duplicate events anywhere in the chapter")
	bad = saved.duplicate(true)
	bad.relics.append("iron_rivet")
	expect(not run._valid_snapshot(bad), "Reject mismatched adventure and active battle relics")
	# Reach rewards through the public play command, with only enemy HP shortened.
	var battle: RefCounted = run.battle
	var attack_id := -1
	for pile in Types.PILES:
		for copy in battle.state[pile]:
			if copy.card_id == "slash":
				attack_id = int(copy.copy_id)
				if pile != "hand":
					battle.state[pile].erase(copy)
					battle.state.hand.append(copy)
				break
		if attack_id >= 0:
			break
	if not expect(attack_id >= 0 and battle.state.enemies.size() == 1, "Opening encounter fixture"):
		return
	battle.state.enemies[0].hp = 1
	if not expect(battle.play_card(attack_id, "warden", battle.state.enemies[0].id) == ""):
		return
	if not expect(
		run.phase == Types.RunPhase.REWARD, "Public victory enters the reward checkpoint"
	):
		return
	saved = JSON.parse_string(JSON.stringify(run.snapshot()))
	expect(run._valid_snapshot(saved), "Accept a real reward checkpoint")
	bad = saved.duplicate(true)
	bad.party[0].name_key = 17
	expect(not run._valid_snapshot(bad), "Reject invalid display field outside active combat")
	bad = saved.duplicate(true)
	bad.reward_cards_done = true
	bad.reward_relics_done = true
	expect(not run._valid_snapshot(bad), "Reject reward phase with no pending decision")
	bad = saved.duplicate(true)
	bad.reward_cards = []
	bad.reward_cards_done = false
	expect(not run._valid_snapshot(bad), "Reject pending card reward without candidates")
	if not expect(run.abandon_run() == ""):
		return
	saved = JSON.parse_string(JSON.stringify(run.snapshot()))
	expect(run._valid_snapshot(saved), "Accept a real terminal checkpoint")
	bad = saved.duplicate(true)
	bad.result = {"outcome": "abandoned"}
	expect(not run._valid_snapshot(bad), "Reject incomplete terminal result before UI rendering")


func _node_at(saved: Dictionary, depth: int, column: int) -> Dictionary:
	for node in saved.map.nodes:
		if int(node.depth) == depth and int(node.column) == column:
			return node
	return {}
