extends RefCounted

signal changed
signal battle_created(engine: RefCounted)

const Types = preload("res://scripts/core/enums.gd")
const Models = preload("res://scripts/core/models.gd")
const Battle = preload("res://scripts/core/battle_engine.gd")
var data: RefCounted
var battle: RefCounted
var rng := RandomNumberGenerator.new()
var phase: int = Types.RunPhase.IDLE
var deck: Array = []
var party: Array = []
var encounters: Array = []
var stage_index := 0
var gold := 0
var reward_candidates: Array[String] = []
var reward_token := 0
var _next_copy_id := 0


func _init(game_data: RefCounted) -> void:
	data = game_data


func start(seed_value: int, lineup: Array[String] = ["warden", "blade", "mender"]) -> bool:
	if lineup.size() != int(data.rule("party_size")):
		return false
	var seen: Dictionary = {}
	for id in lineup:
		if seen.has(id) or data.definition("characters", id).is_empty():
			return false
		seen[id] = true
	rng.seed = seed_value
	deck.clear()
	party.clear()
	reward_candidates.clear()
	reward_token += 1
	_next_copy_id = 0
	stage_index = 0
	gold = int(data.rule("starting_gold"))
	encounters = data.rows("encounters").duplicate(true)
	encounters.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.order < b.order)
	for id in lineup:
		party.append(Models.unit(data.definition("characters", id), id, true))
		for entry in data.rows("characters", "starter"):
			if entry.character_id == id:
				for i in range(int(entry.count)):
					_add_card(entry.card_id)
	_begin_battle()
	return true


func claim_reward(card_id: String, token: int) -> bool:
	if phase != Types.RunPhase.REWARD or token != reward_token or card_id not in reward_candidates:
		return false
	_add_card(card_id)
	_finish_reward()
	return true


func skip_reward(token: int) -> bool:
	if phase != Types.RunPhase.REWARD or token != reward_token:
		return false
	_finish_reward()
	return true


func _finish_reward() -> void:
	reward_candidates.clear()
	reward_token += 1
	stage_index += 1
	_begin_battle()


func _add_card(card_id: String) -> void:
	deck.append(Models.card(_next_copy_id, card_id))
	_next_copy_id += 1


func _begin_battle() -> void:
	phase = Types.RunPhase.BATTLE
	if battle != null and battle.battle_ended.is_connected(_on_battle_ended):
		battle.battle_ended.disconnect(_on_battle_ended)
	battle = Battle.new(data)
	battle.battle_ended.connect(_on_battle_ended)
	battle_created.emit(battle)
	battle.start(party, deck, encounters[stage_index].id, rng)
	changed.emit()


func _on_battle_ended(victory: bool) -> void:
	if phase != Types.RunPhase.BATTLE:
		return
	party = battle.state.heroes.duplicate(true)
	if not victory:
		phase = Types.RunPhase.LOST
		reward_candidates.clear()
		changed.emit()
		return
	for hero in party:
		if hero.hp <= 0:
			hero.hp = mini(
				hero.max_hp, maxi(1, ceili(hero.max_hp * data.rule("post_battle_revive")))
			)
	if stage_index == encounters.size() - 1:
		# This foundation trial does not award full-game completion or unlocks.
		phase = Types.RunPhase.WON
		changed.emit()
		return
	gold += int(encounters[stage_index].gold)
	phase = Types.RunPhase.REWARD
	reward_token += 1
	var pool: Array[String] = []
	for c in data.rows("cards"):
		if not c.reward:
			continue
		for hero in party:
			if (
				(c.owner == "" or c.owner == hero.definition_id)
				and (c.role == "" or c.role == hero.role)
			):
				pool.append(c.id)
				break
	battle.shuffle(pool)
	reward_candidates.clear()
	for i in range(mini(pool.size(), int(data.rule("reward_count")))):
		reward_candidates.append(pool[i])
	changed.emit()
