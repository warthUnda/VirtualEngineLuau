--!strict
--!native
--!optimize 2

-- Libraries --
const CameraPresets = require(script.Parent.CameraPresets)

-- Configs --
const IDENTITY_ANGLES = CFrame.fromEulerAnglesYXZ(0, 0, 0) :: CFrame
const WORLD_UP = Vector3.new(0, 1, 0) :: Vector3

-- Tables --
local CameraRigHelper = {}

-- Functions --
-- ============================================================================
-- 1. AVATAR FOOT WOBBLE, CHARACTER RIG ALIGNMENT & CINEMATIC OVERLAY
-- ============================================================================

--[=[
	Computes roll tilt from R15/R6 foot height delta when walking.
	@param Character Model? -- Active character model.
	@param Wobble number -- Wobble intensity scalar.
	@param CustomHost BasePart? -- Custom camera host override, if active.
	@return CFrame -- Computed roll offset CFrame.
]=]
function CameraRigHelper.ComputeFootWobble(Character: Model?, Wobble: number, CustomHost: BasePart?): CFrame
	if Wobble <= 0 or CustomHost ~= nil or not Character or not Character.Parent then
		return IDENTITY_ANGLES
	end

	const Hum = Character:FindFirstChildWhichIsA("Humanoid")
	if not Hum then
		return IDENTITY_ANGLES
	end

	local FootDeltaY = 0 :: number
	if Hum.RigType == Enum.HumanoidRigType.R15 then
		const LeftFoot = Character:FindFirstChild("LeftFoot")
		const RightFoot = Character:FindFirstChild("RightFoot")
		if LeftFoot and LeftFoot:IsA("BasePart") and RightFoot and RightFoot:IsA("BasePart") then
			FootDeltaY = (LeftFoot.Position.Y - RightFoot.Position.Y) / 1.5
		end
	elseif Hum.RigType == Enum.HumanoidRigType.R6 then
		const LeftLeg = Character:FindFirstChild("Left Leg")
		const RightLeg = Character:FindFirstChild("Right Leg")
		if LeftLeg and LeftLeg:IsA("BasePart") and RightLeg and RightLeg:IsA("BasePart") then
			FootDeltaY = LeftLeg.Position.Y - RightLeg.Position.Y
		end
	end

	if FootDeltaY == 0 then
		return IDENTITY_ANGLES
	end
	return CFrame.fromEulerAnglesYXZ(0, 0, math.rad(FootDeltaY * (Wobble ^ 1.5)))
end

