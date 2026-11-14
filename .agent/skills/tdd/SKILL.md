---
name: tdd
description: Enforces Test-Driven Development (TDD) across the CustomRenderer codebase. Always write or update a failing TestEZ spec before writing or modifying implementation code.
---
# Test-Driven Development (TDD)

## Core Rule
**Never write or modify production code before writing or updating a test.** Every new feature, bug fix, or refactor must start with a TestEZ specification in `src/server/Tests/Specs/` or `src/client/Tests/Specs/`.

## Workflow (Red -> Green -> Refactor)
1. **Red — Write the test first:**
   - Add or update a `describe` / `it` block in the matching `*.spec.luau` file (`ECS.spec.luau`, `BVH.spec.luau`, `Physics.spec.luau`, `RenderMath.spec.luau`, `Replication.spec.luau`, `ReplicationReceiver.spec.luau`, `Cleaner.spec.luau`, `Camera.spec.luau`, or `ClientInput.spec.luau`).
   - Verify the test fails (or would fail) against the current implementation.
2. **Green — Implement the minimum code:**
   - Write only the code needed in `src/` to make the new test pass without breaking existing specs.
   - Follow `.agent/skills/code-formatting/SKILL.md` conventions (`--!strict`, `--!native`, `--!optimize 2`, tabs, `const`/`local`, trailing `::` types).
3. **Verify & Refactor:**
   - Run the TestEZ suite in Roblox Studio (`F5`) and confirm all server and client specs pass.
   - Clean up duplication or helpers while keeping all specs green.

## Spec Authoring Rules
1. **Verify Target Signatures & Buffer Layouts First:**
   - Always read the target function's header and `@param` annotations before writing the spec so buffer vs. `vector`/`Vector3` arguments and parameter order (e.g., `BVH.Raycast(Storage, Origin, Direction, MaxDistance, IgnoreFilter)`) match exactly.
2. **Isolate Client Specs from the `Controller` Actor VM:**
   - `ClientTestRunner.client.luau` executes in the default client Luau VM, whereas live gameplay runs inside `PlayerScripts.Controller` (`Actor` VM).
   - Always create isolated storage instances via `TestHelper.CreateTestStorage()` (or `ECSMain.CreateStorage(false)`) and pass `TestStorage` explicitly into tested functions rather than mutating shared `PlayerScripts` storages.
3. **Clean Up Shared Server State:**
   - When a server spec mutates shared `ServerStorage` or `ViewCulling` observer state, always delete spawned test entities (`ServerStorage.ECSData.DeleteEntity`) and reset `ViewCulling.UpdateObserverFromVectors` before the `it(...)` block finishes.
4. **Lint & Red-Squiggle Rule Before Running:**
   - Verify every new or modified `.spec.luau` file passes static/lint checks (`--!strict`, no undefined helpers, no unused locals) before running Studio (`F5`).
   - If a file shows red in the IDE with `1` or `2` (or more) red squiggles, treat it as a real bug (never dismiss it as a "petty type error") and fix it before testing.
