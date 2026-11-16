---
name: render-executer-style
description: Architecture invariants, 250-line modular decomposition, subagent delegation, and strict Luau code/documentation standards for the CustomRenderer engine.
---

# CustomRenderer Architecture, Delegation & Luau Standards

## 1. Agent Roles & Delegation Protocol

### If You Are the Primary Agent (e.g., Carbon / Argon / Pro)
- **Your Responsibility:** Architecture, modular decomposition (<= 250 lines per file), flat deterministic logic, TDD specs, zero-allocation performance, and strict type/syntax safety (Sections **1–4**).
- **Cleaner Subagent Delegation:**
  - Define and invoke a cleaner subagent on the lighter model (`Model: "flash"` / Hydrogen) with write tools enabled to handle tactile formatting, canonical `-- Section --` headers, flat readability refinements, comments, and `*.md` documentation sync (Section **5**).
  - Do **not** poll or check on the subagent after launching it; only message it if you need to terminate it.
  - Pass the cleaner subagent these exact rules:
    1. You are a refinement-only subagent: you may **never** create new systems, change runtime behavior, alter function signatures, or change test assertions.
    2. Refine modified/created files to match `.agent/skills/code-formatting/SKILL.md` (Sections **4** & **5**): enforce canonical `-- Section --` headers (`-- Variables --`, `-- Local Functions --`, `-- Functions --`, etc.), tactically flatten control flow where safe without sacrificing performance or correctness, run `stylua .` if installed, and never introduce leading-`(` statements.

### If You Are the Cleaner Subagent (Hydrogen / Flash)
- Follow Sections **4** and **5** strictly.
- Tactically make code as flat, predictable, and linearly structured as possible to read—**without sacrificing performance, zero-allocation guarantees, type safety, or exact runtime behavior**.
- Never alter algorithms, buffer strides, parameter orders, return values, or test expectations.

---

## 2. Project Structure, 250-Line Cap & File Placement

### Hard 250-Line File Limit & Design Patterns
- **Never write or grow a `.luau` file beyond 250 lines.**
- When a module approaches 250 lines, split responsibilities across smaller, single-purpose `.luau` files using:
  - **Facade Pattern:** Keep a thin public entry module (`init.luau` or `<System>Controller.luau`) that exposes a clean API and delegates implementation steps to focused internal modules.
  - **Gateway Pattern:** Isolate external Roblox boundaries (`RemoteEvent` / `UnreliableRemoteEvent` wiring, `Actor:SendMessage` / `BindToMessage` transport, `AssetService` / `Players` I/O) in a dedicated gateway module separate from pure domain/math logic.
  - **Focused Sub-Modules:** Split distinct stages into dedicated sibling files (`*Helper.luau`, `*Math.luau`, `*Codec.luau`, `*Partition.luau`). Large TestEZ suites should likewise split by sub-feature (`<System><Topic>.spec.luau`), as test runners auto-discover all `*.spec.luau` files.

### Flat & Deterministic Code Architecture
- Author all execution paths to be **flat, linear, and deterministic**:
  - Data flows top-to-bottom through explicit inputs and outputs rather than hidden cross-file side effects.
  - Given identical buffer/input state, functions must produce deterministic, repeatable results (no order-dependent `pairs(...)` iteration when output order matters).
  - Bail out early with guard clauses (`if not Valid then return end` / `continue`) instead of deep conditional pyramids.

### System Folder Taxonomy
Inside each subsystem (`src/shared/Utilities/<System>/`, `src/server/Objects/<System>/`, `src/client/Objects/<System>/`):
- `Core/`: Stateless math, data codecs, and pure algorithms (`ModuleScript`s).
- `Controller/`: Stateful orchestrators, facades, and frame/tick executors (`ModuleScript`s or server/client scripts).
- `Scene/`: Scene synchronization and entity lifecycle cleaners (e.g., `RendererCleaner.client.luau`).
- `Worker/`: Parallel `Actor` worker scripts (e.g., `ParallelWorker.client.luau`).
- `<System>.md`: System architecture documentation (required per system; update whenever mechanisms change).

