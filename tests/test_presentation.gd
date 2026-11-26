extends "res://tests/test_suite.gd"

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Store = preload("res://scripts/core/save_manager.gd")
const Types = preload("res://scripts/core/enums.gd")
const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
const Preferences = preload("res://scripts/ui/presentation/presentation_preferences.gd")
const Audio = preload("res://scripts/ui/presentation/audio_director.gd")
const MainScene = preload("res://scenes/main.tscn")
const BattleScene = preload("res://scenes/battle/battle_view.tscn")
const UnitScene = preload("res://scenes/battle/unit_view.tscn")
const CardScene = preload("res://scenes/presentation/card_view.tscn")
const NodeScene = preload("res://scenes/run/node_panel.tscn")


class RejectSettings:
	extends RefCounted

	func write_slot(
		_slot: String,
		_payload: Dictionary,
		_terminal: bool = false,
		_validator: Callable = Callable()
	) -> bool:
		return false


var data: RefCounted = Data.new()
var _directories: Array[String] = []


func run_tests() -> void:
	root.size = Vector2i(1440, 900)
	root.gui_embed_subwindows = true
	if not expect(data.load_directory(), "Presentation fixtures require valid gameplay data"):
		return
	_test_art_coverage()
	_test_preferences()
	await _test_audio()
	await _test_cards_and_prices()
	await _test_main_wiring()
	await _test_normal_and_fast()
	_cleanup_directories()


func _test_art_coverage() -> void:
	var cards: Array = data.rows("cards")
	var enemies: Array = data.rows("encounters", "enemies")
	expect(cards.size() == 40 and enemies.size() == 11, "Chapter one art coverage fixture")
	for definition in cards:
		var texture: Texture2D = Art.card_texture(str(definition.id))
		expect(texture != null and texture.get_width() > 0, "Card art: " + str(definition.id))
	for definition in data.rows("characters"):
		expect(
			Art.actor_texture(str(definition.id)) != null, "Party portrait: " + str(definition.id)
		)
	var regions: Array[Rect2] = []
	for definition in enemies:
		var texture: Texture2D = Art.actor_texture(str(definition.id))
		if expect(texture is AtlasTexture, "Enemy atlas portrait: " + str(definition.id)):
			var atlas: AtlasTexture = texture as AtlasTexture
			expect(
				(
					atlas.atlas != null
					and Rect2(Vector2.ZERO, atlas.atlas.get_size()).encloses(atlas.region)
				),
				"Enemy crop must stay inside the atlas"
			)
			expect(
				atlas.region.has_area() and atlas.region not in regions,
				"Distinct nonempty enemy crop"
			)
			regions.append(atlas.region)
	for definition in data.rows("relics"):
		expect(Art.icon_texture(str(definition.id)) != null, "Relic icon: " + str(definition.id))
	for key in [
		"damage", "heal", "shield", "regen", "weak", "vulnerable", "cast", "uninterruptible", "bomb"
	]:
		expect(Art.icon_texture(key) != null, "Mechanic icon: " + key)
	expect(
		(
			Art.actor_texture("missing") == null
			and Art.card_texture("missing") == null
			and Art.icon_texture("missing") == null
		),
		"Unknown art IDs have an explicit empty fallback"
	)


