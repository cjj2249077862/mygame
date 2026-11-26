extends Node

# Presentation only: consumes settled event copies and never reads the battle RNG.
# Two music voices crossfade; bounded SFX voices keep rapid chains from building up.
const MUSIC = {
	"menu": preload("res://assets/audio/music/menu.wav"),
	"chapter": preload("res://assets/audio/music/chapter.wav"),
	"boss": preload("res://assets/audio/music/boss.wav"),
}
const EFFECTS = {
	"card_play": preload("res://assets/audio/sfx/card_play.wav"),
	"damage": preload("res://assets/audio/sfx/damage.wav"),
	"shield": preload("res://assets/audio/sfx/shield.wav"),
	"heal": preload("res://assets/audio/sfx/heal.wav"),
	"cast": preload("res://assets/audio/sfx/cast.wav"),
	"mark": preload("res://assets/audio/sfx/mark.wav"),
	"interrupt": preload("res://assets/audio/sfx/interrupt.wav"),
	"ot": preload("res://assets/audio/sfx/ot.wav"),
	"win": preload("res://assets/audio/sfx/win.wav"),
	"loss": preload("res://assets/audio/sfx/loss.wav"),
	"death": preload("res://assets/audio/sfx/death.wav"),
	"dispel": preload("res://assets/audio/sfx/dispel.wav"),
}
const EVENT_SOUNDS = {
	"card_play": "card_play",
	"card_played": "card_play",
	"damage": "damage",
	"shield": "shield",
	"block": "shield",
	"heal": "heal",
	"revive": "heal",
	"cast": "cast",
	"casting": "cast",
	"bomb": "mark",
	"mark": "mark",
	"phase": "mark",
	"enrage": "mark",
	"bomb_explode": "damage",
	"interrupt": "interrupt",
	"interrupt_failed": "shield",
	"ot": "ot",
	"win": "win",
	"loss": "loss",
	"death": "death",
	"dispel": "dispel",
}
const VOICE_LIMIT := 6
const MUSIC_GAIN := 0.32
const EFFECT_GAIN := 0.18
const FADE_SECONDS := 1.2
var _music: Array[AudioStreamPlayer] = []
var _voices: Array[AudioStreamPlayer] = []
var _weights: Array[float] = [0.0, 0.0]
var _voice_priority: Array[int] = []
var _voice_started: Array[int] = []
var _last_played: Dictionary = {}
var _last_regular := -100000
var _context := ""
var _master_volume := 0.8
var _music_volume := 0.65
var _sfx_volume := 0.9
var _enabled := true
var _fade: Tween


func _ready() -> void:
	_ensure_players()
	var requested: String = _context
	_context = ""
	if requested != "":
		set_context(requested)


func _exit_tree() -> void:
	stop_all()


func configure(options: Dictionary) -> void:
	_master_volume = _volume(options.get("master_volume", _master_volume), _master_volume)
	_music_volume = _volume(options.get("music_volume", _music_volume), _music_volume)
	_sfx_volume = _volume(options.get("sfx_volume", _sfx_volume), _sfx_volume)
	_enabled = bool(options.get("audio_enabled", _enabled))
	_apply_volumes()


func set_context(context: String) -> void:
	var requested: String = context if MUSIC.has(context) else ""
	if requested == _context:
		return
	_ensure_players()
	_context = requested
	if _fade != null and _fade.is_valid():
		_fade.kill()
	if not is_inside_tree():
		return
	_fade = create_tween().set_parallel(true)
	if requested == "":
		for index in range(_music.size()):
			_fade.tween_method(_set_weight.bind(index), _weights[index], 0.0, FADE_SECONDS)
		_fade.chain().tween_callback(_stop_quiet_music)
		return
	# Retain the louder outgoing layer if a second transition arrives mid-fade.
	var outgoing: int = 0 if _weights[0] >= _weights[1] else 1
	var incoming: int = 1 - outgoing
	_music[incoming].stop()
	var loop: AudioStreamWAV = MUSIC[requested].duplicate()
	loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
	loop.loop_begin = 0
	loop.loop_end = roundi(loop.get_length() * loop.mix_rate)
	_music[incoming].stream = loop
	_set_weight(0.0, incoming)
	_music[incoming].play()
	_fade.tween_method(_set_weight.bind(outgoing), _weights[outgoing], 0.0, FADE_SECONDS)
	_fade.tween_method(_set_weight.bind(incoming), 0.0, 1.0, FADE_SECONDS)
	_fade.chain().tween_callback(_stop_quiet_music)