### Helper File Rule (No Inline System `local function`s)
- Inside production systems (`Core`, `Controller`, `Scene`, `Worker`, `Objects`), do **not** define helper `local function` blocks inside the main script.
- Extract helper functions into a sibling `.luau` `ModuleScript` next to the main file (`<Name>Helper.luau`, `<Name>Math.luau`, `<Name>Functions.luau`).
- *Actor Clone Note:* If a script is cloned into an `Actor` alone by `RenderBootstrap.luau` (e.g., `ReplicationReceiver.client.luau`), require its helper via `PlayerScripts` or `ReplicatedStorage` rather than `script.Parent`.

### Configs (`src/shared/Configs/` & `SystemsConfigs.luau`)
- Put tunable values that users or gameplay may adjust (resolutions, target FPS, sync intervals, capacities, lighting) into `src/shared/Configs/*Config.luau`, re-export through `src/shared/SystemsConfigs.luau`, and notify the user when adding a new config.
- Do **not** put fixed mathematical/geometric constants (e.g., unit cube vertex tables or bitmask shifts) into `Configs/`.
- Always cache config values into `const SCREAMING_SNAKE_CASE` locals at the top of each script—never index `SystemsConfigs` inside loops.

### Client Utility Scripts (`src/client/scripts/`)
- A **"script"** in this folder means a small standalone client automation/convenience `LocalScript` (e.g., forcing `ScreenGui.Enabled = true`, debug mouse lock/unlock toggles via `UserInputService`), **not** gameplay or engine logic.
- Place all such scripts in `src/client/scripts/*.client.luau`.
- Bootstraps and core loops (`Starter.client.luau`, `main.client.luau`, `RenderBootstrap.luau`) stay at `src/client/` root.

---

## 3. Non-Negotiable Engine & Performance Invariants

### 1. Contiguous ECS Buffer Strides & Canonical Layouts
- Derive all ECS buffer byte sizes in `ECSConfig.luau` strictly from `ECSMaxEntities * Stride` (never hardcoded round numbers).
- Canonical per-entity strides (1-based `EntityId` -> byte offset `(EntityId - 1) * Stride`):
  - `PositionData` / `SizeData`: `12` bytes (`3 × f32`: `X, Y, Z`).
  - `DirectionsData`: `36` bytes (`Look` at `0..11`, `Up` at `12..23`, `Right` at `24..35` where `Right = Look × Up`). `OrientationData` aliases `Look` (`0..11`).
  - `VisualData`: `4` bytes (`u32` packed RGBA).
  - `PropertiesData`: `4` bytes (`u32` bitfield: `CanCollide`, `IsVisible`, `Anchored`, `HasDynamicId`, `TextureId` [bits 5..12], `ShapeId` [bits 13..15], `DynamicId` [bits 22..31]).

### 2. $O(1)$ Swap-and-Pop Deletion Contract
- `ECSData.DeleteEntity(EntityId)` compacts buffers in $O(1)$ time by copying `LastEntityId -> EntityId`.
- Unlink the deleted entity's `DynamicId` **before** copying `LastEntityId` into `EntityId`, and verify stored `DynamicId` matches before clearing `PropertiesBuffer`.
- Every subsystem indexing per-entity external state (`DynamicObjectsList`, `PhysicsController`, `PlayerController`, `ReplicationReceiver`, `RendererCleaner`) must register a listener via `ECSData.SetSwapPopCallback` (or maintain bidirectional slot maps) so moved tail entities never leave stale `EntityId`s.

