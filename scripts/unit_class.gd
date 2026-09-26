class_name UnitClass
extends RefCounted
## What a unit *can do* - the third leg of the stool beside RobotType (what it is) and
## Personality (how it behaves). A class is a hard capability fence: a Brawler cannot pick a
## rock up however much it loves them, a Slinger's fists are soft, a Shield carries a shield.
## Personality then decides freely *within* the fence, which is why the brain never scores an
## action the class forbids rather than scoring it and refusing later.
##
## Cost is the army builder's currency. THE COSTS ARE PLACEHOLDERS: they are one table, here,
## and M3 calibrates them against real win rates (kills_per_gold in the headless summary is
## the measurement that will do it).
##
## `mixed` is the v0 Rock Bots robot - it throws, punches and kicks with no penalty. It is
## never offered in placement; it is what legacy arguments and the quick battle spawn.

const TABLE := {
	"brawler": {
		"label": "Brawler", "cost": 20,
		"throws": false, "carries": false, "shield": false,
		"melee_mult": 1.0, "speed_mult": 1.0,
		"blurb": "Fists and boots only. Walks straight past the rocks.",
	},
	"slinger": {
		"label": "Slinger", "cost": 30,
		"throws": true, "carries": true, "shield": false,
		"melee_mult": 0.6, "speed_mult": 1.0,
		"blurb": "Throws rocks. Soft hands up close - 0.6x on fists and boots.",
	},
	"shield": {
		"label": "Shield", "cost": 50,
		"throws": false, "carries": false, "shield": true,
		"melee_mult": 1.2, "speed_mult": 0.85,
		"blurb": "Blocks rocks from the front, punches 1.2x, moves 0.85x. Never throws.",
	},
	"mixed": {
		"label": "Mixed", "cost": 30,
		"throws": true, "carries": true, "shield": false,
		"melee_mult": 1.0, "speed_mult": 1.0,
		"blurb": "The original robot: does everything. Quick battles and legacy arguments only.",
	},
}

## The three you can put on the field. `mixed` is internal.
const PLACEABLE: Array[String] = ["brawler", "slinger", "shield"]
const DEFAULT_ID := "mixed"

## A rock inside this arc of the shield's facing can be blocked at all...
const BLOCK_ARC_DEG := 60.0
## ...and is blocked with this chance, plus the wielder's reflex skill.
const BLOCK_BASE := 0.5
const BLOCK_SKILL := 0.4

static var _cache := {}

var id := DEFAULT_ID
var label := "Mixed"
var cost := 30
var throws := true
var carries := true
var shield := false
var melee_mult := 1.0
var speed_mult := 1.0
var blurb := ""


func _init(class_id: String = DEFAULT_ID) -> void:
	id = normalize_id(class_id)
	var row: Dictionary = TABLE[id]
	label = String(row["label"])
	cost = int(row["cost"])
	throws = bool(row["throws"])
	carries = bool(row["carries"])
	shield = bool(row["shield"])
	melee_mult = float(row["melee_mult"])
	speed_mult = float(row["speed_mult"])
	blurb = String(row["blurb"])


## "Brawler", "brawler", "BRAWLER " all mean the same thing; anything else is the default.
static func normalize_id(class_id: String) -> String:
	var k := class_id.strip_edges().to_lower()
	return k if TABLE.has(k) else DEFAULT_ID


static func is_known(class_id: String) -> bool:
	return TABLE.has(class_id.strip_edges().to_lower())


## Classes are immutable, so one instance each is plenty.
static func of(class_id: String) -> UnitClass:
	var k := normalize_id(class_id)
	if not _cache.has(k):
		_cache[k] = UnitClass.new(k)
	return _cache[k]


static func cost_of(class_id: String) -> int:
	return int(TABLE[normalize_id(class_id)]["cost"])


static func label_of(class_id: String) -> String:
	return String(TABLE[normalize_id(class_id)]["label"])


## 0.5 + 0.4 x reflex skill, where an even 0.2 share of reflex is half a skill and 0.4 or
## more is all of it - so an Even Shield stops 7 rocks in 10 from the front and a Ghost 9.
static func block_chance(reflex_skill: float) -> float:
	return clampf(BLOCK_BASE + BLOCK_SKILL * clampf(reflex_skill, 0.0, 1.0), 0.0, 1.0)
