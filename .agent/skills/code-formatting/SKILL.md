---
name: render-executer-style
description: Code style and conventions guide derived from RenderController.client.luau. Documents how Luau code in this project's rendering pipeline is formatted, typed, and commented. Read this to match the project's writing conventions when authoring or editing render code.
---
# Render Code Style Guide

Reference file: `src/shared/Utilities/Render/Controller/RenderController.luau`

This is the canonical example of how rendering-pipeline code is written in this
project. Match these conventions when adding or refactoring render code.

## File Header Directives

Every performance-critical script starts with two directives:

```lua
--!strict
--!native
--!optimize 2
```

- `--!native` enables Luau native code generation.
- `--!optimize 2` sets the compiler optimization level.

## Top-Level Section Organization

State and setup are declared in labeled groups, in this order:

1. `-- Services --` — `game:GetService(...)` lookups.
2. `-- Static References --` — player, GUI, camera, actor refs.
3. `-- Libraries --` — anything with functions, libraries or helpers from a modulescript.
4. `-- Storage --` — things with storage, like ECS or tables or buffers from a modulescript.
5. `-- Configs --` — constants derived from config.
6. `-- Tables --` — table and buffer declarations.
7. `-- Buffers` — buffer declarations (note: this header omits the trailing `--`).
8. Local helper functions.
9. Major runtime blocks separated by banner comments (see below).

## Formatting & Layout

### Indentation
Always use **tabs** (never spaces). Nested method chains indent one tab per level:

```lua
const CameraState = require(
	ReplicatedStorage:WaitForChild("Shared")
		:WaitForChild("Utilities")
		:WaitForChild("Render")
		:WaitForChild("Camera")
		:WaitForChild("CameraState")
)
```

### Multi-line calls
When a call has many arguments, put one argument per line with the closing paren
at the base indentation:

```lua
local ClippedVertexCount = RenderMath.ClipAndProjectTriangle(
	ScreenVertices,
	V0TRI,
	V1TRI,
	V2TRI,
	ProjectedVertices,
	ClipBufferA,
	ClipBufferB,
	CamFOV,
	WIDTH,
	HEIGHT
)
```

### Multi-assignment
Declare several names in one statement with inline type annotations per name:

```lua
const WIDTH: number, HEIGHT: number = RenderConfig.GetDimensions2D()
const X0: number, Y0: number = V0.X, V0.Y
```

### Compound assignment
Use `+= 1` (and similar) instead of `x = x + 1`:

```lua
Received += 1
CurrentFrame += 1
```

### Spacing
- Spaces around operators: `(i - 1) * 4`, `WIDTH * 0.5`.
- Space after commas in argument lists; no space inside call parens.
- `continue` is used to bail out of a loop early instead of nesting.

## Typing Conventions

### `const` vs `local`
- `const` for values assigned once: services, references, modules, config constants.
- `local` for mutable state and buffers that change over the frame.

### `::` type ascription
Types are applied with a trailing `::` cast, not a leading annotation:

```lua
const RunService = game:GetService("RunService") :: RunService
local BufferTable = {} :: { buffer }
local ShadowCacheParts = {} :: { BasePart }
```

### Function signatures
Parameters are typed inline; the return type follows the closing paren:

```lua
local function ReadProjectedVertex(VertexIndex: number): Vector3
```

Anonymous callbacks are typed the same way:

```lua
SelfActor:BindToMessage("Return Render Calculations", function(PixelBuffer: buffer, BandIndex: number, DirtyMinY: number, DirtyMaxY: number, FrameId: number)
```

### Loop variables
Generic `for` loop variables are typed inline:

```lua
for i, TargetActor: Actor in ipairs(PlayerScripts:WaitForChild("WorkerFolder"):GetChildren()) do
```

### Modules
Do **not** annotate `require`d modules or `ModuleScript` references with `:: ModuleScript` so Luau preserves the module's exported types and function signatures:

```lua
const BufferIO = require(ReplicatedStorage.Shared.Utilities.Render.Buffer.BufferIO)
```

Sibling modules cloned into the same Actor are required via `script.Parent`:

```lua
const PartStore = require(script.Parent.PartStore)
```

### Table/array types
`{}` literals are annotated with their element type in braces:

