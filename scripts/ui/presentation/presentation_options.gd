extends AcceptDialog

const TOGGLES := {
	"audio_enabled": "Audio",
	"fast": "Fast",
	"show_log": "Log",
	"shake_enabled": "Shake",
	"flash_enabled": "Flash",
	"parallax_enabled": "Parallax",
}
const VOLUMES := {"master_volume": "Master", "music_volume": "Music", "sfx_volume": "Sfx"}
var _preferences: RefCounted


func _ready() -> void:
	for key in TOGGLES:
		get_node("Content/Options/" + TOGGLES[key]).toggled.connect(_on_changed.bind(key))
	for key in VOLUMES:
		get_node("Content/" + VOLUMES[key] + "/Slider").value_changed.connect(_on_changed.bind(key))
	$Content/Restore.pressed.connect(_on_restore)
	get_parent().get_viewport().size_changed.connect(_on_parent_resized)


func bind_preferences(preferences: RefCounted, data: RefCounted) -> void:
	_preferences = preferences
	title = preferences.text("presentation.options")
	ok_button_text = data.text("ui.close")
	$Content/Description.text = preferences.text("presentation.description")
	$Content/Restore.text = preferences.text("presentation.restore")
	for key in TOGGLES:
		get_node("Content/Options/" + TOGGLES[key]).text = preferences.text("presentation." + key)
	for key in VOLUMES:
		get_node("Content/" + VOLUMES[key] + "/Label").text = preferences.text(
			"presentation." + key
		)
	preferences.changed.connect(refresh)
	refresh()


func refresh() -> void:
	if _preferences == null:
		return
	var options: Dictionary = _preferences.snapshot()
	for key in TOGGLES:
		get_node("Content/Options/" + TOGGLES[key]).set_pressed_no_signal(options[key])
	for key in VOLUMES:
		get_node("Content/" + VOLUMES[key] + "/Slider").set_value_no_signal(options[key])
		get_node("Content/" + VOLUMES[key] + "/Value").text = (
			"%d%%" % roundi(float(options[key]) * 100.0)
		)
	$Content/Error.visible = _preferences.error != ""
	$Content/Error.text = _preferences.text(_preferences.error) if _preferences.error != "" else ""


func open() -> void:
	refresh()
	popup_centered()
	size = Vector2i(620, 540)
	move_to_center()
	move_to_center.call_deferred()


func _on_changed(value: Variant, key: String) -> void:
	if _preferences != null:
		_preferences.set_option(key, value)


func _on_restore() -> void:
	_preferences.restore_defaults()


func _on_parent_resized() -> void:
	if visible:
		move_to_center.call_deferred()