func _test_preferences() -> void:
	var directory: String = _directory("preferences")
	var saves: RefCounted = Store.new(directory)
	expect(saves.write_slot("run", {"sentinel": 1}), "Seed unrelated run save")
	expect(saves.write_slot("run", {"sentinel": 2}), "Seed unrelated run backup")
	expect(saves.write_slot("meta", {"sentinel": 3}), "Seed unrelated meta save")
	expect(
		saves.write_slot("settings", {"version": 1, "resolution": "fixture", "presentation": {}})
	)
	var run_files: Dictionary = _files(directory, ["run.json", "run.json.bak", "meta.json"])
	var gameplay: Dictionary = data.books.duplicate(true)
	var preferences: RefCounted = Preferences.new(directory)
	var texts: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Preferences.TEXT_PATH))
	expect(not Data.BOOKS.has("presentation"), "Presentation has an independent data file")
	for key in texts.texts:
		expect(
			preferences.text(key) == texts.texts[key] and preferences.text(key) != key,
			"Presentation text resolves: " + str(key)
		)
	var changes: Array[bool] = []
	preferences.changed.connect(func() -> void: changes.append(true))
	expect(preferences.set_option("fast", true))
	expect(preferences.set_option("master_volume", 0.35))
	expect(preferences.set_option("audio_enabled", false))
	var restored: RefCounted = Preferences.new(directory)
	expect(
		restored.snapshot() == preferences.snapshot(),
		"Presentation settings persist across recreation"
	)
	expect(
		saves.read_slot("settings").resolution == "fixture",
		"Unrelated settings fields survive saves"
	)
	var before: Dictionary = preferences.snapshot()
	var settings_files: Dictionary = _files(directory, ["settings.json", "settings.json.bak"])
	var valid_changes: int = changes.size()
	for pair in [
		["fast", 1],
		["show_log", "true"],
		["master_volume", -0.01],
		["music_volume", 1.01],
		["sfx_volume", NAN],
		["sfx_volume", true],
		["unknown", false]
	]:
		expect(
			not preferences.set_option(str(pair[0]), pair[1]),
			"Reject malformed setting: " + str(pair[0])
		)
	expect(
		preferences.snapshot() == before and changes.size() == valid_changes,
		"Invalid settings do not mutate or notify"
	)
	expect(
		_files(directory, ["settings.json", "settings.json.bak"]) == settings_files,
		"Invalid settings do not overwrite valid files"
	)
	var detached: Dictionary = preferences.snapshot()
	detached.fast = false
	expect(preferences.snapshot().fast, "Settings snapshots cannot mutate the live preferences")
	expect(
		(
			preferences.restore_defaults()
			and Preferences.new(directory).snapshot() == Preferences.DEFAULTS
		),
		"Restore defaults persists"
	)
	expect(
		_files(directory, ["run.json", "run.json.bak", "meta.json"]) == run_files,
		"Settings never rewrite run or meta data"
	)
	expect(data.books == gameplay, "Presentation loading and saves do not change gameplay tables")
	var corrupt_directory: String = _directory("invalid_settings")
	var corrupt_store: RefCounted = Store.new(corrupt_directory)
	expect(
		corrupt_store.write_slot("settings", {"version": 1, "presentation": {"fast": "invalid"}})
	)
	var invalid: RefCounted = Preferences.new(corrupt_directory)
	expect(
		invalid.snapshot() == Preferences.DEFAULTS and invalid.error == "presentation.load_error",
		"Invalid stored values leave safe defaults and a visible error"
	)


