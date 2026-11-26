extends Button

const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
@export var hover_scale := 1.08
@export var hover_duration := 0.12
@export var frame_scale := 0.2
var _hover: Tween


func _ready() -> void:
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))
	focus_entered.connect(_on_hover.bind(true))
	focus_exited.connect(_on_hover.bind(false))
	$Frame.texture = Art.icon_texture("card_frame")
	$Content/Heading/Cost/Badge.texture = Art.icon_texture("cost_badge")
	$Content/Heading/Name.self_modulate = get_theme_color("title", "CardView")
	$Content/Art.resized.connect(_on_art_resized)
	resized.connect(_fit_frame)
	_fit_frame()


func render(copy: Dictionary, data: RefCounted) -> void:
	var definition: Dictionary = data.definition("cards", copy.card_id)
	# Preserve Button's accessible text; its transparent font is drawn by child labels.
	text = data.card_text(copy)
	tooltip_text = data.card_details(copy)
	$Content/Heading/Name.text = data.text(definition.name_key) + (" +" if copy.upgraded else "")
	$Content/Heading/Cost/Value.text = str(int(definition.cost))
	$Content/Art.texture = Art.card_texture(copy.card_id)
	$Content/Description.text = text.substr(text.find("\n") + 1)
	var role: String = str(definition.role)
	if role == "" and definition.owner != "":
		role = str(data.definition("characters", definition.owner).get("role", ""))
	$Content/Heading/Role.texture = Art.icon_texture("role_" + role)
	$Content/Heading/Role.visible = $Content/Heading/Role.texture != null
	$Frame.self_modulate = get_theme_color(role if role != "" else "neutral", "CardView")
	_on_art_resized.call_deferred()


func _process(_delta: float) -> void:
	$Content.modulate.a = 0.45 if disabled else 1.0
	$Frame.modulate.a = 1.0 if button_pressed else (0.5 if disabled else 0.8)


func _on_art_resized() -> void:
	$Content/Art.pivot_offset = $Content/Art.size * 0.5


func _fit_frame() -> void:
	$Frame.scale = Vector2.ONE * frame_scale
	$Frame.size = size / frame_scale


func _on_hover(active: bool) -> void:
	if _hover != null:
		_hover.kill()
	_hover = create_tween()
	_hover.tween_property(
		$Content/Art, "scale", Vector2.ONE * (hover_scale if active else 1.0), hover_duration
	)
