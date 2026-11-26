extends RefCounted

var _owner: WeakRef
var engine: RefCounted:
	get:
		return _owner.get_ref()


func _init(owner_engine: RefCounted) -> void:
	_owner = weakref(owner_engine)


func damage_value(source: Dictionary, target: Dictionary, base: float) -> int:
	return target_damage_value(target, source_damage_value(source, base))


func source_damage_value(source: Dictionary, base: float) -> float:
	var amount: float = base + float(source.get("strength", 0))
	if engine.status_count(source, "weak") > 0:
		amount *= engine.data.rule("weak_multiplier")
	return maxf(0.0, amount)


func target_damage_value(target: Dictionary, amount: float) -> int:
	if engine.status_count(target, "vulnerable") > 0:
		amount *= engine.data.rule("vulnerable_multiplier")
	for reduction in target.get("damage_reductions", []):
		amount *= 1.0 - float(reduction)
	return maxi(0, floori(amount))


func shared_damage(source: Dictionary, target: Dictionary, base: float) -> int:
	var participants: Array = engine.share_participants(target.id)
	if participants.is_empty():
		return 0
	# Source adjustments are rounded once before division. The named target,
	# then adjacent living slots left-to-right, receive one remainder each.
	var total: int = floori(source_damage_value(source, base))
	var quotient: int = floori(float(total) / participants.size())
	var remainder: int = total % participants.size()
	var actual := 0
	for index in range(participants.size()):
		var ally: Dictionary = participants[index]
		var share: int = quotient + (1 if index < remainder else 0)
		actual += damage(source, ally, target_damage_value(ally, share))
	return actual


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
	engine.mark_boss_thresholds(target)
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
	apply_effects(source, target, effects, chosen_status, "card")


func apply_effects(
	source: Dictionary,
	selected: Dictionary,
	effects: Array,
	chosen_status: String = "",
	origin: String = "card",
	context: Dictionary = {}
) -> void:
	var source_death: int = int(source.get("death_serial", -1))
	var death_versions: Dictionary = {}
	for unit in engine.state.heroes + engine.state.enemies:
		death_versions[unit.id] = unit.death_serial
	for effect in effects:
		if not _source_can_continue(source, source_death):
			break
		if effect.kind == "draw":
			var before: int = engine.state.hand.size()
			engine.draw_cards(int(effect.amount))
			engine.events.append("draw", {"amount": engine.state.hand.size() - before})
			continue
		if effect.kind == "energy":
			engine.state.energy += int(effect.amount)
			engine.events.append("energy", {"amount": int(effect.amount)})
			continue
		var targets: Array = engine.effect_targets(source, selected, effect, context)
		for target in targets:
			if not _source_can_continue(source, source_death):
				break
			var bonus: int = int(effect.get("first_bonus", 0))
			if effect.get("first_bonus_target", target.id) != target.id:
				bonus = 0
			match effect.kind:
				"damage":
					for hit in range(int(effect.hits)):
						if (
							not _source_can_continue(source, source_death)
							or target.hp <= 0
							or (
								target.death_serial
								!= death_versions.get(target.id, target.death_serial)
							)
						):
							break
						var base: float = float(effect.amount) + (bonus if hit == 0 else 0)
						if origin == "card" and source.get("friendly", false):
							base += int(engine.state.get("card_damage_bonus", 0))
						damage(
							source,
							target,
							damage_value(source, target, base),
							float(effect.get("threat_mult", 1))
						)
				"heal":
					heal(source, target, int(effect.amount) + bonus)
				"revive":
					revive(source, target, float(effect.amount))
				"apply_status":
					var attributed_source: Dictionary = target if source.is_empty() else source
					add_status(
						attributed_source,
						target,
						effect.status,
						int(effect.amount),
						float(effect.get("threat_mult", 1))
					)
				"shield":
					grant_shield(source, target, int(effect.amount) + bonus, origin)
				"threat":
					target.threat += int(effect.amount)
					engine.refresh_targets()
				"taunt":
					var highest := 0
					for hero in engine.state.heroes:
						if hero.hp > 0:
							highest = maxi(highest, int(hero.threat))
					target.threat = highest + int(effect.amount)
					engine.events.append("taunt", {"target": target.id, "amount": target.threat})
					engine.refresh_targets()
				"interrupt":
					interrupt(source, target, origin)
				"dispel":
					dispel(source, target, chosen_status, origin)
				"clear_status":
					dispel(source, target, effect.status, origin, false)
				"bomb":
					engine.apply_bomb(source, target, int(effect.amount), int(effect.duration))


func _source_can_continue(source: Dictionary, death_serial: int) -> bool:
	return source.is_empty() or (source.hp > 0 and source.death_serial == death_serial)


func grant_shield(
	source: Dictionary, target: Dictionary, amount: int, origin: String = "card"
) -> void:
	if target.hp <= 0:
		return
	target.shield += amount
	engine.events.append(
		"shield", {"source": source.get("id", ""), "target": target.id, "amount": amount}
	)
	engine.events.notify(
		"shield_granted", {"source": source, "target": target, "amount": amount, "origin": origin}
	)


