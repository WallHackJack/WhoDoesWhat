# WhoDoesWhat — agent instructions

WhoDoesWhat is a Lua 5.1 addon for the WoW TBC Anniversary client. The checked-out repository is also the user's live addon directory, so source files must remain directly loadable by the game.

For the user-facing overview, see [README.md](README.md). For the detailed implementation reference and historical client observations, see [DEVELOPMENT.md](DEVELOPMENT.md). Treat that document as context, not authority: verify behavior against the current code and client before relying on it.

## Non-negotiable rules

- Never edit `Libs/`. Bundled libraries are read-only; customize through addon-owned wrappers or overlays.
- Keep Lua compatible with Lua 5.1 and the current Classic client API.
- Read class, spec, role, ability, icon, and color metadata from `WhoDoesWhat.Classes` and the other tables in `Data.lua`.
- Keep `Assignments.lua` model-only. UI frames belong under `Views/`.
- Preserve the load order in `WhoDoesWhat.toc`; files may localize globals defined by earlier entries.
- Use `WhoDoesWhat:Print(...)` for verbose development logging.
- Do not treat comments or historical client observations as proof of API behavior. Trace callers and verify uncertain behavior.
- Preserve unrelated user changes. Do not edit generated or bundled files to work around addon code.

## Architecture

- `Core.lua`: addon initialization, AceDB defaults, and saved-variable migrations.
- `Data.lua`: shared class/spec/role/ability metadata and customization storage.
- `Permissions.lua`: leader-owned board editing rules.
- `TalentScanning.lua` / `BuffTracking.lua`: talent and live blessing state.
- `Assignments.lua`: assignment model and paladin-buff computation.
- `AssignmentsActions.lua`: tank, CC, and misdirect mutation API.
- `Sync.lua`: versioned AceComm board synchronization.
- `PallyPowerBridge.lua`: computed-plan translation to PallyPower.
- `UnitMenuExtensions.lua` / `RaidMenuExtensions.lua`: Blizzard UI integration.
- `Views/SectionKit.lua`: section-agnostic UI primitives.
- `Views/Sections/`: the five hard-coded assignment sections.
- Other files under `Views/`: complete windows and panels.

## Important invariants

- Paladin coverage is computed from roster, roles, talents, and local rules; it is not stored as per-paladin assignments.
- Hunter pets are derived virtual members used only by paladin-buff planning.
- Only the elected Blizzard-role authority writes other players' Blizzard role flags.
- Every shared board mutation must remain permission-gated and sync-safe.
- Secure buffing-bar attributes are rebuilt out of combat and deferred during combat.
- Fake Raid is a solo-only development tool; never enable it in a real group.

## Working checks

There is currently no automated Lua test suite. For every change:

1. Inspect every caller of the changed function.
2. Confirm every first-party Lua file remains present in `WhoDoesWhat.toc`.
3. Run `git diff --check`.
4. Exercise the affected flow in the game client; use Fake Raid only while solo.

## Releases

- CurseForge packages tagged commits; plain pushes to `main` do not release.
- Use tags such as `1.0.3` without a `v` prefix. Tags containing `alpha` or `beta` set that release channel.
- `WhoDoesWhat.toc` keeps a literal Interface number for the live checkout. The packaged `## Version` is supplied from `@project-version@`.
- Keep repository-only documentation excluded in `.pkgmeta`.
