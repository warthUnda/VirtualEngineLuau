--!strict
--!native
--!optimize 2

return function()
	const SpecEnv = getfenv() :: {
		describe: (string, () -> ()) -> (),
		it: (string, () -> ()) -> (),
		expect: (any) -> any,
	}
	const describe = SpecEnv.describe
	const it = SpecEnv.it
	const expect = SpecEnv.expect

	const ReplicatedStorage = game:GetService("ReplicatedStorage")
	const SharedFolder = ReplicatedStorage:WaitForChild("Shared")

	const CameraHelper = require(
		SharedFolder:WaitForChild("Utilities")
			:WaitForChild("Render")
			:WaitForChild("Camera")
			:WaitForChild("CameraHelper")
	)
	const CameraStore = require(
		SharedFolder:WaitForChild("Utilities")
			:WaitForChild("Render")
			:WaitForChild("Camera")
			:WaitForChild("CameraStore")
	)

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
			const Look = Vector3.new(1, 0, 0) -- Looking along +X
			const Up = Vector3.new(0, 1, 0)
			const Right = Vector3.new(0, 0, -1)

			const RotCF = CameraHelper.VectorsToRotation(Look, Up, Right)
			expect((RotCF.LookVector - Look).Magnitude).to.be.near(0, 1e-4)
			expect((RotCF.UpVector - Up).Magnitude).to.be.near(0, 1e-4)
			expect((RotCF.RightVector - Right).Magnitude).to.be.near(0, 1e-4)
		end)
	end)

	describe("2. Camera Store State & Orientation Accessors", function()
		it("should expose valid camera state dictionary and non-zero basis directions", function()
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
			const Players = game:GetService("Players")
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
			const ClampedPos = CameraHelper.RaycastWorld(Origin, RayVec, nil, nil, TestStorage)
			-- Box spans Z = [-12, -8]; ray from Z=0 in -Z hits at distance 8, clamped to 8 * 0.9 = 7.2 (-Z)
			expect(ClampedPos.Z).to.be.near(-7.2, 0.25)

			TestStorage.ECSData.DeleteEntity(EntityId)
		end)
	end)
end
