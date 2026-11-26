extends CanvasLayer

const KeywordText = preload("res://scripts/ui/presentation/keyword_text.gd")

const META_SECTIONS := "help_sections"
const META_PLAIN := "help_plain_text"
const SOURCE_GROUP := "hover_help_sources"
const WRAP_FLAGS := (
	TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
)
@export var hover_delay: float = 0.25
@export var switch_delay: float = 0.06
@export var dismiss_delay: float = 0.12
@export var panel_width: float = 300.0
@export var maximum_height: float = 520.0
@export var viewport_margin: float = 14.0
@export var anchor_gap: float = 12.0
@export var entry_gap: float = 8.0
@export var content_padding: Vector2 = Vector2(12, 10)
@export var text_gap: float = 5.0
@export var title_font_size: int = 18
@export var body_font_size: int = 16
@export var minimum_font_size: int = 14
@export var title_color: Color = Color(1.0, 0.84, 0.55)
@export var body_color: Color = Color(0.94, 0.91, 0.85)
@export var keyword_style: StyleBox
@export var blur_material: ShaderMaterial
@export var capture_padding: float = 12.0

var _candidate: Control
var _provider: Control
var _warm_provider: Control
var _anchor_rect: Rect2
var _elapsed := 0.0
var _required_delay := 0.25
var _away_elapsed := 0.0
var _shown_revision := -1
var _dragging := false

@onready var panel: Control = $Panel
@onready var capture: BackBufferCopy = $Capture


static func attach(control: Control, sections: Array, suppress_native: bool = false) -> void:
	var cleaned: Array[Dictionary] = []
	var seen: Dictionary = {}
	for section in sections:
		if not section is Dictionary:
			continue
		var id: String = str(section.get("id", ""))
		if id != "" and seen.has(id):
			continue
		if str(section.get("title", "")) == "" and str(section.get("body", "")) == "":
			continue
		if id != "":
			seen[id] = true
		cleaned.append(section.duplicate(true))
	control.set_meta(META_SECTIONS, cleaned)
	control.set_meta(META_PLAIN, plain_text(cleaned))
	control.set_meta("help_revision", int(control.get_meta("help_revision", 0)) + 1)
	if suppress_native:
		if control.tooltip_text != "":
			control.set_meta("help_native_text", control.tooltip_text)
		control.tooltip_text = ""


static func plain_text(sections: Array) -> String:
	var parts: Array[String] = []
	for section in sections:
		if not section is Dictionary:
			continue
		for key in ["title", "body"]:
			var part: String = str(section.get(key, ""))
			if part != "":
				parts.append(part)
	return "\n".join(parts)


func _ready() -> void:
	_clear_entries()
	get_viewport().size_changed.connect(_on_viewport_resized)


func set_dragging(dragging: bool) -> void:
	_dragging = dragging
	if dragging:
		hide_help()


func hide_help() -> void:
	_candidate = null
	_provider = null
	_warm_provider = null
	_elapsed = 0.0
	_away_elapsed = 0.0
	_shown_revision = -1
	if is_node_ready():
		_clear_entries()


func visible_entry_rects() -> Array[Rect2]:
	var result: Array[Rect2] = []
	if panel.visible:
		for child in panel.get_children():
			if child is Control and child.visible:
				result.append(child.get_global_rect())
	return result


func _process(delta: float) -> void:
	if (
		_dragging
		or get_viewport().gui_is_dragging()
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		or _modal_open()
	):
		hide_help()
		return
	if is_instance_valid(_candidate) and not _candidate.is_visible_in_tree():
		hide_help()
	var context: Dictionary = _hover_context(get_viewport().get_mouse_position())
	var hovered: Control = context.owner
	if hovered == null:
		_away_elapsed += delta
		if _away_elapsed >= dismiss_delay:
			hide_help()
		return
	_away_elapsed = 0.0
	if hovered != _candidate:
		var same_hand: bool = (
			is_instance_valid(_warm_provider) and _warm_provider == context.provider
		)
		_clear_entries()
		_candidate = hovered
		_provider = context.provider
		_elapsed = 0.0
		_required_delay = switch_delay if same_hand else hover_delay
		_shown_revision = -1
	_elapsed += delta
	if _elapsed >= _required_delay:
		var revision: int = int(_candidate.get_meta("help_revision", 0))
		if revision != _shown_revision:
			_show_sections(revision)


