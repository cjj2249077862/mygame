extends ConfirmationDialog

signal selected(copy_id: int, token: int, request_id: int)
signal browse_tab_changed(index: int)

const CardView = preload("res://scenes/presentation/card_view.tscn")
const CardOrder = preload("res://scripts/ui/presentation/card_order.gd")
@export var preferred_size: Vector2i = Vector2i(1120, 700)
@export var viewport_margin: Vector2i = Vector2i(40, 40)
@export var grid_card_size: Vector2 = Vector2(168, 252)
@export var comparison_card_size: Vector2 = Vector2(220, 330)
@export var panel_style: StyleBox
var _data: RefCounted
var _candidates: Dictionary = {}
var _token: int = -1
var _selected_copy: int = -1
var _submitted: bool = false
var _host_viewport: Viewport
var _mode: String = "select"
var _request_id: int = 0


func _ready() -> void:
	_host_viewport = get_parent().get_viewport()
	_host_viewport.size_changed.connect(_on_host_resized)
	size_changed.connect(_on_size_changed)
	confirmed.connect(_on_confirmed)
	canceled.connect(dismiss)
	window_input.connect(_on_window_input)
	$Content/ComparePage/Back.pressed.connect(_show_grid)
	$Content/SinglePage/Back.pressed.connect(_show_grid)
	$Content/Tabs.tab_changed.connect(_on_browse_tab_changed)
	if panel_style != null:
		add_theme_stylebox_override("panel", panel_style)
	get_ok_button().custom_minimum_size = Vector2(150, 44)
	get_cancel_button().custom_minimum_size = Vector2(120, 44)


func open_candidates(
	cards: Array, data: RefCounted, party: Array, token: int, options: Dictionary = {}
) -> int:
	dismiss()
	_data = data
	_token = token
	_mode = str(options.get("mode", "select"))
	if _mode not in ["upgrade", "remove", "select", "browse"]:
		dismiss()
		return -1
	_submitted = false
	for child in $Content/GridPage/Scroll/Cards.get_children():
		child.get_parent().remove_child(child)
		child.queue_free()
	var eligible: Array = []
	for card in cards:
		if data.definition("cards", str(card.get("card_id", ""))).is_empty():
			continue
		var copy_id: int = int(card.get("copy_id", -1))
		if copy_id < 0 or _candidates.has(copy_id):
			continue
		var copy: Dictionary = card.duplicate(true)
		# Eligibility comes from the caller; removal must retain upgraded copies.
		copy.upgraded = bool(copy.get("upgraded", false))
		_candidates[copy_id] = copy
		eligible.append(copy)
	if eligible.is_empty() and _mode != "browse":
		dismiss()
		return -1
	for copy in CardOrder.sorted_cards(eligible, data, party):
		var card: Button = CardView.instantiate()
		card.custom_minimum_size = grid_card_size
		# Grid edges are clipped by the scroll area; highlight without scaling past them.
		card.hover_scale = 1.0
		card.set_meta("copy_id", int(copy.copy_id))
		card.pressed.connect(_select_copy.bind(int(copy.copy_id), token, _request_id))
		$Content/GridPage/Scroll/Cards.add_child(card)
		card.render(copy, data)
	if _mode == "browse":
		title = str(options.get("title", data.text("ui.piles")))
		cancel_button_text = data.text("ui.close")
	else:
		title = str(
			options.get("title", data.presentation_text("card_picker." + _mode + ".choose"))
		)
		ok_button_text = str(
			options.get("confirm_text", data.presentation_text("card_picker." + _mode + ".confirm"))
		)
		cancel_button_text = data.text("ui.cancel")
	$Content/Tabs.set_block_signals(true)
	$Content/Tabs.clear_tabs()
	if _mode == "browse":
		for tab in options.get("tabs", []):
			$Content/Tabs.add_tab(str(tab))
		if $Content/Tabs.tab_count > 0:
			$Content/Tabs.current_tab = clampi(
				int(options.get("tab_index", 0)), 0, $Content/Tabs.tab_count - 1
			)
	$Content/Tabs.visible = $Content/Tabs.tab_count > 0
	$Content/Tabs.set_block_signals(false)
	$Content/Hint.text = str(options.get("hint", ""))
	$Content/Hint.visible = not $Content/Hint.text.is_empty()
	var context: String = str(options.get("context", ""))
	$Content/Context.text = data.presentation_text("card_picker.context") + "\n" + context
	$Content/Context.visible = not context.is_empty()
	$Content/Context.scroll_to_line(0)
	for back in [$Content/ComparePage/Back, $Content/SinglePage/Back]:
		back.text = data.presentation_text(
			"card_picker.browse.back" if _mode == "browse" else "card_picker.back"
		)
	$Content/ComparePage/Cards/Before/Label.text = data.presentation_text("card_picker.before")
	$Content/ComparePage/Cards/After/Label.text = data.presentation_text("card_picker.after")
	$Content/SinglePage/Label.text = (
		data.presentation_text("card_picker." + _mode + ".selected")
		if _mode in ["remove", "select"]
		else ""
	)
	$Content/SinglePage/Label.visible = _mode != "browse"
	$Content/SinglePage/Notice.text = data.presentation_text("card_picker.remove.notice")
	$Content/SinglePage/Notice.visible = _mode == "remove"
	$Content/Empty.text = data.presentation_text("card_picker.browse.empty")
	$Content/GridPage/Scroll.scroll_vertical = 0
	_show_grid()
	# Popup first, then apply logical size; this matches the other embedded dialogs.
	popup_centered()
	fit_to_viewport()
	fit_to_viewport.call_deferred()
	return _request_id


