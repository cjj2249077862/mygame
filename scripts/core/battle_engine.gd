class_name BattleEngine
extends RefCounted

signal state_changed
signal log_added(text: String)
signal battle_ended(victory: bool)

var party: Array = []          # Array of Models.UnitState
var enemies: Array = []        # Array of Models.UnitState
var enemy_intents: Dictionary = {} # enemy_id -> Models.EnemyIntent

var master_deck: Array = []    # 局外持久卡组
var draw_pile: Array = []
var hand: Array = []
var discard_pile: Array = []

var max_energy: int = 3
var energy: int = 3
var turn_number: int = 1
var stage_index: int = 1       # 1: 小怪, 2: 精英, 3: Boss
var is_battle_over: bool = false

func start_new_run() -> void:
	master_deck = CardDB.build_starter_deck()
	party = [
		Models.UnitState.new("tank", "铁壁·坦克", Enums.Role.TANK, 65),
		Models.UnitState.new("dps", "影刃·输出", Enums.Role.DPS, 40),
		Models.UnitState.new("healer", "圣光·治疗", Enums.Role.HEALER, 45),
	]
	stage_index = 1
	start_stage(stage_index)

func start_stage(stage: int) -> void:
	stage_index = stage
	is_battle_over = false
	turn_number = 1

	for member in party:
		member.shield = 0
		member.threat = 10 if member.role == Enums.Role.TANK else 0
		member.poison = 0
		member.vulnerable = 0
		member.regen = 0

	enemies.clear()
	enemy_intents.clear()

	match stage:
		1:
			enemies.append(Models.UnitState.new("e1", "地牢哨兵", Enums.Role.ENEMY, 55))
		2:
			enemies.append(Models.UnitState.new("e1", "狂暴食人魔", Enums.Role.ENEMY, 75))
			enemies.append(Models.UnitState.new("e2", "剧毒萨满", Enums.Role.ENEMY, 45))
		3:
			enemies.append(Models.UnitState.new("boss", "【BOSS】腐化守卫", Enums.Role.ENEMY, 130))

	draw_pile = master_deck.duplicate()
	draw_pile.shuffle()
	hand.clear()
	discard_pile.clear()

	_log("=== 第 %d 关开始 ===" % stage_index)
	_begin_player_turn()

func _begin_player_turn() -> void:
	energy = max_energy
	for member in party:
		if member.is_alive():
			member.shield = 0
	_roll_enemy_intents()
	_draw_cards(5)
	_log("--- 第 %d 回合 ---" % turn_number)
	emit_signal("state_changed")

func _roll_enemy_intents() -> void:
	enemy_intents.clear()
	for enemy in enemies:
		if not enemy.is_alive():
			continue
		var intent: Models.EnemyIntent
		if enemy.id == "boss":
			var mod := turn_number % 3
			if mod == 1:
				intent = Models.EnemyIntent.new(Enums.IntentType.ATTACK_AGGRO, "重锤顺劈 (打最高仇恨)", 16, false)
			elif mod == 2:
				intent = Models.EnemyIntent.new(Enums.IntentType.CAST_BIG_HIT, "【读条】毁灭打击 (28伤·可打断)", 28, true)
			else:
				intent = Models.EnemyIntent.new(Enums.IntentType.CAST_POISON, "【读条】瘟疫爆发 (全体3毒·可打断)", 3, true)
		elif enemy.id == "e2":
			if turn_number % 2 == 0:
				intent = Models.EnemyIntent.new(Enums.IntentType.CAST_POISON, "【读条】毒雾术 (全体2毒·可打断)", 2, true)
			else:
				intent = Models.EnemyIntent.new(Enums.IntentType.ATTACK_AGGRO, "暗影箭 (打最高仇恨)", 9, false)
		else:
			if enemy.id == "e1" and stage_index == 2 and turn_number % 3 == 0:
				intent = Models.EnemyIntent.new(Enums.IntentType.CAST_BIG_HIT, "【读条】蓄力猛砸 (22伤·可打断)", 22, true)
			else:
				intent = Models.EnemyIntent.new(Enums.IntentType.ATTACK_AGGRO, "普攻 (打最高仇恨)", 11, false)
		enemy_intents[enemy.id] = intent

