extends RefCounted

enum BattlePhase { IDLE, PLAYER, RESOLVING, WON, LOST }
enum RunPhase { IDLE, BATTLE, REWARD, WON, LOST, MAP, CAMP, SHOP, EVENT, ABANDONED }

const PILES := ["draw", "hand", "discard", "exhaust", "removed"]
const ROLES := ["tank", "assassin", "healer"]
const EFFECTS := ["damage", "heal", "shield", "interrupt", "dispel"]
