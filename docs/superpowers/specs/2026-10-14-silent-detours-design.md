# Rail Doctor: silent detours

## Problem

A stop on the wrong terminal doesn't always break a line. Where a loop offers a way round, the game routes trains
the long way, through other stations without stopping and waiting at their signals, and shows no warning (test map
scenario D: D-CCW ran nearly the whole triangle per leg and queued behind D-CW at D2).

## Design

- **When:** on every rail line window, in the background. The line card's condition shows the plugin for every rail
  line; the plugin renders nothing until it has found something. Broken lines keep today's synchronous diagnosis.
- **Spread over frames:** the whole check runs in a coroutine, resumed once per frame from `react.onStep` through
  `react.enqueueJoin`, yielding when a frame's budget (6 ms, `api.type.Clock`) is used. A total budget (3 s of work)
  ends it. If the game's Lua has no coroutines, it runs once, synchronously, with the 1 s budget.
- **Lengths:** a shortest-route search by track length (`route.shortest`, pure, unit-tested), over the same
  train-shaped states as today, with one-way signals as walls. From each candidate terminal of a stop it finds the
  distance to every candidate terminal of the next stop (or to its first waypoint) in one pass.
- **Best terminals:** a small dynamic programme over the stops' candidate terminals (`detour.tl`, pure,
  unit-tested) minimises the line's total length.
- **Flag:** a leg is a detour when, with the terminals used now, it is at least 25% and at least 500 m longer than
  its best. The card lists each such leg with both lengths, and the terminal changes from the best assignment.
- **Out of scope for now:** alternative terminals (the main terminal only), and the travel direction at a waypoint
  (a train may leave a waypoint either way in this model, which can only make "actual" look shorter, never flag a
  false detour).

## To verify in-game

The game may not pick the shortest route (it might prefer faster track). The first build logs, for each train on the
line, the length of the path it is driving (`MOVE_PATH`) next to our length for that leg. Scenario D is the test.
