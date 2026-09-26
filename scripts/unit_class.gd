class_name UnitClass
extends RefCounted
## What a unit *can do* - the third leg of the stool beside RobotType (what it is) and
## Personality (how it behaves). A class is a hard capability fence: a Brawler cannot pick a
## rock up however much it loves them, a Slinger's fists are soft, a Shield carries a shield.
## Personality then decides freely *within* the fence, which is why the brain never scores an
## action the class forbids rather than scoring it and refusing later.
##
## Cost is the army builder's currency. The costs below were fitted in M3 by simulation -
## `tools/calibrate.py` round-robins single-class armies at equal gold, fits a Bradley-Terry
## strength per class and moves the prices until every class wins about half its battles
## against the field. See tools/calibration_report.md.
##
## SPANS is the other half of that calibration: how much each of the five type properties is
## worth *to this class*. A property's factor is 1.0 at an even 0.2 share whatever the gains
## are, so an Even type still reproduces every class's base numbers exactly.
##
## `mixed` is the v0 Rock Bots robot - it throws, punches and kicks with no penalty. It is
## never offered in placement; it is what legacy arguments and the quick battle spawn.

const TABLE := {
	"brawler": {
		"label": "Brawler", "cost": 35,
		"throws": false, "carries": false, "shield": false,
		"melee_mult": 1.0, "speed_mult": 1.0,
		"blurb": "Fists and boots only. Walks straight past the rocks.",
	},
	"slinger": {
		"label": "Slinger", "cost": 25,
		"throws": true, "carries": true, "shield": false,
		"melee_mult": 0.6, "speed_mult": 1.0,
		"blurb": "Throws rocks. Soft hands up close - 0.6x on fists and boots.",
	},
	"shield": {
		"label": "Shield", "cost": 34,
		"throws": false, "carries": false, "shield": true,
		"melee_mult": 1.2, "speed_mult": 0.85,
		"blurb": "Blocks rocks from the front, punches 1.2x, moves 0.85x. Never throws.",
	},
	# Mixed is deliberately NOT calibrated: it never appears in a budgeted army, only in the
	# quick battle and legacy --red=/--blue= arguments, which are unbudgeted by design.
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

## ------------------------------------------------------------------ type spans, per class
##
## A type property is worth a different amount to different classes: aim decides a Slinger's
## whole afternoon and does nothing at all for a Brawler, who never throws. So the span is a
## per-class knob, not a global one.
##
## `curve` is how steeply a property *below* an even share falls away (lower is gentler, so
## specialising costs less); the five gains scale how far *above and below* 1.0 that property
## moves the derived number. Because the scaling is on the deviation from 1.0, a 0.2 share is
## still exactly 1.0 for every gain - `--classcheck` holds whatever these say.
##
## Fitted in M3 by tools/calibrate.py: specialist (0.6 in one property, 0.1 in the rest)
## against Even, same class both sides, gains nudged until every property wins about half.
const SPANS := {
	"brawler":   {"curve": 0.52, "brawn": 0.56, "speed": 1.61, "grit": 0.83, "reflex": 0.59, "aim": 2.28},
	"slinger":   {"curve": 0.47, "brawn": 0.87, "speed": 0.71, "grit": 0.69, "reflex": 1.12, "aim": 2.09},
	"shield":    {"curve": 0.51, "brawn": 0.60, "speed": 2.34, "grit": 0.82, "reflex": 0.57, "aim": 1.50},
	"mixed":   {"curve": 0.80, "brawn": 1.00, "speed": 1.00, "grit": 1.00, "reflex": 1.00, "aim": 1.00},
}

## Set from the command line by the calibrator (--costs=, --gains=) so a tuning run does not
## have to rewrite the script between probes. Empty in a real game.
static var cost_override := {}
static var span_override := {}


## --costs=brawler:26,shield:44
static func apply_cost_overrides(spec: String) -> void:
	for part in spec.split(",", false):
		var kv: PackedStringArray = String(part).strip_edges().split(":")
		if kv.size() == 2 and is_known(kv[0]):
			cost_override[normalize_id(kv[0])] = maxi(int(float(kv[1])), 1)
	_cache.clear()


## --gains=brawler.aim:0.4,slinger.curve:0.65  (the key "curve" is the below-even falloff)
static func apply_span_overrides(spec: String) -> void:
	for part in spec.split(",", false):
		var kv: PackedStringArray = String(part).strip_edges().split(":")
		if kv.size() != 2:
			continue
		var path: PackedStringArray = kv[0].split(".")
		if path.size() != 2 or not is_known(path[0]):
			continue
		span_override["%s.%s" % [normalize_id(path[0]), path[1].strip_edges().to_lower()]] = float(kv[1])
	_cache.clear()


static func span_value(class_id: String, key: String) -> float:
	var cid := normalize_id(class_id)
	var k := "%s.%s" % [cid, key]
	if span_override.has(k):
		return float(span_override[k])
	return float((SPANS[cid] as Dictionary).get(key, 1.0))

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
	cost = cost_of(id)
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
	var k := normalize_id(class_id)
	if cost_override.has(k):
		return int(cost_override[k])
	return int(TABLE[k]["cost"])


static func label_of(class_id: String) -> String:
	return String(TABLE[normalize_id(class_id)]["label"])


## What one type property is worth *to this class*: 1.0 at an even 0.2 share for every class
## and every gain, rising linearly above it and falling away on `curve` below it, with the
## whole deviation from 1.0 scaled by this class's gain for that property.
func factor(rt: RobotType, p: String) -> float:
	var v := rt.get_prop(p)
	var f: float
	if v >= RobotType.EVEN:
		f = 1.0 + (v - RobotType.EVEN) / RobotType.EVEN
	else:
		f = pow(v / RobotType.EVEN, span_value(id, "curve"))
	return 1.0 + (f - 1.0) * span_value(id, p)


## 0.5 + 0.4 x reflex skill, where an even 0.2 share of reflex is half a skill and 0.4 or
## more is all of it - so an Even Shield stops 7 rocks in 10 from the front and a Ghost 9.
static func block_chance(reflex_skill: float) -> float:
	return clampf(BLOCK_BASE + BLOCK_SKILL * clampf(reflex_skill, 0.0, 1.0), 0.0, 1.0)
