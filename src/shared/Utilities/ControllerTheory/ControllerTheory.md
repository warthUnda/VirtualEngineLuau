# Control-Theory Resource Orchestrator & Interpreter

## Classification & Domain Terminology
- **Domain:** Closed-Loop Real-Time Frame Budget & Adaptive Quality Control
- **Subsystem:** `ControllerTheory` (`src/shared/Utilities/ControllerTheory/`)
- **Architecture / Memory Model:** Zero-Allocation Singleton State Table (`ResourceController.State`) across Server (`Heartbeat`) and Client (`RenderStepped`)

---

## Architectural Mechanisms

- **Intra-Frame Tracking, 2ms Spike Reserve & Residual Budget (`ControllerTheoryMath`):**
  - Reserves a mandatory **`2.0 ms` (`ControllerFreeTimeReserve = 0.002`)** of untouched free frame time every frame ($T_{\text{usable}} = T_{\text{target}} - 0.002 \approx 14.67\text{ ms}$) so transient spikes never push frames below 60 FPS.
  - Tracks current intra-frame progress (`WhereInFrame = os.clock() - FrameStartClock`) alongside measured feedback from Physics ($T_{\text{phys}}$) and Renderer ($T_{\text{rend}}$).
  - Computes non-managed overhead $T_{\text{other}} = \max(0,\; \max(T_{\text{frame}}, \text{WhereInFrame}) - (T_{\text{phys}} + T_{\text{rend}}))$ and evaluates the signed offset against the usable ceiling:
    $$\Delta T_{\text{other}} = T_{\text{other}} - (T_{\text{target}} - T_{\text{free}})$$
  - Allocates remaining usable budget ($-\Delta T_{\text{other}}$) across normalized runtime Renderer and Physics weights, sharing unused slack within $T_{\text{usable}}$ while never encroaching on the $2.0\text{ ms}$ free-time reserve.
- **Internal Plant-Model Equilibrium & Exponential-Backoff Ceiling Lock (`ControllerTheoryMath.StepChannel`, `ResourceController`):**
  - Eliminates limit-cycle hunting ("adapt down $\rightarrow$ crank back up $\rightarrow$ lag again") via two coupled mechanisms:
    1. **Plant Unit-Cost Internal Model:** Estimates full-scale cost $\hat{T}_{100} = T_{\text{measured}} / f(\text{Score})$ from active pixel area or physics duty fraction and caps upward steps at the exact equilibrium score $S_{\text{eq}}$ where predicted load equals $88\%$ of `AllocatedBudget`—so constant heavy scenes hold flat at $S_{\text{eq}}$ indefinitely.
    2. **Gradual Gain Envelope & Exponential-Backoff Ceiling:** Uses gradual downward steps (`ControllerDownGain = 0.22`, `ControllerMaxDropPerFrame = 0.08`) and 10x gentler upward rewards (`ControllerUpGain = 0.014`, `ControllerMaxRisePerFrame = 0.0055`) while holding post-overrun ceilings for `3.0s–15.0s` before probing `+2` and unlocking immediately on $\ge 30\%$ load drops (`ControllerCeilingUnlockRatio = 0.70`).
- **System ControllerReps (`ControllerReps/PhysicsRep.luau`, `ControllerReps/RenderingRep.luau`):**
  - **`PhysicsRep`:** Owns Physics channel curve registration (`GetLoadFraction`, `ScoreFromLoadFraction`), score/feedback binding (`GetScore`, `GetWeight`, `ReportFeedback`), and deterministic Bresenham entity striding (`Interpret`, `ShouldStepEntity`) without leaking Physics details into `ResourceController` or `ControllerTheoryMath`.
  - **`RenderingRep`:** Owns Software Renderer channel curve registration (`GetLoadFraction`, `ScoreFromLoadFraction`), score/feedback binding (`GetScore`, `GetWeight`, `ReportFeedback`), and area-proportional viewport scaling (`Interpret`) for `RenderService` (`RenderResolutionHelper`, `RenderInstanceMethods`, `RenderFrameDispatchHelper`).
  - `ResourceController` manages generic budget allocation and named channels (`GetChannelScore`, `ReportChannelFeedback`, `BindChannelCurves`) while `ControllerTheoryMath` remains domain-agnostic closed-loop control math.