func _test_audio() -> void:
	var audio: Node = Audio.new()
	root.add_child(audio)
	expect(
		audio.get_child_count() == 8 and audio._music.size() == 2 and audio._voices.size() == 6,
		"Audio owns exactly two music and six effect voices"
	)
	var voice_ids: Array[int] = []
	for child in audio.get_children():
		voice_ids.append(child.get_instance_id())
		expect(
			child is AudioStreamPlayer and child.max_polyphony == 1,
			"Every owned voice has bounded polyphony"
		)
	audio.configure(
		{"audio_enabled": true, "master_volume": 0.5, "music_volume": 0.4, "sfx_volume": 0.3}
	)
	audio.set_context("menu")
	var first_stream: Resource = audio._music[1].stream
	audio.set_context("menu")
	expect(
		audio._music[1].stream == first_stream,
		"Refreshing the same context does not restart its music"
	)
	for context in ["chapter", "boss", "menu", "boss"]:
		audio.set_context(context)
	await create_timer(Audio.FADE_SECONDS + 0.1).timeout
	expect(
		is_equal_approx(float(audio._weights[0]) + float(audio._weights[1]), 1.0),
		"Interrupted crossfades finish at one full music layer"
	)
	var active_music: int = 0
	for player in audio._music:
		if player.playing:
			active_music += 1
	expect(active_music == 1, "Quiet outgoing music is stopped after a transition")
	audio.configure({"audio_enabled": false})
	for child in audio.get_children():
		expect(child.volume_db <= -79.0, "Master mute reaches both music and effects")
	var muted_events: Dictionary = audio._last_played.duplicate(true)
	audio.play_event({"kind": "win"})
	expect(
		audio._last_played == muted_events, "Muted event playback does not schedule another voice"
	)
	audio.configure({"audio_enabled": true})
	audio.stop_all()
	audio.play_event({"kind": "damage", "amount": 8, "hp_loss": 0, "shield_loss": 8})
	expect(
		audio._last_played.has("shield") and not audio._last_played.has("damage"),
		"Fully absorbed hit uses shield sound"
	)
	audio.stop_all()
	audio.play_event({"kind": "damage", "amount": 8, "hp_loss": 3, "shield_loss": 5})
	expect(audio._last_played.has("damage"), "Mixed shield and HP hit keeps damage sound")
	audio.stop_all()
	audio.play_event({"kind": "damage", "amount": 8})
	expect(audio._last_played.has("damage"), "Older damage records remain supported")
	audio.stop_all()
	audio.play_event({"kind": "card_play"}, true)
	await create_timer(0.025).timeout
	audio.play_event({"kind": "damage", "amount": 4}, true)
	expect(
		audio._last_played.has("card_play") and audio._last_played.has("damage"),
		"Fast card cue does not swallow its first hit"
	)
	for index in range(80):
		for kind in ["cast", "bomb", "interrupt", "ot", "win", "loss", "damage"]:
			audio.play_event({"kind": kind, "amount": 3}, true)
	var current_ids: Array[int] = []
	for child in audio.get_children():
		current_ids.append(child.get_instance_id())
	expect(
		current_ids == voice_ids,
		"Rapid chains and scene changes reuse the original fixed voice pool"
	)
	audio.stop_all()
	for child in audio.get_children():
		expect(not child.playing, "stop_all stops every owned audio stream")
	expect(
		audio._context == "" and audio._last_played.is_empty() and audio._weights == [0.0, 0.0],
		"stop_all clears transition and throttling state"
	)
	expect(
		audio._fade == null or not audio._fade.is_valid(), "stop_all cancels the crossfade tween"
	)
	audio.queue_free()
	await process_frame


func _test_cards_and_prices() -> void:
	var card: Button = CardScene.instantiate()
	root.add_child(card)
	var copy: Dictionary = {"copy_id": 7, "card_id": "slash", "upgraded": false}
	card.render(copy, data)
	expect(
		card.text == data.card_text(copy) and card.tooltip_text == data.card_details(copy),
		"Rendered card retains complete accessible text and tooltip"
	)
	expect(
		(
			card.get_node("Content/Heading/Cost/Value").text
			== str(int(data.definition("cards", "slash").cost))
		),
		"Energy cost is visible as an integer"
	)
	expect(
		card.get_node("Content/Art").texture != null, "Card illustration reaches the actual scene"
	)
	copy.upgraded = true
	card.render(copy, data)
	expect(
		(
			card.get_node("Content/Heading/Name").text.ends_with(" +")
			and card.tooltip_text == data.card_details(copy)
		),
		"Upgrade label and full upgraded details stay synchronized"
	)
	var panel: Control = NodeScene.instantiate()
	root.add_child(panel)
	var offer: Dictionary = {
		"id": "fixture",
		"kind": "card",
		"item_id": "slash",
		"name": data.text("card.slash"),
		"description": data.card_details(copy),
		"price": 35,
		"sold_out": false
	}
	var state: Dictionary = {
		"phase": Types.RunPhase.SHOP,
		"token": 1,
		"gold": 40,
		"shop": {"offers": [offer], "refresh_cost": 20, "remove_cost": 40, "removable_cards": []}
	}
	panel.render(state, data)
	var button: Button = panel.get_node("Margin/Content/OptionsScroll/Options").get_child(0)
	expect(
		button.text == data.text("ui.shop_offer", offer) and button.text.contains("35"),
		"Illustrated shop offer keeps the actual gold price visible"
	)
	expect(
		button.tooltip_text == offer.description and button.icon != null and not button.disabled,
		"Shop art does not replace the full description or purchasing state"
	)
	card.queue_free()
	panel.queue_free()
	await process_frame


