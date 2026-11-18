---
name: red-team-penetration
description: Explicit slash-command skill (/red-team-penetration). Orchestrates an autonomous architectural red-teaming and exploit-validation pipeline for game engines, auditing trust boundaries, binary buffer decoders, and server authority with a 3-turn reproduction loop before generating HUMAN_REVIEW_BOARD.md. Never activate passively unless explicitly invoked via /red-team-penetration.
---

# Autonomous Architectural Red-Teaming & Validation Pipeline (Game Engines)

## 1. Strict Invocation & Trigger Rule (Slash-Command Only)

- **EXPLICIT SLASH-COMMAND ONLY:** Do **NOT** activate or run this skill automatically during general coding, bug fixing, planning, or architecture tasks.
- Execute this pipeline **only** when the user explicitly invokes it via the `/red-team-penetration` slash command (or explicitly directs you to run the `/red-team-penetration` pipeline).

---

## 2. Role & Objective

When invoked via `/red-team-penetration`, you act as the **Lead Security Orchestrator**. Your goal is to systematically partition the game engine into isolated trust compartments, dispatch parallel domain subagents to audit every untrusted boundary using strict whitelist verification, empirically test each hypothesis in a **3-turn reproduction loop**, and compile a unified, actionable mitigation dashboard (`HUMAN_REVIEW_BOARD.md`).


### Primary Threat Categories
1. **Server-Side Engine Destruction (DoS / Crash / Memory Corruption):**
   - Out-of-bounds `buffer.read*` / `buffer.write*` / `buffer.copy` operations triggered by truncated payloads or forged header counts.
   - `NaN`, `inf`, `-inf`, or denormal float injection (`f32`/`f64`) poisoning spatial indices (BVH AABB tree degeneracy, infinite traversal loops, raycast hangs) or physics integrators.
   - CPU/memory exhaustion via unthrottled remote event spam, unbounded table allocations, or quadratic state resyncs.
2. **Competitive Gameplay Exploitation (Unfair Advantage / Desync):**
   - **Spatial & Movement Spoofing:** Teleportation, speedhacks, out-of-world clipping, or unvalidated observer/camera frustum spoofing (`ObserverStateEvent` / `PlayerStateEvent`) to bypass view-cone culling and harvest hidden world entities (wallhack/ESP data harvesting).
   - **Entity & Slot Desynchronization:** Forging `ServerId`, `DynamicId`, or free-list slot transitions to corrupt server-to-client state tracking or hijack another player's entity record.
3. **Authority & Replication Boundary Breaches:**
   - Missing ownership checks on `RemoteEvent` / `UnreliableRemoteEvent` handlers (`OnServerEvent`).
   - Trusting client-supplied type shapes, table schemas, or bitfields without explicit whitelist gates.

---

## 3. Four-Phase Execution Pipeline

### Phase 1: Architectural & Trust-Boundary Mapping (Orchestrator)
1. **Map the Topology:** Survey the repository layout (`src/server/`, `src/shared/`, `src/client/`) and trace data flow across all trust boundaries:
   - Network Gateways (`RemoteEvent` / `UnreliableRemoteEvent` listeners, e.g., `ServerReplicationGateway.luau`, `ClientRemotes.luau`).
   - Internal Event Bridges (`EventBus.luau` topics crossing from network receivers into domain controllers).
   - Binary Serialization & Buffer Codecs (`PlayerFunctions.luau`, `PlayerControllerHelper.luau`, `EntityVersionTracker.luau`, `ReplicationReceiverHelper.luau`, `ViewObserverCodec.luau`).
   - Spatial, Physics & ECS Storage Mutators (`ECSMain`, `BVH`, `Physics`, `TextureTable`).
2. **Catalog Untrusted Entry Points:** List every function where external or cross-VM data enters authoritative state, noting implicit assumptions (e.g., assuming a `Payload` is a `buffer` of exact length, assuming `LookVector` is unit-normalized, or assuming `UpdatedCount` matches remaining buffer bytes).

---

### Phase 2: Domain Isolation & Parallel Subagent Auditing
1. **Spawn Isolated Subagents:** Use `invoke_subagent` (`TypeName: "research"` or `TypeName: "self"` in read-only audit mode) in parallel—assigning **one isolated subsystem boundary per subagent** so each agent focuses deeply on a single compartment without context dilution.
2. **Enforce Strict Whitelist Auditing:** Instruct every subagent to audit with a **zero-trust whitelist mentality**:
   - Every untrusted input must pass explicit positive validation gates (`typeof(x) == "buffer"`, exact or minimum `buffer.len(x)` checks before every offset read, finite `x == x and math.abs(x) ~= math.huge` checks, range/norm clamping, and player/entity ownership verification).
   - Absence of an explicit validation gate before a buffer read, table index, or state mutation is a structural finding.
3. **Required Subagent Output Schema:** Require each subagent to return findings strictly as a structured JSON array:
   ```json
   [
     {
       "id": "RT-REP-01",
       "subsystem": "Replication / Binary Delta Decoder",
       "severity": "CRITICAL | HIGH | MEDIUM | LOW",
       "category": "SERVER_CRASH | GAMEPLAY_EXPLOIT | AUTHORITY_BREACH | DESYNC",
       "target_file": "src/client/Objects/Replication/ReplicationReceiverHelper.luau",
       "function_name": "IngestPayload",
       "line_range": "184-226",
       "vulnerability_mechanism": "ReadOffset advances by COMPONENT_STRIDE (12) or 24 bytes per set bit in Mask without checking if ReadOffset + Stride <= PayloadLen, allowing a truncated packet with high Mask bits to throw an out-of-bounds buffer access error.",
       "preconditions": "Malformed or truncated replication buffer where header UpdatedCount > 0 and Mask has component bits 1..16 set, but remaining bytes are fewer than the sum of enabled component strides.",
       "proposed_payload": "8-byte header with UpdatedCount = 1, followed by 3-byte record (ServerId = 1, Mask = 0x1F) and 0 component bytes (total 11 bytes)."
     }
   ]
   ```

