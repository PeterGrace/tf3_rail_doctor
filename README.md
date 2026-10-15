# Rail Doctor (Transport Fever 3 mod)

Adds a card to the line window of a rail line the game reports as broken ("could not connect stations") that says
what is in the way and zooms to it: a stop on the wrong terminal (with the terminal changes that fix every leg), a
one-way signal facing the wrong way, a gap in the track, a waypoint on the wrong track, an alternative terminal
trains can't use, or missing catenary (the game's own reason).

- Mod ID: `pgrace_rail_doctor`
- Cosmetic: yes. It doesn't affect the simulation, so achievements stay enabled.

Agent and modding notes for all mods live in `../AGENTS.md`. The design and its in-game findings are in
`docs/superpowers/specs/2026-10-14-terminal-suggestions-design.md`.

## How it works

The card reads the game's verdict per stretch (`getDetailedLineProblems`), then searches the track itself the way a
train can drive it: pieces of track (`BASE_EDGE`) between base nodes, carrying on only where the tangents agree,
reversing only at the stop, and treating a one-way signal passed from behind as blocked. It only advises when its
search agrees with the game on every stretch. Terminal suggestions come from a small solver over the stops; when no
terminal helps, a 0/1-cost route search names the fewest signals to change, or shows where trains get stuck.

## Layout

```
mod/pgrace_rail_doctor/                        # the mod folder TF3 loads
├── mod.json, strings.json, _metadata/         # translations (12 languages), modinfo.json, description.html, screenshots
├── tealdef/                                   # Teal type definitions (canonical; build.py mirrors them into content/)
└── content/gui/pgrace_rail_doctor/
    ├── line_plugin.res.lua                    # registers the card in the line window (::LineEowExtensionPoint)
    ├── pgrace_rail_doctor.script.tl           # track search, diagnosis and the card
    ├── card.css.lua                           # size of the locate pin
    ├── suggest.tl                             # pure: fewest terminal changes (unit-tested)
    ├── route.tl                               # pure: cheapest route search (unit-tested)
    └── plural.tl                              # pure: plural categories per language (unit-tested)
tools/                                         # type check, tests, install, release checks
tests/                                         # unit tests for the pure modules
```

## Dev loop

```bash
just check      # type-check against the game's API definitions
just test       # unit tests
just verify     # check + test + release-check
just install    # symlink into TF3's staging area (just install-copy to copy)
```

Restart TF3 after code changes. The log is
`~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt`; our lines start with `[rail_doctor]`.

## Releasing

1. Screenshots in `mod/pgrace_rail_doctor/_metadata/`: `0.png` is the cover, `1.png`… the gallery (1920x1080, ≤8 MB).
2. For an update: `just bump` and commit.
3. `just release` (revision check + verify).
4. Upload from **Mod Hub > My Mods** in TF3.
5. Commit what the upload changed (the first one creates `_metadata/mod.io_fileid.txt`), then `just mark-uploaded`
   and push `main`.
