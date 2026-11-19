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
const RunService = game:GetService("RunService") :: RunService

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
	Allocates a single mutable ChannelState table for a managed subsystem channel.
	@return ControllerTheoryMath.ChannelState -- Initialized mutable channel record.
]=]
function ResourceControllerHelper.CreateChannelState(): ControllerTheoryMath.ChannelState
	return {
		RawScore = INITIAL_SCORE,
		Score = INITIAL_SCORE,
		PreviousError = 0,
		CeilingScore = INITIAL_SCORE,
		CeilingUnitCost = 0,
		StableFrames = 0,
		HoldTargetFrames = BASE_HOLD_FRAMES,
		ProbingCeiling = false,
		GetLoadFraction = nil,
		ScoreFromLoadFraction = nil,
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

--[=[
	Applies a uniform target score and clears accumulated controller errors/feedback on SingletonState.
	@param SingletonState any -- Target controller singleton state table.
	@param TargetScore number -- Score value to assign across all score and ceiling registers.
]=]
function ResourceControllerHelper.ApplyScorePreset(SingletonState: any, TargetScore: number)
	SingletonState.Scores.Renderer = TargetScore
	SingletonState.Scores.Physics = TargetScore
	SingletonState.RawScores.Renderer = TargetScore
	SingletonState.RawScores.Physics = TargetScore
	SingletonState.CeilingScores.Renderer = TargetScore
	SingletonState.CeilingScores.Physics = TargetScore
	SingletonState.Feedback.RendererFrameTime = 0
	SingletonState.Feedback.PhysicsFrameTime = 0
	SingletonState.PreviousErrors.Renderer = 0
	SingletonState.PreviousErrors.Physics = 0
	ResourceControllerHelper.ResetChannelState(SingletonState.RendererChannel)
	ResourceControllerHelper.ResetChannelState(SingletonState.PhysicsChannel)
end

--[=[
	Connects or disconnects the Server Heartbeat closed-loop step connection based on Enabled and Initialized state.
	@param IsClient boolean -- True when running on the client VM.
	@param CurrentConnection RBXScriptConnection? -- Active Heartbeat connection if bound.
	@param SingletonState any -- Controller singleton state table.
	@param StepControllerFn (number) -> () -- Callback stepping the controller once per Heartbeat.
	@return RBXScriptConnection? -- Resulting Heartbeat connection or nil.
]=]
function ResourceControllerHelper.SyncServerHeartbeat(
	IsClient: boolean,
	CurrentConnection: RBXScriptConnection?,
	SingletonState: any,
	StepControllerFn: (number) -> ()
): RBXScriptConnection?
	if IsClient then
		return CurrentConnection
	end
	if SingletonState.Enabled and SingletonState.Initialized then
		if CurrentConnection then
			return CurrentConnection
		end
		return RunService.Heartbeat:Connect(function(DeltaTime: number)
			if not SingletonState.Enabled then
				return
			end
			const PhysWork = math.max(SingletonState.Feedback.PhysicsFrameTime, 0.0005) :: number
			const EffectiveServerDt = ResourceControllerHelper.ResolveEffectiveFrameTime(
				DeltaTime,
				PhysWork,
				SingletonState.TargetFrameTime
			)
			SingletonState.WhereInFrame = EffectiveServerDt
			StepControllerFn(EffectiveServerDt)
			SingletonState.FrameStartClock = os.clock()
			SingletonState.WhereInFrame = 0
		end)
	end
	if CurrentConnection then
		CurrentConnection:Disconnect()
	end
	return nil
end

return ResourceControllerHelper