func _test_main_wiring() -> void:
	var app: Control = MainScene.instantiate()
	app.save_directory = _directory("main")
	root.add_child(app)
	await process_frame
	if not expect(
		app.run != null and app.preferences != null, "Main initializes presentation services"
	):
		app.queue_free()
		await process_frame
		return
	var view: Control = app.get_node("Battle")
	var options: Window = app.get_node("PresentationOptions")
	var audio: Node = app.get_node("AudioDirector")
	expect(audio._context == "menu", "Menu selects menu music")
	app.preferences.set_option("fast", true)
	if not expect(app.run.start(730031), "Main fixture starts a deterministic run"):
		app.queue_free()
		await process_frame
		return
	await _settle(view)
	expect(audio._context == "chapter", "First battle selects chapter music")
	var before: Dictionary = app.run.battle.snapshot()
	var rng_before: int = app.run.rng.state
	var gameplay: Dictionary = app.data.books.duplicate(true)
	var saved: Dictionary = _files(
		app.save_directory, ["run.json", "run.json.bak", "meta.json", "meta.json.bak"]
	)
	options.get_node("Content/Options/Audio").button_pressed = false
	options.get_node("Content/Options/Log").button_pressed = true
	options.get_node("Content/Options/Shake").button_pressed = false
	options.get_node("Content/Options/Flash").button_pressed = false
	options.get_node("Content/Options/Parallax").button_pressed = false
	options.get_node("Content/Master/Slider").value = 0.25
	options.get_node("Content/Music/Slider").value = 0.45
	options.get_node("Content/Sfx/Slider").value = 0.55
	expect(
		(
			not audio._enabled
			and is_equal_approx(audio._master_volume, 0.25)
			and is_equal_approx(audio._music_volume, 0.45)
			and is_equal_approx(audio._sfx_volume, 0.55)
		),
		"Options controls configure the live audio service"
	)
	expect(
		(
			view.log_view.visible
			and not view._options.shake_enabled
			and not view._options.flash_enabled
		),
		"Options controls configure battle log and effects"
	)
	expect(
		not app.get_node("Background").motion_enabled, "Parallax option reaches the actual backdrop"
	)
	for unit in view._unit_views().values():
		expect(not unit._flash_enabled, "Flash preference reaches already rendered units")
	view.get_node("Margin/Content/Actions/Fast").button_pressed = false
	expect(
		(
			not app.preferences.snapshot().fast
			and not options.get_node("Content/Options/Fast").button_pressed
		),
		"Battle quick toggle saves and updates the options dialog"
	)
	expect(
		not Preferences.new(app.save_directory).snapshot().fast,
		"Battle quick toggle persists to disk"
	)
	expect(
		(
			app.run.battle.snapshot() == before
			and app.run.rng.state == rng_before
			and app.data.books == gameplay
		),
		"Changing presentation does not settle rules or consume gameplay RNG"
	)
	expect(
		(
			_files(app.save_directory, ["run.json", "run.json.bak", "meta.json", "meta.json.bak"])
			== saved
		),
		"Main setting changes do not rewrite gameplay saves"
	)
	app.get_node("Navigation/Actions/Presentation").pressed.emit()
	await process_frame
	expect(
		options.visible and options.title == app.preferences.text("presentation.options"),
		"Navigation opens the translated presentation panel"
	)
	options.hide()
	await _test_main_action_order(app, view)
	var settings_before: Dictionary = _files(
		app.save_directory, ["settings.json", "settings.json.bak"]
	)
	var original_store: RefCounted = app.preferences._store
	app.preferences._store = RejectSettings.new()
	view.get_node("Margin/Content/Actions/Fast").button_pressed = true
	expect(
		options.visible and options.get_node("Content/Error").visible,
		"Failed save from the battle fast toggle opens a visible settings error"
	)
	expect(
		app.preferences.error == "presentation.save_error" and app.preferences.snapshot().fast,
		"Save failure retains the requested session preference with an explicit error"
	)
	expect(
		_files(app.save_directory, ["settings.json", "settings.json.bak"]) == settings_before,
		"Failed preference save preserves the last valid settings files"
	)
	app.preferences._store = original_store
	options.hide()
	app.get_node("AudioDirector").stop_all()
	view.leave_battle()
	app.queue_free()
	await process_frame


