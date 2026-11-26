extends RefCounted

# Presentation-only references. These never enter the gameplay data bundle or saves.
const ACTORS := {
	"warden": "res://assets/characters/tank.png",
	"blade": "res://assets/characters/assassin.png",
	"mender": "res://assets/characters/healer.png",
}
const ENEMY_ATLAS := "res://assets/characters/enemies_chapter_one.png"
# Original transparent atlas: four columns, three rows; the final cell is empty.
const ENEMY_CELLS := {
	"sentry": Vector2i(0, 0),
	"cultist": Vector2i(1, 0),
	"sharpshooter": Vector2i(2, 0),
	"shield_guard": Vector2i(3, 0),
	"torchbearer": Vector2i(0, 1),
	"prison_hound": Vector2i(1, 1),
	"hexer": Vector2i(2, 1),
	"captain": Vector2i(3, 1),
	"gaoler": Vector2i(0, 2),
	"alchemist": Vector2i(1, 2),
	"boss_iron_warden": Vector2i(2, 2),
}
const ICONS := {
	"shield": "res://assets/icons/shield.png",
	"poison": "res://assets/icons/poison.png",
	"burn": "res://assets/icons/burn.png",
	"regeneration": "res://assets/icons/regeneration.png",
	"weakness": "res://assets/icons/weakness.png",
	"vulnerability": "res://assets/icons/vulnerability.png",
	"dispel": "res://assets/icons/dispel.png",
	"interrupt": "res://assets/icons/interrupt.png",
	"health": "res://assets/icons/health.png",
	"energy": "res://assets/icons/energy.png",
	"threat": "res://assets/icons/threat.png",
	"attack_intent": "res://assets/icons/attack_intent.png",
	"interruptible_cast": "res://assets/icons/interruptible_cast.png",
	"uninterruptible_cast": "res://assets/icons/uninterruptible_cast.png",
	"time_bomb": "res://assets/icons/time_bomb.png",
	"soak": "res://assets/icons/soak.png",
	"battle": "res://assets/icons/battle.png",
	"elite": "res://assets/icons/elite.png",
	"camp": "res://assets/icons/camp.png",
	"shop": "res://assets/icons/shop.png",
	"event": "res://assets/icons/event.png",
	"boss": "res://assets/icons/boss.png",
	"gold": "res://assets/icons/gold.png",
	"settings": "res://assets/icons/settings.png",
	"draw_pile": "res://assets/icons/draw_pile.png",
	"discard_pile": "res://assets/icons/discard_pile.png",
	"exhaust": "res://assets/icons/exhaust.png",
	"retain": "res://assets/icons/retain.png",
	"card_frame": "res://assets/ui/card_frame.png",
	"card_back": "res://assets/ui/card_back.png",
	"title_strip": "res://assets/ui/title_strip.png",
	"cost_badge": "res://assets/ui/cost_badge.png",
	"role_tank": "res://assets/ui/role_tank.png",
	"role_assassin": "res://assets/ui/role_assassin.png",
	"role_healer": "res://assets/ui/role_healer.png",
}
const ICON_ALIASES := {
	"regen": "regeneration",
	"weak": "weakness",
	"vulnerable": "vulnerability",
	"attack": "attack_intent",
	"damage": "attack_intent",
	"heal": "health",
	"revive": "health",
	"cast": "interruptible_cast",
	"uninterruptible": "uninterruptible_cast",
	"bomb": "time_bomb",
	"draw": "draw_pile",
	"discard": "discard_pile",
	"deck": "card_back",
	"taunt": "threat",
	"tank": "role_tank",
	"assassin": "role_assassin",
	"healer": "role_healer",
	# Relics share mechanic icons until individual illustrations are available.
	"iron_rivet": "shield",
	"vanguard_banner": "threat",
	"sentry_lens": "draw_pile",
	"quiet_incense": "regeneration",
	"tank_buckle": "role_tank",
	"assassin_seal": "role_assassin",
	"mercy_charm": "role_healer",
	"purge_charm": "dispel",
	"shock_ring": "interrupt",
	"medical_kit": "health",
	"camp_kettle": "camp",
	"weapon_stone": "attack_intent",
	"boss_furnace": "energy",
	"boss_tome": "draw_pile",
	"boss_aegis": "shield",
}
const ILLUSTRATIONS := {
	"shield_bash": "res://assets/cards/shield_bash.png",
	"backstab": "res://assets/cards/backstab.png",
	"flash_heal": "res://assets/cards/flash_heal.png",
}
# The existing art is reused by subject; unique card names/effects remain UI text.
const CARD_ART := {
	"slash": "attack_intent",
	"guard": "shield",
	"stab": "backstab",
	"parry": "shield",
	"smite": "attack_intent",
	"heal": "flash_heal",
	"shield_bash": "shield_bash",
	"double_stab": "backstab",
	"first_aid": "flash_heal",
	"tank_bulwark": "shield",
	"tank_crush": "shield_bash",
	"tank_cover": "soak",
	"tank_break": "weakness",
	"assassin_precise": "backstab",
	"assassin_feint": "draw_pile",
	"assassin_toxin": "poison",
	"assassin_opening": "vulnerability",
	"healer_renew": "regeneration",
	"healer_shelter": "shield",
	"healer_cleanse": "dispel",
	"healer_ember": "burn",
	"warden_fortress": "shield",
	"warden_rally": "threat",
	"warden_command": "draw_pile",
	"warden_wall": "soak",
	"warden_resolve": "retain",
	"blade_execution": "backstab",
	"blade_flurry": "backstab",
	"blade_disrupt": "interrupt",
	"blade_exploit": "vulnerability",
	"blade_prepare": "energy",
	"mender_restore": "flash_heal",
	"mender_mass_heal": "flash_heal",
	"mender_purify": "dispel",
	"mender_resuscitate": "health",
	"mender_reserve": "energy",
	"tactic_plan": "draw_pile",
	"tactic_guard": "shield",
	"tactic_bandage": "flash_heal",
	"tactic_purge": "dispel",
}
static var _enemy_texture_cache: Dictionary = {}


