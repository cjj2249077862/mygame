extends Button

signal preview_requested(card: Control, active: bool)

const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
const HoverHelp = preload("res://scripts/ui/presentation/hover_help.gd")
@export var hover_scale: float = 1.1
@export var hover_duration: float = 0.12
@export var tank_title_color: Color
@export var assassin_title_color: Color
@export var healer_title_color: Color
@export var neutral_title_color: Color
var layout_owner: Control
var _hover: Tween
var _pointer_inside: bool = false
var _previewing: bool = false
var _last_disabled: bool = false
var _last_selected: bool = false
var _drag_suppressed: bool = false


func _ready() -> void:
	mouse_entered.connect(_on_pointer.bind(true))
	mouse_exited.connect(_on_pointer.bind(false))
	focus_entered.connect(_update_preview)
	focus_exited.connect(_update_preview)
	resized.connect(_fit_content)
	$Frame.texture = Art.icon_texture("card_frame")
	$Content/Heading/Cost/Badge.texture = Art.icon_texture("cost_badge")
	_fit_content()
	_sync_state()


func render(copy: Dictionary, data: RefCounted) -> void:
	var definition: Dictionary = data.definition("cards", copy.card_id)
	# Button text remains available to accessibility and existing callers.
	text = data.card_text(copy)
	tooltip_text = data.card_details(copy)
	$Content/Heading/Name.text = data.text(definition.name_key) + (" +" if copy.upgraded else "")
	$Content/Heading/Cost/Value.text = str(int(definition.cost))
	$Content/Description.text = text.substr(text.find("\n") + 1)
	var role: String = str(definition.role)
	if role == "" and definition.owner != "":
		role = str(data.definition("characters", definition.owner).get("role", ""))
	var illustration: Texture2D = Art.card_texture(str(copy.card_id))
	# Existing paintings fill the illustration window instead of enlarged icons.
	if illustration == null or not illustration.resource_path.contains("/cards/"):
		var shared_art: String = {"tank": "shield_bash", "assassin": "stab", "healer": "heal"}.get(
			role, "shield_bash"
		)
		illustration = Art.card_texture(shared_art)
	$Content/Art.texture = illustration
	$Content/Role.texture = Art.icon_texture("role_" + role)
	$Content/Role.visible = $Content/Role.texture != null
	$Content/Heading/RoleColor.color = (
		{"tank": tank_title_color, "assassin": assassin_title_color, "healer": healer_title_color}
		. get(role, neutral_title_color)
	)
	_fit_content.call_deferred()
	_sync_state()
	HoverHelp.attach(self, data.card_sections(copy))


func set_drag_suppressed(suppressed: bool) -> void:
	_drag_suppressed = suppressed
	if suppressed:
		_pointer_inside = false
	_update_preview()


func set_layout_hover(inside: bool) -> void:
	_pointer_inside = inside
	_update_preview()


func _get_tooltip(_at_position: Vector2) -> String:
	return "" if has_meta("help_sections") else tooltip_text


func _process(_delta: float) -> void:
	if disabled != _last_disabled or button_pressed != _last_selected:
		_sync_state()


func _sync_state() -> void:
	_last_disabled = disabled
	_last_selected = button_pressed
	$Content.modulate.a = 0.72 if disabled else 1.0
	$Frame.modulate = Color(0.7, 0.7, 0.7, 1.0) if disabled else Color.WHITE
	$Selected.visible = button_pressed
	$HoverGlow.visible = _previewing and not button_pressed


func _fit_content() -> void:
	if not is_node_ready():
		return
	pivot_offset = Vector2(size.x * 0.5, size.y)
	var name_label: Label = $Content/Heading/Name
	var title_size: int = clampi(roundi(size.x * 0.095), 12, 21)
	var font: Font = name_label.get_theme_font("font")
	while (
		title_size > 11
		and (
			font.get_string_size(name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size).x
			> name_label.size.x
		)
	):
		title_size -= 1
	name_label.add_theme_font_size_override("font_size", title_size)
	$Content/Heading/Cost/Value.add_theme_font_size_override(
		"font_size", clampi(roundi(size.x * 0.115), 16, 25)
	)
	$Content/Description.add_theme_font_size_override(
		"font_size", clampi(roundi(size.x * 0.081), 11, 18)
	)


func _on_pointer(inside: bool) -> void:
	# The hand owns hit testing against fixed slots, independent of the animated face.
	if layout_owner != null:
		return
	_pointer_inside = inside
	_update_preview()


func _update_preview() -> void:
	var active: bool = not _drag_suppressed and (_pointer_inside or has_focus())
	if _previewing == active:
		return
	_previewing = active
	_sync_state()
	if layout_owner != null:
		preview_requested.emit(self, active)
		return
	if _hover != null and _hover.is_valid():
		_hover.kill()
	_hover = create_tween()
	_hover.tween_property(
		self, "scale", Vector2.ONE * (hover_scale if active else 1.0), hover_duration
	)


func _has_point(point: Vector2) -> bool:
	if layout_owner != null:
		return layout_owner.accepts_card_point(self, point)
	if not Rect2(Vector2.ZERO, size).has_point(point):
		return false
	return true