func _test_main_action_order(app: Control, view: Control) -> void:
	var copy_id: int = _prepare_slash(view)
	if not expect(copy_id >= 0, "Action order fixture requires a real slash card"):
		return
	var enemy: Node = view._unit_views().get("enemy_0")
	var before_hp: float = enemy.get_node("Content/Health").value
	var heard: Array[Dictionary] = []
	view.presentation_event.connect(
		func(record: Dictionary, _fast: bool) -> void: heard.append(record.duplicate(true))
	)
	view._on_card_selected(copy_id)
	view._on_unit_selected("enemy_0")
	expect(view.locked, "Main locks additional actions during record playback")
	expect(
		int(app.run.battle.find_unit("enemy_0").hp) < int(before_hp),
		"Rules have already settled the damage"
	)
	expect(
		enemy.get_node("Content/Health").value == before_hp,
		"Main changed signal must not render final HP before its records"
	)
	expect(
		not heard.is_empty() and heard[0].kind == "card_play",
		"Successful card cue starts the ordered event queue"
	)
	var settled_state: Dictionary = app.run.battle.snapshot()
	view._on_card_selected(copy_id)
	view._on_unit_selected("enemy_0")
	expect(
		app.run.battle.snapshot() == settled_state,
		"Repeated clicks during playback cannot duplicate the action"
	)
	await _settle(view)
	expect(
		int(enemy.get_node("Content/Health").value) == int(app.run.battle.find_unit("enemy_0").hp),
		"Final HP is rendered when playback completes"
	)
	var damage: Dictionary = {}
	for record in heard:
		if record.kind == "damage":
			damage = record
			break
	expect(
		damage.has("hp_loss") and damage.has("shield_loss"),
		"Damage exposes absorbed and HP portions for presentation"
	)
	var count_before: int = heard.size()
	var next_copy: int = _prepare_slash(view)
	if next_copy >= 0:
		view.engine.state.energy = 0
		view._on_card_selected(next_copy)
		view._on_unit_selected("enemy_0")
		expect(heard.size() == count_before, "Rejected play emits no successful card sound")


func _test_normal_and_fast() -> void:
	var normal_run: RefCounted = Run.new(data)
	var fast_run: RefCounted = Run.new(data)
	if not expect(
		normal_run.start(618034) and fast_run.start(618034), "Two identical seeded runs start"
	):
		return
	var normal: Control = BattleScene.instantiate()
	var fast: Control = BattleScene.instantiate()
	root.add_child(normal)
	root.add_child(fast)
	normal.configure_presentation(
		{"fast": false, "show_log": false, "shake_enabled": false, "flash_enabled": false}
	)
	fast.configure_presentation({"fast": true, "show_log": false})
	normal.bind_battle(normal_run.battle, data, normal_run.deck)
	fast.bind_battle(fast_run.battle, data, fast_run.deck)
	normal_run.battle.settled.emit([], normal_run.battle.snapshot())
	fast_run.battle.settled.emit([], fast_run.battle.snapshot())
	var normal_copy: int = _prepare_slash(normal)
	var fast_copy: int = _prepare_slash(fast)
	if expect(
		normal_copy >= 0 and normal_copy == fast_copy, "Both modes use the same real card copy"
	):
		for pair in [[normal, normal_copy], [fast, fast_copy]]:
			pair[0]._on_card_selected(int(pair[1]))
			pair[0]._on_unit_selected("enemy_0")
		expect(
			(
				normal_run.battle.snapshot() == fast_run.battle.snapshot()
				and normal_run.rng.state == fast_run.rng.state
			),
			"Normal and fast actions settle to identical state and RNG before animation finishes"
		)
		await _settle(normal)
		await _settle(fast)
		normal._end_turn()
		fast._end_turn()
		await _settle(normal)
		await _settle(fast)
		expect(
			(
				normal_run.battle.snapshot() == fast_run.battle.snapshot()
				and normal_run.rng.state == fast_run.rng.state
			),
			"Enemy actions, draws and intent RNG remain identical after both presentation modes"
		)
	await _test_unit_cues(normal_run)
	await _test_feedback_cleanup(normal, normal_run, fast_run)
	normal.leave_battle()
	fast.leave_battle()
	normal.queue_free()
	fast.queue_free()
	await process_frame


