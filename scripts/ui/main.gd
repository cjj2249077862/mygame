extends Control

const Data = preload("res://scripts/data/game_data.gd")
const Run = preload("res://scripts/core/run_manager.gd")
const Types = preload("res://scripts/core/enums.gd")
var data := Data.new()
var run: RefCounted


func _ready() -> void:
	if not data.load_directory():
		$Menu/Content/Title.text = "配置加载失败"
		$Menu/Content/Subtitle.text = "\n".join(data.errors)
		$Menu/Content/Start.disabled = true
		return
	run = Run.new(data)
	run.changed.connect(_on_run_changed)
	run.battle_created.connect(_on_battle_created)
	$Battle.presentation_finished.connect(_on_run_changed)
	$Reward.claimed.connect(_on_claimed)
	$Reward.skipped.connect(_on_skipped)
	$Menu/Content/Start.pressed.connect(_on_start)
	$Result/Content/Restart.pressed.connect(_on_start)
	$Menu/Content/Title.text = data.text("ui.title")
	$Menu/Content/Subtitle.text = data.text("ui.subtitle")
	$Menu/Content/Start.text = data.text("ui.start")
	$Result/Content/Restart.text = data.text("ui.restart")
	$Result/Content/Hint.text = data.text("ui.result_hint")


func _on_start() -> void:
	$Menu.hide()
	$Result.hide()
	$Reward.hide()
	$Battle.show()
	run.start(int(Time.get_unix_time_from_system()))


func _on_battle_created(engine: RefCounted) -> void:
	$Battle.bind_battle(engine, data, run.deck)
	$Battle.gold = run.gold


func _on_run_changed() -> void:
	if $Battle.locked:
		return
	$Battle.visible = run.phase == Types.RunPhase.BATTLE
	$Reward.visible = run.phase == Types.RunPhase.REWARD
	$Result.visible = run.phase in [Types.RunPhase.WON, Types.RunPhase.LOST]
	if run.phase == Types.RunPhase.REWARD:
		$Reward.render(data, run.reward_candidates, run.reward_token)
	if $Result.visible:
		$Result/Content/Title.text = data.text(
			"ui.win" if run.phase == Types.RunPhase.WON else "ui.loss"
		)
	$Battle.gold = run.gold
	$Battle.refresh()


func _on_claimed(card_id: String, token: int) -> void:
	run.claim_reward(card_id, token)


func _on_skipped(token: int) -> void:
	run.skip_reward(token)
