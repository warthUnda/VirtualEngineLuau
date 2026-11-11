---
name: render-executer-style
description: Code style and conventions guide derived from RenderController.client.luau. Documents how Luau code in this project's rendering pipeline is formatted, typed, and commented. Read this to match the project's writing conventions when authoring or editing render code.
---
# Render Code Style Guide

Reference file: `src/shared/Utilities/Render/Controller/RenderController.client.luau`

This is the canonical example of how rendering-pipeline code is written in this
project. Match these conventions when adding or refactoring render code.

## File Header Directives

Every performance-critical script starts with two directives:

```lua
--!native
--!optimize 2
```

- `--!native` enables Luau native code generation.
- `--!optimize 2` sets the compiler optimization level.

## Top-Level Section Organization

State and setup are declared in labeled groups, in this order:

1. `-- Services --` — `game:GetService(...)` lookups.
2. `-- Static References --` — player, GUI, camera, actor refs.
3. `-- Modules --` — `require(...)` calls.
4. `-- Configs --` — constants derived from config.
5. `-- Tables --` — table and buffer declarations.
6. `-- Buffers` — buffer declarations (note: this header omits the trailing `--`).
7. Local helper functions.
8. Major runtime blocks separated by banner comments (see below).

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
SelfActor:BindToMessage("Return Render Calculations", function(PixelBuffer: buffer, ZBuffer: buffer, FrameId: number)
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

### Performance notes
Expensive regions are flagged with their measured cost:

```lua
-- 2.5 miliseconds part here:
-- 1.49 miliseconds part here:
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

- Once you think there is something worth to add as a config that would get changed alot, add a config to SystemConfigs and tell the user
- If the change is somethng that would almost never change like vertex data for a cube, do NOT include it
- Cache it at the top of the script in whatever script the systemConfigs config is asking for as to not hurt performance

- do not add types to module script references via require()