func _test_unit_cues(run: RefCounted) -> void:
	var unit: Button = UnitScene.instantiate()
	root.add_child(unit)
	unit.configure_presentation({"motion_enabled": false, "flash_enabled": false})
	var original: Dictionary = run.battle.snapshot()
	var rng_before: int = run.rng.state
	var hero: Dictionary = run.battle.find_unit("warden").duplicate(true)
	unit.render(hero, data, run.battle, false, false)
	unit.play_cue("death", true)
	unit.reset_presentation()
	expect(
		not unit._alive and unit.get_node("Content/Portrait").modulate == unit.dead_tint,
		"Cancelling death cue retains the dead portrait"
	)
	hero.hp = 0
	unit.render(hero, data, run.battle, false, false)
	unit.play_cue("damage", true)
	unit.reset_presentation()
	expect(
		unit.get_node("Content/Portrait").modulate == unit.dead_tint,
		"Subsequent cleanup cannot revive a dead portrait"
	)
	hero.hp = 1
	unit.render(hero, data, run.battle, false, false)
	unit.play_cue("revive", true)
	await create_timer(float(unit.cue_duration) * 0.45 + 0.04).timeout
	unit.reset_presentation()
	expect(
		unit._alive and unit.get_node("Content/Portrait").modulate == Color.WHITE,
		"Revive restores the living portrait"
	)
	unit.play_cue("cast")
	unit.reset_presentation()
	expect(
		(
			unit.get_node("Content/Portrait").position == Vector2.ZERO
			and unit.get_node("Content/Portrait").scale == Vector2.ONE
		),
		"Cancelled motion restores position and scale"
	)
	expect(
		run.battle.snapshot() == original and run.rng.state == rng_before,
		"Unit animation never changes combat data or RNG"
	)
	unit.queue_free()
	await process_frame