func dismiss() -> void:
	hide()
	_request_id += 1
	_token = -1
	_selected_copy = -1
	_candidates.clear()
	_submitted = false
	if is_node_ready():
		$HoverHelp.hide_help()
		get_ok_button().disabled = true


func _show_grid() -> void:
	_selected_copy = -1
	$HoverHelp.hide_help()
	$Content/ComparePage.hide()
	$Content/SinglePage.hide()
	$Content/Heading.text = (
		title if _mode == "browse" else _data.presentation_text("card_picker." + _mode + ".choose")
	)
	$Content/GridPage.visible = not _candidates.is_empty()
	$Content/Empty.visible = _mode == "browse" and _candidates.is_empty()
	get_ok_button().disabled = true
	get_ok_button().hide()
	_layout_cards.call_deferred()


func is_request_current(request_id: int, token: int) -> bool:
	return _token >= 0 and token == _token and request_id == _request_id


func _select_copy(copy_id: int, token: int, request_id: int) -> void:
	if (
		not visible
		or _submitted
		or not is_request_current(request_id, token)
		or not _candidates.has(copy_id)
	):
		return
	_selected_copy = copy_id
	$HoverHelp.hide_help()
	var before: Dictionary = _candidates[copy_id].duplicate(true)
	if _mode == "upgrade":
		var after: Dictionary = before.duplicate(true)
		after.upgraded = true
		$Content/ComparePage/Cards/Before/Card.render(before, _data)
		$Content/ComparePage/Cards/After/Card.render(after, _data)
	else:
		$Content/SinglePage/Card.render(before, _data)
	$Content/Heading.text = _data.text(_data.definition("cards", before.card_id).name_key)
	$Content/GridPage.hide()
	$Content/ComparePage.visible = _mode == "upgrade"
	$Content/SinglePage.visible = _mode != "upgrade"
	get_ok_button().visible = _mode != "browse"
	get_ok_button().disabled = _mode == "browse"
	_layout_cards()
	_layout_cards.call_deferred()


func _on_confirmed() -> void:
	if (
		_mode == "browse"
		or not visible
		or _submitted
		or _token < 0
		or not _candidates.has(_selected_copy)
	):
		return
	var copy_id: int = _selected_copy
	var token: int = _token
	var request_id: int = _request_id
	_submitted = true
	get_ok_button().disabled = true
	$HoverHelp.hide_help()
	hide()
	selected.emit(copy_id, token, request_id)


func _on_browse_tab_changed(index: int) -> void:
	if visible and _mode == "browse":
		browse_tab_changed.emit(index)


func fit_to_viewport() -> void:
	if not visible or _host_viewport == null:
		return
	var available: Vector2i = Vector2i(_host_viewport.get_visible_rect().size) - viewport_margin
	size = Vector2i(mini(preferred_size.x, available.x), mini(preferred_size.y, available.y))
	move_to_center()
	_layout_cards.call_deferred()


func _on_host_resized() -> void:
	fit_to_viewport()


func _on_size_changed() -> void:
	_layout_cards.call_deferred()


func _layout_cards() -> void:
	if not visible:
		return
	var grid: GridContainer = $Content/GridPage/Scroll/Cards
	var gap: float = float(grid.get_theme_constant("h_separation"))
	var width: float = $Content/GridPage/Scroll.size.x - 20.0
	grid.columns = clampi(floori((width + gap) / (grid_card_size.x + gap)), 1, 6)
	# Reserve actual label/button heights; long localized notices must not push the footer out.
	var page: Control = $Content/ComparePage if _mode == "upgrade" else $Content/SinglePage
	# Containers may still be stretched by the previous card minimum after a resize.
	# Derive the budget from the window, rather than that stale container size.
	var content: VBoxContainer = $Content
	var page_height: float = (
		float(size.y) * (content.anchor_bottom - content.anchor_top)
		+ content.offset_bottom
		- content.offset_top
	)
	for header in [$Content/Heading, $Content/Tabs, $Content/Hint, $Content/Context]:
		if header.visible:
			page_height -= (
				header.get_combined_minimum_size().y + content.get_theme_constant("separation")
			)
	var reserved: float
	if _mode == "upgrade":
		reserved = (
			maxf(
				$Content/ComparePage/Cards/Before/Label.get_combined_minimum_size().y,
				$Content/ComparePage/Cards/After/Label.get_combined_minimum_size().y
			)
			+ $Content/ComparePage/Cards/Before.get_theme_constant("separation")
			+ $Content/ComparePage/Back.get_combined_minimum_size().y
			+ page.get_theme_constant("separation")
		)
	else:
		reserved = $Content/SinglePage/Back.get_combined_minimum_size().y
		reserved += page.get_theme_constant("separation")
		if $Content/SinglePage/Label.visible:
			reserved += (
				$Content/SinglePage/Label.get_combined_minimum_size().y
				+ page.get_theme_constant("separation")
			)
		if _mode == "remove":
			reserved += (
				$Content/SinglePage/Notice.get_combined_minimum_size().y
				+ page.get_theme_constant("separation")
			)
	var height: float = minf(comparison_card_size.y, maxf(180.0, page_height - reserved))
	var face_size := Vector2(height * 2.0 / 3.0, height)
	for card in [
		$Content/ComparePage/Cards/Before/Card,
		$Content/ComparePage/Cards/After/Card,
		$Content/SinglePage/Card
	]:
		card.custom_minimum_size = face_size
		card.size = face_size


func _on_window_input(event: InputEvent) -> void:
	if (
		event.is_action_pressed("ui_cancel")
		or (
			event is InputEventMouseButton
			and event.pressed
			and event.button_index == MOUSE_BUTTON_RIGHT
		)
	):
		dismiss()
		set_input_as_handled()
