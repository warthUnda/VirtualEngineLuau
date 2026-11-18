--!strict
--!native
--!optimize 2

--[=[
	@class ControllerTheoryClient.spec
	Client TestEZ specifications verifying dynamic renderer resolution scaling driven by
	ResourceController feedback and ControllerInterpreter on the client boundary.
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
	const RenderRoot = UtilitiesFolder:WaitForChild("Render")
	const ControllerTheoryRoot = UtilitiesFolder:WaitForChild("ControllerTheory")

	-- Libraries --
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const CameraLibrary = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraLibrary"))
	const RenderService = require(RenderRoot:WaitForChild("Core"):WaitForChild("RenderService"))
	const ResourceController =
		require(ControllerTheoryRoot:WaitForChild("Controller"):WaitForChild("ResourceController"))

	describe("1. Client Renderer Dynamic Resolution Scaling & Controller Feedback", function()
		it("should dynamically lower RenderService resolution when controller score drops and restore at 100", function()
			ResourceController.Reset()

			const IsolatedStorage = ECSMain.CreateStorage(false)
			const CustomCam = CameraLibrary.New(CFrame.new(0, 5, 20), 70)
			const MountContainer = Instance.new("Folder")

			const RendererObj = RenderService.New({
				Width = 320,
				Height = 240,
				Storage = IsolatedStorage,
				Camera = CustomCam,
				GuiName = "SpecAdaptiveRendererGui",
			})
			RendererObj:Init(MountContainer, false)
			expect(RendererObj.Width).to.equal(320)
			expect(RendererObj.Height).to.equal(240)
			const InitialRowWorkDiff = RendererObj.RowWorkDiff
			const InitialRowToWorker = RendererObj.RowToWorker
			const InitialStagedTriangles = RendererObj.StagedTriangles

			-- Simulate 1 second (60 frames) of heavy render feedback to step RendererScore down gradually
			for _ = 1, 60 do
				ResourceController.ReportRendererFeedback(0.025)
				ResourceController.ReportPhysicsFeedback(0.001)
				ResourceController.StepController(0.028)
			end
			expect(ResourceController.GetRendererScore() < 100).to.equal(true)

			RendererObj:DrawFrame()
			expect(RendererObj.Width < 320).to.equal(true)
			expect(RendererObj.Height < 240).to.equal(true)
			expect(buffer.len(RendererObj.FinalPixel)).to.equal(RendererObj.Width * RendererObj.Height * 4)
			expect(RendererObj.RowWorkDiff).to.equal(InitialRowWorkDiff)
			expect(RendererObj.RowToWorker).to.equal(InitialRowToWorker)
			expect(RendererObj.StagedTriangles).to.equal(InitialStagedTriangles)

			const BoundImg = RendererObj:GetEditableImage()
			const BoundLabel = RendererObj:GetImageLabel()
			if BoundImg then
				expect(BoundImg.Size.X).to.equal(320)
				expect(BoundImg.Size.Y).to.equal(240)
			end
			if BoundLabel then
				expect(BoundLabel.ImageRectSize.X).to.equal(RendererObj.Width)
				expect(BoundLabel.ImageRectSize.Y).to.equal(RendererObj.Height)
			end

			-- Reset controller back to 100 and confirm resolution scales back up to BaseWidth x BaseHeight
			ResourceController.Reset()
			RendererObj:DrawFrame()
			expect(RendererObj.Width).to.equal(320)
			expect(RendererObj.Height).to.equal(240)
			if BoundLabel then
				expect(BoundLabel.ImageRectSize.X).to.equal(320)
				expect(BoundLabel.ImageRectSize.Y).to.equal(240)
			end

			RendererObj:Destroy()
			CustomCam:Destroy()
			MountContainer:Destroy()
			ResourceController.Reset()
		end)
	end)
end