func _test_feedback_cleanup(view: Control, old_run: RefCounted, new_run: RefCounted) -> void:
	var feedback: Control = view.get_node("Feedback")
	expect(
		feedback.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"Feedback overlay never steals targeting input"
	)
	expect(
		(
			feedback.color_for("damage") != feedback.color_for("heal")
			and feedback.color_for("heal") != feedback.color_for("shield")
		),
		"Damage, heal and shield numbers have distinct colors"
	)
	var before: Dictionary = old_run.battle.snapshot()
	var rng_before: int = old_run.rng.state
	feedback.reset()
	view.configure_presentation({"shake_enabled": true})
	view._present_record(
		{"kind": "damage", "target": "warden", "amount": 8, "hp_loss": 0, "shield_loss": 8}, false
	)
	var numbers: Control = feedback.get_node("Numbers")
	expect(numbers.get_child_count() == 1, "A fully absorbed hit displays only shield loss")
	if numbers.get_child_count() == 1:
		var blocked: Label = numbers.get_child(0)
		expect(
			(
				blocked.text == "−8"
				and blocked.get_theme_color("font_color") == feedback.color_for("shield")
			),
			"Absorbed damage is a shield-colored negative number"
		)
	expect(
		view._shake_tween == null or not view._shake_tween.is_valid(),
		"Fully absorbed damage causes no HP-impact shake"
	)
	feedback.reset()
	view._present_record(
		{"kind": "damage", "target": "warden", "amount": 8, "hp_loss": 3, "shield_loss": 5}, true
	)
	expect(numbers.get_child_count() == 2, "A mixed hit separately displays shield and HP loss")
	if numbers.get_child_count() == 2:
		expect(
			numbers.get_child(0).text == "−5" and numbers.get_child(1).text == "−3",
			"Mixed damage numbers use the actual absorbed and HP portions"
		)
	feedback.reset()
	var records: Array = [
		{"kind": "ot", "target": "warden"},
		{"kind": "interrupt", "target": "enemy_0"},
		{"kind": "interrupt_failed", "target": "enemy_0"},
		{"kind": "bomb", "target": "warden", "amount": 9, "remaining": 2},
		{"kind": "phase", "target": "enemy_0", "phase": 2},
		{"kind": "enrage", "target": "enemy_0"}
	]
	for record in records:
		view._present_record(record, true)
	expect(
		not view.log_view.visible and feedback.get_node("Banner").visible,
		"Critical events remain visible with the combat log hidden"
	)
	expect(
		feedback._visible_banners.size() == 3 and feedback._pending_banners.size() == 3,
		"Fast warning bursts retain three readable messages and queue the rest"
	)
	for index in range(3):
		expect(
			feedback.get_node("Banner/Text").text.contains(view._record_text(records[index])),
			"Later fast events do not overwrite an unread warning"
		)
	feedback._process(0.5)
	expect(
		feedback._visible_banners.size() == 3 and feedback._pending_banners.size() == 3,
		"Warnings remain visible through a quick chain of actions"
	)
	feedback._process(float(feedback.banner_duration))
	expect(
		feedback._visible_banners.size() == 3 and feedback._pending_banners.is_empty(),
		"Queued warnings fill expired slots in order"
	)
	for index in range(3):
		expect(
			(
				str(feedback._visible_banners[index].text) == view._record_text(records[index + 3])
				and float(feedback._visible_banners[index].remaining) >= 2.0
			),
			"Every queued warning receives a fresh readable lifetime"
		)
	feedback.show_number("+7", Vector2(200, 100), "heal", false)
	expect(
		feedback.get_node("Numbers").get_child_count() > 0,
		"Floating numbers are attached to the overlay"
	)
	expect(
		old_run.battle.snapshot() == before and old_run.rng.state == rng_before,
		"Warning and number presentation is read-only"
	)
	old_run.battle.settled.emit(records, old_run.battle.snapshot())
	expect(view.locked, "Cleanup fixture interrupts active playback")
	view.leave_battle()
	expect(
		(
			feedback.get_node("Numbers").get_child_count() == 0
			and not feedback.get_node("Banner").visible
		),
		"Leaving removes floating numbers and warnings immediately"
	)
	expect(feedback._tweens.is_empty(), "Leaving releases floating-number tween references")
	expect(
		feedback._visible_banners.is_empty() and feedback._pending_banners.is_empty(),
		"Leaving clears both visible and queued warning records"
	)
	view.bind_battle(new_run.battle, data, new_run.deck)
	new_run.battle.settled.emit([], new_run.battle.snapshot())
	await create_timer(float(view.event_duration) * 4.0 + 0.05).timeout
	expect(
		not view.locked and view.engine == new_run.battle,
		"Old asynchronous records cannot lock or replace a newly bound battle"
	)
	expect(
		(
			feedback.get_node("Numbers").get_child_count() == 0
			and not feedback.get_node("Banner").visible
		),
		"Old warnings do not replay after rebind"
	)


func _prepare_slash(view: Control) -> int:
	for pile in Types.PILES:
		for copy in view.engine.state[pile]:
			if copy.card_id != "slash":
				continue
			var copy_id: int = int(copy.copy_id)
			if pile != "hand":
				view.engine.state[pile].erase(copy)
				view.engine.state.hand.append(copy)
			view.refresh()
			return copy_id
	return -1


func _settle(view: Control) -> void:
	for index in range(1000):
		if not view.locked:
			await process_frame
			return
		await create_timer(0.01).timeout
	expect(false, "Presentation must release its lock within ten seconds")


func _directory(label: String) -> String:
	var directory: String = "user://presentation_%s_%d" % [label, Time.get_ticks_usec()]
	_directories.append(directory)
	return directory


func _files(directory: String, names: Array) -> Dictionary:
	var result: Dictionary = {}
	for name in names:
		var path: String = directory.path_join(str(name))
		result[name] = (
			FileAccess.get_file_as_bytes(path)
			if FileAccess.file_exists(path)
			else PackedByteArray()
		)
	return result


func _cleanup_directories() -> void:
	for directory in _directories:
		for slot in ["run", "meta", "settings"]:
			for suffix in [".json", ".json.bak", ".json.tmp", ".json.bak.tmp"]:
				var path: String = directory.path_join(slot + suffix)
				if FileAccess.file_exists(path):
					DirAccess.remove_absolute(path)
		DirAccess.remove_absolute(directory)
