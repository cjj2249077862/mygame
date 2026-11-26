extends RichTextLabel


func reset() -> void:
	clear()


func append_records(records: Array, data: RefCounted, engine: RefCounted) -> void:
	for record in records:
		var values: Dictionary = record.duplicate(true)
		for key in ["source", "target"]:
			if values.has(key):
				var unit: Dictionary = engine.find_unit(values[key])
				values[key] = (
					data.text(unit.name_key)
					if not unit.is_empty()
					else data.text("ui.status_effect")
				)
		if values.has("status"):
			values.status = data.text("status." + str(values.status))
		append_text(data.text("log." + str(record.kind), values) + "\n")