static func actor_texture(definition_id: String) -> Texture2D:
	if ENEMY_CELLS.has(definition_id):
		return _enemy_texture(definition_id)
	return _texture(str(ACTORS.get(definition_id, "")))


static func card_texture(card_id: String) -> Texture2D:
	var art: String = str(CARD_ART.get(card_id, ""))
	if ILLUSTRATIONS.has(art):
		return _texture(str(ILLUSTRATIONS[art]))
	return icon_texture(art)


static func icon_texture(key: String) -> Texture2D:
	var canonical: String = str(ICON_ALIASES.get(key, key))
	return _texture(str(ICONS.get(canonical, "")))


static func background_texture(context: String) -> Texture2D:
	if context in ["menu", "map", "battle", "boss", "chapter_one", "camp", "shop", "event"]:
		return _texture("res://assets/backgrounds/dungeon_outpost.png")
	return null


static func _texture(path: String) -> Texture2D:
	if path == "":
		return null
	# ResourceLoader already caches loaded textures; there is no mutable gameplay state here.
	return load(path) as Texture2D


static func _enemy_texture(definition_id: String) -> Texture2D:
	if _enemy_texture_cache.has(definition_id):
		return _enemy_texture_cache[definition_id] as Texture2D
	var atlas: Texture2D = _texture(ENEMY_ATLAS)
	if atlas == null:
		return null
	var cell: Vector2i = ENEMY_CELLS[definition_id]
	var cell_size: Vector2 = atlas.get_size() / Vector2(4.0, 3.0)
	var portrait := AtlasTexture.new()
	portrait.atlas = atlas
	portrait.region = Rect2(Vector2(cell) * cell_size, cell_size)
	portrait.filter_clip = true
	_enemy_texture_cache[definition_id] = portrait
	return portrait
