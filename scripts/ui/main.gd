extends Control

var engine: BattleEngine
var pending_card_index: int = -1
var log_lines: Array[String] = []

var top_bar_label: Label
var party_container: HBoxContainer
var enemy_container: HBoxContainer
var log_label: RichTextLabel
var hand_container: HBoxContainer
var energy_label: Label
var end_turn_btn: Button
var modal_panel: PanelContainer
var modal_title: Label
var modal_buttons: VBoxContainer

func _ready() -> void:
	engine = BattleEngine.new()
	engine.state_changed.connect(_refresh_ui)
	engine.log_added.connect(_on_log_added)
	engine.battle_ended.connect(_on_battle_ended)

	_build_ui()
	engine.start_new_run()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.11, 0.12, 0.16)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	# 顶部信息栏
	var top_margin := MarginContainer.new()
	top_margin.add_theme_constant_override("margin_top", 8)
	top_margin.add_theme_constant_override("margin_left", 16)
	top_margin.add_theme_constant_override("margin_right", 16)
	root.add_child(top_margin)

	top_bar_label = Label.new()
	top_bar_label.add_theme_font_size_override("font_size", 18)
	top_margin.add_child(top_bar_label)

	# 战场区域：左我方小队，右敌方目标
	var arena := HBoxContainer.new()
	arena.size_flags_vertical = Control.SIZE_EXPAND_FILL
	arena.add_theme_constant_override("separation", 24)
	root.add_child(arena)

	party_container = HBoxContainer.new()
	party_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	party_container.alignment = BoxContainer.ALIGNMENT_CENTER
	party_container.add_theme_constant_override("separation", 12)
	arena.add_child(party_container)

	enemy_container = HBoxContainer.new()
	enemy_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enemy_container.alignment = BoxContainer.ALIGNMENT_CENTER
	enemy_container.add_theme_constant_override("separation", 12)
	arena.add_child(enemy_container)

	# 战斗日志
	var log_box := PanelContainer.new()
	log_box.custom_minimum_size = Vector2(0, 110)
	root.add_child(log_box)

	log_label = RichTextLabel.new()
	log_label.scroll_following = true
	log_box.add_child(log_label)

	# 底部手牌与操作区
	var bottom := HBoxContainer.new()
	bottom.custom_minimum_size = Vector2(0, 175)
	bottom.add_theme_constant_override("separation", 12)
	root.add_child(bottom)

	var left_ctrl := VBoxContainer.new()
	left_ctrl.custom_minimum_size = Vector2(160, 0)
	left_ctrl.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_child(left_ctrl)

	energy_label = Label.new()
	energy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	energy_label.add_theme_font_size_override("font_size", 20)
	left_ctrl.add_child(energy_label)

	end_turn_btn = Button.new()
	end_turn_btn.text = "结束回合"
	end_turn_btn.custom_minimum_size = Vector2(130, 44)
	end_turn_btn.pressed.connect(_on_end_turn_pressed)
	left_ctrl.add_child(end_turn_btn)

	hand_container = HBoxContainer.new()
	hand_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand_container.alignment = BoxContainer.ALIGNMENT_CENTER
	hand_container.add_theme_constant_override("separation", 10)
	bottom.add_child(hand_container)

	# 弹窗（奖励三选一 / 胜负重开）
	modal_panel = PanelContainer.new()
	modal_panel.visible = false
	modal_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	modal_panel.custom_minimum_size = Vector2(460, 300)
	add_child(modal_panel)

	var modal_vbox := VBoxContainer.new()
	modal_vbox.add_theme_constant_override("separation", 12)
	modal_panel.add_child(modal_vbox)

	modal_title = Label.new()
	modal_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	modal_title.add_theme_font_size_override("font_size", 20)
	modal_vbox.add_child(modal_title)

	modal_buttons = VBoxContainer.new()
	modal_buttons.add_theme_constant_override("separation", 8)
	modal_vbox.add_child(modal_buttons)