### 3. Roblox `Actor` VM Boundaries & Compact Messaging
- Every `Actor` (`Controller`, `ParallelSetup1..N`) runs an isolated Luau VM with its own copy of required `ModuleScript`s.
- `script:GetActor()` returns `nil` inside `ReplicatedStorage` modules even when required from an `Actor`. Resolve `PlayerScripts.Controller.ObjectStorage` first on the client, and accept an optional `ProvidedStorage: ECSMain.ECSStorage?` override for isolated unit tests.
- Across `Actor:SendMessage(...)` boundaries, copy and send only active bytes (`CompactSlice = buffer.create(ActiveBytes)`), never full-capacity scratch buffers.

### 4. Zero-Allocation Hot Paths & Scanline Invariance
- **Zero heap allocations** inside per-frame, per-substep, BVH build/traversal, replication culling, or rasterizer loops: never allocate `{}` tables, closures, `RaycastParams.new()`, or `workspace:Raycast` calls.
- Use `BVH.Raycast` and `BVH.QueryAABBScalar` (with pre-allocated `u32` candidate buffers and once-per-substep `BVH.EnsureFresh`) for spatial queries.
- Never use function dispatch tables inside hot loops (`BVH`, `RenderMath`, `MathModule`, `PhysicsMath`); inline scalar locals and guard clauses.
- In scanline rasterization (`MathModule.RasterizeTriangleSpan`), step integer scalar edge weights and evaluate row attributes (`RowInverseZ`, `RowUOverZ`, `RowVOverZ`) directly in `f64` per row rather than `f32` `vector.dot` stepping so pixels remain bit-for-bit invariant across dynamic worker band seams.

---

## 4. Mandatory Luau Syntax, Typing & Control-Flow Rules

### File Header Directives & Indentation
Start every engine/system `.luau` file with all three directives, and indent with **tabs**:

```lua
--!strict
--!native
--!optimize 2
```

### Critical Syntax Safety (No Leading Parentheses)
- **Never** start a line with `(` (such as `(Obj :: any).EntityId = Slot` or `(Remote :: RemoteEvent):FireClient(...)` after a previous expression). Luau parses a leading `(` as a function-call continuation of the prior line (`Ambiguous syntax` compile error).
- Always bind a typed local first:
  ```lua
  const LinkedRecord = LinkedObj :: { [string]: any }
  LinkedRecord.EntityId = TargetSlot
  ```

### `const` vs. `local` & Trailing `::` Type Casts
- Use `const` for bindings assigned once (services, module imports, config constants, immutable locals).
- Use `local` only for state or accumulators reassigned later.
- Apply types on variables/literals via trailing `::` casts; type function parameters and return values inline:
  ```lua
  const RunService = game:GetService("RunService") :: RunService
  local WorkerOffsets = table.create(ACTOR_COUNT, 0) :: { number }

  function Helper.StepAccumulator(Current: number, DeltaTime: number): (boolean, number)
  ```
- **Never** cast `require(...)` results with `:: ModuleScript` (preserve exported module types).
- Compound assignments: use `+=`, `-=`, `*=` instead of `x = x + 1`.
- Multi-assignments: annotate each variable inline (`const Width: number, Height: number = ...`).

### Public API Contracts & Defensive Code
- Document every cross-file/exported function with Moonwave `--[=[ ... ]=]` docblocks including `@param` and `@return`, and update them immediately whenever signatures change.
- Enforce strict parameter types on public consumer APIs: do **not** make parameters optional (`?`) unless multiple call shapes are intentionally supported (e.g., `ProvidedStorage: ECSMain.ECSStorage?` for test isolation).
- Do **not** add redundant defensive checks (`if typeof(x) == ...`) on internal typed paths; reserve defensive guards strictly for volatile Roblox state (e.g., disconnecting `Player`, destroyed `Character` parts, or untrusted network buffers from `RemoteEvent`s).

### Control Flow & Nesting
- Maximum `if` nesting depth: **2 levels**. Flatten nested branches into early `return` / `continue` guard clauses.
- Outside performance-critical hot paths, replace `if/elseif` chains longer than 5 branches/lines with a clean dispatch table.

