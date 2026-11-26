extends PanelContainer

signal action_requested(
	action: String, item_id: String, copy_id: int, token: int, selection_id: String
)

const Types = preload("res://scripts/core/enums.gd")
const Art = preload("res://scripts/ui/presentation/art_catalog.gd")
const HoverHelp = preload("res://scripts/ui/presentation/hover_help.gd")
@export var choice_minimum_size: Vector2
@export var picker_preferred_size: Vector2i
@export var picker_viewport_margin: Vector2i
var _data: RefCounted
var _state: Dictionary = {}
var _token := -1
var _submitted := false
var _blocked := false
var _picker_mode := ""
var _picker_token := -1
var _event_option := ""
var _selected_choice := ""
var _event_needs_selection := false
var _card_request_id := -1
var _card_context: Dictionary = {}


func _ready() -> void:
	$Margin/Content/Camp/Rest.pressed.connect(_request.bind("camp_rest", "", -1))
	$Margin/Content/Camp/Upgrade.pressed.connect(_open_picker.bind("camp_upgrade"))
	$Margin/Content/ShopActions/Refresh.pressed.connect(_request.bind("shop_refresh", "", -1))
	$Margin/Content/ShopActions/Remove.pressed.connect(_open_picker.bind("shop_remove"))
	$Margin/Content/ShopActions/Leave.pressed.connect(_request.bind("leave_shop", "", -1))
	$Picker.confirmed.connect(_on_picker_confirmed)
	$Picker.canceled.connect(_clear_picker)
	$Picker.window_input.connect(_on_picker_input)
	$CardPicker.selected.connect(_on_card_selected)
	resized.connect(_on_resized)


func render(state: Dictionary, data: RefCounted) -> void:
	deactivate()
	_data = data
	_state = state.duplicate(true)
	_token = int(state.token)
	_submitted = false
	_blocked = state.get("persistence_error", "") != ""
	var camp: bool = state.phase == Types.RunPhase.CAMP
	var shop: bool = state.phase == Types.RunPhase.SHOP
	$Margin/Content/Camp.visible = camp
	$Margin/Content/ShopActions.visible = shop
	$Margin/Content/OptionsScroll.visible = not camp
	$Picker.ok_button_text = data.text("ui.confirm")
	$Picker.cancel_button_text = data.text("ui.cancel")
	var options := $Margin/Content/OptionsScroll/Options
	_clear_children(options)
	if camp:
		$Margin/Content/Title.text = data.text("ui.node.camp")
		var lines: Array[String] = [data.text("ui.camp_hint")]
		for recovery in state.camp.recoveries:
			lines.append(data.text("ui.camp_recovery", recovery))
		$Margin/Content/Body.text = "\n".join(lines)
		$Margin/Content/Camp/Rest.text = data.text("ui.camp_rest")
		$Margin/Content/Camp/Upgrade.text = data.text("ui.camp_upgrade")
		$Margin/Content/Camp/Rest.disabled = _blocked
		$Margin/Content/Camp/Upgrade.disabled = _blocked or state.camp.upgrade_cards.is_empty()
	elif shop:
		$Margin/Content/Title.text = data.text("ui.node.shop")
		$Margin/Content/Body.text = data.text("ui.shop_hint", {"gold": state.gold})
		for offer in state.shop.offers:
			var text: String = data.text("ui.shop_offer", offer)
			if offer.sold_out:
				text += "\n" + data.text("ui.sold_out")
			var button := _choice(text, str(offer.description), "shop_buy", str(offer.id), -1)
			button.icon = (
				Art.card_texture(offer.item_id)
				if offer.kind == "card"
				else Art.icon_texture(offer.item_id)
			)
			button.expand_icon = true
			button.add_theme_constant_override("icon_max_width", 44)
			button.disabled = (
				_blocked or offer.sold_out or offer.item_id == "" or state.gold < offer.price
			)
			if offer.item_id == "":
				button.text = data.text("ui.out_of_stock")
			elif not offer.sold_out and state.gold < offer.price:
				button.tooltip_text += "\n" + data.text("ui.not_enough_gold")
			if offer.item_id != "":
				var sections: Array = (
					data.card_sections({"card_id": offer.item_id, "upgraded": false})
					if offer.kind == "card"
					else data.relic_sections(offer.item_id)
				)
				# Offers show only the name and price; keep the missing description once.
				var description: String = (
					data.card_text({"card_id": offer.item_id, "upgraded": false})
					if offer.kind == "card"
					else ""
				)
				for section in sections:
					if section.get("kind", "") == "main" and description.is_empty():
						description = str(section.get("body", ""))
				sections = sections.filter(
					func(section: Dictionary) -> bool: return section.get("kind", "") != "main"
				)
				if not offer.sold_out and state.gold < offer.price:
					description += "\n" + data.text("ui.not_enough_gold")
				sections.push_front(
					{"id": "offer", "title": "", "body": description, "kind": "main"}
				)
				HoverHelp.attach(button, sections, true)
			options.add_child(button)
		$Margin/Content/ShopActions/Refresh.text = data.text(
			"ui.shop_refresh", {"cost": state.shop.refresh_cost}
		)
		$Margin/Content/ShopActions/Remove.text = data.text(
			"ui.shop_remove", {"cost": state.shop.remove_cost}
		)
		$Margin/Content/ShopActions/Leave.text = data.text("ui.leave_shop")
		$Margin/Content/ShopActions/Refresh.disabled = (
			_blocked or state.gold < state.shop.refresh_cost
		)
		$Margin/Content/ShopActions/Remove.disabled = (
			_blocked or state.gold < state.shop.remove_cost or state.shop.removable_cards.is_empty()
		)
		$Margin/Content/ShopActions/Leave.disabled = _blocked
	else:
		$Margin/Content/Title.text = str(state.event.title)
		$Margin/Content/Body.text = str(state.event.body)
		for option in state.event.options:
			var button := Button.new()
			button.text = str(option.text) + "\n" + str(option.details)
			button.tooltip_text = str(option.details)
			button.custom_minimum_size = choice_minimum_size
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.pressed.connect(_on_event_option.bind(option.duplicate(true), _token))
			button.disabled = _blocked or not option.enabled
			if option.error != "":
				button.tooltip_text += "\n" + data.text(str(option.error))
			options.add_child(button)


