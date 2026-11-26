extends RefCounted

signal changed

const Store = preload("res://scripts/core/save_manager.gd")
const TEXT_PATH := "res://data/presentation.json"
const DEFAULTS := {
	"audio_enabled": true,
	"master_volume": 0.8,
	"music_volume": 0.65,
	"sfx_volume": 0.9,
	"fast": false,
	"show_log": false,
	"shake_enabled": true,
	"flash_enabled": true,
	"parallax_enabled": true,
}
var options: Dictionary = DEFAULTS.duplicate(true)
var error := ""
var _texts: Dictionary = {}
var _stored: Dictionary = {}
var _store: RefCounted


func _init(directory: String = "") -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEXT_PATH))
	if parsed is Dictionary and parsed.get("version") == 1 and parsed.get("texts") is Dictionary:
		_texts = parsed.texts.duplicate(true)
	if directory == "":
		return
	_store = Store.new(directory)
	if not _store.has_slot("settings"):
		return
	_stored = _store.read_slot("settings", _valid_settings)
	if _stored.is_empty():
		error = "presentation.load_error"
		return
	for key in _stored.get("presentation", {}):
		if DEFAULTS.has(key):
			options[key] = _stored.presentation[key]


func text(key: String) -> String:
	return str(_texts.get(key, key))


func snapshot() -> Dictionary:
	return options.duplicate(true)


func set_option(key: String, value: Variant) -> bool:
	if not _valid_option(key, value):
		return false
	options[key] = value
	return _save()


func restore_defaults() -> bool:
	options = DEFAULTS.duplicate(true)
	return _save()


func _save() -> bool:
	var candidate: Dictionary = _stored.duplicate(true)
	candidate["version"] = 1
	candidate["presentation"] = snapshot()
	var saved: bool = (
		_store == null or _store.write_slot("settings", candidate, false, _valid_settings)
	)
	error = "" if saved else "presentation.save_error"
	if saved:
		_stored = candidate
	changed.emit()
	return saved


func _valid_option(key: String, value: Variant) -> bool:
	if not DEFAULTS.has(key):
		return false
	if DEFAULTS[key] is bool:
		return value is bool
	return (
		(value is float or value is int) and is_finite(float(value)) and value >= 0 and value <= 1
	)


func _valid_settings(candidate: Dictionary) -> bool:
	if candidate.get("version", 1) != 1:
		return false
	var saved: Variant = candidate.get("presentation", {})
	if not saved is Dictionary:
		return false
	for key in saved:
		if not key is String or not _valid_option(key, saved[key]):
			return false
	return true