func interrupt(source: Dictionary, target: Dictionary, origin: String = "card") -> bool:
	if target.hp <= 0:
		return false
	var valid: bool = engine.can_interrupt(target.id)
	if valid:
		target.interrupted = true
		target.interrupt_streak += 1
		if target.interrupt_threshold > 0 and target.interrupt_streak >= target.interrupt_threshold:
			target.immunity += target.immunity_count
			target.interrupt_streak = 0
	engine.events.append("interrupt" if valid else "interrupt_failed", {"target": target.id})
	engine.events.notify(
		"interrupt_resolved",
		{"source": source, "target": target, "success": valid, "origin": origin}
	)
	return valid


func dispel(
	source: Dictionary,
	target: Dictionary,
	status: String,
	origin: String = "card",
	require_dispellable: bool = true
) -> bool:
	if target.hp <= 0 or status == "":
		return false
	if (
		require_dispellable
		and not engine.data.definition("battle_rules", status, "statuses").get("dispellable", false)
	):
		return false
	var removed: bool = target.statuses.erase(status)
	if status == "bomb":
		var before: int = target.marks.size()
		target.marks = target.marks.filter(
			func(mark: Dictionary) -> bool: return mark.kind != "bomb"
		)
		removed = removed or target.marks.size() != before
	if not removed:
		return false
	engine.events.append("dispel", {"target": target.id, "status": status})
	engine.events.notify(
		"status_dispelled",
		{"source": source, "target": target, "status": status, "origin": origin, "success": true}
	)
	return true


func revive(source: Dictionary, target: Dictionary, ratio: float) -> bool:
	if ratio <= 0 or not engine.can_revive(target.id):
		return false
	target.revives_used += 1
	target.hp = mini(int(target.max_hp), maxi(1, ceili(float(target.max_hp) * ratio)))
	target.shield = 0
	target.threat = 0
	target.death_handled = false
	# Keep death_serial and passive counters: revival cannot resume an interrupted
	# multihit action or refund a first-card opportunity already spent this turn.
	engine.restore_removed_cards()
	engine.events.append(
		"revive", {"source": source.get("id", ""), "target": target.id, "amount": target.hp}
	)
	engine.events.notify("unit_revived", {"source": source, "target": target})
	engine.refresh_targets()
	return true


func add_status(
	source: Dictionary, target: Dictionary, status: String, stacks: int, multiplier: float = 1
) -> void:
	if target.hp <= 0 or stacks <= 0:
		return
	if not target.statuses.has(status):
		target.statuses[status] = []
	var per_stack: int = int(engine.data.definition("battle_rules", status, "statuses").per_stack)
	var merged := false
	for contribution in target.statuses[status]:
		if (
			contribution.source == source.id
			and contribution.multiplier == multiplier
			and int(contribution.get("per_stack", per_stack)) == per_stack
		):
			contribution.stacks += stacks
			merged = true
			break
	if not merged:
		target.statuses[status].append(
			{
				"source": source.id,
				"stacks": stacks,
				"multiplier": multiplier,
				"per_stack": per_stack
			}
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
	var weights: Array = []
	var raw := 0
	for contribution in contributions:
		var weight: int = (
			int(contribution.stacks) * int(contribution.get("per_stack", definition.per_stack))
		)
		weights.append(weight)
		raw += weight
	var actual: int
	if status == "regen":
		actual = heal({}, target, raw, false, "regen")
	else:
		actual = damage({}, target, raw, 0, status == "poison", status)
	var portions: Array[int] = _allocate_integer(actual, weights)
	var threat_by_source: Dictionary = {}
	for index in range(contributions.size()):
		var contribution: Dictionary = contributions[index]
		var source: Dictionary = engine.find_unit(contribution.source)
		if not source.is_empty() and source.hp > 0 and source.friendly:
			var multiplier: float = (
				engine.data.rule("heal_threat")
				if status == "regen"
				else float(contribution.multiplier)
			)
			# Multiple applications by one caster must not each round a fractional share.
			var share: float = portions[index] * multiplier
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
	# Largest remainders preserve source proportions; equal remainders retain
	# the fixed contribution order. The same rule allocates actual periodic gains.
	var weights: Array = []
	for contribution in target.statuses[status]:
		weights.append(int(contribution.stacks))
	var portions := _allocate_integer(decrement, weights)
	for index in range(portions.size()):
		target.statuses[status][index].stacks -= portions[index]
	target.statuses[status] = target.statuses[status].filter(
		func(c: Dictionary) -> bool: return c.stacks > 0
	)


func _allocate_integer(amount: int, weights: Array) -> Array[int]:
	var portions: Array[int] = []
	var total := 0
	for weight in weights:
		total += int(weight)
	var remainders: Array = []
	var allocated := 0
	for index in range(weights.size()):
		var exact: float = float(amount) * int(weights[index]) / total if total > 0 else 0.0
		var part := floori(exact)
		portions.append(part)
		allocated += part
		remainders.append({"index": index, "remainder": exact - part})
	remainders.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			if is_equal_approx(left.remainder, right.remainder):
				return left.index < right.index
			return left.remainder > right.remainder
	)
	for index in range(amount - allocated if total > 0 else 0):
		portions[remainders[index].index] += 1
	return portions
