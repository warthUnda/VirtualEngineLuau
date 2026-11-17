# Control-Theory Resource Orchestrator & Interpreter

## Classification & Domain Terminology
- **Domain:** Closed-Loop Real-Time Frame Budget & Adaptive Quality Control
- **Subsystem:** `ControllerTheory` (`src/shared/Utilities/ControllerTheory/`)
- **Architecture / Memory Model:** Zero-Allocation Singleton State Table (`ResourceController.State`) across Server (`Heartbeat`) and Client (`RenderStepped`)

---

## Architectural Mechanisms

- **Intra-Frame Tracking & Residual Frame-Time Budget (`ControllerTheoryMath`):**
  - Tracks current intra-frame progress (`WhereInFrame = os.clock() - FrameStartClock`) alongside measured feedback from Physics ($T_{\text{phys}}$) and Renderer ($T_{\text{rend}}$).
  - Computes non-managed overhead $T_{\text{other}} = \max(0,\; \max(T_{\text{frame}}, \text{WhereInFrame}) - (T_{\text{phys}} + T_{\text{rend}}))$ and evaluates the signed offset against the 60 FPS ($16.67\text{ ms}$) target:
    $$\Delta T_{\text{other}} = T_{\text{other}} - T_{\text{target}}$$
  - Allocates remaining budget ($-\Delta T_{\text{other}}$) with runtime weights **60% Renderer (`0.60`)** and **40% Physics (`0.40`)**, using work-conserving slack sharing when one subsystem is under-utilized while enforcing strict 60/40 isolation under dual contention.
- **Closed-Loop Velocity-Form PI/PD Controller (`ResourceController`):**
  - Outputs integer resource scores in **`[1, 100]`** stored on the singleton `ResourceController.State` table on both Server and Client.
  - Asymmetric attack/recovery gains throttle scores down rapidly on 60 FPS overruns, apply derivative damping to prevent oscillation, hold steady inside a $\pm 3\%$ deadband, and recover smoothly toward `100` when frame headroom returns.
- **Deterministic Mathematical Interpreter (`ControllerInterpreter`):**
  - **Physics (`ShouldStepPhysicsEntity`):** Uses a coprime Bresenham modular accumulator (`((FrameTick * Duty + (EntityId - 1) * 53) % 100) < Duty`, zero `math.random`) to deterministically step awake dynamic parts every frame at score `100`, strictly every 2 frames (50/50 interleaved) at score `50`, down to `ControllerMinPhysicsDutyPercent`.
  - **Renderer (`InterpretRenderer`):** Scales linear viewport dimensions by $\sqrt{\text{AreaFraction}(\text{Score})}$ (quantized to `ControllerResolutionStep` pixels) so total rasterized pixel count scales linearly with the `1..100` score.
