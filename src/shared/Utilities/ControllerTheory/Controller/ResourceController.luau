--!strict
--!native
--!optimize 2

--[=[
	@class ResourceController
	Singleton control-theory resource orchestrator operating on both Server and Client.
	Tracks intra-frame progress (WhereInFrame), computes (OtherSystemsFrameTime - TargetFrameTime)
	against the 60 FPS target, weights allocations 60% Renderer / 40% Physics, and updates 1..100
	subsystem scores from closed-loop frame-time feedback with zero per-frame allocations.
]=]

-- Services --
const ReplicatedStorage = game:GetService("ReplicatedStorage") :: ReplicatedStorage
const RunService = game:GetService("RunService") :: RunService

-- Static References --
const IS_CLIENT = RunService:IsClient() :: boolean
const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
const ControllerTheoryRoot = script.Parent.Parent

-- Libraries --
const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
const ControllerTheoryMath = require(ControllerTheoryRoot:WaitForChild("Core"):WaitForChild("ControllerTheoryMath"))

-- Configs --
const TARGET_FRAME_TIME = SystemsConfigs.ControllerTargetFrameTime :: number
const DEFAULT_RENDERER_WEIGHT = SystemsConfigs.ControllerRendererWeight :: number
const DEFAULT_PHYSICS_WEIGHT = SystemsConfigs.ControllerPhysicsWeight :: number
const INITIAL_SCORE = SystemsConfigs.ControllerInitialScore :: number

export type ControllerWeights = {
	Renderer: number,
	Physics: number,
}

export type ControllerScores = {
	Renderer: number,
	Physics: number,
}

export type ControllerFeedback = {
	RendererFrameTime: number,
	PhysicsFrameTime: number,
}

export type ControllerSingletonState = {
	Weights: ControllerWeights,
	Scores: ControllerScores,
	RawScores: ControllerScores,
	Feedback: ControllerFeedback,
	PreviousErrors: ControllerScores,
	TargetFrameTime: number,
	FrameStartClock: number,
	WhereInFrame: number,
	TotalFrameTime: number,
	OtherSystemsFrameTime: number,
	OtherMinusTargetFrameTime: number,
	RendererBudget: number,
	PhysicsBudget: number,
	FrameTick: number,
	Initialized: boolean,
}

-- Variables --
local HeartbeatConnection: RBXScriptConnection? = nil

-- Tables --
local SingletonState: ControllerSingletonState = {
	Weights = {
		Renderer = DEFAULT_RENDERER_WEIGHT,
		Physics = DEFAULT_PHYSICS_WEIGHT,
	},
	Scores = {
		Renderer = INITIAL_SCORE,
		Physics = INITIAL_SCORE,
	},
	RawScores = {
		Renderer = INITIAL_SCORE,
		Physics = INITIAL_SCORE,
	},
	Feedback = {
		RendererFrameTime = 0,
		PhysicsFrameTime = 0,
	},
	PreviousErrors = {
		Renderer = 0,
		Physics = 0,
	},
	TargetFrameTime = TARGET_FRAME_TIME,
	FrameStartClock = os.clock(),
	WhereInFrame = 0,
	TotalFrameTime = TARGET_FRAME_TIME,
	OtherSystemsFrameTime = 0,
	OtherMinusTargetFrameTime = -TARGET_FRAME_TIME,
	RendererBudget = DEFAULT_RENDERER_WEIGHT * TARGET_FRAME_TIME,
	PhysicsBudget = DEFAULT_PHYSICS_WEIGHT * TARGET_FRAME_TIME,
	FrameTick = 0,
	Initialized = false,
}

local ResourceController = {
	State = SingletonState,
}

-- Functions --
-- ============================================================================
-- 1. SINGLETON CONTROL-THEORY LIFECYCLE, FEEDBACK & 1..100 SCORE ALLOCATION
-- ============================================================================

--[=[
	Updates and returns the current elapsed seconds inside the active frame (WhereInFrame).
	@param NowClockOverride number? -- Optional clock timestamp override for deterministic tests.
	@return number -- Elapsed seconds since FrameStartClock.
]=]
function ResourceController.UpdateWhereInFrame(NowClockOverride: number?): number
	const CurrentClock = (NowClockOverride or os.clock()) :: number
	const Elapsed = math.max(0, CurrentClock - SingletonState.FrameStartClock) :: number
	SingletonState.WhereInFrame = Elapsed
	return Elapsed
end