### Linting & Red-Squiggle Rule
- Ensure zero unused variables, zero dead imports, zero nil-indexed fields, and valid `default.project.json` syntax.
- Run `stylua .`, `selene`, and `luau-lsp` whenever available in `PATH`.
- **Red-Squiggle Rule:** Any red IDE error/squiggle is an actual code bug—never dismiss it as a "minor type warning." Fix the root cause immediately.

---

## 5. Canonical File Layout, Naming & Documentation (Cleaner Checklist)

### Top-Level Section Order
Structure every file predictably from top to bottom using these exact `-- Section --` headers (omit any section that has zero declarations in that file):

1. `-- Services --` — `game:GetService(...)` lookups.
2. `-- Static References --` — immutable `LocalPlayer`, `PlayerGui`, `Actor`, and folder references.
3. `-- Libraries --` — `require(...)` imports for stateless/code modules (`ECSMain`, `SystemsConfigs`, `*Helper`, `RenderMath`, `BVH`).
4. `-- Storage --` — `require(...)` imports for data/ECS storage (`ObjectStorage`, `ECSStorage`, `ServerStorage`).
5. `-- Configs --` — `SCREAMING_SNAKE_CASE` constants cached from `SystemsConfigs` or fixed module constants, followed by `export type` definitions.
6. `-- Remote Events --` — `RemoteEvent` / `UnreliableRemoteEvent` lookups.
7. `-- Variables --` — module-scope mutable scalar state (`local CurrentFrame = 0 :: number`, flags, accumulators).
8. `-- Tables --` — module-scope state tables and the exported module table (`local Module = {}`).
9. `-- Buffers` — pre-allocated `buffer.create(...)` declarations (note: no trailing `--`).
10. `-- Local Functions --` — file-private `local function` helpers (only in standalone scripts/specs; production systems place helpers in sibling `*Helper.luau` modules per Section 2).
11. `-- Functions --` & Numbered Runtime Banners — public `Module.FunctionName` definitions, message listeners, and frame loops grouped under numbered banners:
    ```lua
    -- ============================================================================
    -- 1. SECTION TITLE IN ALL CAPS
    -- ============================================================================
    ```

### Cleaner Subagent Tactile Rules
- Enforce the exact `-- Section --` headers above (`-- Variables --`, `-- Tables --`, `-- Local Functions --`, `-- Functions --`, etc.) consistently across touched files.
- Flatten avoidable nesting into linear guard clauses where safe, **without sacrificing performance, allocations, or behavior**.
- Flag or split files that exceed the **250-line** ceiling only when delegated; otherwise preserve public module contracts intact.

### Naming Conventions
- **Config / Fixed Constants:** `SCREAMING_SNAKE_CASE` (`RENDER_TARGET_FPS`, `COMPONENT_STRIDE`).
- **Variables, Tables, Buffers & Functions:** `PascalCase` (`CurrentFrame`, `StagedTriangles`, `DispatchStagedTriangles`).
- **Math Variables:** Use descriptive names (`SignedDoubleTriangleArea`, `InverseTriangleArea`, `RowEdgeWeight`) instead of cryptic abbreviations (`W01`, `Det`).
- **Loop Counters:** Typed inline for iterators (`for i, TargetActor: Actor in ipairs(WorkerActors) do`).

### Comment & Documentation Standards
- **Inline comments:** Short, technical, and explain *why* (intent/invariants), never obvious mechanics (`buffer.readf32`, `i += 1`).
- **System `<System>.md` & `README.md`:**
  - Start with a **Classification & Domain Terminology** block (`Domain`, `Subsystem`, `Architecture` / `Memory Model`) so readers grasp the system immediately.
  - Follow with concise **Architectural Mechanisms** bullets describing how the active code works.
  - Keep `<System>.md` and `README.md` updated whenever architecture or behavior changes.
