extends SceneTree

const Data = preload("res://scripts/data/game_data.gd")


func _initialize() -> void:
	var data := Data.new()
	assert(data.load_directory(), str(data.errors))
	assert(data.rows("cards").size() == 9)
	assert(data.card_effects("double_stab", true)[0].hits == 2)
	var good := data.books.duplicate(true)
	var bad := good.duplicate(true)
	bad.cards.sheets.main.append(bad.cards.sheets.main[0].duplicate(true))
	assert(not data.validate(bad))
	assert(data.books == good, "Rejected data must preserve the working set")
	bad = good.duplicate(true)
	bad.cards.sheets.main[0].cost = "1"
	assert(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.effects[0].kind = "unknown"
	assert(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.main[0].name_key = "missing"
	assert(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.effects[0].amount = -1
	assert(not data.validate(bad))
	bad = good.duplicate(true)
	bad.cards.sheets.effects[0].erase("amount")
	assert(not data.validate(bad))
	bad = good.duplicate(true)
	bad.characters.sheets.starter[0].card_id = "missing"
	assert(not data.validate(bad))
	bad = good.duplicate(true)
	bad.encounters.sheets.intents[0].order = 3
	assert(not data.validate(bad))
	assert(data.validate(good), str(data.errors))
	print("test_game_data: passed")
	quit()