```lua
local PartSizeArray = PartStore.GetSizeArray() :: { Vector3 }
local PendingShadowParts = {} :: { BasePart }
```

## Naming Conventions

- **Constants** (config values): `SCREAMING_SNAKE_CASE` — `WIDTH`, `TOTAL_PIXELS`,
  `SUN_DIRECTION`, `AMBIENT_LIGHT`, `MAX_SHADOW_RAYS_PER_FRAME`.
- **Variables** (mutable state, locals, buffers): `PascalCase` — `CurrentFrame`,
  `Received`, `OffsetBuffer`, `BufferTable`, `SmallestValue`, `RenderResult`.
- **Functions**: `PascalCase` — `ReadProjectedVertex`, `QueueShadowSample`.
- **Booleans** read naturally: `Moved`, `Expired`, `FullyInside`, `CachedShadow`.

Known exceptions (do not treat these as the rule): `targetPosition` is camelCase,
and `ActorCount` / `SphereVertices` are PascalCase despite being constants.

## Comment Conventions

### Banner comments (major blocks)
Separate large sections with a full-width `=` rule and an ALL-CAPS, numbered title:

```lua
-- ============================================================================
-- 1. LISTENER - LISTENS TO RETURNING DATA
-- ============================================================================
```

### Group header comments (variable groups)
Short labels mark related declarations:

```lua
-- Services --
-- Static References --
-- Modules --
-- Configs --
-- Tables --
-- Buffers
```

### Inline block comments
One-line comments explain non-obvious intent before a block:

```lua
-- Find the smallest value then increase it
-- Apply changes and create a information buffer for workers
-- Sends the information to all workers workers
```

### Trailing inline comments
Brief clarifications sit at the end of a line:

```lua
const RBOffset = buffer.readu32(OffsetBuffer, (SVIndex - 1) * 4) :: number -- Render buffer memory offset
if FrameId ~= CurrentFrame then -- ignore stale frames
for i = 1, TOTAL_PIXELS do -- Overwrites the FinalZ and FinalPixel buffers
```

### What NOT to comment
Comments are short, technical, and only explain intent or performance. Obvious
mechanics (a `buffer.readf32`, a simple `for`) are left uncommented.

## Idioms & Patterns

- All state lives at module scope (the script runs inside an `Actor`).
- Message in: `SelfActor:BindToMessage("Return Render Calculations", function(...) ... end)`.
- Dispatch out: `TargetActor:SendMessage("Execute Rendering", RenderBuffer, byteCount, CurrentFrame)`.
- Frame loop: `RunService.RenderStepped:Connect(function() ... end)`.
- Deferred init: `task.spawn(function() ... end)`.
- Early exit inside loops with `continue` instead of wrapping in an outer `if`.


## Maintainability and configs

- Once you think there is something worth to add as a config that would get changed alot, add a config to Configs and tell the user
- If the change is somethng that would almost never change like vertex data for a cube, do NOT include it
- Cache it at the top of the script in whatever script the systemConfigs config is asking for as to not hurt performance

- you will see multiple files, put them into whatever category you are doing
- do not add types to module script references via require()

## local functions

- inside a system, if there is a local function put it into a new file thats right next to the main file, it should be a .luau file

- put the local functions in there, name the file Whatever then helper, math, functions or whatever helps it there

## Math

- for mathematical variables like W01 (for triangles in rendering as a example) use a clearer name
- it can be bigger, and should have a descriptive name

## for systems

- use Core as a library, controller as executer, scene for objects etc
- for getting a better idea, look into some systems to see how its done and copy the way we do it

## params
- every function that will be used outside of the system its in, add @param and document its parameters
- if you change it, update it

- for public ends that the consumer would regularly use, do not let them do whatever they want with the params
- ensure conformity, do not use ? unless there are multiple options and force the user to bend to whatever you want
- if the user does not comply you should just leave them and let the compiler hit them like a dumptruck

## documentation
- for every system, make a .md file that is documentation for a specific system
- use terms and classification at the top of the documentation with highly descriptive writing and terminology to make the user understand whats happening immediately

- afterwards, keep it short and describe how its mechanisms work
- update it once you change it

## read me
- if the read me is outdated, empty or just a 10 line template messsage
- look at the project and describe it
- make it short and at the start of the read me use terms and classifications so people would understand it 

