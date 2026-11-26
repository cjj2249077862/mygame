extends PanelContainer

signal claimed(card_id: String, token: int)
signal skipped(token: int)

var _token := -1


func _ready() -> void:
	$Margin/Content/Skip.pressed.connect(_on_skip)


func render(data: RefCounted, candidates: Array, token: int) -> void:
	_token = token
	$Margin/Content/Title.text = data.text("ui.reward")
	$Margin/Content/Hint.text = data.text("ui.reward_hint")
	$Margin/Content/Skip.text = data.text("ui.skip")
	$Margin/Content/Skip.disabled = false
	for child in $Margin/Content/Cards.get_children():
		$Margin/Content/Cards.remove_child(child)
		child.queue_free()
	for id in candidates:
		var button := Button.new()
		button.text = data.card_text({"card_id": id, "upgraded": false})
		button.custom_minimum_size = Vector2(220, 150)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.pressed.connect(_on_claim.bind(id, token))
		$Margin/Content/Cards.add_child(button)


func _on_claim(card_id: String, token: int) -> void:
	claimed.emit(card_id, token)


func _on_skip() -> void:
	skipped.emit(_token)
