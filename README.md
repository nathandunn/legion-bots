# Rock Bots

5-a-side AI robot brawl in Godot 4 (3D). Robots throw rocks and punch. Pure spectator sim —
you set each team's personality, watch, or batch-run matches for statistics.

Part of the Precog sim suite (sibling of Battle Bots / Pack Hunt / War Sim).

## Rules (as specced)

| thing | value |
|---|---|
| teams | 5 v 5, last team standing, 150 s cap (most total HP wins on time) |
| robot speed | 6 m/s (±8 % by aggression); backpedalling (moving away from what you face) is 22 % slower, so chasers catch fleers |
| rock speed | 18 m/s (3× robot), ~20 m range, lofted flight |
| rocks | 5 on the field (1 per 2 robots), scattered, reusable — thrown rocks land and can be picked up again |
| hitboxes | head, torso, 2 arms, 2 legs. Hit quality = parts struck / "full" parts |
| rock hit | up to **50 % of max HP** for a direct hit (4+ parts within the 0.78 m splash); 1 part = 12.5 %. **Always knocks the robot down** (1.8 s) |
| punch | up to **20 % of max HP** (3+ parts in the fist box); every 0.6 s (4× a throw's 2.4 s), no rock needed. **Knockdown chance 50 % × hit quality** (1.1 s) |
| knockdown | robot drops flat, can't act; 0.4 s grace after getting up. A flat robot is below the fist box, so it can't be punched while down |
| HP | 200, shown as a bar over each robot (green → red) |
| dodging | robots notice an incoming enemy rock with probability 0.2 + 0.75·caution, react after 0.2–0.55 s, then sidestep |

All of these are `const`s at the top of `scripts/robot.gd` and `scripts/rock.gd`.

## Personalities

Seven 0–1 traits (`scripts/personality.gd`): `aggression`, `caution`, `rock_love`, `accuracy`,
`teamwork`, `patience`, `survival` (when hurt: back off, grab a rock on the way, throw from range —
fades when the enemy is far, worse off than you, or the clock is running out). Presets: Brawler, Slinger, Coward, Tactician, Balanced, Random.
Each robot gets the team personality ±0.08 jitter so a team isn't five clones.

The brain (`Robot._decide`) is a small utility AI: every 0.15 s it scores
`dodge / fetch / throw / punch / kite / retreat / regroup / wander` from traits + situation and takes the best
(with hysteresis). Punches and throws also fire opportunistically whenever a target is in reach and
the cooldown is up.

## Controls

- Drag to orbit, wheel / pinch to zoom. Camera auto-orbits when idle.
- `1x 2x 4x 8x` — sim speed (raises the physics tick rate to match, so fast mode is not sloppier).
- `Teams / setup` — preset + sliders per team, then `Start match with these teams`.
- `Live list` — per-robot HP / current action. `Last results` reopens the last match's results.
- `New match`, `Batch x10` — batch runs at 8× and prints win rates, damage by source, throw/punch accuracy,
  knockdowns and a histogram of hitboxes-struck-per-rock-hit.
- At the end of a match a results panel shows team totals (throws/hits %, punches/hits %, damage by
  source, knockdowns, kills) and a per-robot table (damage by source, accuracy, knockdowns, kills, HP).
  Matches auto-restart 20 s later; the UI scales with device pixel density and wraps for phones.

## Headless simulation

```
godot --headless --path . -- --sim=20 --red=Slinger --blue=Brawler --seed=1
```

Prints one line per match, a summary line, then a JSON blob (wins, avg duration, damage by source,
throws / hits, punches / hits, hitbox histogram). Runs at 20× game speed.

Sample (12 matches, seed 5): Slinger 6 – Brawler 6, avg 34 s. Slingers: 99 rock dmg + 810 punch dmg per
match, 49 % throw accuracy. Brawlers: 873 punch dmg. Balanced mirror (seed 33): 6–6.

## Build / deploy

- Godot **4.4.1**, GL Compatibility renderer, GDScript only, no addons, everything built in code
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
```

## Next ideas

- Swap `Personality` for the sim-core schema and drive it from agent-forge sweeps.
- Rock pickup animation, throw arc preview, hit numbers.
- Team compositions (mixed presets per team), more rocks / bigger arena options in the HUD.