## defensive programming
- do not use defensive programming unless managing volatile state like a player that could have a certain part deleted due to ingame death

## if statements
- do not nest deeper than 2 recursions
- if if statements in a block are getting bigger than 5 lines and its not a performance critical system or a part that would not make it matter use a dispatch table thats clean and clear

- always use guard clauses unless its a one line thing or something that would make it clearer like
- if shouldexecute == true then execute()

## line management
- if exceeding 300 lines, use different helpers that are specific until it is under 300 lines
- however, unless its necessary do not do this
- examples include libraries or services

## modules
- When requiring modules for data/storage (`Storage`, `ObjectStorage`, `ECSStorage`), place them under `-- Storage --`.
- When requiring modules for functions, math, or libraries (`RenderMath`, `BVH`, `PhysicsMath`), place them under `-- Modules --` (or `-- Libraries --`).
- Never annotate `require(...)` results with `:: ModuleScript` so Luau preserves exported function and type signatures.

## linting
- Every time you write or modify Luau code, run linting / static verification (`selene` / `luau-lsp` when available, plus symbol/reference and JSON checks) before finishing.
- **Red File / Red Squiggle Rule:** If a file turns red in the IDE with `1` or `2` (or more) red squiggles/problems, treat it as an **actual code/logic issue** (such as an undefined symbol, nil-indexed field, or broken call signature), **never** dismiss it as a "petty type error." Investigate and fix the root cause immediately.
- Ensure strict `--!strict` compliance: zero unused variables, zero dead imports, zero nil-indexed fields, and exact parameter count/type matching across module boundaries.

## Architecture & Performance Guardrails

### 1. Contiguous Buffer Strides & Canonical Layouts
- Derive all ECS buffer byte sizes in `ECSConfig.luau` directly from `ECSMaxEntities * Stride` (never hardcoded round numbers).
- Canonical strides:
  - `PositionData` / `SizeData`: `12` bytes (`3 × f32`: `X, Y, Z`).
  - `DirectionsData`: `36` bytes (`Look` at `0..11`, `Up` at `12..23`, `Right` at `24..35` where `Right = Look × Up`). `OrientationData` aliases `Look` (`0..11`).
  - `VisualData`: `4` bytes (`u32` packed RGBA).
  - `PropertiesData`: `4` bytes (`u32` bitfield: `CanCollide`, `IsVisible`, `Anchored`, `HasDynamicId`, `TextureId`, `ShapeId`, `DynamicId`).

### 2. O(1) Swap-and-Pop Deletion Contract
- `ECSData.DeleteEntity(EntityId)` moves `LastEntityId -> EntityId` in $O(1)$ time.
- Any subsystem indexing per-entity state (`DynamicObjectsList`, `PhysicsController`, `ReplicationReceiver`, `RendererCleaner`) must register a listener via `ECSData.SetSwapPopCallback` (or bidirectional slot maps) so moved tail entities never leave ghost slots or stale IDs.

### 3. Roblox Actor VM Boundaries & Storage Resolution
- `script:GetActor()` returns `nil` for shared `ModuleScript`s in `ReplicatedStorage`, even when `require`d from inside an `Actor` (`Controller` or `ParallelWorker`).
- Never rely on `script:GetActor()` inside `ReplicatedStorage` modules to detect the `Controller` Actor. Resolve `PlayerScripts.Controller.ObjectStorage` first for live client systems, and allow an optional `ProvidedStorage` override for isolated unit tests.
- When sending triangle command batches across Actor VMs (`TargetActor:SendMessage`), copy only the active `ByteCount` (`CompactSlice = buffer.create(ByteCount)`) rather than serializing oversized capacity buffers.

### 4. Zero-Allocation Hot Paths (Render, BVH, Physics, Replication)
- Never allocate Lua tables (`{}`), closures, `RaycastParams.new()`, or `Instance` queries (`workspace:Raycast`) inside per-frame, per-substep, BVH build/traversal, or rasterizer loops.
- Use `BVH.Raycast` and `BVH.QueryAABBScalar` (with pre-allocated `u32` candidate buffers and once-per-substep `BVH.EnsureFresh`) for all spatial queries.
- Do **not** use function dispatch tables inside hot loops (`BVH`, `RenderMath`, `MathModule`, `PhysicsMath`); use inline scalar locals and guard clauses.
