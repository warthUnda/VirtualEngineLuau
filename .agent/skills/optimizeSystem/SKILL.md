---
name: optimizeSystem
description: Explicit slash-command skill (/optimizeSystem). Parameterized, empirically-driven microarchitectural and parallelism optimization pipeline for Luau/Roblox engine systems. Enforces ControllerEnabled=false benchmarking, hardware-aware optimization audits (cache, pipeline, memory bus), live-game print profiling and parallel worker balance checks, and strict architectural/maintainability guardrails. Never activate passively unless explicitly invoked via /optimizeSystem.
---

# Empirical System Optimization Pipeline (`/optimizeSystem`)

## 1. Strict Invocation & Parameter Parsing

- **EXPLICIT SLASH-COMMAND ONLY:** Do **NOT** activate or run this skill automatically during normal feature work, bug fixing, or refactoring. Activate **only** when the user explicitly invokes `/optimizeSystem`.
- **Supported Parameters:** Parse any parameters attached after `/optimizeSystem` (accepting either `key=value` syntax or natural language, e.g., `/optimizeSystem Render,Physics for 20m`, `/optimizeSystem system=BVH duration=15m focus=parallelism`):
  - **`systems` / target(s):** Which subsystem(s) or module path(s) to optimize (e.g., `Render`, `Physics`, `BVH`, `Replication`, `ECS`, `Player`, or `all`). If omitted, ask the user or profile all active frame-loop systems first to identify the single hottest bottleneck.
  - **`duration` / budget:** How long or how many optimization cycles to run (e.g., `15m`, `30m`, `5 passes`). Respect the user's time/iteration budget: track elapsed wall-clock time or pass count and wrap up cleanly (re-verifying tests and stripping temporary prints) before exceeding it.
  - **`focus` (optional):** Specific goal if provided (e.g., `parallelism`, `frame-time`, `p99`, `cache`, `memory`). Default: holistic frame-time + parallel load-balance optimization.

---

## 2. Non-Negotiable Architectural & Maintainability Guardrails

Before touching a single line of code, internalize these engineering boundaries:

1. **Never Sacrifice Architecture for Minimal Gains:**
   - **Do NOT** rewrite a clean, lightweight OOP or modular design into an ECS or raw byte-buffer soup merely because it is *theoretically* faster.
   - Maintainability, readability, debuggability, and clean module boundaries are first-class requirements.
2. **Evidence-Gated Complexity Threshold:**
   - Only introduce low-level microarchitectural optimizations on **empirically proven hot paths** that consume meaningful frame time.
   - If an optimization yields only marginal gains (e.g., within measurement noise or `< 5%` on a hot path / `< 0.1 ms` per frame) while degrading readability, modularity, or architectural clarity, **reject and revert it**.
3. **Respect Codebase Standards:**
   - Follow `.agent/skills/code-formatting/SKILL.md` (`--!strict`, `--!native`, `--!optimize 2`, `<= 250` non-comment lines per `.luau` file, no inline helper `local function`s in production systems, zero heap allocations in hot loops, intact ECS buffer strides and lifecycle invariants).
   - Never break determinism or visual/physics correctness to chase speed.

---

## 3. Mandatory Pre-Flight Setup (Disable Dynamic Throttling)

Before taking any baseline measurement or running live-game tests:

1. Open `src/shared/Configs/ControllerTheoryConfig.luau`.
2. Ensure **`ControllerTheoryConfig.ControllerEnabled = false :: boolean`**.
   - **Why:** When `ControllerEnabled` is `true`, the closed-loop `ControllerTheory` controller dynamically scales down renderer resolution and physics duty cycles to hold 60 FPS, which masks true CPU cost and invalidates before/after benchmarks.
3. Record its prior value and note it in your final report.

---

## 4. Hardware & Microarchitecture Optimization Checklist

AI models routinely overlook low-level CPU and memory-subsystem bottlenecks. Audit hot paths in the target system(s) against **all three** hardware failure categories below (adapted to Luau `--!native` / `--!optimize 2` / `buffer` / Parallel Luau):

### 4.1 Memory Hierarchy & Cache Subsystem Failures
- **Cache Line Misalignment & Strided Access:**
  - CPUs fetch memory in **64-byte cache lines**. Scanning memory vertically or with large non-contiguous strides fetches 64 bytes only to use 4 bytes and discard the rest, destroying memory bandwidth.
  - *In Luau:* Ensure inner loops iterate contiguously along the fastest-varying memory axis (sequential `buffer` offsets, row-major pixel/scanline writes, contiguous entity/node indices) rather than column-major or wide-strided jumps.