func deactivate() -> void:
	$Picker.hide()
	$CardPicker.dismiss()
	_clear_picker()


func _choice(
	text: String, details: String, action: String, item_id: String, copy_id: int
) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = details
	button.custom_minimum_size = choice_minimum_size
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.pressed.connect(_request_at_token.bind(action, item_id, copy_id, _token))
	return button


func _request(action: String, item_id: String, copy_id: int) -> void:
	_request_at_token(action, item_id, copy_id, _token)


func _request_at_token(
	action: String, item_id: String, copy_id: int, token: int, selection_id: String = ""
) -> void:
	if not is_visible_in_tree() or _blocked or _submitted or token != _token:
		return
	_submitted = true
	deactivate()
	action_requested.emit(action, item_id, copy_id, token, selection_id)


func _open_picker(mode: String) -> void:
	if _blocked or _submitted or not is_visible_in_tree():
		return
	_clear_picker()
	if mode == "camp_upgrade":
		if _state.get("phase") == Types.RunPhase.CAMP:
			_open_card_picker(
				_state.camp.upgrade_cards,
				mode,
				_token,
				{
					"mode": "upgrade",
					"title": _data.text("ui.choose_upgrade"),
					"context": _data.presentation_text("camp_upgrade.hint"),
				}
			)
		return
	if (
		mode != "shop_remove"
		or _state.get("phase") != Types.RunPhase.SHOP
		or _state.gold < _state.shop.remove_cost
	):
		return
	_open_card_picker(
		_state.shop.removable_cards,
		mode,
		_token,
		{
			"mode": "remove",
			"title": _data.text("ui.choose_remove"),
			"context":
			_data.presentation_text(
				"card_picker.shop_remove.hint",
				{"cost": _state.shop.remove_cost, "gold": _state.gold}
			),
		}
	)