func play_card(hand_index: int, target_id: String = "") -> bool:
	if is_battle_over or hand_index < 0 or hand_index >= hand.size():
		return false
	var card: Models.CardData = hand[hand_index]
	if card.cost > energy:
		_log("能量不足，无法打出 [%s]" % card.title)
		return false

	var owner_unit := _get_alive_by_role(card.owner_role)
	if owner_unit == null:
		_log("对应职业已阵亡，无法使用 [%s]！" % card.title)
		return false

	var target_unit := _find_unit(target_id)
	if card.target_type != Enums.TargetType.NONE and (target_unit == null or not target_unit.is_alive()):
		_log("请先选择一个有效的目标")
		return false

	energy -= card.cost
	hand.remove_at(hand_index)
	discard_pile.append(card)
	_log("打出 [%s]" % card.title)

	for eff in card.effects:
		_apply_effect(eff, owner_unit, target_unit)

	_check_battle_end()
	emit_signal("state_changed")
	return true

func _apply_effect(eff: Dictionary, owner_unit: Models.UnitState, target_unit: Models.UnitState) -> void:
	match eff["op"]:
		"damage":
			if target_unit == null:
				return
			var dmg: int = eff["val"]
			if target_unit.vulnerable > 0:
				dmg = int(round(dmg * 1.5))
			_deal_damage(target_unit, dmg)
			var threat_gain := int(round(dmg * eff.get("threat_mult", 1.0)))
			owner_unit.threat += threat_gain
			_log("  -> 对 %s 造成 %d 伤害 (%s 仇恨 +%d)" % [target_unit.display_name, dmg, owner_unit.display_name, threat_gain])
		"shield_role":
			var u := _get_alive_by_role(eff["role"])
			if u:
				u.shield += eff["val"]
				_log("  -> %s 获得 %d 护盾" % [u.display_name, eff["val"]])
		"shield_all":
			for m in party:
				if m.is_alive():
					m.shield += eff["val"]
			_log("  -> 全队获得 %d 护盾" % eff["val"])
		"threat_role":
			var u := _get_alive_by_role(eff["role"])
			if u:
				u.threat += eff["val"]
		"taunt_role":
			var u := _get_alive_by_role(eff["role"])
			if u:
				var max_t := 0
				for m in party:
					if m.is_alive() and m.threat > max_t:
						max_t = m.threat
				u.threat = max_t + eff["bonus"]
				_log("  -> %s 嘲讽！仇恨跃升至 %d" % [u.display_name, u.threat])
		"reset_threat_role":
			var u := _get_alive_by_role(eff["role"])
			if u:
				u.threat = 0
				_log("  -> %s 假死脱战，仇恨清零" % u.display_name)
		"interrupt":
			if target_unit and enemy_intents.has(target_unit.id):
				var intent: Models.EnemyIntent = enemy_intents[target_unit.id]
				if intent.interruptible and not intent.interrupted:
					intent.interrupted = true
					intent.title = "【已打断】"
					_log("  -> 成功打断了 %s 的读条技能！" % target_unit.display_name)
		"apply_poison":
			if target_unit:
				target_unit.poison += eff["val"]
				_log("  -> %s 中毒 +%d 层" % [target_unit.display_name, eff["val"]])
		"apply_vulnerable":
			if target_unit:
				target_unit.vulnerable += eff["val"]
				_log("  -> %s 获得 %d 回合易伤" % [target_unit.display_name, eff["val"]])
		"heal_target":
			if target_unit and target_unit.is_alive():
				var healed: int = min(eff["val"], target_unit.max_hp - target_unit.hp)
				target_unit.hp += healed
				owner_unit.threat += int(round(healed * 0.4))
				_log("  -> 治疗 %s +%d 生命" % [target_unit.display_name, healed])
		"heal_all":
			for m in party:
				if m.is_alive():
					var healed: int = min(eff["val"], m.max_hp - m.hp)
					m.hp += healed
			owner_unit.threat += 6
			_log("  -> 全队恢复 %d 生命" % eff["val"])
		"regen_all":
			for m in party:
				if m.is_alive():
					m.regen += eff["val"]
		"dispel_target":
			if target_unit and target_unit.is_alive():
				target_unit.poison = 0
				target_unit.vulnerable = 0
				_log("  -> 驱散了 %s 的负面状态" % target_unit.display_name)
		"draw":
			_draw_cards(eff["val"])

