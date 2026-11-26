extends RefCounted

const RANDOM_KINDS := ["battle", "elite", "camp", "shop", "event"]


static func generate(
	definition: Dictionary, pools: Array, node_rules: Array, rng: RandomNumberGenerator
) -> Dictionary:
	var count := int(definition.node_count)
	var width := int(definition.width)
	var nodes: Array = []
	var layers: Array = []
	for depth in range(1, count + 1):
		var layer: Array = []
		var slots := 1 if depth in [1, count - 1, count] else width
		for column in range(slots):
			var kind := "battle"
			if depth == count:
				kind = "boss"
			elif depth == count - 1:
				kind = "camp"
			elif depth > 1:
				var weights: Array = []
				for rule in node_rules:
					if (
						rule.map_id != definition.id
						or depth < rule.min_depth
						or depth > rule.max_depth
					):
						continue
					# Column zero is a reachable route without elites. Its next edge
					# is always retained, while optional edges and other nodes vary.
					if column == 0 and rule.kind == "elite":
						continue
					weights.append({"id": rule.kind, "weight": rule.weight})
				kind = weighted_pick(weights, rng)
			var node := {
				"id": "node_%02d_%d" % [depth, column],
				"depth": depth,
				"column": column,
				"kind": kind,
				"content_id": "",
				"next": [],
			}
			layer.append(node)
			nodes.append(node)
		layers.append(layer)
	# Guarantee at least one reachable shop. It does not force every route to shop.
	var shop_depth := rng.randi_range(2, count - 2)
	layers[shop_depth - 1][0].kind = "shop"
	for depth_index in range(layers.size() - 1):
		var current: Array = layers[depth_index]
		var following: Array = layers[depth_index + 1]
		for node in current:
			if current.size() == 1:
				for child in following:
					node.next.append(child.id)
			elif following.size() == 1:
				node.next.append(following[0].id)
			else:
				node.next.append(following[node.column].id)
				for direction in [-1, 1]:
					var adjacent: int = node.column + direction
					if adjacent >= 0 and adjacent < following.size() and rng.randi_range(0, 1) == 1:
						node.next.append(following[adjacent].id)
	var used_events: Array = []
	for node in nodes:
		if node.depth == 1:
			node.content_id = definition.first_encounter_id
		elif node.kind == "boss":
			node.content_id = definition.boss_encounter_id
		elif node.kind in ["battle", "elite", "event"]:
			var candidates: Array = []
			for entry in pools:
				if (
					entry.map_id == definition.id
					and entry.kind == node.kind
					and node.depth >= entry.get("min_depth", 2)
					and node.depth <= entry.get("max_depth", count - 2)
					and (node.kind != "event" or entry.content_id not in used_events)
				):
					candidates.append({"id": entry.content_id, "weight": entry.weight})
			if node.kind == "event" and candidates.is_empty():
				node.kind = "battle"
				for entry in pools:
					if (
						entry.map_id == definition.id
						and entry.kind == "battle"
						and node.depth >= entry.get("min_depth", 2)
						and node.depth <= entry.get("max_depth", count - 2)
					):
						candidates.append({"id": entry.content_id, "weight": entry.weight})
			node.content_id = weighted_pick(candidates, rng)
			if node.kind == "event":
				used_events.append(node.content_id)
	return {
		"chapter_id": definition.id,
		"nodes": nodes,
		"start_id": nodes[0].id,
		"boss_encounter_id": definition.boss_encounter_id,
	}


static func weighted_pick(candidates: Array, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for entry in candidates:
		total += float(entry.weight)
	if total <= 0:
		return ""
	var pick := rng.randf() * total
	for entry in candidates:
		pick -= float(entry.weight)
		if pick < 0:
			return str(entry.id)
	return str(candidates.back().id)


static func validate(map: Dictionary, expected_count: int = 10) -> bool:
	if not map.get("nodes") is Array or map.nodes.is_empty():
		return false
	for key in ["chapter_id", "start_id", "boss_encounter_id"]:
		if not map.get(key) is String or map[key] == "":
			return false
	var by_id: Dictionary = {}
	var per_depth: Dictionary = {}
	var positions: Dictionary = {}
	for node in map.nodes:
		if not node is Dictionary or not node.get("id") is String or by_id.has(node.id):
			return false
		if not node.get("next") is Array or not node.get("kind") is String:
			return false
		if not node.get("depth") is float and not node.get("depth") is int:
			return false
		var depth := int(node.depth)
		if depth < 1 or depth > expected_count or depth != node.depth:
			return false
		if not node.get("column") is float and not node.get("column") is int:
			return false
		if node.column < 0 or node.column != floorf(node.column):
			return false
		var position := "%d:%d" % [depth, int(node.column)]
		if positions.has(position):
			return false
		positions[position] = true
		if not node.get("content_id") is String:
			return false
		if node.kind not in RANDOM_KINDS + ["boss"]:
			return false
		if depth == 1 and node.kind != "battle":
			return false
		if depth == expected_count - 1 and node.kind != "camp":
			return false
		if (depth == expected_count) != (node.kind == "boss"):
			return false
		by_id[node.id] = node
		per_depth[depth] = int(per_depth.get(depth, 0)) + 1
	if per_depth.size() != expected_count or per_depth[1] != 1 or per_depth[expected_count] != 1:
		return false
	if not by_id.has(map.get("start_id", "")) or by_id[map.start_id].depth != 1:
		return false
	var reachable: Dictionary = {map.start_id: true}
	var safe: Dictionary = {map.start_id: true}
	var shop_seen := false
	for depth in range(1, expected_count + 1):
		for node in map.nodes:
			if node.depth != depth:
				continue
			if not reachable.has(node.id):
				return false
			shop_seen = shop_seen or node.kind == "shop"
			if (depth == expected_count) != node.next.is_empty():
				return false
			var seen_edges: Dictionary = {}
			for target in node.next:
				if (
					not target is String
					or not by_id.has(target)
					or by_id[target].depth != depth + 1
					or seen_edges.has(target)
				):
					return false
				seen_edges[target] = true
				reachable[target] = true
				if safe.has(node.id) and by_id[target].kind != "elite":
					safe[target] = true
	return (
		shop_seen
		and safe.has(
			map.nodes.filter(func(n: Dictionary) -> bool: return n.depth == expected_count)[0].id
		)
	)