func play_event(event: Dictionary, fast: bool = false) -> void:
	if not _enabled or _master_volume <= 0.0 or _sfx_volume <= 0.0 or not is_inside_tree():
		return
	var kind: String = str(event.get("kind", ""))
	var sound: String = EVENT_SOUNDS.get(kind, "")
	if sound == "":
		return
	if kind in ["damage", "shield", "heal"] and float(event.get("amount", 0)) <= 0:
		return
	if (
		kind == "damage"
		and float(event.get("shield_loss", 0)) > 0
		and float(event.get("hp_loss", event.get("amount", 0))) == 0
	):
		sound = "shield"
	_ensure_players()
	var priority: int = _priority(sound)
	# The card cue has its own per-sound cooldown, so the following impact can
	# still sound in fast playback without opening the regular impact floodgate.
	var regular_impact: bool = priority == 1 and sound != "card_play"
	var now: int = Time.get_ticks_msec()
	var cooldown: int = 240 if fast else 90
	if priority >= 3:
		cooldown = 200
	if sound in ["win", "loss"]:
		cooldown = 1200
	if now - int(_last_played.get(sound, -100000)) < cooldown:
		return
	if regular_impact and now - _last_regular < (130 if fast else 55):
		return
	var index: int = _available_voice(priority)
	if index < 0:
		return
	_last_played[sound] = now
	if regular_impact:
		_last_regular = now
	_voice_priority[index] = priority
	_voice_started[index] = now
	var player: AudioStreamPlayer = _voices[index]
	player.stop()
	player.stream = EFFECTS[sound]
	player.play()


func stop_all() -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_fade = null
	# Stop while the players still exist and release their playback/stream
	# references explicitly; the audio thread drains stopped voices separately.
	for player in _music:
		player.stop()
		player.stream = null
	for player in _voices:
		player.stop()
		player.stream = null
	_weights = [0.0, 0.0]
	_context = ""
	_last_played.clear()
	_last_regular = -100000


func _ensure_players() -> void:
	if not _music.is_empty():
		return
	for index in range(2):
		var player := AudioStreamPlayer.new()
		player.name = "Music%d" % index
		player.max_polyphony = 1
		add_child(player)
		_music.append(player)
	for index in range(VOICE_LIMIT):
		var player := AudioStreamPlayer.new()
		player.name = "Effect%d" % index
		player.max_polyphony = 1
		add_child(player)
		_voices.append(player)
		_voice_priority.append(0)
		_voice_started.append(-100000)
	_apply_volumes()


func _available_voice(priority: int) -> int:
	var replacement := -1
	for index in range(_voices.size()):
		if not _voices[index].playing:
			return index
		# A normal hit cannot cut off a warning or the victory/defeat sting.
		if _voice_priority[index] > priority:
			continue
		if replacement < 0 or _voice_started[index] < _voice_started[replacement]:
			replacement = index
	return replacement


func _priority(sound: String) -> int:
	if sound in ["win", "loss"]:
		return 4
	if sound in ["mark", "interrupt", "ot"]:
		return 3
	if sound in ["cast", "death"]:
		return 2
	return 1


func _set_weight(value: float, index: int) -> void:
	_weights[index] = clampf(value, 0.0, 1.0)
	_music[index].volume_db = _db(_music_gain() * _weights[index])


func _stop_quiet_music() -> void:
	for index in range(_music.size()):
		if _weights[index] <= 0.001:
			_music[index].stop()


func _apply_volumes() -> void:
	for index in range(_music.size()):
		_music[index].volume_db = _db(_music_gain() * _weights[index])
	for player in _voices:
		player.volume_db = _db(_master_volume * _sfx_volume * EFFECT_GAIN if _enabled else 0.0)


func _music_gain() -> float:
	return _master_volume * _music_volume * MUSIC_GAIN if _enabled else 0.0


func _db(value: float) -> float:
	return linear_to_db(value) if value > 0.0 else -80.0


func _volume(value: Variant, previous: float) -> float:
	if (value is int or value is float) and is_finite(float(value)):
		return clampf(float(value), 0.0, 1.0)
	return previous