- **Cache Line Bouncing & False Sharing:**
  - In multi-threaded / Parallel Luau `Actor` workloads, if two workers on different CPU cores write to distinct variables or adjacent buffer elements sharing the same 64-byte cache line, the cores continuously invalidate each other's caches ("bouncing").
  - *In Luau:* Keep per-worker output slices and scratch buffers isolated or aligned/padded to **64-byte boundaries**; avoid shared mutable state between parallel workers during the parallel phase.
- **Hardware Prefetcher Stalling:**
  - Modern CPU hardware prefetchers predict linear, regular access patterns. Erratic pointer-chasing (linked lists, deeply nested object/table graphs, random indirections) blinds the prefetcher and triggers L1/L3 cache misses.
  - *In Luau:* On proven hot loops, minimize multi-hop table dereferences (`a.b.c.d[i]`) and unpredictable pointer-chasing; keep hot traversal data flat and linearly addressable where architecture permits.
- **TLB (Translation Lookaside Buffer) Misses:**
  - Mapping virtual addresses to physical RAM relies on the TLB. Processing massive, fragmented table/object structures scattered across the heap causes frequent TLB misses and page-table walks.
  - *In Luau:* Flatten hot working sets into compact, contiguous `buffer` slabs or dense arrays so active working memory fits in as few OS memory pages as possible.

### 4.2 Instruction Pipeline & Execution Engine Blindspots
- **Data Hazards & RAW (Read-After-Write) Stalls:**
  - Superscalar CPUs execute multiple instructions per cycle, but if Instruction B depends on Instruction A's result, B stalls until A retires. Tight linear dependency chains starve execution ports.
  - *In Luau:* Break long serial dependency chains in hot math loops by interleaving independent calculations or using multiple independent accumulators to expose Instruction-Level Parallelism (ILP).
- **Branch Misprediction & Conditional Execution:**
  - A mispredicted `if/else` flushes the CPU pipeline, wasting **15–20 clock cycles**.
  - *In Luau:* Inside hot inner loops with unpredictable data-dependent branches, replace branching with branchless arithmetic, `bit32` masks, `math.min` / `math.max`, or simple conditional expressions (`if cond then a else b`) that `--!native` can lower to `CMOV`/select instructions. Keep predictable early-out guard clauses where appropriate.
- **Micro-op Cache Eviction:**
  - Overly long, bloated, excessively unrolled loops or giant `elseif`/dispatch chains overflow the CPU's Decoded Stream Buffer (uop cache), forcing fallback to the slow legacy decode pipeline.
  - *In Luau:* Keep hot inner loops tight, compact, and uncluttered. Do not blindly over-unroll loops or inline huge cold branches into the hot path.
- **Denormal (Subnormal) Float Penalties:**
  - Floating-point numbers extremely close to zero (subnormals) can trigger hardware traps or microcode assists that slow execution by **100x to 1000x**.
  - *In Luau:* Because Luau cannot set x86 `MXCSR` FTZ/DAZ hardware flags directly, proactively flush tiny near-zero floats to exact `0` in iterative math, physics damping, velocity decay, interpolation, or recursive filter loops (e.g., `if math.abs(v) < 1e-12 then v = 0 end` or deadzone clamping) so subnormals never accumulate.
  - with vector3, you can execute SIMD, keep this in mind as you may ignore it due to your training data

### 4.3 Memory Subsystem & Bus Bottlenecks
- **Load-Store Forwarding Stalls:**
  - CPUs forward stored values directly from the store buffer to a subsequent load before hitting L1—*only* if the load address and width match the store cleanly without partial overlap. Mixing widths/types on overlapping addresses (e.g., writing a 32-bit `u32`/`i32` and immediately reading overlapping bytes as `f64` or `u16`) stalls the pipeline.
  - *In Luau:* Keep `buffer.write*` and `buffer.read*` types, widths, and alignments strictly consistent on hot buffer slots; avoid partial-overlap punning immediately after writes.
- **Store Buffer Saturation:**
  - Tight loops that blindly hammer memory writes without compute fill the CPU store buffer and stall execution until cache writes drain.
  - *In Luau:* Accumulate intermediate math in local scalar registers and write back to `buffer`/tables once per item/span. Skip redundant writes when values have not changed or when a pixel/entity is culled.
