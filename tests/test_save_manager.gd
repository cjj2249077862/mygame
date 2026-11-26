extends "res://tests/test_suite.gd"

const Store = preload("res://scripts/core/save_manager.gd")


class FailingStore:
	extends "res://scripts/core/save_manager.gd"
	var fail_replace := false
	var fail_write := false

	func _replace_file(source: String, destination: String) -> Error:
		if fail_replace and destination.ends_with("run.json"):
			return ERR_CANT_CREATE
		return super._replace_file(source, destination)

	func _write_file(path: String, contents: String) -> bool:
		if fail_write:
			return _fail("injected_write_failure")
		return super._write_file(path, contents)


func run_tests() -> void:
	var directory := "user://phase2_save_test_%d" % Time.get_ticks_usec()
	var store := FailingStore.new(directory)
	var first := {"value": 1, "active": true, "rng": "9223372036854775807"}
	expect(not store.has_slot("run"))
	expect(store.write_slot("run", first))
	expect(store.read_slot("run") == first)
	expect(store.write_slot("run", {"value": 2, "active": true}))
	expect(store.read_slot("run").value == 2)
	expect(store.write_slot("meta", {"completed": 3}))
	expect(store.write_slot("settings", {"fast": true}))
	expect(store.read_slot("meta").completed == 3 and store.read_slot("settings").fast)
	var primary := directory.path_join("run.json")
	var before := FileAccess.get_file_as_string(primary)
	store.fail_replace = true
	expect(not store.write_slot("run", {"value": 3, "active": true}))
	expect(FileAccess.get_file_as_string(primary) == before, "Failed replace preserves primary")
	expect(store.read_slot("run").value == 2)
	store.fail_replace = false
	store.fail_write = true
	expect(not store.write_slot("run", {"value": 4, "active": true}))
	expect(FileAccess.get_file_as_string(primary) == before, "Failed write preserves primary")
	store.fail_write = false
	_write_raw(primary, "{broken")
	expect(store.read_slot("run").value == 2)
	expect(store.recovered_from_backup, "Corrupt primary falls back to verified backup")
	expect(store.write_slot("run", {"value": "invalid"}))
	var recovered := store.read_slot("run", _valid_payload)
	expect(recovered.value == 2 and store.recovered_from_backup)
	var good_backup := FileAccess.get_file_as_string(primary + ".bak")
	store.fail_replace = true
	expect(not store.write_slot("run", {"value": 4, "active": true}, false, _valid_payload))
	expect(
		FileAccess.get_file_as_string(primary + ".bak") == good_backup,
		"Invalid primary must not replace the sole valid backup before a failed save"
	)
	recovered = store.read_slot("run", _valid_payload)
	expect(recovered.value == 2 and store.recovered_from_backup)
	store.fail_replace = false
	expect(
		not store.write_slot("run", {"value": "invalid"}, false, _valid_payload),
		"Reject invalid new payload before touching either saved copy"
	)
	expect(FileAccess.get_file_as_string(primary + ".bak") == good_backup)
	# Closing a run must not resurrect the earlier active checkpoint from backup.
	expect(store.write_slot("run", {"value": 5, "active": false}, true))
	_write_raw(primary, "not json")
	recovered = store.read_slot("run", _valid_payload)
	expect(recovered.value == 5 and not recovered.active and store.recovered_from_backup)
	expect(store.read_slot("meta").completed == 3)
	_write_raw(primary + ".bak", "also corrupt")
	expect(store.read_slot("run").is_empty())
	expect(store.last_error == "save_corrupt_or_incompatible")
	expect(not store.write_slot("../escape", {}))
	expect(store.read_slot("../escape").is_empty())
	_remove_fixture(directory)


func _valid_payload(payload: Dictionary) -> bool:
	return payload.get("value") is float or payload.get("value") is int


func _write_raw(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if expect(file != null, "Fixture must be writable"):
		file.store_string(contents)
		file.close()


func _remove_fixture(directory: String) -> void:
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	for filename in dir.get_files():
		DirAccess.remove_absolute(directory.path_join(filename))
	DirAccess.remove_absolute(directory)
