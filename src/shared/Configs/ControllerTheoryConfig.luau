--!strict
--!native
--!optimize 2

--[=[
	@class ControllerTheoryConfig
	Tunable control-theory parameters for frame-budget target tracking, 60/40 runtime resource
	weighting, PI/PD feedback gains, dynamic renderer resolution bounds, and deterministic physics striding.
]=]

-- Tables --
local ControllerTheoryConfig = {}

-- Frame Target & Runtime Resource Weights --

ControllerTheoryConfig.ControllerEnabled = false :: boolean
-- Enables or disables closed-loop ControllerTheory resource throttling; when false, scores stay locked at ControllerMaxScore.

ControllerTheoryConfig.ControllerTargetFPS = 60 :: number
-- Target frames per second maintained by the closed-loop resource controller.

ControllerTheoryConfig.ControllerTargetFrameTime = (1 / ControllerTheoryConfig.ControllerTargetFPS) :: number
-- Target frame duration in seconds (1 / 60 = 0.0166667s).

ControllerTheoryConfig.ControllerFreeTimeReserve = 0.002 :: number
-- Mandatory unused free frame time in seconds (2.0 ms) reserved every frame to absorb spikes without missing 60 FPS.

ControllerTheoryConfig.ControllerRendererWeight = 0.60 :: number
-- Runtime frame-budget weight assigned to the software renderer (60%).

ControllerTheoryConfig.ControllerPhysicsWeight = 0.40 :: number
-- Runtime frame-budget weight assigned to the physics engine (40%).

ControllerTheoryConfig.ControllerMinScore = 1 :: number
-- Minimum resource allocation score output by the controller (1 out of 100).

ControllerTheoryConfig.ControllerMaxScore = 100 :: number
-- Maximum resource allocation score output by the controller (100 out of 100).

ControllerTheoryConfig.ControllerInitialScore = 100 :: number
-- Initial resource allocation score before frame-time feedback reduces resources.

-- Closed-Loop Feedback Gains (Aggressive Downward Optimization & Conservative Rewards) --

ControllerTheoryConfig.ControllerDownGain = 1.25 :: number
-- Aggressive proportional step-down gain when exceeding usable frame budget.

ControllerTheoryConfig.ControllerUpGain = 0.014 :: number
-- Gradual proportional step-up reward gain (10x gentler than fast recovery) when headroom is available.

ControllerTheoryConfig.ControllerDerivativeGain = 0.25 :: number
-- Derivative damping gain applied to frame-error rate of change to react quickly to rising spikes and suppress hunting.

ControllerTheoryConfig.ControllerErrorDeadband = 0.02 :: number
-- Tighter normalized budget error deadband (+/-2% of 16.67ms) so optimization kicks in sooner.

ControllerTheoryConfig.ControllerMaxDropPerFrame = 0.25 :: number
-- Maximum downward score step per frame (99 / 0.25 = 396 frames = ~6.6s minimum full drop at 60 FPS under severe lag).

ControllerTheoryConfig.ControllerMaxRisePerFrame = 0.0055 :: number
-- Maximum upward reward step per frame (10x reduced: 99 / 0.0055 = 18,000 frames = ~300s minimum full recovery at 60 FPS).

ControllerTheoryConfig.ControllerEquilibriumBudgetRatio = 0.82 :: number
-- Target fraction of allocated usable budget predicted by the plant internal model so steady state stays safely below the lag threshold.

ControllerTheoryConfig.ControllerUpscaleHeadroomDeadband = 0.08 :: number
-- Minimum normalized positive budget margin (+8% of frame period) required before rewarding resource scores upward.

ControllerTheoryConfig.ControllerBaseCeilingHoldFrames = 300 :: number
-- Initial stable frame count (~5.0s at 60 FPS) to hold a post-overrun safe ceiling before cautiously probing upward.

ControllerTheoryConfig.ControllerMaxCeilingHoldFrames = 1800 :: number
-- Maximum exponential-backoff hold duration (~30.0s at 60 FPS) after repeated ceiling hits in a heavy scene.

ControllerTheoryConfig.ControllerCeilingProbeStep = 2.0 :: number
-- Score increment tested per ceiling probe after HoldTargetFrames of uninterrupted stability.

ControllerTheoryConfig.ControllerCeilingUnlockRatio = 0.70 :: number
-- Per-unit plant cost ratio (<= 70%, i.e., >= 30% genuine load drop) that unlocks a post-overrun ceiling immediately.

-- Interpreter Bounds (Renderer & Deterministic Physics) --

ControllerTheoryConfig.ControllerMinResolutionScale = 0.20 :: number
-- Minimum linear resolution multiplier at score 1 (20% width x 20% height = 4% pixel count).

ControllerTheoryConfig.ControllerResolutionStep = 4 :: number
-- Pixel alignment quantum for dynamically scaled viewport dimensions to avoid per-frame EditableImage churn.

ControllerTheoryConfig.ControllerMinViewportDim = 32 :: number
-- Minimum allowed scaled pixel width or height when BaseWidth/BaseHeight exceed 32.

ControllerTheoryConfig.ControllerMinPhysicsDutyPercent = 5 :: number
-- Minimum active part percentage per frame at score 1 (5% = deterministic stride of every 20 frames).

ControllerTheoryConfig.ControllerMaxPhysicsDtScale = 2.0 :: number
-- Maximum substep delta-time multiplier applied to frame-strided dynamic parts to preserve fall speed without tunneling.

return ControllerTheoryConfig