--[=[
	Records measured physics execution time feedback for the closed-loop controller.
	@param ElapsedSeconds number -- Physics frame execution duration in seconds.
]=]
function ResourceController.ReportPhysicsFeedback(ElapsedSeconds: number)
	SingletonState.Feedback.PhysicsFrameTime = math.max(0, ElapsedSeconds)
	SingletonState.WhereInFrame = math.max(0, os.clock() - SingletonState.FrameStartClock)
end

--[=[
	Records measured renderer execution time feedback for the closed-loop controller.
	@param ElapsedSeconds number -- Renderer frame execution duration in seconds.
]=]
function ResourceController.ReportRendererFeedback(ElapsedSeconds: number)
	SingletonState.Feedback.RendererFrameTime = math.max(0, ElapsedSeconds)
	SingletonState.WhereInFrame = math.max(0, os.clock() - SingletonState.FrameStartClock)
end

--[=[
	Steps the control-theory feedback equations for a completed frame duration, updating
	OtherSystemsFrameTime - TargetFrameTime and adjusting 1..100 scores for Renderer and Physics.
	@param TotalFrameDeltaTime number -- Observed total frame duration in seconds.
]=]
function ResourceController.StepController(TotalFrameDeltaTime: number)
	const TargetDt = SingletonState.TargetFrameTime :: number
	const SafeTotalDt = if TotalFrameDeltaTime > 0 then TotalFrameDeltaTime else TargetDt :: number
	const PhysTime = SingletonState.Feedback.PhysicsFrameTime :: number
	const RendTime = SingletonState.Feedback.RendererFrameTime :: number

	const OtherTime: number, OtherMinusTarget: number, RendBudget: number, PhysBudget: number =
		ControllerTheoryMath.ComputeBudgetAllocation(
			SafeTotalDt,
			PhysTime,
			RendTime,
			SingletonState.WhereInFrame,
			TargetDt,
			SingletonState.Weights.Renderer,
			SingletonState.Weights.Physics
		)

	SingletonState.TotalFrameTime = SafeTotalDt
	SingletonState.OtherSystemsFrameTime = OtherTime
	SingletonState.OtherMinusTargetFrameTime = OtherMinusTarget
	SingletonState.RendererBudget = RendBudget
	SingletonState.PhysicsBudget = PhysBudget

	const NextRawRend: number, IntRend: number, ErrRend: number = ControllerTheoryMath.StepSystemScore(
		SingletonState.RawScores.Renderer,
		SingletonState.PreviousErrors.Renderer,
		RendBudget,
		RendTime,
		TargetDt
	)
	const NextRawPhys: number, IntPhys: number, ErrPhys: number = ControllerTheoryMath.StepSystemScore(
		SingletonState.RawScores.Physics,
		SingletonState.PreviousErrors.Physics,
		PhysBudget,
		PhysTime,
		TargetDt
	)

	SingletonState.RawScores.Renderer = NextRawRend
	SingletonState.Scores.Renderer = IntRend
	SingletonState.PreviousErrors.Renderer = ErrRend

	SingletonState.RawScores.Physics = NextRawPhys
	SingletonState.Scores.Physics = IntPhys
	SingletonState.PreviousErrors.Physics = ErrPhys
	SingletonState.FrameTick += 1
end

--[=[
	Marks the start of active execution for the incoming frame so WhereInFrame measures true intra-frame progress.
	If an explicit TotalFrameDeltaTime is passed directly, evaluates StepController immediately for backward compatibility.
	@param TotalFrameDeltaTime number? -- Optional explicit frame duration to step immediately.
]=]
function ResourceController.BeginFrame(TotalFrameDeltaTime: number?)
	const NowClock = os.clock() :: number
	if TotalFrameDeltaTime ~= nil then
		const MeasuredSpan = math.max(0, NowClock - SingletonState.FrameStartClock) :: number
		SingletonState.WhereInFrame = MeasuredSpan
		ResourceController.StepController(TotalFrameDeltaTime)
	end
	SingletonState.FrameStartClock = NowClock
	SingletonState.WhereInFrame = 0
end

