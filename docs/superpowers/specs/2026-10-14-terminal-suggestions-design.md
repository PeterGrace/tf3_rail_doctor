# Rail Doctor: terminal suggestions

## Problem

A line whose stops use the wrong terminals gets "No path" even though the track is fine. Seen with Express & Local
Rail Stations (`express_local_stations_1`): its game script puts one-way path signals at both ends of each station
(starters on the leaving tracks, home signals on the incoming mains, right-hand running), so each track can only be
entered from one end. A line left on terminal 0 everywhere broke on 3 of 5 legs; moving leg 1's stops to the track on
the right-hand side fixed it (verified in-game).

The game's own "no path" report (`api.engine.util.line.getDetailedLineProblems`) gives `noPathLocation` only for
transport-mode problems (catenary, tram track). For these legs it was nil, so it can't point at anything.

## Design

A card on the line window (`LineEowExtensionPoint`, order 25), shown only when a leg has no path.

- **Candidates:** every terminal of every station in the stop's station group that has a vehicle node and loads the
  same things (passengers / cargo) as the terminal the stop uses now.
- **Reachability:** `api.engine.util.pathfinding.findPathNodeToNode({fromNode}, {toNode}, {TRAIN})`, non-empty means
  reachable. Cached per (leg, from, to).
- **Self-check:** the current terminals are run through the pathfinder first. If it finds a path on a leg the game
  calls broken, the pathfinder doesn't see what the game sees (signals), and the card says suggestions can't be
  trusted.
- **Solver** (`suggest.tl`, pure, unit-tested): broken legs in order; for each, try changing the destination stop's
  terminal, then the origin's, then both. A change must not break a neighbouring leg that works. Accepted changes
  carry into later legs, so a leg can come out "fixed by the change above".
- **Card text:** per broken leg, `Leg 3: San Luis Obispo [Terminal 1] → Sulphur [Terminal 1]`, then `Use Terminal 4
  at Sulphur`, `Fixed by the change above`, or `No terminals work: the track or its signals block this leg`. A note
  says to untick "Assign terminals automatically" first.
- **Also logged:** the game's `lineSystem.getBestLineAssignment(line, copy, true)` for comparison, and timings.

## Not yet

- An Apply button (`makeLineUpdateCmd` on a copy of the line, as Bus Loops does).
- Finding the blocking signal when no terminals work.

## What it became (verified on a flat test map, scenarios A–L)

The pathfinder API (`findPathNodeToNode`) disagreed with the game on the first broken line, so reachability is our
own search instead:

- **Track search** (`route.tl` + the track code in the script): states are pieces of track entered in one
  direction; a train carries on only where tangents agree and reverses only at its stop. A one-way signal passed
  from behind costs 1. With costs as walls the search must agree with the game on every stretch (the self-check),
  or the card gives no advice.
- **Signal direction and type** (scenario E): for a train running node0 → node1 the blocking signal is
  `getSignal(edge, false)`; type 1 is one-way, 0 a normal two-way signal (scenario I: ignored).
- **Terminals** (G): the solver above, with this search as `reach`. Verified: one suggested change fixed two legs.
- **No terminal helps:** up to two wrong-way signals are listed by name and distance (E, H). More than two means the
  route is running against the other track's traffic, so the card shows where trains get stuck instead (F: right at
  the gap).
- **Waypoints** (J): one problem entry per stretch; waypoints are directionless spots on the track. A broken
  stretch next to a waypoint is offered as "Either move the waypoint / Or change these one-way signals".
- **Alternative terminals** (L): the game's `noPathFrom/ToAlternative` names the terminal; same either/or layout.
- **Transport-mode problems** (K): the game's `noPathLocation` and its own text ("Missing catenaries"); those
  stretches stay out of our search.
- **Layout:** rows indented by level, locate pins on clickable rows (camera at the closest zoom), explanations in
  tooltips, a gap between legs.

Not done: silent detours (a wrong terminal where a loop offers a long way round; scenario D), an Apply button.
