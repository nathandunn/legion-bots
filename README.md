# Legion Bots — TABS-style armies on the Rock Bots personality model

AI robot battle in Godot 4 (3D). You get **500 gold and 20 units a side**: buy Brawlers,
Slingers and Shields, place them on your half of a 2 m grid, give each squad a type and a
personality, and press Fight. Nobody takes orders — what a unit does comes out of its class,
its type and its personality, through the same utility brain Rock Bots always had.

Part of the Precog sim suite (sibling of Battle Bots / Pack Hunt / War Sim).

## M2 in one screen

- **Armies** (button in the top row) opens the builder: camera overhead, your half lit up,
  class buttons with their costs along the bottom, gold and unit count live.
- Tap your half to drop a unit, drag to paint a line of them, tap one to take it away.
  Undo / Clear. Over 500 gold or over 20 units is refused and says so.
- Three preset armies, "Fill enemy from preset", a Red/Blue toggle, five saved-army slots
  kept in the browser, and a Sandbox switch that lifts the gold limit (never the 20 cap).
- **Quick battle**: with nothing placed, both sides spawn `?size=N` do-everything robots —
  the v0 game — so the first load still starts a battle on its own.

## Unit classes

A class is a hard fence on what a unit *can* do; the personality then decides freely inside
it. The brain never scores an action the class forbids, so a Brawler with a high `rock_love`
simply walks past the rocks rather than fetching one it could never throw.

| class | cost | fists / boots | rocks | notes |
|---|---|---|---|---|
| **Brawler** | 20 g | full damage | never picks one up | the cheap body |
| **Slinger** | 30 g | 0.6× damage | throws | soft hands up close |
| **Shield** | 50 g | 1.2× damage | never throws | a shield on the left arm: a rock arriving within ±60° of its facing is blocked with chance `0.5 + 0.4 × reflex skill` (0.7 for an Even type). A block is total — no damage, no knockdown, the rock drops dead. Moves at 0.85× |
| *Mixed* | 30 g | full | throws | the v0 robot. Internal only: quick battles and legacy `--red=Brawler` |

**The costs are placeholders.** They live in one table (`scripts/unit_class.gd`) and M3
calibrates them; the headless summary prints `kills_per_gold` by class, which is the number
to calibrate against. As it stands the Brawler is far and away the best buy (see the last
section).

An Even type (0.2 in all five properties) reproduces each class's base numbers exactly:

```
godot --headless --path . -- --classcheck
```

## Rules (as specced)

