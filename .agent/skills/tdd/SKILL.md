---
name: tdd
description: Enforces strict Test-Driven Development (TDD) across the CustomRenderer codebase. Read before adding features, fixing bugs, or refactoring Luau systems.
---

# Test-Driven Development (TDD)

## 1. Scope: When Tests Are Required vs. Exempt

### Required (Write/Update Spec First)
Every new feature, bug fix, optimization, or behavior-changing refactor in:
- `src/shared/` (`ECSMain`, `DynamicObjectsMain`, `Configs`, `BVH`, `Physics`, `Player`, `Render`)
- `src/server/Objects/` (`ObjectsECS`, `Player`, `Replication`)
- `src/client/Objects/` and `src/client/RenderBootstrap.luau`

### Exempt (No Spec Needed)
- Standalone debug/convenience scripts in `src/client/scripts/` (non-logic UI/input toggles).
- Documentation-only (`*.md`), comment-only, or pure formatting changes that do not alter runtime behavior.

---

## 2. Mandatory Workflow (Red -> Green -> Refactor)

1. **Red — Write or Update a Failing Spec First**
   - Locate the matching spec in `src/server/Tests/Specs/` or `src/client/Tests/Specs/` (or create a new `<System>.spec.luau` if adding a new subsystem).
   - Write assertions against the **real** target module that fail (or do not yet resolve) before production edits.
   - **Do not write or modify production code in `src/` until the spec change is written.**

2. **Green — Implement Minimal Production Code**
   - Write the minimal, zero-allocation production code required to satisfy the new assertions without breaking existing suites.
   - Follow `.agent/skills/code-formatting/SKILL.md` rules (`--!strict`, `--!native`, `--!optimize 2`, tabs, `const`/`local`, trailing `::` casts, no leading `(` statements).

3. **Verify & Refactor**
   - Run static checks (`selene` / `luau-lsp` / `stylua .` when installed; otherwise manually audit imports, types, `WaitForChild` names, and syntax).
   - Confirm all server and client TestEZ suites pass in Roblox Studio (`F5`) with zero infinite-yield warnings and zero red IDE diagnostics.

---

## 3. Spec Placement Map

| Target Domain | Spec Directory | Existing Specs |
| :--- | :--- | :--- |
| Shared Math, ECS, BVH, Physics, Server Player & Replication | `src/server/Tests/Specs/` | `BVH.spec.luau`, `ECS.spec.luau`, `Physics.spec.luau`, `Player.spec.luau`, `RenderMath.spec.luau`, `Replication.spec.luau` |
| Client Camera, Input, Cleaner, Client Player & Delta Receiver | `src/client/Tests/Specs/` | `Camera.spec.luau`, `Cleaner.spec.luau`, `ClientInput.spec.luau`, `PlayerClient.spec.luau`, `ReplicationReceiver.spec.luau` |

Both runners (`TestRunner.server.luau` and `ClientTestRunner.client.luau`) auto-discover every `*.spec.luau` module in their `Specs` folder.

---

## 4. Strict Spec Authoring Rules

### 1. Test Real Modules — Never Duplicate Production Logic in Specs
- Always `require` and call the actual production module.
- Because `.client.luau` and `.server.luau` scripts cannot be `require`d, extract testable logic into a sibling `*Helper.luau` `ModuleScript` (e.g., `ReplicationReceiverHelper.luau`) and test that module directly. Never copy-paste production loops into a spec.

### 2. Canonical `--!strict` Spec Header
Use this exact header so TestEZ globals pass `--!strict` with zero red squiggles:

```lua
--!strict
--!native
--!optimize 2

return function()
	const SpecEnv = getfenv() :: {
		describe: (string, () -> ()) -> (),
		it: (string, () -> ()) -> (),
		expect: (any) -> any,
	}
	const describe = SpecEnv.describe
	const it = SpecEnv.it
	const expect = SpecEnv.expect

	-- Services --
	-- Static References --
	-- Libraries --
	-- Configs --
end
```

### 3. Verify Signatures, Strides & `WaitForChild` Paths Before Writing
- Read the target function's definition first. Match exact parameter order and types (`buffer` vs. `vector` vs. `Vector3`, 1-based `EntityId` vs. 0-based byte offset).
- Verify every `:WaitForChild("ModuleName")` target actually exists in the file tree; a missing module causes TestEZ planning to hang with `Infinite yield possible`.

### 4. Isolate Client Specs from the `Controller` Actor VM
- `ClientTestRunner.client.luau` runs in the default client Luau VM, while live gameplay runs inside the `PlayerScripts.Controller` `Actor` VM.
- Always allocate isolated storage via `TestHelper.CreateTestStorage()` or `ECSMain.CreateStorage(false)` and pass it via the target function's `ProvidedStorage` parameter. Never mutate shared `PlayerScripts` storages in unit tests.

### 5. Clean Up Shared Singleton State Before `it(...)` Ends
- If a test touches shared module state (`ServerStorage`, `TextureTable`, `ViewCulling`, `PlayerController`, `PlayerFunctions`), restore or delete all test entries (`DeleteEntity`, `ResetRegistryForTest`, `RemovePlayerState`, `UpdateObserverFromVectors`) before the `it(...)` block returns so suite order never causes cross-test failures.

### 6. Red-Squiggle Rule
- Any red squiggle or static warning in a `.spec.luau` or production `.luau` file (undefined symbol, nil-indexed field, mismatched argument count/type, unused variable, or ambiguous `(` line start) is a **real bug**. Fix it immediately before asking to run Studio (`F5`).