func _input(event: InputEvent) -> void:
	if (
		event.is_action_pressed("ui_cancel")
		or (
			event is InputEventMouseButton
			and event.pressed
			and event.button_index == MOUSE_BUTTON_RIGHT
		)
	):
		hide_help()


func _hover_context(pointer: Vector2) -> Dictionary:
	for source in get_tree().get_nodes_in_group(SOURCE_GROUP):
		if not source is Control or not source.is_visible_in_tree():
			continue
		var region: Rect2 = source.hover_region()
		if region.has_point(pointer):
			# Empty slots and overlay-blocked slots must not fall back to animated cards.
			var owner: Control = source.help_hover_owner(pointer)
			if owner != null and bool(owner.get_meta("help_disabled", false)):
				owner = null
			return {"owner": owner, "provider": source}
	return {"owner": _help_owner(get_viewport().gui_get_hovered_control()), "provider": null}


func _modal_open() -> bool:
	for window in get_viewport().get_embedded_subwindows():
		if window.visible:
			return true
	return false


func _help_owner(hovered: Control) -> Control:
	var node: Node = hovered
	var found: Control
	var claimed := false
	while node != null:
		if bool(node.get_meta("help_disabled", false)):
			return null
		if not claimed and node is Control and node.has_meta(META_SECTIONS):
			# An explicit empty list suppresses ancestor help, including keyword-free cards.
			claimed = true
			var sections: Variant = node.get_meta(META_SECTIONS)
			if sections is Array and not sections.is_empty():
				found = node
		node = node.get_parent()
	return found


func _clear_entries() -> void:
	panel.hide()
	capture.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	for child in panel.get_children():
		panel.remove_child(child)
		child.queue_free()


func _show_sections(revision: int) -> void:
	_clear_entries()
	_shown_revision = revision
	if not is_instance_valid(_candidate):
		return
	if is_instance_valid(_provider):
		_warm_provider = _provider
	var sections: Array = _candidate.get_meta(META_SECTIONS, [])
	if sections.is_empty():
		return
	_anchor_rect = _candidate.get_global_rect()
	if is_instance_valid(_provider):
		_anchor_rect = _provider.help_anchor_rect(_candidate)
	var available: Rect2 = _available_rect()
	var layout: Dictionary = _layout_sections(sections, available.size)
	if layout.is_empty():
		return
	# Text is shaped and every rectangle is fixed before any surface becomes visible.
	for entry in layout.entries:
		_create_entry(entry)
	panel.size = layout["size"]
	_position_panel(available)
	capture.rect = panel.get_global_rect().grow(capture_padding).intersection(
		get_viewport().get_visible_rect()
	)
	capture.copy_mode = BackBufferCopy.COPY_MODE_RECT
	panel.show()


func _available_rect() -> Rect2:
	var result: Rect2 = get_viewport().get_visible_rect().grow(-viewport_margin)
	for source in get_tree().get_nodes_in_group(SOURCE_GROUP):
		if source is Control and source.is_visible_in_tree():
			var excluded: Rect2 = source.help_exclusion_rect()
			if excluded.intersects(result):
				result.size.y = maxf(0.0, excluded.position.y - anchor_gap - result.position.y)
	return result


func _layout_sections(sections: Array, available: Vector2) -> Dictionary:
	if available.x <= content_padding.x * 2.0 or available.y <= content_padding.y * 2.0:
		return {}
	var first_width: float = minf(panel_width, available.x)
	var widths: Array[float] = [first_width, minf(first_width + 80.0, available.x), available.x]
	for font_size in range(body_font_size, minimum_font_size - 1, -1):
		for width in widths:
			var entries: Array[Dictionary] = _measure_sections(sections, width, font_size)
			var layout: Dictionary = _pack_columns(
				entries, available, minf(maximum_height, available.y)
			)
			if not layout.is_empty():
				return layout
	return {}