func _refresh_ui() -> void:
	var aggro_unit := engine.get_highest_threat_ally()
	var aggro_name := aggro_unit.display_name if aggro_unit else "无"
	top_bar_label.text = "第 %d / 3 关  |  回合 %d  |  当前仇恨目标: %s  |  牌库:%d 弃牌:%d" % [
		engine.stage_index, engine.turn_number, aggro_name, engine.draw_pile.size(), engine.discard_pile.size()
	]
	energy_label.text = "能量: %d / %d" % [engine.energy, engine.max_energy]

	# 刷新我方
	for c in party_container.get_children():
		c.queue_free()
	for m in engine.party:
		party_container.add_child(_create_unit_card(m, aggro_unit == m, true))

	# 刷新敌方
	for c in enemy_container.get_children():
		c.queue_free()
	for e in engine.enemies:
		enemy_container.add_child(_create_unit_card(e, false, false))

	# 刷新手牌
	for c in hand_container.get_children():
		c.queue_free()
	for i in range(engine.hand.size()):
		var card: Models.CardData = engine.hand[i]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(155, 150)
		var selected_prefix := "▶ [选目标] " if pending_card_index == i else ""
		btn.text = "%s[%d费] %s\n\n%s" % [selected_prefix, card.cost, card.title, card.description]
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.disabled = engine.is_battle_over or card.cost > engine.energy
		btn.pressed.connect(_on_hand_card_pressed.bind(i))
		hand_container.add_child(btn)

func _create_unit_card(unit: Models.UnitState, is_aggro: bool, is_ally: bool) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(185, 220)
	btn.disabled = not unit.is_alive()

	var status_parts: Array[String] = []
	if unit.shield > 0:
		status_parts.append("盾:%d" % unit.shield)
	if unit.poison > 0:
		status_parts.append("毒:%d" % unit.poison)
	if unit.vulnerable > 0:
		status_parts.append("易伤:%d" % unit.vulnerable)
	if unit.regen > 0:
		status_parts.append("再生:%d" % unit.regen)

	var lines := [
		unit.display_name + (" [★仇恨]" if is_aggro else ""),
		"HP: %d / %d" % [unit.hp, unit.max_hp],
	]
	if is_ally:
		lines.append("仇恨值: %d" % unit.threat)
	else:
		var intent: Models.EnemyIntent = engine.enemy_intents.get(unit.id, null)
		if intent:
			lines.append("意图: " + intent.title)

	if not status_parts.is_empty():
		lines.append("状态: " + " ".join(status_parts))

	btn.text = "\n".join(lines)
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.pressed.connect(_on_unit_clicked.bind(unit.id, is_ally))
	return btn

func _on_hand_card_pressed(index: int) -> void:
	var card: Models.CardData = engine.hand[index]
	if card.target_type == Enums.TargetType.NONE:
		pending_card_index = -1
		engine.play_card(index)
	else:
		if pending_card_index == index:
			pending_card_index = -1
		else:
			pending_card_index = index
			_on_log_added("已选中 [%s]，请点击上方对应目标..." % card.title)
		_refresh_ui()

func _on_unit_clicked(unit_id: String, is_ally: bool) -> void:
	if pending_card_index == -1:
		return
	var card: Models.CardData = engine.hand[pending_card_index]
	if card.target_type == Enums.TargetType.ALLY and not is_ally:
		_on_log_added("该卡牌只能对【我方队友】使用！")
		return
	if card.target_type == Enums.TargetType.ENEMY and is_ally:
		_on_log_added("该卡牌只能对【敌方目标】使用！")
		return

	var idx := pending_card_index
	pending_card_index = -1
	engine.play_card(idx, unit_id)

func _on_end_turn_pressed() -> void:
	pending_card_index = -1
	engine.end_player_turn()

func _on_log_added(msg: String) -> void:
	log_lines.append(msg)
	if log_lines.size() > 60:
		log_lines.pop_front()
	if log_label:
		log_label.text = "\n".join(log_lines)

func _on_battle_ended(victory: bool) -> void:
	for c in modal_buttons.get_children():
		c.queue_free()
	modal_panel.visible = true

	if not victory:
		modal_title.text = "小队团灭！再接再厉"
		var retry := Button.new()
		retry.text = "重新开始挑战"
		retry.pressed.connect(func():
			modal_panel.visible = false
			engine.start_new_run()
		)
		modal_buttons.add_child(retry)
		return

	if engine.stage_index >= 3:
		modal_title.text = "恭喜通关【腐化守卫】副本！"
		var restart := Button.new()
		restart.text = "再来一局"
		restart.pressed.connect(func():
			modal_panel.visible = false
			engine.start_new_run()
		)
		modal_buttons.add_child(restart)
		return

	modal_title.text = "战斗胜利！选择 1 张新卡牌加入牌库"
	var pool := CardDB.get_reward_pool()
	pool.shuffle()
	for i in range(min(3, pool.size())):
		var card: Models.CardData = pool[i]
		var pick := Button.new()
		pick.text = "[%d费] %s — %s" % [card.cost, card.title, card.description]
		pick.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		pick.pressed.connect(func():
			engine.add_card_to_master_deck(card)
			modal_panel.visible = false
			engine.start_stage(engine.stage_index + 1)
		)
		modal_buttons.add_child(pick)
