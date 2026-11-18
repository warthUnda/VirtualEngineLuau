--!strict
--!native
--!optimize 2

--[=[
	@class ResourceControllerHelper
	Helper module for ResourceController managing pre-allocated channel state construction,
	in-place channel resets, and VSync-aware active frame duration resolution.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage

-- Static References --
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const ControllerTheoryRoot = script.Parent.Parent

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ControllerTheoryMath = require(ControllerTheoryRoot:WaitForChild("Core"):WaitForChild("ControllerTheoryMath"))

-- Configs --
const INITIAL_SCORE = SystemsConfigs.ControllerInitialScore :: number
const BASE_HOLD_FRAMES = SystemsConfigs.ControllerBaseCeilingHoldFrames :: number

-- Tables --
local ResourceControllerHelper = {}

-- Functions --
-- ============================================================================
-- 1. CHANNEL STATE LIFECYCLE & VSYNC-AWARE FRAME SPAN RESOLUTION
-- ============================================================================

--[=[
	Allocates a single mutable ChannelState table for either Physics or Renderer.
	@param IsPhysics boolean -- True for Physics channel; false for Renderer channel.
	@return ControllerTheoryMath.ChannelState -- Initialized mutable channel record.
]=]
function ResourceControllerHelper.CreateChannelState(IsPhysics: boolean): ControllerTheoryMath.ChannelState
	return {
		IsPhysics = IsPhysics,
		RawScore = INITIAL_SCORE,
		Score = INITIAL_SCORE,
		PreviousError = 0,
		CeilingScore = INITIAL_SCORE,
		CeilingUnitCost = 0,
		StableFrames = 0,
		HoldTargetFrames = BASE_HOLD_FRAMES,
		ProbingCeiling = false,
	}
end

--[=[
	Resets an existing ChannelState table in place without allocating a new table.
	@param Channel ControllerTheoryMath.ChannelState -- Target channel record to reset.
]=]
function ResourceControllerHelper.ResetChannelState(Channel: ControllerTheoryMath.ChannelState)
	Channel.RawScore = INITIAL_SCORE
	Channel.Score = INITIAL_SCORE
	Channel.PreviousError = 0
	Channel.CeilingScore = INITIAL_SCORE
	Channel.CeilingUnitCost = 0
	Channel.StableFrames = 0
	Channel.HoldTargetFrames = BASE_HOLD_FRAMES
	Channel.ProbingCeiling = false
end

--[=[
	Resolves the effective frame duration for controller stepping, ignoring idle 60 Hz VSync
	wait time unless the scheduler frame genuinely exceeded the 60 FPS window beyond jitter (8%).
	@param SchedulerDeltaTime number -- Raw RenderStepped or Heartbeat DeltaTime in seconds.
	@param ActiveWorkSpan number -- Measured active execution work in seconds.
	@param TargetFrameTime number -- Target frame period (1 / 60).
	@return number -- Effective frame time in seconds for budget calculation.
]=]
function ResourceControllerHelper.ResolveEffectiveFrameTime(
	SchedulerDeltaTime: number,
	ActiveWorkSpan: number,
	TargetFrameTime: number
): number
	if SchedulerDeltaTime > TargetFrameTime * 1.08 then
		return math.max(SchedulerDeltaTime, ActiveWorkSpan)
	end
	return ActiveWorkSpan
end

return ResourceControllerHelper