func end_player_turn() -> void:
	if is_battle_over:
		return

	# 弃掉手牌
	for c in hand:
		discard_pile.append(c)
	hand.clear()

	# 敌方行动
	for enemy in enemies:
		if not enemy.is_alive():
			continue
		var intent: Models.EnemyIntent = enemy_intents.get(enemy.id, null)
		if intent == null:
			continue
		if intent.interrupted:
			_log("%s 因被打断而跳过行动！" % enemy.display_name)
			continue

		match intent.type:
			Enums.IntentType.ATTACK_AGGRO, Enums.IntentType.CAST_BIG_HIT:
				var aggro_target := get_highest_threat_ally()
				if aggro_target:
					_log("%s 攻击最高仇恨目标 %s (%d 伤害)" % [enemy.display_name, aggro_target.display_name, intent.power])
					_deal_damage(aggro_target, intent.power)
			Enums.IntentType.CAST_POISON:
				_log("%s 释放全体毒雾！全队 +%d 层中毒" % [enemy.display_name, intent.power])
				for m in party:
					if m.is_alive():
						m.poison += intent.power
			Enums.IntentType.ATTACK_AOE:
				for m in party:
					if m.is_alive():
						_deal_damage(m, intent.power)

	# 回合末结算 DOT / HOT / 易伤递减
	_tick_statuses(party)
	_tick_statuses(enemies)

	_check_battle_end()
	if not is_battle_over:
		turn_number += 1
		_begin_player_turn()
	else:
		emit_signal("state_changed")

func _tick_statuses(units: Array) -> void:
	for u in units:
		if not u.is_alive():
			continue
		if u.poison > 0:
			_deal_damage(u, u.poison)
			_log("  %s 受到 %d 点毒素伤害" % [u.display_name, u.poison])
			u.poison = max(0, u.poison - 1)
		if u.is_alive() and u.regen > 0:
			var heal_amt: int = min(4, u.max_hp - u.hp)
			u.hp += heal_amt
			u.regen = max(0, u.regen - 1)
		if u.vulnerable > 0:
			u.vulnerable = max(0, u.vulnerable - 1)

func _deal_damage(target: Models.UnitState, amount: int) -> void:
	var rem := amount
	if target.shield > 0:
		var blocked: int = min(target.shield, rem)
		target.shield -= blocked
		rem -= blocked
	if rem > 0:
		target.hp = max(0, target.hp - rem)
		if target.hp == 0:
			_log("  [!] %s 倒下了！" % target.display_name)

func _draw_cards(count: int) -> void:
	for i in range(count):
		if draw_pile.is_empty():
			if discard_pile.is_empty():
				break
			draw_pile = discard_pile.duplicate()
			discard_pile.clear()
			draw_pile.shuffle()
		hand.append(draw_pile.pop_back())

func get_highest_threat_ally() -> Models.UnitState:
	var best: Models.UnitState = null
	for m in party:
		if m.is_alive():
			if best == null or m.threat > best.threat:
				best = m
	return best

func _get_alive_by_role(role: int) -> Models.UnitState:
	for m in party:
		if m.role == role and m.is_alive():
			return m
	return null

func _find_unit(id: String) -> Models.UnitState:
	for m in party:
		if m.id == id:
			return m
	for e in enemies:
		if e.id == id:
			return e
	return null

func _check_battle_end() -> void:
	var any_enemy_alive := false
	for e in enemies:
		if e.is_alive():
			any_enemy_alive = true
			break
	if not any_enemy_alive:
		is_battle_over = true
		_log("=== 战斗胜利！ ===")
		emit_signal("battle_ended", true)
		return

	var any_ally_alive := false
	for m in party:
		if m.is_alive():
			any_ally_alive = true
			break
	if not any_ally_alive:
		is_battle_over = true
		_log("=== 小队团灭... ===")
		emit_signal("battle_ended", false)

func add_card_to_master_deck(card: Models.CardData) -> void:
	master_deck.append(card)

func _log(msg: String) -> void:
	emit_signal("log_added", msg)
