extends RefCounted

var _owner: WeakRef
var engine: RefCounted:
	get:
		return _owner.get_ref()


func _init(owner_engine: RefCounted) -> void:
	_owner = weakref(owner_engine)


func damage_value(source: Dictionary, target: Dictionary, base: float) -> int:
	var amount: float = base + float(source.get("strength", 0))
	if engine.status_count(source, "weak") > 0:
		amount *= engine.data.rule("weak_multiplier")
	if engine.status_count(target, "vulnerable") > 0:
		amount *= engine.data.rule("vulnerable_multiplier")
	return maxi(0, floori(amount))


func damage(
	source: Dictionary,
	target: Dictionary,
	amount: int,
	multiplier: float = 1,
	bypass: bool = false,
	damage_kind: String = "direct"
) -> int:
	if target.hp <= 0:
		return 0
	var shield_loss: int = 0 if bypass else mini(target.shield, amount)
	var hp_loss := mini(int(target.hp), amount - shield_loss)
	target.shield -= shield_loss
	target.hp -= hp_loss
	var actual := shield_loss + hp_loss
	if not source.is_empty() and source.friendly and source.hp > 0:
		source.threat += roundi(actual * multiplier)
	engine.events.append(
		"damage", {"source": source.get("id", ""), "target": target.id, "amount": actual}
	)
	var killed: bool = target.hp == 0
	(
		engine
		. events
		. notify(
			"damage_resolved",
			{
				"source": source,
				"target": target,
				"amount": actual,
				"hp_loss": hp_loss,
				"shield_loss": shield_loss,
				"damage_kind": damage_kind,
			}
		)
	)
	# A nested damage notification can kill an initially surviving target and
	# finish its death itself. Only this hit's lethal transition is handled here.
	if killed:
		engine.handle_death(target)
	engine.refresh_targets()
	return actual


func heal(
	source: Dictionary,
	target: Dictionary,
	amount: int,
	attribute: bool = true,
	heal_kind: String = "instant"
) -> int:
	if target.hp <= 0:
		return 0
	var actual := mini(amount, int(target.max_hp - target.hp))
	target.hp += actual
	if attribute and not source.is_empty() and source.friendly and source.hp > 0:
		source.threat += roundi(actual * engine.data.rule("heal_threat"))
	engine.events.append(
		"heal", {"source": source.get("id", ""), "target": target.id, "amount": actual}
	)
	engine.events.notify(
		"heal_resolved",
		{"source": source, "target": target, "amount": actual, "heal_kind": heal_kind}
	)
	engine.refresh_targets()
	return actual


func apply_card(
	source: Dictionary, target: Dictionary, effects: Array, chosen_status: String
) -> void:
	for effect in effects:
		if source.hp <= 0:
			break
		var bonus: int = int(effect.get("first_bonus", 0))
		match effect.kind:
			"damage":
				for hit in range(int(effect.hits)):
					if source.hp <= 0 or target.hp <= 0:
						break
					# Each hit observes the current state; only the first gets the passive bonus.
					var amount := damage_value(
						source, target, effect.amount + (bonus if hit == 0 else 0)
					)
					damage(source, target, amount, effect.threat_mult)
			"heal":
				heal(source, target, int(effect.amount) + bonus)
			"shield":
				if target.hp > 0:
					var amount: int = int(effect.amount) + bonus
					target.shield += amount
					engine.events.append(
						"shield", {"source": source.id, "target": target.id, "amount": amount}
					)
					engine.events.notify(
						"shield_granted", {"source": source, "target": target, "amount": amount}
					)
			"interrupt":
				if target.hp > 0:
					var valid: bool = engine.can_interrupt(target.id)
					if valid:
						target.interrupted = true
						target.interrupt_streak += 1
						if (
							target.interrupt_threshold > 0
							and target.interrupt_streak >= target.interrupt_threshold
						):
							target.immunity += target.immunity_count
							target.interrupt_streak = 0
					engine.events.append(
						"interrupt" if valid else "interrupt_failed", {"target": target.id}
					)
					engine.events.notify(
						"interrupt_resolved", {"source": source, "target": target, "success": valid}
					)
			"dispel":
				if target.hp > 0 and chosen_status != "":
					target.statuses.erase(chosen_status)
					engine.events.append("dispel", {"target": target.id, "status": chosen_status})
					engine.events.notify(
						"status_dispelled",
						{"source": source, "target": target, "status": chosen_status}
					)


func add_status(
	source: Dictionary, target: Dictionary, status: String, stacks: int, multiplier: float = 1
) -> void:
	if target.hp <= 0 or stacks <= 0:
		return
	if not target.statuses.has(status):
		target.statuses[status] = []
	var merged := false
	for contribution in target.statuses[status]:
		if contribution.source == source.id and contribution.multiplier == multiplier:
			contribution.stacks += stacks
			merged = true
			break
	if not merged:
		target.statuses[status].append(
			{"source": source.id, "stacks": stacks, "multiplier": multiplier}
		)
	engine.events.append("status", {"target": target.id, "status": status, "amount": stacks})
	engine.events.notify(
		"status_applied", {"source": source, "target": target, "status": status, "amount": stacks}
	)


func tick_status(target: Dictionary, status: String) -> void:
	var total: int = engine.status_count(target, status)
	if total <= 0 or target.hp <= 0:
		return
	var contributions: Array = target.statuses[status].duplicate(true)
	var definition: Dictionary = engine.data.definition("battle_rules", status, "statuses")
	var raw: int = total * int(definition.per_stack)
	var actual: int
	if status == "regen":
		actual = heal({}, target, raw, false, "regen")
	else:
		actual = damage({}, target, raw, 0, status == "poison", status)
	var threat_by_source: Dictionary = {}
	for contribution in contributions:
		var source: Dictionary = engine.find_unit(contribution.source)
		if not source.is_empty() and source.hp > 0 and source.friendly:
			var multiplier: float = (
				engine.data.rule("heal_threat")
				if status == "regen"
				else float(contribution.multiplier)
			)
			# Multiple applications by one caster must not each round a fractional share.
			var share: float = float(actual) * contribution.stacks / total * multiplier
			threat_by_source[source.id] = float(threat_by_source.get(source.id, 0.0)) + share
	for source_id in threat_by_source:
		var source: Dictionary = engine.find_unit(source_id)
		source.threat += roundi(threat_by_source[source_id])
	if target.hp > 0:
		decay_status(target, status, int(definition.decay))
	engine.events.notify("status_ticked", {"target": target, "status": status, "amount": actual})
	engine.refresh_targets()


func decay_status(target: Dictionary, status: String, decrement: int) -> void:
	var total: int = engine.status_count(target, status)
	if total <= decrement:
		target.statuses.erase(status)
		return
	# Preserve source proportions; assign integer remainders in application order.
	var remaining := total - decrement
	var allocated := 0
	for contribution in target.statuses[status]:
		contribution.stacks = floori(float(contribution.stacks) * remaining / total)
		allocated += int(contribution.stacks)
	var index := 0
	while allocated < remaining:
		target.statuses[status][index].stacks += 1
		allocated += 1
		index += 1
	target.statuses[status] = target.statuses[status].filter(
		func(c: Dictionary) -> bool: return c.stacks > 0
	)