--[=[
	Updates character root alignment or R15 upper-body Motor6D lean toward the pointer.
	@param State CameraPresets.CameraRuntimeState -- Mutable camera runtime state.
	@param Service any -- CameraService singleton table.
	@param CamCFrame CFrame -- Unsmoothed camera target CFrame.
	@param Mouse Mouse -- LocalPlayer mouse instance.
]=]
function CameraRigHelper.UpdateCharacterRig(
	State: CameraPresets.CameraRuntimeState,
	Service: any,
	CamCFrame: CFrame,
	Mouse: Mouse
)
	const ActiveChar = State.CurrentCharacter
	if State.CustomHost ~= nil or not ActiveChar or not ActiveChar.Parent then
		return
	end

	workspace.Retargeting = Enum.AnimatorRetargetingMode.Disabled
	const Humanoid = ActiveChar:FindFirstChildWhichIsA("Humanoid")
	const RootCandidate = ActiveChar:FindFirstChild("HumanoidRootPart")
	if not Humanoid or Humanoid.Health <= 0 or not RootCandidate or not RootCandidate:IsA("BasePart") then
		return
	end

	const UpperTorso = ActiveChar:FindFirstChild("UpperTorso")
	const Head = ActiveChar:FindFirstChild("Head")
	const IsR15 = (Humanoid.RigType == Enum.HumanoidRigType.R15) :: boolean
	const Waist = if IsR15 and UpperTorso then UpperTorso:FindFirstChildWhichIsA("Motor6D") else nil
	const Neck = if IsR15 and Head then Head:FindFirstChildWhichIsA("Motor6D") else nil

	if Waist and not State.WaistCache then
		State.WaistCache = Waist.C0
	end
	if Neck and not State.NeckCache then
		State.NeckCache = Neck.C0
	end

	if Service.AlignChar and Humanoid.FloorMaterial ~= Enum.Material.Water then
		if Waist and State.WaistCache and Waist.C0 ~= State.WaistCache then
			Waist.C0 = State.WaistCache
		end
		if Neck and State.NeckCache and Neck.C0 ~= State.NeckCache then
			Neck.C0 = State.NeckCache
		end
		const _Pitch: number, YawAngle: number, _Roll: number = CamCFrame:ToEulerAnglesYXZ()
		const ShoulderBias = if Service.Offset.X == 0 then 0 else -6 :: number
		RootCandidate.CFrame = CFrame.fromEulerAnglesYXZ(0, YawAngle + math.rad(ShoulderBias), 0) + RootCandidate.Position
		return
	end

	if not IsR15 then
		return
	end

	if Service.BodyFollow and Waist and Neck and State.WaistCache and State.NeckCache then
		const MouseLook = Mouse.Hit.LookVector :: Vector3
		const RootLeftDir = (CFrame.Angles(RootCandidate.CFrame:ToEulerAnglesYXZ()) * CFrame.new(-1, 0, 0)).Position.Unit :: Vector3
		const TargetWaist = CFrame.fromEulerAnglesYXZ(
			math.rad(MouseLook:Dot(WORLD_UP) * 10),
			math.rad(MouseLook:Dot(RootLeftDir) * 40),
			0
		) + State.WaistCache.Position
		const TargetNeck = CFrame.fromEulerAnglesYXZ(math.rad(MouseLook:Dot(WORLD_UP) * 30), 0, 0) + State.NeckCache.Position
		Waist.C0 = Waist.C0:Lerp(TargetWaist, 0.25)
		Neck.C0 = Neck.C0:Lerp(TargetNeck, 0.25)
		return
	end

	if Waist and State.WaistCache and Waist.C0 ~= State.WaistCache then
		Waist.C0 = State.WaistCache
	end
	if Neck and State.NeckCache and Neck.C0 ~= State.NeckCache then
		Neck.C0 = State.NeckCache
	end
end

--[=[
	Creates or tweens out the letterbox bars for the Cinematic camera view.
	@param LocalPlayer Player -- Active LocalPlayer.
	@param ViewType string -- Newly applied camera view name.
]=]
function CameraRigHelper.SyncCinematicBars(LocalPlayer: Player, ViewType: string)
	const PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
	if ViewType == "Cinematic" then
		const Gui = Instance.new("ScreenGui")
		Gui.Name = "CameraService_Cinematic_Effect"
		Gui.Enabled = true
		Gui.ResetOnSpawn = false
		Gui.IgnoreGuiInset = true
		Gui.Parent = PlayerGui

		const TopBar = Instance.new("Frame")
		TopBar.BackgroundColor3 = Color3.new(0, 0, 0)
		TopBar.Name = "Frame1"
		TopBar.BorderSizePixel = 0
		TopBar.Size = UDim2.new(1, 0, 0.135, 0)
		TopBar.Position = UDim2.new(0, 0, -0.136, 0)
		TopBar.Parent = Gui

		const BottomBar = TopBar:Clone()
		BottomBar.Name = "Frame2"
		BottomBar.Position = UDim2.new(0, 0, 1, 0)
		BottomBar.Parent = Gui

		TopBar:TweenPosition(UDim2.new(0, 0, 0, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Sine, 0.25, true)
		BottomBar:TweenPosition(UDim2.new(0, 0, 0.865, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Sine, 0.25, true)
		return
	end

	const ExistingGui = PlayerGui:FindFirstChild("CameraService_Cinematic_Effect")
	if not ExistingGui then
		return
	end
	const TopBar = ExistingGui:FindFirstChild("Frame1")
	const BottomBar = ExistingGui:FindFirstChild("Frame2")
	if TopBar and TopBar:IsA("Frame") then
		TopBar:TweenPosition(UDim2.new(0, 0, -0.136, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Sine, 0.25, true)
	end
	if BottomBar and BottomBar:IsA("Frame") then
		BottomBar:TweenPosition(UDim2.new(0, 0, 1, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Sine, 0.25, true)
	end
	task.wait(0.25)
	ExistingGui:Destroy()
end

return CameraRigHelper
