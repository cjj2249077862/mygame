extends PanelContainer

signal claimed(card_id: String, token: int)
signal skipped(token: int)

var _token := -1
var _submitted := false
var _candidates: Array[String] = []

@export var card_minimum_size: Vector2


func _ready() -> void:
	$Margin/Content/Skip.pressed.connect(_on_skip)


func render(data: RefCounted, candidates: Array, token: int) -> void:
	if _token != token:
		_submitted = false
	_token = token
	_candidates.assign(candidates)
	$Margin/Content/Title.text = data.text("ui.reward")
	$Margin/Content/Hint.text = data.text("ui.reward_hint")
	$Margin/Content/Skip.text = data.text("ui.skip")
	$Margin/Content/Skip.disabled = _submitted
	for child in $Margin/Content/Cards.get_children():
		$Margin/Content/Cards.remove_child(child)
		child.queue_free()
	for id in candidates:
		var button := Button.new()
		button.text = data.card_text({"card_id": id, "upgraded": false})
		button.tooltip_text = data.card_details({"card_id": id, "upgraded": false})
		button.custom_minimum_size = card_minimum_size
		button.disabled = _submitted
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.pressed.connect(_on_claim.bind(id, token))
		$Margin/Content/Cards.add_child(button)


func _on_claim(card_id: String, token: int) -> void:
	if _submitted or token != _token or card_id not in _candidates:
		return
	_mark_submitted()
	claimed.emit(card_id, token)


func _on_skip() -> void:
	if _submitted:
		return
	_mark_submitted()
	skipped.emit(_token)


func _mark_submitted() -> void:
	_submitted = true
	$Margin/Content/Skip.disabled = true
	for child in $Margin/Content/Cards.get_children():
		child.disabled = true
