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
