class_name Models

class UnitState extends RefCounted:
	var id: String
	var display_name: String
	var role: int
	var max_hp: int
	var hp: int
	var shield: int = 0
	var threat: int = 0
	var poison: int = 0       # 层数：回合末扣血并减1层
	var vulnerable: int = 0   # 易伤：受到伤害+50%
	var regen: int = 0        # 再生：回合末回血并减1层

	func _init(p_id: String, p_name: String, p_role: int, p_hp: int) -> void:
		id = p_id
		display_name = p_name
		role = p_role
		max_hp = p_hp
		hp = p_hp

	func is_alive() -> bool:
		return hp > 0

class CardData extends RefCounted:
	var id: String
	var title: String
	var cost: int
	var owner_role: int       # 属于哪个职业（影响视觉配色与职业限制）
	var target_type: int
	var description: String
	var effects: Array        # Array of Dictionary

	func _init(p_id: String, p_title: String, p_cost: int, p_role: int, p_target: int, p_desc: String, p_effects: Array) -> void:
		id = p_id
		title = p_title
		cost = p_cost
		owner_role = p_role
		target_type = p_target
		description = p_desc
		effects = p_effects

class EnemyIntent extends RefCounted:
	var type: int
	var title: String
	var power: int
	var interruptible: bool = false
	var interrupted: bool = false

	func _init(p_type: int, p_title: String, p_power: int, p_interruptible: bool = false) -> void:
		type = p_type
		title = p_title
		power = p_power
		interruptible = p_interruptible