| thing | value |
|---|---|
| teams | up to **20 a side** (`MatchManager.MAX_SIZE`), last team standing, **no clock** — stop it yourself if you tire of it (headless sims are capped at `--cap=300` s) |
| robot speed | 6 m/s (±8 % by aggression); backpedalling (moving away from what you face) is 22 % slower, so chasers catch fleers |
| rock speed | 18 m/s (3× robot), ~20 m range, lofted flight |
| rocks | 5 on the field (1 per 2 robots), scattered, reusable — thrown rocks land and can be picked up again. Three sizes (1.2 / 2 / 3.2 kg); heavier ones leave the hand slower but carry more momentum |
| hitboxes | head, torso, 2 arms, 2 legs. Hit quality = parts struck / "full" parts |
| rock hit | physics decides: damage = 50 % of max HP × parts-struck quality × (kinetic energy of the rock **relative to the robot** / a full-speed 2 kg throw). Walking into a rock hurts more than being clipped while running with it. **Friendly fire is on.** Knockdown impulse is the rock's momentum; down time 0.7–2 s by energy |
| punch | up to **20 % of max HP** (3+ parts in the fist box); every 0.6 s (4× a throw's 2.4 s), no rock needed. A punch has a 0.22 s wind-up: a target who can see it coming sidesteps with chance 0.15 + 0.6·caution, and the swing itself lands with chance 0.55 + 0.45·`ACCURACY`. Accuracy (0.7) is the same for everyone — it is not a personality trait. Every landed punch sends the target sprawling as a ragdoll (0.55 s); with **chance 50 % × hit quality** it's a proper floor (1.1 s) |
| kick | from the hip: 0.3 s wind-up, reach 2 m, cooldown 0.9 s; a third of melee attacks on a standing enemy are kicks (punch damage, 60 % × quality knockdown). **A man on the floor can only be kicked**: a stomp does 12 % of max HP, keeps him down another 0.5 s and shoves the ragdoll. Everyone stomps a floored enemy in reach; the brain also goes looking for them (`stomp` action — slingers half as keen, cowards only when nobody standing is near) |
| knockdown | the robot becomes a **ragdoll** (six pinned rigid bodies) and gets shoved away from the hit; it can't act, and its hitboxes drop below the fist box so it can't be punched while down; 0.4 s grace after getting up. Dead robots stay ragdolls |
| HP | 200, shown as a bar over each robot (green → red) |
| eyes | robots see ~190° in front of them and not through cover. A rock they can see coming is spotted 92 % of the time, and after 0.08–0.28 s (quicker when cautious) they drop everything and sprint out of its path; a rock from behind or over a block is never seen. Throws need the target in view too |

All of these are `const`s at the top of `scripts/robot.gd` and `scripts/rock.gd`.

## Personalities

Seven 0–1 traits (`scripts/personality.gd`): `aggression`, `caution`, `rock_love`,
`teamwork`, `patience`, `survival` (when hurt: back off, grab a rock on the way, throw from range —
fades when the enemy is far or worse off than you), `protect` (guard your mates: when one is floored or
has an enemy within 4 m, go and get between them and hit the attacker — or, if you don't box, keep
throwing distance and put your rocks into the attacker; throws favour whoever is on a mate; fades when
you're nearly dead yourself). Presets: Brawler, Slinger, Coward, Tactician, Guardian, Balanced, Random.
Each robot gets the team personality ±0.08 jitter so a team isn't five clones.

Doctrine that falls out of the traits:
- **Slinger** (`rock_love` ≥ 0.75) never punches unless cornered (no rock in hand, none to fetch,
  enemy within 3 m); walks in to its preferred throwing distance (`7 + 8·(1−aggression) + 6·caution` m,
  ~13 m for a Slinger) for a better shot, throws, then sprints for the next rock. Anyone will throw
  early at a target that is running away.
- **Coward** (`caution` ≥ 0.8) never closes in: hides behind cover when an enemy is holding a rock,
  runs (properly — facing the way it's going, not backwards) when someone comes at it, throws only when
  armed and far away. Fists only when an enemy is already in reach: trapped against a wall or block it
  fights; with an open escape it's one poke and then run.
- Stuck behind a block or a body (pressed against it, or inching back and forth for 1.5 s without
  getting anywhere) → a random heading 60–150° off, held for 0.5–1.1 s.
- Throws pick the nearest enemy that is standing and has a clear line (raycast against cover); a floored
  enemy is aimed at low and only if nobody is up. **Nobody throws through a mate**: a teammate inside a
  cone around the flight line (0.9 m at the hand widening ~12° out to the target and 12 m past it, wider
  for wild throwers, for mates on the move, and right in front of the hand; anyone within 1.7 m of the
  thrower) blocks the throw, and the thrower sidesteps to open the lane instead. Friendly fire still
  happens when a mate runs into a rock already in the air.
- Seeing an incoming rock beats every other urge: the dodge is a sideways sprint (with a step back if there is time and the robot is cautious).
- The winning team jogs to a line in front of the centre block, dances for two seconds on one shared beat, then shares out the fallen enemies and, for each, squats over him four times and then stands back a pace and relieves himself on the body (a puddle spreads and stays). The results panel opens as the dance starts, off to one side (right half in landscape, lower part in portrait) so you can watch; Close it to see everything.

The brain (`Robot._decide`) is a small utility AI: every 0.15 s it scores
`dodge / fetch / throw / punch / kite / retreat / regroup / wander` from traits + situation and takes the best
(with hysteresis). Punches and throws also fire opportunistically whenever a target is in reach and
the cooldown is up.

## Controls

- Drag to orbit, wheel / pinch to zoom. The camera stays where you put it (it glides in on the winners
  during the celebration and back out afterwards).
- `Pause` / `Play`, then `1x 2x 4x 8x` — sim speed (raises the physics tick rate to match, so fast mode is not sloppier).
- `Armies` — the builder (above). `Fight!` from there; afterwards the results panel offers
  *Same armies again* and *Edit armies*.
- `Teams / setup` — preset + sliders per team for the quick battle, then `Start match with these teams`.
- `Live list` — per-robot HP / current action. `Last results` reopens the last match's results.
- `New match`, `Batch x10` — batch runs at 8× and prints win rates, damage by source, throw/punch accuracy,
  knockdowns and a histogram of hitboxes-struck-per-rock-hit.
- Nothing starts by itself: the results panel asks *Start the next match?* — same armies again, edit
  armies, change teams first, or not yet. With nothing placed it is the quick battle: Slinger vs Brawler.
- At the end of a match a results panel shows team totals (throws/hits %, punches/hits %, damage by
  source, knockdowns, kills — a team's kills equal the enemies it killed; a robot's kills are the ones
  its own hands or rocks finished, own goals listed separately) and a per-robot table.
  The UI scales with device pixel density and wraps for phones.

## The army builder

An army is a list of **squads**. A squad is one class, one type, one personality and the
cells its units stand on — never an order. Adding a class either starts its squad or selects
the one that is already there, so a side is at most one squad per class.

The grid is 2 m cells over the middle band of the floor, 18 across by 12 deep; Red owns the
low-x half, Blue the high-x half, and a cell with a cover block in it cannot be built on.
Preset armies, all inside 500 gold and 20 units:

| preset | units | gold |
|---|---|---|
| Brawler Mob | 20 Brawler (Bruiser / Brawler) | 400 |
| Slinger Line | 5 Shield + 8 Slinger, shields in front | 490 |
| Shield Wall | 7 Shield + 5 Slinger | 500 |

Saved armies are the third kind of slot in `scripts/custom_slots.gd`, beside the five
personality and five type slots, in the same `user://custom_slots.json`. Every field is
re-validated on the way in, so an old or hand-mangled save costs that slot and never the
game. Loading an army onto the other half mirrors it.

The army model has a self-test that needs no browser:

```
godot --headless --path . --script scripts/army_selftest.gd
```

## Headless simulation

```
godot --headless --path . -- --sim=20 --red=Slinger --blue=Brawler --seed=1
```

`--red=` and `--blue=` take three shapes:

| argument | means |
|---|---|
| `--red="Shield Wall"` | one of the three preset armies |
| `--red=brawler:10:Bruiser:Brawler,slinger:6:Sniper:Slinger` | squads: `class:count:type:personality` |
| `--red=Slinger` | legacy: a personality for the whole side, `TEAM_SIZE` Mixed robots |

Headless armies are laid out on their own half automatically (shields in front, then fists,
then the rock throwers). `--sandbox` lifts the gold limit. The SUMMARY json carries
`cost_left` and `kills_per_gold` by class per side alongside the old numbers, and the
results panel gains a Class column and gold spent / gold left standing per team.

Prints one line per match, a summary line, then a JSON blob (wins, avg duration, damage by source,
throws / hits, punches / hits, hitbox histogram). Runs at 20× game speed.

Sample (6 matches, seed 5): Slinger 2 – Brawler 4, avg 32 s; slingers 606 rock dmg per match at 51 %
throw accuracy (they only throw at what they can see), brawlers 948 punch dmg. Slinger 3 – Balanced 3.
Set `RBCELEB=1` to let the winners finish their celebration headless (prints the phase changes).
Legs swing from the hip in time with the ground covered (no more sliding statues); kicks animate the right leg.

## Build / deploy

- Godot **4.7.2**, GL Compatibility renderer, GDScript only, no addons, everything built in code
  (the only scene file is `scenes/Main.tscn`).
- Web export preset is in `export_presets.cfg` (thread support **off**, so no COOP/COEP headers needed —
  plain static hosting works):
  ```
  godot --headless --path . --export-release Web build/web/index.html
  ```
- `build/web/` is a ready static site (~44 MB, mostly `index.wasm`). Drop it behind Caddy like the other
  Godot apps (`war-godot`, `pack-hunt-3d`); suggested subdomain `rock-bots.apps.precogsoftwareservices.com`.
- Verified: headless batch sims run clean (no script errors), web build loads and runs in Chromium.

## Layout

```
project.godot
scenes/Main.tscn          root node + main.gd
scripts/main.gd           wiring, sim speed, batch mode, CLI args
scripts/match_manager.gd  spawn teams/rocks, clock, winner, stats
scripts/robot.gd          body + hitboxes, movement, utility AI, punch/throw
scripts/rock.gd           rock states (idle/held/thrown/spent), impact + splash damage
scripts/personality.gd    traits + presets
scripts/arena.gd          floor, walls, cover
scripts/camera_rig.gd     orbit camera (mouse + touch)
scripts/hud.gd            scoreboard, speed, team panel, results
scripts/unit_class.gd     the class table: costs and what each class may do
scripts/placement.gd      the army builder - overhead field, grid, bottom bar
scripts/custom_slots.gd   your five personalities, five types and five armies
scripts/army_selftest.gd  headless self-test for the army model
```

## Next ideas (M3)

- **Calibrate the costs.** 30 headless battles at the placeholder prices: Brawler Mob beats
  both shield armies 6–0 in about 24 s, and the two shield armies are 3–3 with each other.
  Kills per gold: Brawler 0.030–0.059, Slinger 0.006–0.022, Shield 0.000–0.012. The Brawler
  is underpriced, or the Shield is overpriced, or both.
- Pinch-zoom and pan on the placement camera: a 2 m cell is ~21 px on a 412-wide phone.
- Swap `Personality` for the sim-core schema and drive it from agent-forge sweeps.
- Rock pickup animation, throw arc preview, hit numbers.
- Team compositions (mixed presets per team), more rocks / bigger arena options in the HUD.
