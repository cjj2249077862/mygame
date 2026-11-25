class_name Enums

enum Role {
	TANK,
	DPS,
	HEALER,
	ENEMY,
}

enum TargetType {
	NONE,        # 无需指定目标（如全体、自身或自动最高仇恨）
	ALLY,        # 指定我方单体
	ENEMY,       # 指定敌方单体
}

enum IntentType {
	ATTACK_AGGRO,   # 攻击当前最高仇恨目标
	ATTACK_AOE,     # 全体攻击
	CAST_BIG_HIT,   # 读条重击（可打断）
	CAST_POISON,    # 读条全体上毒（可打断）
}