---

### Phase 3: Automated Validation Loop (3-Turn Empirical Verification Budget)
For each unique finding returned by the subagents, the Orchestrator empirically tests whether the vulnerability is exploitable against the real codebase modules:

1. **Select the Verification Harness:**
   - **Preferred (Live / Studio MCP Execution):** If a Roblox Studio MCP session (`execute_luau`) or the project's `TestHarness.luau` / TestEZ runner is available, execute a self-contained reproduction snippet directly against the real required `ModuleScript` using isolated test storage (`ECSMain.CreateStorage(false)` or `TestHelper.CreateTestStorage()`) so live state is never polluted.
   - **Fallback (Static Trace & Symbolic Proof):** If no live Luau runtime is connected, construct the exact reproduction script and perform a deterministic instruction-by-instruction boundary trace of the target function with concrete byte offsets and register values.
2. **Iterative -Turn Budget per Finding:**
   - **Turn 1:** Draft and execute the initial exploit payload (e.g., malformed `buffer`, `NaN` vector, out-of-range `ServerId`, or spoofed `Player` state packet) against the target boundary function.
   - **Turn 2 (if Turn 1 did not trigger):** Refine packet header fields, bitmasks, or pre-seeded storage state to bypass outer guard clauses and reach the vulnerable inner line.
   - **Turn 3 (if Turn 2 did not trigger):** Final payload mutation attempt (e.g., boundary off-by-one byte lengths or degenerate float combinations).
3. **Strict Classification Rule:**
   - **`[VERIFIED EXPLOIT]`**: The payload deterministically triggers an unhandled runtime error/crash, corrupts ECS/storage memory, bypasses server authority, or yields unauthorized state/vision advantage within $\le 3$ turns.
   - **`[THEORETICAL RISK]`**: The code lacks a defensive gate or relies on caller invariants, but existing upstream guards or runtime constraints prevented reproduction within the 3-turn budget.

4. always start the game first and then run the command to see if its actually crashing things

5. if the client tries to cause itself issues or crashes itself and it does NOT get advantages, leave them fucked because they arent our customer really
---

### Phase 4: Human-in-the-Loop Mitigation Dashboard (`HUMAN_REVIEW_BOARD.md`)
Aggregate all results into `HUMAN_REVIEW_BOARD.md` at the repository root (unless the user specifies another path). Do **not** modify production `.luau` files during a red-team audit unless the user explicitly asks to apply the fixes—provide drop-in Luau remediation blocks inside the report instead.

Structure `HUMAN_REVIEW_BOARD.md` with:
1. **Executive Summary & Threat Matrix:** Total compartments audited, counts of `[VERIFIED EXPLOIT]` vs. `[THEORETICAL RISK]` ordered by severity (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`).
2. **Trust-Boundary Architecture Diagram:** Mermaid `flowchart LR` illustrating client-to-server remotes, `EventBus` bridges, and where validation gates failed.
3. **Verified Exploits Section:** For every `[VERIFIED EXPLOIT]`:
   - Clickable file and line-range link (`[ModuleName.luau](file:///.../ModuleName.luau#L10-L25)`).
   - Attack Vector & Impact (Server Crash, Wallhack/Culling Bypass, Teleport/Desync, etc.).
   - Exact Reproduction Payload / Proof-of-Concept Luau snippet and observed failure output.
   - **Drop-In Luau Patch:** Copy-ready replacement code adhering strictly to `.agent/skills/code-formatting/SKILL.md` (`--!strict`, `const`, flat guard clauses, zero allocations).
4. **Theoretical Risks & Hardening Recommendations:** Findings that did not trigger within 3 turns but merit defense-in-depth hardening.

---

## 4. Subagent Prompt Template

When spawning domain subagents in Phase 2, use this concrete prompt template:

```text
ROLE: Domain Security Gatekeeper (Red-Team Auditor)
TARGET COMPARTMENT: [SUBSYSTEM_NAME]
FILES IN SCOPE:
[EXPLICIT_LIST_OF_LUAU_FILE_PATHS]

DIRECTIVE:
You are auditing an isolated compartment of a high-performance Luau game engine.
Assume ALL incoming network buffers, EventBus payloads, player references, and cross-module parameters entering this compartment are 100% untrusted and controlled by a malicious client.

AUDIT CHECKLIST (STRICT WHITELIST MENTALITY):
1. Buffer Bounds Safety: Before every buffer.read*, buffer.write*, or buffer.copy call, verify whether an explicit length check guarantees the offset + read_size <= buffer.len(buf). Check loop counters (e.g., UpdatedCount) and variable-length bitmask strides against remaining buffer bytes.
2. Float & Math Integrity: Check whether f32/f64 values decoded from buffers or vectors can be NaN (x ~= x), +inf, -inf, or zero-length vectors (division by zero during normalization, degenerate cross products, or corrupting BVH AABB bounds).
3. Entity & Slot Bounds: Check whether 1-based EntityId, ServerId, or DynamicId indices are validated against [1, MaxEntities] and ActiveFlags before indexing buffers or mutating free-list slots.
4. Authority & Rate/State Abuse: Check if a malicious client can spoof observer frustums, force excessive allocations, or overwrite another player's state.

OUTPUT FORMAT:
Return ONLY a valid JSON array matching the Phase 2 schema (id, subsystem, severity, category, target_file, function_name, line_range, vulnerability_mechanism, preconditions, proposed_payload) with exact 1-based line numbers.
```
