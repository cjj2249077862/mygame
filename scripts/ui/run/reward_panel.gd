extends PanelContainer

signal claimed(card_id: String, token: int)
signal skipped(token: int)
signal relic_claimed(relic_id: String, token: int)
signal relic_skipped(token: int)

const CardView = preload("res://scenes/presentation/card_view.tscn")
const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
var _token := -1
var _submitted := false
var _relic_submitted := false
var _blocked := false
var _cards_done := false
var _relics_done := true
var _candidates: Array[String] = []
var _relics: Array[String] = []
@export var card_minimum_size: Vector2


func _ready() -> void:
	$Margin/Content/Skip.pressed.connect(_on_skip)
	$Margin/Content/SkipRelic.pressed.connect(_on_skip_relic)


func render(data: RefCounted, candidates: Array, token: int) -> void:
	render_rewards(
		data,
		{
			"cards": candidates,
			"relics": [],
			"cards_done": false,
			"relics_done": true,
			"gold_granted": 0
		},
		token
	)


func render_rewards(
	data: RefCounted, rewards: Dictionary, token: int, blocked: bool = false
) -> void:
	if token != _token:
		$Margin.set_deferred("scroll_vertical", 0)
	_token = token
	_submitted = false
	_relic_submitted = false
	_blocked = blocked
	_cards_done = rewards.cards_done
	_relics_done = rewards.relics_done
	_candidates.assign(rewards.cards)
	_relics.assign(rewards.relics)
	$Margin/Content/Title.text = data.text("ui.reward")
	$Margin/Content/Hint.text = data.text("ui.reward_gold", {"gold": rewards.gold_granted})
	$Margin/Content/CardsTitle.text = data.text(
		"ui.reward_cards_done" if _cards_done else "ui.reward_cards"
	)
	$Margin/Content/RelicsTitle.text = data.text(
		"ui.reward_relics_done" if _relics_done else "ui.reward_relics"
	)
	$Margin/Content/Skip.text = data.text("ui.skip")
	$Margin/Content/SkipRelic.text = data.text("ui.skip_relic")
	$Margin/Content/Skip.disabled = blocked or _cards_done
	$Margin/Content/SkipRelic.disabled = blocked or _relics_done
	_clear_children($Margin/Content/Cards)
	_clear_children($Margin/Content/Relics)
	for id in _candidates:
		var button = CardView.instantiate()
		button.custom_minimum_size = card_minimum_size
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		button.disabled = blocked or _cards_done
		button.pressed.connect(_on_claim.bind(id, token))
		$Margin/Content/Cards.add_child(button)
		button.render({"card_id": id, "upgraded": false}, data)
	for id in _relics:
		var button := _button(data.relic_text(id), data.relic_text(id))
		button.icon = Art.icon_texture(id)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 42)
		button.disabled = blocked or _relics_done
		button.pressed.connect(_on_claim_relic.bind(id, token))
		$Margin/Content/Relics.add_child(button)


func _button(text: String, details: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = details
	button.custom_minimum_size = Vector2(220, 90)
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return button


func _on_claim(card_id: String, token: int) -> void:
	if (
		not is_visible_in_tree()
		or _blocked
		or _submitted
		or _cards_done
		or token != _token
		or card_id not in _candidates
	):
		return
	_mark_submitted(false)
	claimed.emit(card_id, token)


func _on_skip() -> void:
	if not is_visible_in_tree() or _blocked or _submitted or _cards_done:
		return
	_mark_submitted(false)
	skipped.emit(_token)


func _on_claim_relic(relic_id: String, token: int) -> void:
	if (
		not is_visible_in_tree()
		or _blocked
		or _relic_submitted
		or _relics_done
		or token != _token
		or relic_id not in _relics
	):
		return
	_mark_submitted(true)
	relic_claimed.emit(relic_id, token)


func _on_skip_relic() -> void:
	if not is_visible_in_tree() or _blocked or _relic_submitted or _relics_done:
		return
	_mark_submitted(true)
	relic_skipped.emit(_token)


func _mark_submitted(relic: bool) -> void:
	if relic:
		_relic_submitted = true
		$Margin/Content/SkipRelic.disabled = true
	else:
		_submitted = true
		$Margin/Content/Skip.disabled = true
	var container: Node = $Margin/Content/Relics if relic else $Margin/Content/Cards
	for child in container.get_children():
		child.disabled = true


func _clear_children(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
