class_name Icons
extends RefCounted
## Little textures drawn pixel by pixel in code, so every build and personality has a badge you
## can tell apart at a glance in a row of players. Godot's bundled font has no emoji and none of
## these projects ship an image file, so the icons are drawn rather than typed.
##
## Shape carries the meaning and colour reinforces it; the key is on the hover, and on the "?"
## button beside each team. Badges are assigned by position in the roster rather than by name,
## so this same file drops into every game in the suite unchanged - only the roster differs.

enum Shape { DISC, SQUARE, TRI_UP, DIAMOND, CROSS, RING, TRI_DOWN, BOLT, STAR, BARS, HOURGLASS, SHIELD }

const SIZE := 20

static var _cache := {}


static func get_icon(shape: Shape, color: Color) -> ImageTexture:
	var key := "%d_%s" % [int(shape), color.to_html(false)]
	if _cache.has(key):
		return _cache[key]
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := float(SIZE) * 0.5
	for y in SIZE:
		for x in SIZE:
			# sample at pixel centres, in a -1..1 box, so the shapes come out symmetrical
			var u := (float(x) + 0.5 - c) / (c - 1.0)
			var v := (float(y) + 0.5 - c) / (c - 1.0)
			var a := _coverage(shape, u, v)
			if a > 0.0:
				# a darker rim keeps the badge readable against a pale button
				var edge: float = clampf((a - 0.5) * 2.0, 0.0, 1.0)
				var col: Color = color.lerp(color.darkened(0.45), 1.0 - edge)
				col.a = clampf(a, 0.0, 1.0)
				img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## Rough antialiasing: 1 inside, 0 outside, a soft band between.
static func _band(d: float, w: float = 0.09) -> float:
	return clampf(0.5 - d / w, 0.0, 1.0)


static func _coverage(shape: Shape, u: float, v: float) -> float:
	match shape:
		Shape.DISC:
			return _band(sqrt(u * u + v * v) - 0.86)
		Shape.SQUARE:
			return _band(maxf(absf(u), absf(v)) - 0.76)
		Shape.TRI_UP:
			var d1: float = -v - 0.62
			var d2: float = (absf(u) * 0.95 + v * 0.55) - 0.46
			return _band(maxf(d1, d2))
		Shape.TRI_DOWN:
			var e1: float = v - 0.62
			var e2: float = (absf(u) * 0.95 - v * 0.55) - 0.46
			return _band(maxf(e1, e2))
		Shape.DIAMOND:
			return _band(absf(u) + absf(v) - 0.98)
		Shape.CROSS:
			var arm: float = minf(maxf(absf(u) - 0.86, absf(v) - 0.3), maxf(absf(u) - 0.3, absf(v) - 0.86))
			return _band(arm)
		Shape.RING:
			var r: float = sqrt(u * u + v * v)
			return minf(_band(r - 0.88), _band(0.46 - r))
		Shape.BOLT:
			var top: float = maxf(absf(u * 1.5 + 0.35) - 0.42, absf(v + 0.42) - 0.46)
			var bot: float = maxf(absf(u * 1.5 - 0.35) - 0.42, absf(v - 0.42) - 0.46)
			return _band(minf(top, bot))
		Shape.STAR:
			var d_a: float = absf(u) * 2.2 + absf(v) * 0.75 - 0.92
			var d_b: float = absf(u) * 0.75 + absf(v) * 2.2 - 0.92
			return _band(minf(d_a, d_b))
		Shape.BARS:
			var b1: float = maxf(absf(u + 0.52) - 0.2, absf(v) - 0.84)
			var b2: float = maxf(absf(u) - 0.2, absf(v) - 0.58)
			var b3: float = maxf(absf(u - 0.52) - 0.2, absf(v) - 0.32)
			return _band(minf(b1, minf(b2, b3)))
		Shape.HOURGLASS:
			var h: float = maxf(absf(u) * 0.9 + absf(v) * 0.1 - 0.5 - absf(v) * 0.55, absf(v) - 0.82)
			return _band(h)
		Shape.SHIELD:
			var w: float = 0.9 - 0.62 * clampf((v + 0.5) * 0.9, 0.0, 1.4)
			return _band(maxf(absf(u) - w, absf(v + 0.02) - 0.85))
	return 0.0


# ---------------------------------------------------------------- the two rosters

## Builds get one family of shapes, personalities another, so the two rows never blur into
## each other even at a glance. RING and BOLT are reserved for "Team" and "Random".
const BUILD_SHAPES := [Shape.DISC, Shape.SQUARE, Shape.TRI_UP, Shape.SHIELD, Shape.STAR, Shape.DIAMOND, Shape.BARS, Shape.HOURGLASS]
const BUILD_COLORS := [
	Color(0.72, 0.74, 0.80), Color(0.90, 0.42, 0.28), Color(0.36, 0.82, 0.52), Color(0.55, 0.60, 0.72),
	Color(0.95, 0.80, 0.30), Color(0.60, 0.55, 0.92), Color(0.40, 0.78, 0.88), Color(0.88, 0.55, 0.72),
]
const PERSONA_SHAPES := [Shape.DISC, Shape.CROSS, Shape.TRI_DOWN, Shape.HOURGLASS, Shape.BARS, Shape.SHIELD, Shape.STAR, Shape.SQUARE]
const PERSONA_COLORS := [
	Color(0.70, 0.76, 0.82), Color(0.92, 0.35, 0.30), Color(0.95, 0.70, 0.25), Color(0.55, 0.78, 0.85),
	Color(0.45, 0.70, 0.95), Color(0.45, 0.85, 0.60), Color(0.85, 0.75, 0.45), Color(0.78, 0.60, 0.90),
]

const TEAM_COLOR := Color(0.78, 0.78, 0.84)
const RANDOM_COLOR := Color(0.85, 0.55, 0.85)


## `index` is the entry's position in its roster, which is fixed for a given game, so a badge
## always means the same thing. The three reserved names get their own marks wherever they sit.
static func roster_icon(entry_name: String, index: int, is_build: bool) -> ImageTexture:
	match entry_name:
		"Team":
			return get_icon(Shape.RING, TEAM_COLOR)
		"Random":
			return get_icon(Shape.BOLT, RANDOM_COLOR)
		"Custom":
			return get_icon(Shape.BARS, Color(0.70, 0.72, 0.78))
	var shapes: Array = BUILD_SHAPES if is_build else PERSONA_SHAPES
	var colors: Array = BUILD_COLORS if is_build else PERSONA_COLORS
	var i := maxi(index, 0) % shapes.size()
	return get_icon(shapes[i], colors[i])
