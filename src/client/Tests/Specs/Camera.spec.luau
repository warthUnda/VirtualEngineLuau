--!strict
--!native
--!optimize 2

--[=[
	@class Camera.spec
	TestEZ specifications verifying single-player OOP CameraService construction,
	per-frame basis Vector3 and SIMD vector caching, projection parameter calculations,
	and CameraStore/CameraLibrary facades.
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
	const Players = game:GetService("Players")
	const ReplicatedStorage = game:GetService("ReplicatedStorage")

	-- Static References --
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")
	const CameraFolder = SharedFolder:WaitForChild("Utilities"):WaitForChild("Render"):WaitForChild("Camera")

	-- Libraries --
	const CameraHelper = require(CameraFolder:WaitForChild("CameraHelper"))
	const CameraStore = require(CameraFolder:WaitForChild("CameraStore"))
	const CameraService = require(CameraFolder:WaitForChild("CameraService"))
	const CameraLibrary = require(CameraFolder:WaitForChild("CameraLibrary"))

	describe("1. Camera Basis Matrix & Orthonormal CFrame Math", function()
		it("should produce identity rotation for standard forward (-Z) view", function()
			const Look = Vector3.new(0, 0, -1)
			const Up = Vector3.new(0, 1, 0)
			const Right = Vector3.new(1, 0, 0)

			const RotCF = CameraHelper.VectorsToRotation(Look, Up, Right)
			expect((RotCF.Position - Vector3.zero).Magnitude).to.be.near(0, 1e-4)
			expect((RotCF.LookVector - Look).Magnitude).to.be.near(0, 1e-4)
			expect((RotCF.UpVector - Up).Magnitude).to.be.near(0, 1e-4)
			expect((RotCF.RightVector - Right).Magnitude).to.be.near(0, 1e-4)
		end)

		it("should produce an orthogonal CFrame under 90-degree yaw rotation", function()
			const Look = Vector3.new(1, 0, 0)
			const Up = Vector3.new(0, 1, 0)
			const Right = Vector3.new(0, 0, -1)

			const RotCF = CameraHelper.VectorsToRotation(Look, Up, Right)
			expect((RotCF.LookVector - Look).Magnitude).to.be.near(0, 1e-4)
			expect((RotCF.UpVector - Up).Magnitude).to.be.near(0, 1e-4)
			expect((RotCF.RightVector - Right).Magnitude).to.be.near(0, 1e-4)
		end)
	end)

	describe("2. Camera Store Facade & BVH Occlusion", function()
		it("should expose valid camera state dictionary and cached basis directions", function()
			const StateTable = CameraStore.GetCameraTable()
			expect(StateTable ~= nil).to.equal(true)
			expect(StateTable.CameraFOV > 0).to.equal(true)

			const CamPos = CameraStore.GetCameraPosition()
			expect(typeof(CamPos)).to.equal("Vector3")

			const Look = CameraStore.GetCameraLook()
			const Right = CameraStore.GetCameraRight()
			const Up = CameraStore.GetCameraUp()

			expect(Look.Magnitude > 0.9).to.equal(true)
			expect(Right.Magnitude > 0.9).to.equal(true)
			expect(Up.Magnitude > 0.9).to.equal(true)
		end)

		it("should resolve camera occlusion via BVH.Raycast without Workspace part queries", function()
			const LocalPlayer = Players.LocalPlayer :: Player?
			if not LocalPlayer then
				return
			end

			const ClientTestHelper = require(LocalPlayer.PlayerScripts.Client.Tests.TestHelper)
			const TestStorage = ClientTestHelper.CreateTestStorage()
			const EntityId = ClientTestHelper.PopulateEntity(
				TestStorage,
				Vector3.new(0, 500, -10),
				Vector3.new(0, 0, -1),
				Vector3.new(0, 1, 0),
				Vector3.new(1, 0, 0),
				Vector3.new(6, 6, 4),
				Color3.new(1, 1, 1)
			)
			TestStorage.PropertiesData.CreateLayout((EntityId - 1) * 4, true, true, true, 0)

			const Origin = Vector3.new(0, 500, 0)
			const RayVec = Vector3.new(0, 0, -20)
			const ClampedPos = CameraHelper.RaycastWorld(Origin, RayVec, TestStorage)
			expect(ClampedPos.Z).to.be.near(-7.2, 0.25)

			TestStorage.ECSData.DeleteEntity(EntityId)
		end)
	end)

	describe("3. OOP CameraService & CameraLibrary Facade", function()
		it("should compute clamped pitch/yaw rotation from mouse delta", function()
			const MaxPitchRad = math.rad(60)
			const Rot = CameraHelper.ComputeLookRotation(Vector2.zero, Vector3.new(25, -100, 0), MaxPitchRad)
			expect(Rot.X < 0).to.equal(true)
			expect(Rot.Y > 0).to.equal(true)

			const ClampedUp = CameraHelper.ComputeLookRotation(Vector2.new(0, MaxPitchRad), Vector3.new(0, -10000, 0), MaxPitchRad)
			expect(ClampedUp.Y).to.be.near(MaxPitchRad, 1e-5)

			const ClampedDown = CameraHelper.ComputeLookRotation(Vector2.new(0, -MaxPitchRad), Vector3.new(0, 10000, 0), MaxPitchRad)
			expect(ClampedDown.Y).to.be.near(-MaxPitchRad, 1e-5)
		end)

		it("should construct lean OOP CameraService instances without renderer cache bloat", function()
			const InitialCF = CFrame.new(12, 34, 56) * CFrame.Angles(0, math.rad(90), 0)
			const CamObj = CameraLibrary.New(InitialCF, 75)

			expect(CamObj.ClassName).to.equal("CameraService")
			expect(CamObj:GetFOV()).to.equal(75)
			expect((CamObj:GetCFrame().Position - Vector3.new(12, 34, 56)).Magnitude).to.be.near(0, 1e-4)
			expect((CamObj:GetCFrame().LookVector - InitialCF.LookVector).Magnitude).to.be.near(0, 1e-4)

			const RawCam = CamObj :: { [string]: any }
			expect(RawCam.CachedPosVec).to.equal(nil)
			expect(RawCam.CachedFocalLength).to.equal(nil)
			expect(RawCam.GetProjectionParameters).to.equal(nil)
			expect(RawCam.SyncFrame).to.equal(nil)

			const NextCF = CFrame.new(-5, 10, -20)
			CamObj:SetCFrame(NextCF)
			CamObj:ChangeFOV(90)
			expect((CamObj:GetCFrame().Position - Vector3.new(-5, 10, -20)).Magnitude).to.be.near(0, 1e-4)
			expect(CamObj:GetFOV()).to.equal(90)

			CamObj:Destroy()
		end)

		it("should update active singleton camera FOV through CameraService and CameraLibrary facades", function()
			const PrevFov = CameraLibrary.GetFOV()
			CameraService:ChangeFOV(85)
			expect(CameraLibrary.GetFOV()).to.equal(85)
			expect(CameraStore.GetCameraTable().CameraFOV).to.equal(85)
			CameraLibrary.ChangeFOV(PrevFov)
			expect(CameraService:GetFOV()).to.equal(PrevFov)
		end)
	end)
end