func _open_card_picker(
	cards: Array, action: String, token: int, options: Dictionary, event_option: String = ""
) -> void:
	$Picker.hide()
	var choices: Dictionary = {}
	for card in cards:
		var copy_id: int = int(card.get("copy_id", -1))
		if copy_id >= 0:
			choices[copy_id] = str(card.get("id", str(copy_id)))
	_card_context = {"action": action, "token": token, "option": event_option, "choices": choices}
	_card_request_id = $CardPicker.open_candidates(
		cards, _data, _state.get("party", []), token, options
	)
	if _card_request_id < 0:
		_card_context.clear()


func _on_card_selected(copy_id: int, token: int, request_id: int) -> void:
	if (
		_card_context.is_empty()
		or request_id != _card_request_id
		or token != _card_context.token
		or not $CardPicker.is_request_current(request_id, token)
		or not _card_context.choices.has(copy_id)
	):
		return
	var action: String = str(_card_context.action)
	if action == "choose_event_option":
		_request_at_token(
			action, str(_card_context.option), -1, token, _card_context.choices[copy_id]
		)
	else:
		_request_at_token(action, "", copy_id, token)


func _on_picker_confirmed() -> void:
	if _picker_mode == "choose_event_option":
		if _event_needs_selection and _selected_choice == "":
			return
		_request_at_token(_picker_mode, _event_option, -1, _picker_token, _selected_choice)
		return


func _clear_picker() -> void:
	_picker_mode = ""
	_card_request_id = -1
	_card_context.clear()
	_picker_token = -1
	_event_option = ""
	_selected_choice = ""
	_event_needs_selection = false


func _on_event_option(option: Dictionary, token: int) -> void:
	if not is_visible_in_tree() or _blocked or _submitted or token != _token or not option.enabled:
		return
	_clear_picker()
	if option.selection in ["card", "unupgraded_card"]:
		_open_card_picker(
			option.choices,
			"choose_event_option",
			token,
			{
				"mode": str(option.get("card_mode", "select")),
				"title": str(option.text),
				"context": str(option.details),
			},
			str(option.id)
		)
		return
	$CardPicker.dismiss()
	_picker_mode = "choose_event_option"
	_picker_token = token
	_event_option = str(option.id)
	_event_needs_selection = option.selection != "none"
	$Picker.title = _data.text("ui.event_confirm")
	$Picker/Content/Preview.text = str(option.text) + "\n" + str(option.details)
	$Picker.get_ok_button().disabled = option.selection != "none"
	_clear_children($Picker/Content/Scroll/Cards)
	for choice in option.choices:
		var button := Button.new()
		button.text = str(choice.text)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.pressed.connect(
			_on_event_target.bind(
				choice.duplicate(true), str(option.details), str(option.id), token
			)
		)
		$Picker/Content/Scroll/Cards.add_child(button)
	_fit_picker()


func _on_resized() -> void:
	if $Picker.visible:
		_fit_picker()
	$CardPicker.fit_to_viewport()


func _fit_picker() -> void:
	var available: Vector2i = Vector2i(get_viewport_rect().size) - picker_viewport_margin
	var desired := Vector2i(
		mini(picker_preferred_size.x, available.x), mini(picker_preferred_size.y, available.y)
	)
	if not $Picker.visible:
		$Picker.popup_centered()
	$Picker.size = desired
	_center_picker()
	_center_picker.call_deferred()


func _center_picker() -> void:
	if $Picker.visible:
		$Picker.move_to_center()


func _on_event_target(
	choice: Dictionary, option_details: String, option_id: String, token: int
) -> void:
	if (
		_picker_mode != "choose_event_option"
		or _picker_token != _token
		or _event_option != option_id
		or token != _picker_token
	):
		return
	_selected_choice = str(choice.id)
	$Picker/Content/Preview.text = option_details + "\n\n" + str(choice.details)
	$Picker.get_ok_button().disabled = false


func _on_picker_input(event: InputEvent) -> void:
	if (
		event.is_action_pressed("ui_cancel")
		or (
			event is InputEventMouseButton
			and event.pressed
			and event.button_index == MOUSE_BUTTON_RIGHT
		)
	):
		deactivate()
		$Picker.set_input_as_handled()


func _clear_children(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
