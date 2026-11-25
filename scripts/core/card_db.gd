class_name CardDB

static func get_all_cards() -> Dictionary:
	var db := {}

	# --- TANK 卡牌：护盾、嘲讽、打断 ---
	db["shield_wall"] = Models.CardData.new(
		"shield_wall", "盾墙", 1, Enums.Role.TANK, Enums.TargetType.NONE,
		"坦克获得 12 护盾，并产生 15 仇恨。",
		[
			{"op": "shield_role", "role": Enums.Role.TANK, "val": 12},
			{"op": "threat_role", "role": Enums.Role.TANK, "val": 15},
		]
	)
	db["taunt"] = Models.CardData.new(
		"taunt", "嘲讽怒吼", 1, Enums.Role.TANK, Enums.TargetType.NONE,
		"强制将坦克仇恨设为全队最高 +10，抽 1 张牌。",
		[
			{"op": "taunt_role", "role": Enums.Role.TANK, "bonus": 10},
			{"op": "draw", "val": 1},
		]
	)
	db["shield_bash"] = Models.CardData.new(
		"shield_bash", "盾牌猛击", 1, Enums.Role.TANK, Enums.TargetType.ENEMY,
		"造成 6 点伤害，产生 10 仇恨；若目标正在读条，则打断它！",
		[
			{"op": "damage", "val": 6, "source_role": Enums.Role.TANK, "threat_mult": 1.6},
			{"op": "interrupt"},
		]
	)

	# --- DPS 卡牌：高伤、上毒、易伤（高仇恨风险）---
	db["backstab"] = Models.CardData.new(
		"backstab", "背刺", 1, Enums.Role.DPS, Enums.TargetType.ENEMY,
		"造成 14 点伤害（产生 14 仇恨，注意别 OT！）。",
		[
			{"op": "damage", "val": 14, "source_role": Enums.Role.DPS, "threat_mult": 1.0},
		]
	)
	db["venom_strike"] = Models.CardData.new(
		"venom_strike", "淬毒箭", 1, Enums.Role.DPS, Enums.TargetType.ENEMY,
		"造成 5 点伤害，施加 4 层中毒。",
		[
			{"op": "damage", "val": 5, "source_role": Enums.Role.DPS, "threat_mult": 1.0},
			{"op": "apply_poison", "val": 4},
		]
	)
	db["expose_weakness"] = Models.CardData.new(
		"expose_weakness", "破甲射击", 1, Enums.Role.DPS, Enums.TargetType.ENEMY,
		"造成 6 点伤害，施加 2 回合易伤（受伤+50%）。",
		[
			{"op": "damage", "val": 6, "source_role": Enums.Role.DPS, "threat_mult": 1.0},
			{"op": "apply_vulnerable", "val": 2},
		]
	)

	# --- HEALER 卡牌：治疗、再生、驱散 ---
	db["flash_heal"] = Models.CardData.new(
		"flash_heal", "快速治疗", 1, Enums.Role.HEALER, Enums.TargetType.ALLY,
		"为指定队友恢复 14 点生命（产生 6 仇恨）。",
		[
			{"op": "heal_target", "val": 14, "source_role": Enums.Role.HEALER},
		]
	)
	db["cleanse"] = Models.CardData.new(
		"cleanse", "净化术", 1, Enums.Role.HEALER, Enums.TargetType.ALLY,
		"清除指定队友全部中毒与易伤，并恢复 5 生命。",
		[
			{"op": "dispel_target"},
			{"op": "heal_target", "val": 5, "source_role": Enums.Role.HEALER},
		]
	)
	db["prayer_of_mending"] = Models.CardData.new(
		"prayer_of_mending", "愈合祷言", 2, Enums.Role.HEALER, Enums.TargetType.NONE,
		"全队恢复 8 生命，并获得 2 层再生。",
		[
			{"op": "heal_all", "val": 8, "source_role": Enums.Role.HEALER},
			{"op": "regen_all", "val": 2},
		]
	)

	# --- 奖励池进阶卡牌 ---
	db["execute"] = Models.CardData.new(
		"execute", "斩杀", 2, Enums.Role.DPS, Enums.TargetType.ENEMY,
		"造成 26 点高额伤害（产生 30 仇恨！）。",
		[
			{"op": "damage", "val": 26, "source_role": Enums.Role.DPS, "threat_mult": 1.15},
		]
	)
	db["iron_aegis"] = Models.CardData.new(
		"iron_aegis", "圣盾庇护", 2, Enums.Role.TANK, Enums.TargetType.NONE,
		"全队获得 10 护盾，坦克额外获得 18 仇恨。",
		[
			{"op": "shield_all", "val": 10},
			{"op": "threat_role", "role": Enums.Role.TANK, "val": 18},
		]
	)
	db["feign_death"] = Models.CardData.new(
		"feign_death", "假死脱战", 0, Enums.Role.DPS, Enums.TargetType.NONE,
		"输出位仇恨清零，并抽 1 张牌。",
		[
			{"op": "reset_threat_role", "role": Enums.Role.DPS},
			{"op": "draw", "val": 1},
		]
	)

	return db

static func build_starter_deck() -> Array:
	var db := get_all_cards()
	var ids := [
		"shield_wall", "shield_wall", "taunt", "shield_bash",
		"backstab", "backstab", "venom_strike",
		"flash_heal", "flash_heal", "cleanse",
	]
	var deck := []
	for id in ids:
		deck.append(db[id])
	return deck

static func get_reward_pool() -> Array:
	var db := get_all_cards()
	return [
		db["execute"],
		db["iron_aegis"],
		db["feign_death"],
		db["expose_weakness"],
		db["prayer_of_mending"],
		db["shield_bash"],
	]
