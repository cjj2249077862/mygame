extends RefCounted

const Palette = preload("res://themes/game_theme.tres")


static func color_for(
	control: Control, section_id: String, surface: String, fallback: Color
) -> Color:
	if not section_id.begins_with("keyword."):
		return fallback
	var keyword: String = section_id.trim_prefix("keyword.")
	if control.has_theme_color(keyword, surface):
		return control.get_theme_color(keyword, surface)
	if Palette.has_color(keyword, surface):
		return Palette.get_color(keyword, surface)
	return Palette.get_color("default", surface)


static func render(label: RichTextLabel, plain_text: String, sections: Array) -> void:
	var terms: Array[Dictionary] = []
	for section in sections:
		var id: String = str(section.get("id", ""))
		var title: String = str(section.get("title", ""))
		if id.begins_with("keyword.") and title != "":
			(
				terms
				. append(
					{
						"text": title,
						"color": color_for(label, id, "KeywordCard", Color.WHITE),
					}
				)
			)
	label.clear()
	var cursor := 0
	while cursor < plain_text.length():
		var next_position: int = plain_text.length()
		var matched: Dictionary = {}
		for term in terms:
			var position: int = plain_text.find(str(term.text), cursor)
			if position < cursor:
				continue
			# Prefer the longest term at the same position; never re-scan styled text.
			if (
				position < next_position
				or (
					position == next_position
					and str(term.text).length() > str(matched.get("text", "")).length()
				)
			):
				next_position = position
				matched = term
		label.add_text(plain_text.substr(cursor, next_position - cursor))
		if matched.is_empty():
			break
		label.push_color(matched.color)
		# add_text keeps brackets and any future localized markup literal.
		label.add_text(str(matched.text))
		label.pop()
		cursor = next_position + str(matched.text).length()