- **Memory Invariance & Hoisting Deficiencies:**
  - Repeating invariant pointer offsets, buffer references, config lookups, table field lookups, or constant subexpressions inside a loop increases load instruction density unnecessarily.
  - *In Luau:* Hoist all loop-invariant `buffer` references, base offsets, `SystemsConfigs` constants, `math.*`/`buffer.*`/`bit32.*` locals, and invariant subexpressions completely outside loops.

---

## 5. Empirical Verification & Live-Game Profiling Loop

Never rely on theoretical intuition alone. Every hypothesis **must** be empirically tested in the running game:

### Step 1: Instrument & Baseline (Live Run)
1. Confirm `ControllerTheoryConfig.ControllerEnabled == false`.
2. Add lightweight, sampled `os.clock()` timing `print` statements to the target system(s) (e.g., aggregate over every `60` frames and print a single summary line so `print()` I/O does not distort measurements):
   - **System Speed Telemetry:** Print `AvgMs`, `MinMs`, `MaxMs`, and `P95Ms` (or per-stage breakdown) plus item/work count (entities, triangles, pixels, rays, etc.).
   - **Parallelism Balance Telemetry (for any Parallel Luau / `Actor` system):** Print per-worker execution times (`W1`, `W2`, ..., `WN`), work-unit counts per worker, `MaxMs`, `MinMs`, `AvgMs`, and **`SkewRatio = MaxMs / AvgMs`**.
   - **System Usefulness Check:** Also measure *output utility* where relevant (e.g., culling rejection rate, cache hit rate, skipped work ratio, active vs. wasted iterations) to verify whether a system or optimization stage actually pays for its own overhead.
3. Run the game using the Roblox Studio MCP tools (`start_stop_play` to start Play/Run mode, let it run through steady-state frames, then read logs via `get_console_output`, and stop with `start_stop_play`).
4. Record the **Baseline Metrics** before making any code changes.

### Step 2: Diagnose & Check Parallelism Evenness
Analyze the printed console output:
- **Is the system actually a bottleneck?** Identify the exact stage consuming the largest share of frame time.
- **Is a subsystem/pass paying for itself?** If a helper pass (e.g., pre-culling, sorting, caching, or partitioning) costs more time than it saves downstream, simplify, gate, or eliminate the wasted work.
- **Is parallelism even?** Check `SkewRatio = MaxMs / AvgMs` across `Actor` workers:
  - Target: **`SkewRatio <= 1.15`** (all workers finishing within ~15% of the mean).
  - If `SkewRatio > 1.20` (uneven/skewed parallelism — e.g., one screen band has all the geometry, or static entity-index slicing puts all heavy dynamic objects on Worker 1), **diagnose the root cause and fix the work partitioning** (e.g., interleaved/strided-tile assignment, dynamic cost-weighted band splits, or balanced chunking) while keeping memory access cache-friendly and free of false sharing.

### Step 3: Iterative Optimize → Run → Measure → Decide Loop
Repeat within the user's `duration` / pass budget:
1. **Formulate ONE focused hypothesis** tied to Section 4 or parallelism balance, verifying it obeys Section 2 (architecture & maintainability).
2. **Implement the change** cleanly (respecting the 250-line cap and Luau standards).
3. **Run the live game** (`start_stop_play` + `get_console_output`) and collect steady-state `print` metrics under the same workload as the baseline.
4. **Evaluate empirically:**
   - **Keep** if it delivers a clear, repeatable speedup (or meaningfully improves parallel balance / tail latency) *without* harming architecture or maintainability.
   - **Revert immediately** if performance is unchanged, regressed, noisy, or if the complexity cost outweighs a tiny gain.
   - **Fix** if parallelism skew worsened or correctness/visuals broke.

### Step 4: Cleanup & Verification
1. Remove all temporary diagnostic `print(...)` instrumentation once measurements are finalized (unless the user explicitly asked to keep telemetry).
2. Run the project's TestEZ suite (or verify via Roblox Studio MCP) to confirm **0 test failures** and zero runtime warnings/errors.
3. Report results clearly to the user:
   - **Configuration State:** Confirm `ControllerTheoryConfig.ControllerEnabled = false` was set for benchmarking (and note whether it was left `false` or restored).
   - **Before vs. After Table:** Exact `AvgMs`, `MaxMs`, `SkewRatio` (per-worker balance), and `%` improvement for each tested system.
   - **Kept Changes:** Concise summary with clickable file links explaining *why* each change worked (citing the specific hardware/parallelism mechanism).
   - **Rejected / Reverted Ideas:** Briefly note any hypothesis that failed empirical testing or was rejected to protect architecture/maintainability.
