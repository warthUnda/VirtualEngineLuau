--!strict
--!native
--!optimize 2

--[=[
	@class RenderService.spec
	TestEZ specifications verifying OOP RenderService instantiation, self-created ScreenGui
	and ImageLabel mounting, visibility toggling, and RenderController/RenderLibrary facades.
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
	const RenderRoot = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render")

	-- Libraries --
	const ECSMain = require(SharedFolder:WaitForChild("ECSMain"))
	const CameraLibrary = require(RenderRoot:WaitForChild("Camera"):WaitForChild("CameraLibrary"))
	const RenderService = require(RenderRoot:WaitForChild("Core"):WaitForChild("RenderService"))
	const RenderLibrary = require(RenderRoot:WaitForChild("RenderLibrary"))
	const RenderController = require(RenderRoot:WaitForChild("Controller"):WaitForChild("RenderController"))

	describe("1. OOP RenderService, Self-Created ScreenGui/ImageLabel & Facades", function()
		it("should instantiate an OOP RenderService object that creates its own ScreenGui and ImageLabel", function()
			const IsolatedStorage = ECSMain.CreateStorage(false)
			const CustomCam = CameraLibrary.New(CFrame.new(0, 5, 15), 70)
			const MountContainer = Instance.new("Folder")

			const RendererObj = RenderLibrary.New({
				Width = 64,
				Height = 48,
				Storage = IsolatedStorage,
				Camera = CustomCam,
				GuiName = "SpecRendererGui",
			})

			expect(RendererObj.ClassName).to.equal("RenderService")
			expect(RendererObj.Width).to.equal(64)
			expect(RendererObj.Height).to.equal(48)
			expect(RendererObj.Camera).to.equal(CustomCam)

			RendererObj:Init(MountContainer, false)

			const CreatedGui = RendererObj:GetScreenGui()
			const CreatedLabel = RendererObj:GetImageLabel()
			expect(CreatedGui ~= nil).to.equal(true)
			expect(CreatedLabel ~= nil).to.equal(true)

			if CreatedGui and CreatedLabel then
				expect(CreatedGui.Parent).to.equal(MountContainer)
				expect(CreatedGui.Name).to.equal("SpecRendererGui")
				expect(CreatedGui.IgnoreGuiInset).to.equal(true)
				expect(CreatedGui.ResetOnSpawn).to.equal(false)
				expect(CreatedGui.Enabled).to.equal(true)

				expect(CreatedLabel.Parent).to.equal(CreatedGui)
				expect(CreatedLabel.Size).to.equal(UDim2.fromScale(1, 1))
				expect(CreatedLabel.BackgroundTransparency).to.equal(1)

				RendererObj:SetEnabled(false)
				expect(CreatedGui.Enabled).to.equal(false)
				RendererObj:SetEnabled(true)
				expect(CreatedGui.Enabled).to.equal(true)
			end

			RendererObj:Destroy()
			expect(RendererObj:GetScreenGui()).to.equal(nil)
			expect(#MountContainer:GetChildren()).to.equal(0)

			CustomCam:Destroy()
			MountContainer:Destroy()
		end)

		it("should expose unified singleton access through RenderController and RenderLibrary facades", function()
			const ActiveFromController = RenderController.GetActiveRenderer()
			const ActiveFromLibrary = RenderLibrary.GetActiveRenderer()
			expect(ActiveFromController ~= nil).to.equal(true)
			expect(ActiveFromController).to.equal(ActiveFromLibrary)
			expect(ActiveFromController.ClassName).to.equal("RenderService")
		end)

		it("should cache camera basis SIMD vectors and projection scalars inside RenderService", function()
			const IsolatedStorage = ECSMain.CreateStorage(false)
			const CustomCam = CameraLibrary.New(CFrame.new(12, 34, 56) * CFrame.Angles(0, math.rad(90), 0), 75)
			const MountContainer = Instance.new("Folder")

			const RendererObj = RenderService.New({
				Width = 64,
				Height = 48,
				Storage = IsolatedStorage,
				Camera = CustomCam,
				GuiName = "SpecCacheGui",
			})
			RendererObj:Init(MountContainer, false)

			const DispatchedA = RendererObj:DrawFrame()
			expect(DispatchedA).to.equal(true)
			expect(RendererObj.CachedCameraPosVec.x).to.be.near(12, 1e-4)
			expect(RendererObj.CachedCameraPosVec.y).to.be.near(34, 1e-4)
			expect(RendererObj.CachedCameraPosVec.z).to.be.near(56, 1e-4)
			expect(RendererObj.CachedFocalLength > 0).to.equal(true)
			expect(RendererObj.CachedCameraFOV).to.equal(75)

			const PrevFocal = RendererObj.CachedFocalLength
			CustomCam:SetCFrame(CFrame.new(-5, 10, -20))
			CustomCam:ChangeFOV(90)

			const DispatchedB = RendererObj:DrawFrame()
			expect(DispatchedB).to.equal(true)
			expect(RendererObj.CachedCameraPosVec.x).to.be.near(-5, 1e-4)
			expect(RendererObj.CachedCameraPosVec.z).to.be.near(-20, 1e-4)
			expect(RendererObj.CachedCameraFOV).to.equal(90)
			expect(RendererObj.CachedFocalLength < PrevFocal).to.equal(true)

			RendererObj:Destroy()
			CustomCam:Destroy()
			MountContainer:Destroy()
		end)
	end)
end
