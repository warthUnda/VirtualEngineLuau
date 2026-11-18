--!strict
--!native
--!optimize 2

--[=[
	@class ControllerTheory.spec
	Server TestEZ specifications verifying the ControllerTheory singleton, 60/40 runtime weights,
	intra-frame timing and (OtherSystemsFrameTime - TargetFrameTime) budget math, deterministic
	ControllerInterpreter physics part striding, and closed-loop feedback convergence.
]=]

return function()
	const SpecEnv = getfenv() :: {
		describe: (string, () -> ()) -> (),
		it: (string, () -> ()) -> (),
		expect: (any) -> any,
	}
	const describe = SpecEnv.describe
	const it = SpecEnv.it
	const expect = SpecEnv.expect

	-- Services --
	const ReplicatedStorage = game:GetService("ReplicatedStorage")

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
	const UtilitiesFolder = SharedFolder:WaitForChild("Utilities")
	const ControllerTheoryRoot = UtilitiesFolder:WaitForChild("ControllerTheory")

	-- Libraries --
	const SystemsConfigs = require(SharedFolder:WaitForChild("SystemsConfigs"))
	const ResourceController =
		require(ControllerTheoryRoot:WaitForChild("Controller"):WaitForChild("ResourceController"))
	const ControllerInterpreter =
		require(ControllerTheoryRoot:WaitForChild("Core"):WaitForChild("ControllerInterpreter"))
	const ControllerTheoryMath =
		require(ControllerTheoryRoot:WaitForChild("Core"):WaitForChild("ControllerTheoryMath"))

	-- Configs --
	const TARGET_FRAME_TIME = (1 / 60) :: number
	const FREE_TIME_RESERVE = 0.002 :: number

	describe("1. Singleton ResourceController, Runtime Weights, 2ms Spike Reserve & Frame Offset Math", function()
		it("should expose a singleton state table with configured weights, 2ms free reserve, and 1..100 scores", function()
			ResourceController.Reset()

			const State = ResourceController.State
			expect(State ~= nil).to.equal(true)
			expect(State.Weights.Renderer).to.be.near(SystemsConfigs.ControllerRendererWeight, 1e-4)
			expect(State.Weights.Physics).to.be.near(SystemsConfigs.ControllerPhysicsWeight, 1e-4)
			expect(State.FreeTimeReserve).to.be.near(FREE_TIME_RESERVE, 1e-5)
			expect(ResourceController.GetRendererScore()).to.equal(100)
			expect(ResourceController.GetPhysicsScore()).to.equal(100)

			ResourceController.Reset()
		end)

		it("should reserve 2ms of untouched spike free time when computing OtherSystemsFrameTime - UsableTarget", function()
			ResourceController.Reset()

			const OtherTime: number, OtherMinusTarget: number, RendererBudget: number, PhysicsBudget: number =
				ControllerTheoryMath.ComputeBudgetAllocation(
					0.020,
					0.005,
					0.007,
					0.008,
					TARGET_FRAME_TIME,
					0.60,
					0.40,
					FREE_TIME_RESERVE
				)

			-- OtherSystemsFrameTime = 0.020 - (0.005 + 0.007) = 0.008s; UsableTarget = (1/60) - 0.002 = 0.0146667s
			const UsableTarget = TARGET_FRAME_TIME - FREE_TIME_RESERVE :: number
			expect(OtherTime).to.be.near(0.008, 1e-5)
			expect(OtherMinusTarget).to.be.near(0.008 - UsableTarget, 1e-5)

			-- Remaining 0.0066667s is contested by both (0.007 > 0.60*0.00667 and 0.005 > 0.40*0.00667), leaving 2ms untouched
			const Available = UsableTarget - 0.008 :: number
			expect(RendererBudget).to.be.near(Available * 0.60, 1e-5)
			expect(PhysicsBudget).to.be.near(Available * 0.40, 1e-5)
			expect(OtherTime + RendererBudget + PhysicsBudget).to.be.near(TARGET_FRAME_TIME - FREE_TIME_RESERVE, 1e-5)

			const ElapsedInFrame = ResourceController.UpdateWhereInFrame(ResourceController.State.FrameStartClock + 0.004)
			expect(ElapsedInFrame).to.be.near(0.004, 1e-5)

			ResourceController.Reset()
		end)

		it("should adaptively throttle down whenever free frame time drops below 2ms even before missing 60 FPS", function()
			ResourceController.Reset()

			-- Total frame = 15.8ms (< 16.67ms 60 FPS), leaving only ~0.87ms free (< 2.0ms required spike reserve)
			for _ = 1, 60 do
				ResourceController.ReportRendererFeedback(0.0138)
				ResourceController.ReportPhysicsFeedback(0.001)
				ResourceController.StepController(0.0158)
			end

			expect(ResourceController.GetRendererScore() < 100).to.equal(true)
			expect(ResourceController.State.FreeFrameTime < FREE_TIME_RESERVE).to.equal(true)

			ResourceController.Reset()
		end)

		it("should throttle scores down under frame overruns and naturally recover toward 100 when under budget", function()
			ResourceController.Reset()

			for _ = 1, 60 do
				ResourceController.ReportRendererFeedback(0.018)
				ResourceController.ReportPhysicsFeedback(0.001)
				ResourceController.StepController(0.021)
			end

			const ThrottledRenderer = ResourceController.GetRendererScore()
			const UnaffectedPhysics = ResourceController.GetPhysicsScore()
			expect(ThrottledRenderer < 100).to.equal(true)
			expect(ThrottledRenderer >= 1).to.equal(true)
			expect(UnaffectedPhysics).to.equal(100)

			-- Overload from other systems eating > 16.67ms forces both systems down gradually within [1, 100]
			for _ = 1, 90 do
				ResourceController.ReportRendererFeedback(0.004)
				ResourceController.ReportPhysicsFeedback(0.004)
				ResourceController.StepController(0.030)
			end
			expect(ResourceController.State.OtherMinusTargetFrameTime > 0).to.equal(true)
			expect(ResourceController.GetPhysicsScore() < 100).to.equal(true)
			expect(ResourceController.GetPhysicsScore() >= 1).to.equal(true)
			expect(ResourceController.GetRendererScore() >= 1).to.equal(true)

			const LowRendererScore = ResourceController.GetRendererScore()
			const LowPhysicsScore = ResourceController.GetPhysicsScore()

			-- Fast 60+ FPS frames naturally reward scores upward gradually
			for _ = 1, 240 do
				ResourceController.ReportRendererFeedback(0.002)
				ResourceController.ReportPhysicsFeedback(0.001)
				ResourceController.StepController(0.005)
			end
			expect(ResourceController.GetRendererScore() > LowRendererScore).to.equal(true)
			expect(ResourceController.GetPhysicsScore() > LowPhysicsScore).to.equal(true)
			expect(ResourceController.GetRendererScore() <= 100).to.equal(true)
			expect(ResourceController.GetPhysicsScore() <= 100).to.equal(true)

			ResourceController.Reset()
		end)

		it("should lock onto a steady non-oscillating equilibrium under constant heavy scene load without hunting back into lag", function()
			ResourceController.Reset()

			local SettledMin = 100 :: number
			local SettledMax = 1 :: number
			local SettledOverruns = 0 :: number
			const UsableLimit = (TARGET_FRAME_TIME - FREE_TIME_RESERVE) :: number

			for Frame = 1, 2100 do
				const CurrentScore = ResourceController.GetRendererScore()
				const _W: number, _H: number, LinearScale: number =
					ControllerInterpreter.InterpretRenderer(CurrentScore, 340, 240)
				const AreaFraction = LinearScale * LinearScale :: number
				const SimRenderTime = 0.004 + 0.018 * AreaFraction :: number
				const SimPhysicsTime = 0.001 :: number
				const SimTotalTime = SimRenderTime + SimPhysicsTime + 0.0005 :: number

				ResourceController.ReportRendererFeedback(SimRenderTime)
				ResourceController.ReportPhysicsFeedback(SimPhysicsTime)
				ResourceController.StepController(SimTotalTime)

				if Frame >= 1800 then
					const PostScore = ResourceController.GetRendererScore()
					if PostScore < SettledMin then
						SettledMin = PostScore
					end
					if PostScore > SettledMax then
						SettledMax = PostScore
					end
					if SimTotalTime > UsableLimit then
						SettledOverruns += 1
					end
				end
			end

			expect(SettledMax < 100).to.equal(true)
			expect(SettledMax - SettledMin <= 2).to.equal(true)
			expect(SettledOverruns).to.equal(0)

			ResourceController.Reset()
		end)
	end)

	describe("2. Deterministic ControllerInterpreter Formulas (Physics & Renderer)", function()
		it("should deterministically step physics parts every frame at 100 and every 2 frames at 50 without math.random", function()
			const Duty100: number, Stride100: number = ControllerInterpreter.InterpretPhysics(100)
			expect(Duty100).to.equal(100)
			expect(Stride100).to.be.near(1.0, 1e-4)

			for EntityId = 1, 16 do
				for Tick = 1, 6 do
					expect(ControllerInterpreter.ShouldStepPhysicsEntity(EntityId, Tick, 100)).to.equal(true)
				end
			end

			const Duty50: number, Stride50: number = ControllerInterpreter.InterpretPhysics(50)
			expect(Duty50).to.equal(50)
			expect(Stride50).to.be.near(2.0, 1e-4)

			-- Repeatability & exact 2-frame cadence per entity + exact 50% active per frame
			for Tick = 1, 8 do
				local ActiveThisFrame = 0 :: number
				for EntityId = 1, 20 do
					const FirstEval = ControllerInterpreter.ShouldStepPhysicsEntity(EntityId, Tick, 50)
					const SecondEval = ControllerInterpreter.ShouldStepPhysicsEntity(EntityId, Tick, 50)
					const NextTickEval = ControllerInterpreter.ShouldStepPhysicsEntity(EntityId, Tick + 1, 50)
					expect(FirstEval).to.equal(SecondEval)
					expect(FirstEval ~= NextTickEval).to.equal(true)
					if FirstEval then
						ActiveThisFrame += 1
					end
				end
				expect(ActiveThisFrame).to.equal(10)
			end
		end)

		it("should map renderer 1..100 score monotonically into scaled viewport dimensions", function()
			const W100: number, H100: number, Scale100: number = ControllerInterpreter.InterpretRenderer(100, 340, 240)
			const W50: number, H50: number, Scale50: number = ControllerInterpreter.InterpretRenderer(50, 340, 240)
			const W1: number, H1: number, Scale1: number = ControllerInterpreter.InterpretRenderer(1, 340, 240)

			expect(W100).to.equal(340)
			expect(H100).to.equal(240)
			expect(Scale100).to.be.near(1.0, 1e-4)

			expect(W50 < W100 and W50 > W1).to.equal(true)
			expect(H50 < H100 and H50 > H1).to.equal(true)
			expect(Scale50 < Scale100 and Scale50 > Scale1).to.equal(true)
			expect(W1 >= 32 and H1 >= 32).to.equal(true)
		end)
	end)
end