--[=[
	Completes active frame execution, separating real active CPU work and <60 FPS frame stalls
	from idle 60 Hz VSync wait time inside RenderStepped/Heartbeat before stepping the controller.
	@param SchedulerDeltaTime number -- Raw RenderStepped or Heartbeat DeltaTime in seconds.
]=]
function ResourceController.EndFrame(SchedulerDeltaTime: number)
	const ActiveLoopSpan = math.max(0, os.clock() - SingletonState.FrameStartClock) :: number
	SingletonState.WhereInFrame = ActiveLoopSpan
	const ManagedWork = (SingletonState.Feedback.PhysicsFrameTime + SingletonState.Feedback.RendererFrameTime) :: number
	const ActiveFrameWork = math.max(ActiveLoopSpan, ManagedWork) :: number
	const TargetDt = SingletonState.TargetFrameTime :: number

	-- Only include SchedulerDeltaTime when the frame genuinely missed 60 FPS beyond normal VSync jitter (8%)
	const EffectiveFrameTime = if SchedulerDeltaTime > TargetDt * 1.08
		then math.max(SchedulerDeltaTime, ActiveFrameWork)
		else ActiveFrameWork :: number

	ResourceController.StepController(EffectiveFrameTime)
end

--[=[
	Initializes the singleton controller; on the Server binds Heartbeat to drive closed-loop updates automatically.
]=]
function ResourceController.Initialize()
	if SingletonState.Initialized then
		return
	end
	SingletonState.Initialized = true
	SingletonState.FrameStartClock = os.clock()

	if not IS_CLIENT and not HeartbeatConnection then
		HeartbeatConnection = RunService.Heartbeat:Connect(function(DeltaTime: number)
			const TargetDt = SingletonState.TargetFrameTime :: number
			const PhysWork = SingletonState.Feedback.PhysicsFrameTime :: number
			const EffectiveServerDt = if DeltaTime > TargetDt * 1.08
				then math.max(DeltaTime, PhysWork)
				else math.max(PhysWork, 0.0005) :: number
			SingletonState.WhereInFrame = EffectiveServerDt
			ResourceController.StepController(EffectiveServerDt)
			SingletonState.FrameStartClock = os.clock()
			SingletonState.WhereInFrame = 0
		end)
	end
end

--[=[
	Returns the current 1..100 resource allocation score for the Renderer.
	@return number -- Integer score in [1, 100].
]=]
function ResourceController.GetRendererScore(): number
	return SingletonState.Scores.Renderer
end

--[=[
	Returns the current 1..100 resource allocation score for Physics.
	@return number -- Integer score in [1, 100].
]=]
function ResourceController.GetPhysicsScore(): number
	return SingletonState.Scores.Physics
end

--[=[
	Updates runtime resource weights on the singleton controller (normalized to sum to 1.0).
	@param RendererWeight number -- Desired renderer weight (default 0.60).
	@param PhysicsWeight number -- Desired physics weight (default 0.40).
]=]
function ResourceController.SetWeights(RendererWeight: number, PhysicsWeight: number)
	const ClampedR = math.max(0, RendererWeight) :: number
	const ClampedP = math.max(0, PhysicsWeight) :: number
	const WeightSum = ClampedR + ClampedP :: number
	if WeightSum <= 1e-6 then
		return
	end
	SingletonState.Weights.Renderer = ClampedR / WeightSum
	SingletonState.Weights.Physics = ClampedP / WeightSum
end

--[=[
	Restores all singleton controller scores, weights, and timing accumulators to defaults.
]=]
function ResourceController.Reset()
	SingletonState.Weights.Renderer = DEFAULT_RENDERER_WEIGHT
	SingletonState.Weights.Physics = DEFAULT_PHYSICS_WEIGHT
	SingletonState.Scores.Renderer = INITIAL_SCORE
	SingletonState.Scores.Physics = INITIAL_SCORE
	SingletonState.RawScores.Renderer = INITIAL_SCORE
	SingletonState.RawScores.Physics = INITIAL_SCORE
	SingletonState.Feedback.RendererFrameTime = 0
	SingletonState.Feedback.PhysicsFrameTime = 0
	SingletonState.PreviousErrors.Renderer = 0
	SingletonState.PreviousErrors.Physics = 0
	SingletonState.TargetFrameTime = TARGET_FRAME_TIME
	SingletonState.FrameStartClock = os.clock()
	SingletonState.WhereInFrame = 0
	SingletonState.TotalFrameTime = TARGET_FRAME_TIME
	SingletonState.OtherSystemsFrameTime = 0
	SingletonState.OtherMinusTargetFrameTime = -TARGET_FRAME_TIME
	SingletonState.RendererBudget = DEFAULT_RENDERER_WEIGHT * TARGET_FRAME_TIME
	SingletonState.PhysicsBudget = DEFAULT_PHYSICS_WEIGHT * TARGET_FRAME_TIME
	SingletonState.FrameTick = 0
end

return ResourceController