func _measure_sections(sections: Array, width: float, font_size: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var font: Font = panel.get_theme_font("font", "Label")
	var title_size: int = title_font_size - (body_font_size - font_size)
	var text_width: float = width - content_padding.x * 2.0
	for section in sections:
		var title: String = str(section.get("title", ""))
		var body: String = str(section.get("body", ""))
		var title_height: float = _text_height(font, title, title_size, text_width)
		var body_height: float = _text_height(font, body, font_size, text_width)
		var gap: float = text_gap if title != "" and body != "" else 0.0
		(
			result
			. append(
				{
					"section": section,
					"size":
					Vector2(width, content_padding.y * 2.0 + title_height + body_height + gap),
					"title_height": title_height,
					"body_height": body_height,
					"title_size": title_size,
					"font_size": font_size,
					"text_gap": gap,
				}
			)
		)
	return result


func _text_height(font: Font, text: String, font_size: int, width: float) -> float:
	if text == "":
		return 0.0
	return (
		ceilf(
			(
				font
				. get_multiline_string_size(
					text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, -1, WRAP_FLAGS
				)
				. y
			)
		)
		+ 2.0
	)


func _pack_columns(
	entries: Array[Dictionary], available: Vector2, height_limit: float
) -> Dictionary:
	var cursor := Vector2.ZERO
	var extent := Vector2.ZERO
	for entry in entries:
		var extent_size: Vector2 = entry["size"]
		if extent_size.y > height_limit:
			return {}
		if cursor.y > 0.0 and cursor.y + extent_size.y > height_limit:
			cursor.x += extent_size.x + entry_gap
			cursor.y = 0.0
		if cursor.x + extent_size.x > available.x:
			return {}
		entry["position"] = cursor
		extent.x = maxf(extent.x, cursor.x + extent_size.x)
		extent.y = maxf(extent.y, cursor.y + extent_size.y)
		cursor.y += extent_size.y + entry_gap
	return {"entries": entries, "size": extent}


func _create_entry(entry: Dictionary) -> void:
	var frame := Control.new()
	frame.name = "Entry"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.position = entry["position"]
	frame.size = entry["size"]
	frame.set_meta("help_section_id", str(entry.section.get("id", "")))
	panel.add_child(frame)
	if blur_material != null:
		var blur := ColorRect.new()
		blur.name = "Blur"
		blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
		blur.size = frame.size
		var material: ShaderMaterial = blur_material.duplicate() as ShaderMaterial
		material.set_shader_parameter("rect_size", frame.size)
		blur.material = material
		frame.add_child(blur)
	var border := Panel.new()
	border.name = "Border"
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	border.size = frame.size
	if keyword_style != null:
		border.add_theme_stylebox_override("panel", keyword_style)
	frame.add_child(border)
	_add_label(
		frame,
		"Title",
		str(entry.section.get("title", "")),
		content_padding,
		Vector2(frame.size.x - content_padding.x * 2.0, entry.title_height),
		entry.title_size,
		KeywordText.color_for(panel, str(entry.section.get("id", "")), "KeywordHelp", title_color)
	)
	_add_label(
		frame,
		"Body",
		str(entry.section.get("body", "")),
		content_padding + Vector2(0, entry.title_height + entry.text_gap),
		Vector2(frame.size.x - content_padding.x * 2.0, entry.body_height),
		entry.font_size,
		body_color
	)


func _add_label(
	parent: Control,
	label_name: String,
	text: String,
	position: Vector2,
	label_size: Vector2,
	font_size: int,
	color: Color
) -> void:
	if text == "":
		return
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.position = position
	label.size = label_size
	label.add_theme_font_override("font", panel.get_theme_font("font", "Label"))
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("line_spacing", 0)
	parent.add_child(label)


func _position_panel(available: Rect2) -> void:
	var position: Vector2
	if is_instance_valid(_provider):
		position = Vector2(
			_anchor_rect.get_center().x - panel.size.x * 0.5, available.end.y - panel.size.y
		)
	else:
		position = Vector2(_anchor_rect.end.x + anchor_gap, _anchor_rect.position.y)
		if position.x + panel.size.x > available.end.x:
			position.x = _anchor_rect.position.x - anchor_gap - panel.size.x
		if position.x < available.position.x:
			position = _anchor_rect.position - Vector2(0, panel.size.y + anchor_gap)
	position.x = clampf(
		position.x, available.position.x, maxf(available.position.x, available.end.x - panel.size.x)
	)
	position.y = clampf(
		position.y, available.position.y, maxf(available.position.y, available.end.y - panel.size.y)
	)
	panel.position = position.round()


func _on_viewport_resized() -> void:
	if _shown_revision >= 0 and is_instance_valid(_candidate):
		_show_sections(int(_candidate.get_meta("help_revision", 0)))
