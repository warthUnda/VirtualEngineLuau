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

ControllerTheoryConfig.ControllerTargetFPS = 60 :: number
-- Target frames per second maintained by the closed-loop resource controller.

ControllerTheoryConfig.ControllerTargetFrameTime = (1 / ControllerTheoryConfig.ControllerTargetFPS) :: number
-- Target frame duration in seconds (1 / 60 = 0.0166667s).

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

-- Closed-Loop Feedback Gains --

ControllerTheoryConfig.ControllerDownGain = 18.0 :: number
-- Proportional step-down gain applied when a subsystem exceeds its available 60 FPS frame budget.

ControllerTheoryConfig.ControllerUpGain = 4.0 :: number
-- Proportional step-up recovery gain applied when frame headroom is available below 16.67ms.

ControllerTheoryConfig.ControllerDerivativeGain = 3.0 :: number
-- Derivative damping gain applied to frame-error rate of change to suppress score hunting.

ControllerTheoryConfig.ControllerErrorDeadband = 0.03 :: number
-- Normalized budget error deadband (+/-3% of 16.67ms) where scores hold steady without jitter.

ControllerTheoryConfig.ControllerMaxDropPerFrame = 25.0 :: number
-- Maximum downward score step per single frame to prevent transient scheduler spikes from slamming to 1.

ControllerTheoryConfig.ControllerMaxRisePerFrame = 10.0 :: number
-- Maximum upward score recovery step per single frame.

-- Interpreter Bounds (Renderer & Deterministic Physics) --

ControllerTheoryConfig.ControllerMinResolutionScale = 0.25 :: number
-- Minimum linear resolution multiplier at score 1 (25% width x 25% height = 6.25% pixel count).

ControllerTheoryConfig.ControllerResolutionStep = 4 :: number
-- Pixel alignment quantum for dynamically scaled viewport dimensions to avoid per-frame EditableImage churn.

ControllerTheoryConfig.ControllerMinViewportDim = 32 :: number
-- Minimum allowed scaled pixel width or height when BaseWidth/BaseHeight exceed 32.

ControllerTheoryConfig.ControllerMinPhysicsDutyPercent = 10 :: number
-- Minimum active part percentage per frame at score 1 (10% = deterministic stride of every 10 frames).

ControllerTheoryConfig.ControllerMaxPhysicsDtScale = 2.0 :: number
-- Maximum substep delta-time multiplier applied to frame-strided dynamic parts to preserve fall speed without tunneling.

return ControllerTheoryConfig
