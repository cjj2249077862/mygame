extends RefCounted

const FORMAT_VERSION := 1
const SLOTS := ["run", "meta", "settings"]
var directory: String
var last_error := ""
var recovered_from_backup := false


func _init(save_directory: String = "user://raiddeck") -> void:
	directory = save_directory


func has_slot(slot: String) -> bool:
	return (
		slot in SLOTS
		and (FileAccess.file_exists(_path(slot)) or FileAccess.file_exists(_path(slot) + ".bak"))
	)


func read_slot(slot: String, validator: Callable = Callable()) -> Dictionary:
	# This is a JSON transport layer: numbers arrive as floats. Schema owners
	# validate integer-valued fields and restore their intended runtime types.
	last_error = ""
	recovered_from_backup = false
	if slot not in SLOTS:
		last_error = "invalid_save_slot"
		return {}
	var candidates: Array = []
	for suffix in ["", ".bak"]:
		var candidate := _read_file(_path(slot) + suffix)
		if candidate.is_empty():
			continue
		if validator.is_valid() and not validator.call(candidate.payload):
			continue
		candidate["backup"] = suffix != ""
		candidates.append(candidate)
	if candidates.is_empty():
		if has_slot(slot):
			last_error = "save_corrupt_or_incompatible"
		return {}
	candidates.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return a.revision > b.revision
	)
	recovered_from_backup = candidates[0].backup
	return candidates[0].payload.duplicate(true)


func write_slot(
	slot: String, payload: Dictionary, terminal: bool = false, validator: Callable = Callable()
) -> bool:
	last_error = ""
	if slot not in SLOTS:
		return _fail("invalid_save_slot")
	if validator.is_valid() and not validator.call(payload):
		return _fail("save_corrupt_or_incompatible")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _fail("cannot_create_save_directory")
	var destination := _path(slot)
	var primary := _read_file(destination)
	var backup := _read_file(destination + ".bak")
	var revision := maxi(int(primary.get("revision", 0)), int(backup.get("revision", 0))) + 1
	# A checksum only proves file integrity. Never rotate a semantically invalid
	# primary over the good backup selected by read_slot's schema validator.
	if validator.is_valid() and not primary.is_empty() and not validator.call(primary.payload):
		primary = {}
	if validator.is_valid() and not backup.is_empty() and not validator.call(backup.payload):
		backup = {}
	# Keep the exact payload string for checksum verification; JSON parsing would
	# otherwise change integer formatting. RNG 64-bit values belong in strings.
	var body := JSON.stringify(payload)
	var envelope := (
		JSON
		. stringify(
			{
				"format": FORMAT_VERSION,
				"revision": revision,
				"sha256": body.sha256_text(),
				"payload": body,
			}
		)
	)
	var temporary := destination + ".tmp"
	if not _write_file(temporary, envelope):
		return false
	if _read_file(temporary).is_empty():
		return _fail("temporary_save_verification_failed")
	# A completed/abandoned run writes a terminal backup as well, so corruption
	# cannot revive the previous active checkpoint. Readers prefer newest revision.
	if (
		terminal
		or (not primary.is_empty() and int(primary.revision) >= int(backup.get("revision", 0)))
	):
		var backup_body := envelope if terminal else FileAccess.get_file_as_string(destination)
		if not _write_file(destination + ".bak.tmp", backup_body):
			return false
		if _read_file(destination + ".bak.tmp").is_empty():
			return _fail("backup_verification_failed")
		if _replace_file(destination + ".bak.tmp", destination + ".bak") != OK:
			return _fail("backup_replace_failed")
	# rename_absolute replaces an existing file. The primary is never deleted
	# before this step, and a failed replacement leaves its contents intact.
	if _replace_file(temporary, destination) != OK:
		return _fail("save_replace_failed")
	return true


func _path(slot: String) -> String:
	return directory.path_join(slot + ".json")


func _read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	file.close()
	if parse_error != OK:
		return {}
	var envelope: Variant = parser.data
	if not envelope is Dictionary or envelope.get("format") != FORMAT_VERSION:
		return {}
	if not envelope.get("payload") is String or not envelope.get("sha256") is String:
		return {}
	var revision: Variant = envelope.get("revision")
	if not (revision is int or revision is float) or revision < 1 or revision != floorf(revision):
		return {}
	if envelope.payload.sha256_text() != envelope.sha256:
		return {}
	if parser.parse(envelope.payload) != OK:
		return {}
	var payload: Variant = parser.data
	if not payload is Dictionary:
		return {}
	return {"revision": int(revision), "payload": payload}


func _write_file(path: String, contents: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail("save_open_failed")
	file.store_string(contents)
	file.flush()
	var result := file.get_error()
	file.close()
	if result != OK:
		return _fail("save_write_failed")
	return true


func _replace_file(source: String, destination: String) -> Error:
	return DirAccess.rename_absolute(source, destination)


func _fail(reason: String) -> bool:
	last_error = reason
	return false
