Claim result: true table: 0x49a6a8e9eabe3445
```[cite: 16]

`ActionRemote:InvokeServer("Quests", "Claim", id)` succeeded and returned a full transaction response table without a `"slow down"` error[cite: 15, 16].

### Why Quests Failed Previously
The previous code made rapid requests:
1. It queried `("Quests")`.
2. It called `("Quests", "Claim", questId)` immediately after[cite: 15].
3. It attempted multi-argument variants like `("Quests", "Claim", "Daily", questId)`.

This rapid burst overwhelmed the server's request throttle and produced `"slow down"`[cite: 15]. When properly spaced (~1.2 seconds between calls), each completed quest claims cleanly.

---

### Full Production Script (V10.2)

Replace your GitHub script file with this version:

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local VirtualUser = game:GetService("VirtualUser")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes", 5)
local ActionRemote = RemotesFolder and RemotesFolder:FindFirstChild("Action")
local NetRemote = RemotesFolder and RemotesFolder:FindFirstChild("Net")
local TrackRemote = RemotesFolder and RemotesFolder:FindFirstChild("Track")

local CONFIG = {
    MysteryCrate = {
        CategoryName = "Mystery Crates",
        Names = {"Mystery Crate", "MysteryCrate", "Crate", "CrateSpawn"},
        Tags = {"MysteryCrateTag", "CrateTag", "MysteryCrate"},
        Color = Color3.fromRGB(255, 170, 0),
        FolderNames = {"Crates", "MysteryCrates", "SpawnedCollectibles"}
    },
    CandyPail = {
        CategoryName = "Candy Pails",
        Names = {"Candy Pail", "CandyPail", "CandyBucket", "Pail", "Candy", "HalloweenBucket"},
        Tags = {"CandyPailTag", "PailTag", "CandyPail"},
        Color = Color3.fromRGB(255, 85, 255),
        FolderNames = {"CandyPails", "Pails", "EventCollectibles", "Candy"}
    },
    Settings = {
        HighlightsEnabled = true,
        DisplayLabels = true,
        DisplayDistance = true,
        AutoRefresh = true,
        RefreshInterval = 2.0,
        FillTransparency = 0.7,
        OutlineTransparency = 0.1,
        StopDistance = 3,
        AutoFarmEnabled = false,
        AntiAfkEnabled = true,
        AutoRebirthEnabled = false,
        AutoSpinWheelEnabled = false,
        AutoClaimQuestsEnabled = false,
        AutoClaimDailyEnabled = false,
        ModDetectorEnabled = true,
        PlayerESPEnabled = false,
        WalkSpeedEnabled = false,
        WalkSpeedBonus = 16,
        JumpPowerEnabled = false,
        JumpPowerBonus = 50,
        AutoBrewEnabled = false,
        BrewLimit = 999999,
        BrewsCompleted = 0,
        ToggleKey = Enum.KeyCode.RightShift
    }
}

local State = {
    ActiveTab = "Finder",
    CategoryFilter = "All",
    SearchQuery = "",
    DetectedCollectibles = {},
    CurrentTrackedTarget = nil,
    AutoWalkEnabled = false,
    OriginalWalkSpeed = 16,
    OriginalJumpPower = 50,
    HasCapturedOriginals = false,
    CratesClaimed = 0,
    PailsClaimed = 0,
    ScriptStartTime = tick(),
    AutoFarmStartTime = 0,
    PreviousTargetInstance = nil,
    PreviousTargetCategory = nil,
    Waypoints = {},
    CurrentWaypointIndex = 1,
    LastPathCalcTick = 0,
    LastPosition = Vector3.zero,
    StuckTimer = 0,
    IsComputingPath = false,
    Highlights = {},
    BillboardGuis = {},
    PlayerESPs = {},
    Connections = {},
    GuiInstance = nil,
    Views = {},
    StatsLabelRef = nil,
    IsMinimized = false,
    IsListeningForKey = false,
    LastAntiAfkTick = 0,
    SpinLogs = {},
    BrewLogs = {},
    SpinLogLabels = {},
    BrewLogLabels = {},
    SpinWin = nil,
    BrewWin = nil
}

local function GetCharacter() return LocalPlayer.Character end
local function GetHumanoid() local c = GetCharacter() return c and c:FindFirstChildWhichIsA("Humanoid") end
local function GetRootPart() local c = GetCharacter() return c and c:FindFirstChild("HumanoidRootPart") end
local function GetCharacterPosition() local r = GetRootPart() return r and r.Position end

local function CalculateDistance(pos)
    local cp = GetCharacterPosition()
    if cp then return math.floor((pos - cp).Magnitude) end
    return 999999
end

local function GetPrimaryPart(obj)
    if obj:IsA("BasePart") then return obj
    elseif obj:IsA("Model") then return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart", true) end
    return nil
end

local function CreateCorner(parent, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius)
    corner.Parent = parent
    return corner
end

local function CreateStroke(parent, color, thickness)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Thickness = thickness
    stroke.Parent = parent
    return stroke
end

local function FormatTime(totalSeconds)
    local m = math.floor(totalSeconds / 60)
    local s = totalSeconds % 60
    return string.format("%02d:%02d", m, s)
end

local function AddLogEntry(logType, message)
    local targetList = (logType == "Spin") and State.SpinLogs or State.BrewLogs
    local targetLabels = (logType == "Spin") and State.SpinLogLabels or State.BrewLogLabels
    local formatted = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(message))

    table.insert(targetList, 1, formatted)
    if #targetList > 10 then table.remove(targetList, 11) end

    for i = 1, 10 do
        if targetLabels[i] then targetLabels[i].Text = targetList[i] or "" end
    end
end

local function SafeInvoke(...)
    if not ActionRemote then return nil end
    local args = {...}
    local success, res = pcall(function()
        return ActionRemote:InvokeServer(unpack(args))
    end)
    if success then return res end
    return nil
end

local function SafeFireEvent(...)
    local args = {...}
    if NetRemote then pcall(function() NetRemote:FireServer(unpack(args)) end) end
    if TrackRemote then pcall(function() TrackRemote:FireServer(unpack(args)) end) end
end

local function GetPlayerCandy()
    local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
    local candyVal = leaderstats and (leaderstats:FindFirstChild("Candy") or leaderstats:FindFirstChild("Candies"))
    if candyVal and candyVal:IsA("ValueBase") then return candyVal.Value end
    local dataFolder = LocalPlayer:FindFirstChild("Candy") or LocalPlayer:FindFirstChild("Data")
    if dataFolder and dataFolder:FindFirstChild("Candy") then return dataFolder.Candy.Value end
    return nil
end

local function GetPlayerCash()
    local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
    local cashVal = leaderstats and (leaderstats:FindFirstChild("Cash") or leaderstats:FindFirstChild("Money"))
    if cashVal and cashVal:IsA("ValueBase") then return cashVal.Value end
    return nil
end

-- 1. Auto Rebirth
task.spawn(function()
    while true do
        task.wait(3.0)
        if not State.GuiInstance then break end
        if CONFIG.Settings.AutoRebirthEnabled then
            pcall(function()
                SafeInvoke("Rebirth")
                SafeInvoke("Rebirth", "Buy")
                SafeFireEvent("Rebirth")
            end)
        end
    end
end)

-- 2. Auto Spin Wheel
task.spawn(function()
    while true do
        task.wait(5.0)
        if not State.GuiInstance then break end
        if CONFIG.Settings.AutoSpinWheelEnabled then
            pcall(function()
                local res = SafeInvoke("Spin", "Roll") or SafeInvoke("Wheel", "Spin") or SafeInvoke("Spin")
                if res and type(res) == "table" and res.ok then
                    AddLogEntry("Spin", res.msg or res.Prize or res.Reward or "Spin Token Used")
                else
                    local hudMain = LocalPlayer.PlayerGui:FindFirstChild("HUD") and LocalPlayer.PlayerGui.HUD:FindFirstChild("Main")
                    if hudMain then
                        local spinBtn = hudMain.Right:FindFirstChild("Spin")
                        if spinBtn and spinBtn.Visible then
                            local absPos = spinBtn.AbsolutePosition
                            local absSize = spinBtn.AbsoluteSize
                            local inset, _ = GuiService:GetGuiInset()
                            local cx = absPos.X + absSize.X / 2
                            local cy = absPos.Y + absSize.Y / 2 + inset.Y

                            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
                            task.wait(0.04)
                            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)

                            task.wait(0.3)
                            for _, child in ipairs(hudMain:GetDescendants()) do
                                if child:IsA("GuiButton") and child.Visible then
                                    local t = child.Name:lower() .. " " .. (child:IsA("TextButton") and child.Text:lower() or "")
                                    if t:find("spin") or t:find("roll") or t:find("free") then
                                        local p = child.AbsolutePosition
                                        local s = child.AbsoluteSize
                                        VirtualInputManager:SendMouseButtonEvent(p.X + s.X/2, p.Y + s.Y/2 + inset.Y, 0, true, game, 1)
                                        task.wait(0.04)
                                        VirtualInputManager:SendMouseButtonEvent(p.X + s.X/2, p.Y + s.Y/2 + inset.Y, 0, false, game, 1)
                                        AddLogEntry("Spin", "Claimed Free Wheel Spin")
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end
    end
end)

-- 3. Auto Claim Daily
task.spawn(function()
    while true do
        task.wait(6.0)
        if not State.GuiInstance then break end
        if CONFIG.Settings.AutoClaimDailyEnabled then
            pcall(function()
                local res = SafeInvoke("ClaimDaily") or SafeInvoke("Daily", "Claim")
                if res and type(res) == "table" and res.ok then
                    AddLogEntry("Spin", "Daily: Claimed Daily Reward!")
                end
            end)
        end
    end
end)

-- 4. Auto Claim Quests (Rate-Limited to Prevent Throttle Errors)
task.spawn(function()
    while true do
        task.wait(4.0)
        if not State.GuiInstance then break end
        if CONFIG.Settings.AutoClaimQuestsEnabled then
            pcall(function()
                local questData = SafeInvoke("Quests")
                if questData and type(questData) == "table" and questData.ok then
                    local function ProcessCategory(catTable)
                        if type(catTable) ~= "table" then return end
                        for questId, info in pairs(catTable) do
                            task.wait(1.2)
                            local res = SafeInvoke("Quests", "Claim", questId)
                            if res and type(res) == "table" and res.ok then
                                AddLogEntry("Spin", "Quest Completed: ID " .. tostring(questId))
                            end
                        end
                    end
                    ProcessCategory(questData.Daily)
                    ProcessCategory(questData.Weekly)
                    ProcessCategory(questData.Ach)
                else
                    for _, id in ipairs({1, 2, 3, 4, 5, "dGold", "dPlay", "dMystery"}) do
                        task.wait(1.2)
                        SafeInvoke("Quests", "Claim", id)
                    end
                end
            end)
        end
    end
end)

-- 5. Auto Brew Cauldron (Dynamic Inset-Corrected Click Engine)
task.spawn(function()
    while true do
        task.wait(2.2)
        if not State.GuiInstance then break end
        if CONFIG.Settings.AutoBrewEnabled and CONFIG.Settings.BrewsCompleted < CONFIG.Settings.BrewLimit then
            pcall(function()
                local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
                local hudMain = playerGui and playerGui:FindFirstChild("HUD") and playerGui.HUD:FindFirstChild("Main")
                if not hudMain then return end

                local halFrame = hudMain:FindFirstChild("Halloween")
                local cauldronFrame = halFrame and halFrame:FindFirstChild("Body") and halFrame.Body:FindFirstChild("Cauldron")
                local brewBtn = cauldronFrame and cauldronFrame:FindFirstChild("Brew")

                if not brewBtn or not brewBtn.Visible then return end

                for _, child in ipairs(brewBtn:GetDescendants()) do
                    if child:IsA("GuiObject") and child ~= brewBtn then
                        child.Active = false
                    end
                end

                local startCandy = GetPlayerCandy()
                local startCash = GetPlayerCash()

                local inset, _ = GuiService:GetGuiInset()
                local absPos = brewBtn.AbsolutePosition
                local absSize = brewBtn.AbsoluteSize
                local clickX = absPos.X + (absSize.X / 2)
                local clickY = absPos.Y + (absSize.Y / 2) + inset.Y

                VirtualInputManager:SendMouseButtonEvent(clickX, clickY, 0, true, game, 1)
                task.wait(0.04)
                VirtualInputManager:SendMouseButtonEvent(clickX, clickY, 0, false, game, 1)

                task.wait(0.5)

                local detectedPrize = nil
                local endCandy = GetPlayerCandy()
                local endCash = GetPlayerCash()

                if startCandy and endCandy and (endCandy - startCandy) > 0 then
                    detectedPrize = "+150 Candy Back!"
                elseif startCash and endCash and (endCash - startCash) > 0 then
                    detectedPrize = string.format("Cash Payout (+$%s)", tostring(endCash - startCash))
                end

                if not detectedPrize then
                    for _, popup in ipairs(hudMain:GetChildren()) do
                        if popup:IsA("GuiObject") and popup.Visible and popup ~= halFrame and not popup.Name:find("Halloween") then
                            local lbl = popup:FindFirstChildWhichIsA("TextLabel", true)
                            if lbl and #lbl.Text > 1 then
                                local t = lbl.Text:gsub("<[^>]-b>", ""):gsub("<[^>]->", "")
                                if not t:lower():find("store") and not t:lower():find("cauldron") and not t:lower():find("mummy wraps") then
                                    detectedPrize = t
                                    break
                                end
                            end
                        end
                    end
                end

                if not detectedPrize then
                    detectedPrize = "Cauldron Brew (-75 Candy)"
                end

                CONFIG.Settings.BrewsCompleted = CONFIG.Settings.BrewsCompleted + 1
                AddLogEntry("Brew", string.format("%s (x%d)", detectedPrize, CONFIG.Settings.BrewsCompleted))
            end)
        end
    end
end)

local function UpdatePlayerESP()
    if not CONFIG.Settings.PlayerESPEnabled then
        for plr, esp in pairs(State.PlayerESPs) do
            if esp.Highlight then esp.Highlight:Destroy() end
            if esp.Billboard then esp.Billboard:Destroy() end
        end
        table.clear(State.PlayerESPs)
        return
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
            local char = player.Character
            if not State.PlayerESPs[player] or State.PlayerESPs[player].Character ~= char then
                if State.PlayerESPs[player] then
                    if State.PlayerESPs[player].Highlight then State.PlayerESPs[player].Highlight:Destroy() end
                    if State.PlayerESPs[player].Billboard then State.PlayerESPs[player].Billboard:Destroy() end
                end

                local hl = Instance.new("Highlight")
                hl.FillColor = Color3.fromRGB(255, 50, 50)
                hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                hl.FillTransparency = 0.6
                hl.OutlineTransparency = 0.2
                hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                hl.Parent = char

                local bb = Instance.new("BillboardGui")
                bb.Size = UDim2.new(0, 200, 0, 30)
                bb.StudsOffset = Vector3.new(0, 3.5, 0)
                bb.AlwaysOnTop = true

                local txt = Instance.new("TextLabel")
                txt.Size = UDim2.new(1, 0, 1, 0)
                txt.BackgroundTransparency = 1
                txt.Text = player.Name
                txt.TextColor3 = Color3.fromRGB(255, 255, 255)
                txt.TextStrokeTransparency = 0.2
                txt.Font = Enum.Font.GothamBold
                txt.TextSize = 12
                txt.Parent = bb
                bb.Parent = char

                State.PlayerESPs[player] = {Highlight = hl, Billboard = bb, Character = char, Label = txt}
            else
                local dist = CalculateDistance(char.HumanoidRootPart.Position)
                State.PlayerESPs[player].Label.Text = player.Name .. " [" .. tostring(dist) .. "s]"
            end
        end
    end
end

local function ApplyPlayerModifications()
    local hum = GetHumanoid()
    if not hum then return end

    if not State.HasCapturedOriginals then
        State.OriginalWalkSpeed = hum.WalkSpeed > 0 and hum.WalkSpeed or 16
        State.OriginalJumpPower = hum.JumpPower > 0 and hum.JumpPower or 50
        State.HasCapturedOriginals = true
    end

    local targetSpeed = State.OriginalWalkSpeed
    if CONFIG.Settings.WalkSpeedEnabled then
        targetSpeed = State.OriginalWalkSpeed + CONFIG.Settings.WalkSpeedBonus
    end
    if math.abs(hum.WalkSpeed - targetSpeed) > 0.1 then
        hum.WalkSpeed = targetSpeed
    end

    local targetJump = State.OriginalJumpPower
    if CONFIG.Settings.JumpPowerEnabled then
        targetJump = State.OriginalJumpPower + CONFIG.Settings.JumpPowerBonus
    end
    hum.UseJumpPower = true
    if math.abs(hum.JumpPower - targetJump) > 0.1 then
        hum.JumpPower = targetJump
        pcall(function() hum.JumpHeight = targetJump / 2.5 end)
    end
end

local function SetupAntiAfk()
    local conn = LocalPlayer.Idled:Connect(function()
        if CONFIG.Settings.AntiAfkEnabled then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new(0, 0))
            end)
        end
    end)
    table.insert(State.Connections, conn)
end

local function StepAntiAfk(dt)
    if not CONFIG.Settings.AntiAfkEnabled then return end
    State.LastAntiAfkTick = State.LastAntiAfkTick + dt
    if State.LastAntiAfkTick >= 50 then
        State.LastAntiAfkTick = 0
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:Button2Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
            task.wait(0.1)
            VirtualUser:Button2Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
        end)
    end
end

local function CheckPlayerForMod(player)
    if player == LocalPlayer then return end
    local nameLower = player.Name:lower()
    local dispLower = player.DisplayName:lower()
    local keywords = {"mod", "admin", "owner", "developer", "dev", "staff", "helper", "trial", "creator"}
    for _, kw in ipairs(keywords) do
        if string.find(nameLower, kw) or string.find(dispLower, kw) then
            pcall(function()
                StarterGui:SetCore("SendNotification", {
                    Title = "SECURITY ALERT!",
                    Text = "Mod joined: " .. player.Name,
                    Duration = 10
                })
            end)
            break
        end
    end
end

local function SetupModDetector()
    for _, p in ipairs(Players:GetPlayers()) do CheckPlayerForMod(p) end
    local conn = Players.PlayerAdded:Connect(function(p)
        if CONFIG.Settings.ModDetectorEnabled then CheckPlayerForMod(p) end
    end)
    table.insert(State.Connections, conn)
end

local function StopAutoWalk()
    local hum = GetHumanoid()
    if hum then hum:MoveTo(GetCharacterPosition() or Vector3.zero) end
    State.Waypoints = {}
    State.CurrentWaypointIndex = 1
    State.StuckTimer = 0
end

local function ComputePathToAsync(targetPos)
    if State.IsComputingPath then return end
    State.IsComputingPath = true

    task.defer(function()
        local charPos = GetCharacterPosition()
        if not charPos then State.IsComputingPath = false return end

        local path = PathfindingService:CreatePath({
            AgentRadius = 2.5,
            AgentHeight = 5.0,
            AgentCanJump = true,
            WaypointSpacing = 4.0
        })

        local success = pcall(function() path:ComputeAsync(charPos, targetPos) end)
        if success and path.Status == Enum.PathStatus.Success then
            State.Waypoints = path:GetWaypoints()
            State.CurrentWaypointIndex = 2
        else
            local hum = GetHumanoid()
            if hum then hum:MoveTo(targetPos) end
        end
        State.IsComputingPath = false
    end)
end

local function CheckForwardObstacleAndJump()
    local root = GetRootPart()
    local hum = GetHumanoid()
    if not root or not hum then return end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {GetCharacter()}

    local origin = root.Position - Vector3.new(0, 1, 0)
    local direction = root.CFrame.LookVector * 3.5

    local result = workspace:Raycast(origin, direction, rayParams)
    if result and result.Instance and result.Instance.CanCollide then
        hum.Jump = true
    end
end

local function StepAutoWalk()
    if not State.AutoWalkEnabled or not State.CurrentTrackedTarget then return end

    if not State.CurrentTrackedTarget:IsDescendantOf(workspace) then
        State.CurrentTrackedTarget = nil
        State.AutoWalkEnabled = false
        StopAutoWalk()
        return
    end

    local targetPart = GetPrimaryPart(State.CurrentTrackedTarget)
    local hum = GetHumanoid()
    local charPos = GetCharacterPosition()
    if not targetPart or not hum or not charPos then return end

    local dist = CalculateDistance(targetPart.Position)
    if dist <= CONFIG.Settings.StopDistance then
        if not CONFIG.Settings.AutoFarmEnabled then
            State.AutoWalkEnabled = false
            State.CurrentTrackedTarget = nil
            StopAutoWalk()
        end
        return
    end

    local movedDistance = (charPos - State.LastPosition).Magnitude
    State.LastPosition = charPos

    if movedDistance < 0.2 then
        State.StuckTimer = State.StuckTimer + 0.1
        if State.StuckTimer >= 0.8 then
            hum.Jump = true
            State.StuckTimer = 0
            State.LastPathCalcTick = 0
        end
    else
        State.StuckTimer = 0
    end

    CheckForwardObstacleAndJump()

    local now = tick()
    if now - State.LastPathCalcTick > 1.5 or #State.Waypoints == 0 then
        State.LastPathCalcTick = now
        ComputePathToAsync(targetPart.Position)
    end

    if #State.Waypoints > 0 and State.CurrentWaypointIndex <= #State.Waypoints then
        local wp = State.Waypoints[State.CurrentWaypointIndex]
        hum:MoveTo(wp.Position)

        if wp.Action == Enum.PathWaypointAction.Jump or (wp.Position.Y - charPos.Y) > 1.5 then
            hum.Jump = true
        end

        if (charPos - Vector3.new(wp.Position.X, charPos.Y, wp.Position.Z)).Magnitude < 3.5 then
            State.CurrentWaypointIndex = State.CurrentWaypointIndex + 1
        end
    else
        hum:MoveTo(targetPart.Position)
    end
end

local function RemoveHighlightFor(inst)
    if State.Highlights[inst] then State.Highlights[inst]:Destroy() State.Highlights[inst] = nil end
    if State.BillboardGuis[inst] then State.BillboardGuis[inst]:Destroy() State.BillboardGuis[inst] = nil end
end

local function ClearAllHighlights()
    for _, hl in pairs(State.Highlights) do hl:Destroy() end
    table.clear(State.Highlights)
    for _, bb in pairs(State.BillboardGuis) do bb:Destroy() end
    table.clear(State.BillboardGuis)
end

local function ApplyHighlight(itemData)
    local inst = itemData.Instance
    if not inst or not inst:IsDescendantOf(workspace) then return end
    if State.Highlights[inst] then return end
    if not CONFIG.Settings.HighlightsEnabled then return end

    local color = itemData.Category == "CandyPail" and CONFIG.CandyPail.Color or CONFIG.MysteryCrate.Color

    local hl = Instance.new("Highlight")
    hl.Name = "CollectibleHighlight"
    hl.Adornee = inst
    hl.FillColor = color
    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
    hl.FillTransparency = CONFIG.Settings.FillTransparency
    hl.OutlineTransparency = CONFIG.Settings.OutlineTransparency
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = inst
    State.Highlights[inst] = hl

    if CONFIG.Settings.DisplayLabels then
        local targetPart = GetPrimaryPart(inst)
        if targetPart then
            local bb = Instance.new("BillboardGui")
            bb.Name = "CollectibleBillboard"
            bb.Adornee = targetPart
            bb.Size = UDim2.new(0, 150, 0, 36)
            bb.StudsOffset = Vector3.new(0, 3, 0)
            bb.AlwaysOnTop = true

            local label = Instance.new("TextLabel")
            label.Size = UDim2.new(1, 0, 1, 0)
            label.BackgroundTransparency = 0.4
            label.BackgroundColor3 = Color3.fromRGB(18, 19, 24)
            label.TextColor3 = color
            label.Font = Enum.Font.SourceSansBold
            label.TextSize = 13
            label.TextWrapped = true

            local distText = CONFIG.Settings.DisplayDistance and ("\n[" .. tostring(itemData.Distance) .. " studs]") or ""
            label.Text = itemData.Name .. distText
            label.Parent = bb
            CreateCorner(label, 6)
            CreateStroke(label, Color3.fromRGB(50, 52, 62), 1)

            bb.Parent = inst
            State.BillboardGuis[inst] = bb
        end
    end
end

local function IsCollectibleMatch(inst, categoryConfig)
    for _, tag in ipairs(categoryConfig.Tags) do
        if CollectionService:HasTag(inst, tag) then return true end
    end
    for _, name in ipairs(categoryConfig.Names) do
        if string.find(inst.Name:lower(), name:lower(), 1, true) then return true end
    end
    for _, folderName in ipairs(categoryConfig.FolderNames) do
        local folder = workspace:FindFirstChild(folderName)
        if folder and inst:IsDescendantOf(folder) then return true end
    end
    return false
end

local function ScanForCollectibles()
    if State.PreviousTargetInstance and not State.PreviousTargetInstance:IsDescendantOf(workspace) then
        if State.PreviousTargetCategory == "MysteryCrate" then
            State.CratesClaimed = State.CratesClaimed + 1
        elseif State.PreviousTargetCategory == "CandyPail" then
            State.PailsClaimed = State.PailsClaimed + 1
        end
        State.PreviousTargetInstance = nil
        State.PreviousTargetCategory = nil
    end

    local found = {}
    local seen = {}

    local function EvaluateInstance(inst)
        if seen[inst] then return end
        local part = GetPrimaryPart(inst)
        if not part then return end

        local category = nil
        if IsCollectibleMatch(inst, CONFIG.MysteryCrate) then
            category = "MysteryCrate"
        elseif IsCollectibleMatch(inst, CONFIG.CandyPail) then
            category = "CandyPail"
        end

        if category then
            seen[inst] = true
            local dist = CalculateDistance(part.Position)
            table.insert(found, {
                Instance = inst,
                Position = part.Position,
                Category = category,
                Distance = dist,
                Name = inst.Name
            })
        end
    end

    for _, folderName in ipairs({"Crates", "MysteryCrates", "CandyPails", "Pails", "SpawnedCollectibles", "Spawns", "Debris"}) do
        local folder = workspace:FindFirstChild(folderName)
        if folder then
            for _, child in ipairs(folder:GetChildren()) do EvaluateInstance(child) end
        end
    end

    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") or obj:IsA("BasePart") then EvaluateInstance(obj) end
    end

    table.sort(found, function(a, b) return a.Distance < b.Distance end)
    State.DetectedCollectibles = found

    for inst in pairs(State.Highlights) do
        local present = false
        for _, item in ipairs(found) do
            if item.Instance == inst then present = true break end
        end
        if not present then RemoveHighlightFor(inst) end
    end

    for _, item in ipairs(found) do ApplyHighlight(item) end

    if CONFIG.Settings.AutoFarmEnabled then
        if (not State.CurrentTrackedTarget or not State.CurrentTrackedTarget:IsDescendantOf(workspace)) and #State.DetectedCollectibles > 0 then
            State.CurrentTrackedTarget = State.DetectedCollectibles[1].Instance
            State.AutoWalkEnabled = true
        end
    end

    if State.CurrentTrackedTarget then
        State.PreviousTargetInstance = State.CurrentTrackedTarget
        for _, item in ipairs(found) do
            if item.Instance == State.CurrentTrackedTarget then
                State.PreviousTargetCategory = item.Category
                break
            end
        end
    end
end

local WaypointGui = nil
local ArrowFrame = nil
local DistanceText = nil

local function CreateWaypointUI()
    if WaypointGui then return end
    WaypointGui = Instance.new("ScreenGui")
    WaypointGui.Name = "CollectibleFinder_WaypointOverlay"
    WaypointGui.ResetOnSpawn = false
    WaypointGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    ArrowFrame = Instance.new("Frame")
    ArrowFrame.Size = UDim2.new(0, 40, 0, 40)
    ArrowFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    ArrowFrame.BackgroundTransparency = 1
    ArrowFrame.Visible = false
    ArrowFrame.Parent = WaypointGui

    local arrowIcon = Instance.new("TextLabel")
    arrowIcon.Size = UDim2.new(1, 0, 1, 0)
    arrowIcon.BackgroundTransparency = 1
    arrowIcon.Text = "▲"
    arrowIcon.TextColor3 = Color3.fromRGB(255, 204, 0)
    arrowIcon.TextSize = 28
    arrowIcon.Font = Enum.Font.SourceSansBold
    arrowIcon.Parent = ArrowFrame

    DistanceText = Instance.new("TextLabel")
    DistanceText.Size = UDim2.new(0, 100, 0, 20)
    DistanceText.Position = UDim2.new(0.5, -50, 1, 2)
    DistanceText.BackgroundTransparency = 0.5
    DistanceText.BackgroundColor3 = Color3.fromRGB(15, 16, 20)
    DistanceText.TextColor3 = Color3.fromRGB(255, 255, 255)
    DistanceText.TextSize = 12
    DistanceText.Font = Enum.Font.SourceSansBold
    DistanceText.Parent = ArrowFrame
    CreateCorner(DistanceText, 4)
end

local function UpdateWaypointTracking()
    if not State.CurrentTrackedTarget or not State.CurrentTrackedTarget:IsDescendantOf(workspace) then
        if ArrowFrame then ArrowFrame.Visible = false end
        return
    end

    local primaryPart = GetPrimaryPart(State.CurrentTrackedTarget)
    if not primaryPart then
        if ArrowFrame then ArrowFrame.Visible = false end
        return
    end

    local worldPos = primaryPart.Position
    local screenPos, onScreen = Camera:WorldToViewportPoint(worldPos)
    local viewportSize = Camera.ViewportSize

    ArrowFrame.Visible = true
    local dist = CalculateDistance(worldPos)
    DistanceText.Text = tostring(dist) .. " studs"

    if onScreen then
        ArrowFrame.Position = UDim2.new(0, screenPos.X, 0, screenPos.Y)
        ArrowFrame.Rotation = 180
    else
        local center = viewportSize / 2
        local dir = (Vector2.new(screenPos.X, screenPos.Y) - center).Unit
        local edgePos = center + dir * (math.min(viewportSize.X, viewportSize.Y) * 0.4)
        ArrowFrame.Position = UDim2.new(0, edgePos.X, 0, edgePos.Y)
        local angle = math.atan2(dir.Y, dir.X)
        ArrowFrame.Rotation = math.deg(angle) - 90
    end
end

local function UnloadScript()
    for _, conn in ipairs(State.Connections) do
        if conn and conn.Connected then conn:Disconnect() end
    end
    table.clear(State.Connections)

    StopAutoWalk()
    State.AutoWalkEnabled = false
    State.CurrentTrackedTarget = nil
    CONFIG.Settings.AutoFarmEnabled = false
    CONFIG.Settings.AntiAfkEnabled = false
    CONFIG.Settings.AutoRebirthEnabled = false
    CONFIG.Settings.AutoSpinWheelEnabled = false
    CONFIG.Settings.AutoClaimQuestsEnabled = false
    CONFIG.Settings.AutoClaimDailyEnabled = false
    CONFIG.Settings.AutoBrewEnabled = false
    CONFIG.Settings.WalkSpeedEnabled = false
    CONFIG.Settings.JumpPowerEnabled = false
    CONFIG.Settings.PlayerESPEnabled = false
    
    UpdatePlayerESP()

    local hum = GetHumanoid()
    if hum and State.HasCapturedOriginals then
        hum.WalkSpeed = State.OriginalWalkSpeed
        hum.UseJumpPower = true
        hum.JumpPower = State.OriginalJumpPower
        pcall(function() hum.JumpHeight = State.OriginalJumpPower / 2.5 end)
    end

    ClearAllHighlights()

    if WaypointGui then WaypointGui:Destroy() WaypointGui = nil end
    if State.GuiInstance then State.GuiInstance:Destroy() State.GuiInstance = nil end
end

local PopulateFinderList

local function SwitchTab(targetTab)
    State.ActiveTab = targetTab
    for tabName, viewFrame in pairs(State.Views) do
        viewFrame.Visible = (tabName == targetTab)
    end
    if targetTab == "Finder" then
        PopulateFinderList()
    end
end

local function CreateStaticLogWindow(name, titleStr, pos, logKey)
    local win = Instance.new("Frame")
    win.Name = name
    win.Size = UDim2.new(0, 240, 0, 205)
    win.Position = pos
    win.BackgroundColor3 = Color3.fromRGB(18, 19, 24)
    win.Visible = false
    win.Parent = State.GuiInstance
    CreateCorner(win, 8)
    CreateStroke(win, Color3.fromRGB(50, 53, 65), 1)

    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 28)
    titleBar.BackgroundColor3 = Color3.fromRGB(26, 28, 35)
    titleBar.Parent = win
    CreateCorner(titleBar, 8)

    local dragging, dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = win.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    local titleText = Instance.new("TextLabel")
    titleText.Size = UDim2.new(0.7, 0, 1, 0)
    titleText.Position = UDim2.new(0, 10, 0, 0)
    titleText.BackgroundTransparency = 1
    titleText.Text = titleStr
    titleText.TextColor3 = Color3.fromRGB(245, 245, 250)
    titleText.Font = Enum.Font.GothamBold
    titleText.TextSize = 12
    titleText.TextXAlignment = Enum.TextXAlignment.Left
    titleText.Parent = titleBar

    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.new(0, 20, 0, 20)
    minBtn.Position = UDim2.new(1, -24, 0.5, -10)
    minBtn.BackgroundColor3 = Color3.fromRGB(45, 48, 60)
    minBtn.Text = "-"
    minBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 12
    minBtn.Parent = titleBar
    CreateCorner(minBtn, 4)

    local contentHolder = Instance.new("Frame")
    contentHolder.Size = UDim2.new(1, -10, 1, -34)
    contentHolder.Position = UDim2.new(0, 5, 0, 30)
    contentHolder.BackgroundTransparency = 1
    contentHolder.Parent = win

    local labelTable = (logKey == "Spin") and State.SpinLogLabels or State.BrewLogLabels

    for i = 1, 10 do
        local row = Instance.new("TextLabel")
        row.Size = UDim2.new(1, 0, 0, 16)
        row.Position = UDim2.new(0, 0, 0, (i - 1) * 17)
        row.BackgroundTransparency = 1
        row.Text = ""
        row.TextColor3 = Color3.fromRGB(200, 200, 210)
        row.Font = Enum.Font.Gotham
        row.TextSize = 10
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextTruncate = Enum.TextTruncate.AtEnd
        row.Parent = contentHolder
        labelTable[i] = row
    end

    local isMin = false
    minBtn.MouseButton1Click:Connect(function()
        isMin = not isMin
        if isMin then
            win.Size = UDim2.new(0, 240, 0, 28)
            contentHolder.Visible = false
            minBtn.Text = "+"
        else
            win.Size = UDim2.new(0, 240, 0, 205)
            contentHolder.Visible = true
            minBtn.Text = "-"
        end
    end)

    return win
end

local function BuildGUI()
    local existing = LocalPlayer.PlayerGui:FindFirstChild("TycoonCollectibleFinderGui")
    if existing then existing:Destroy() end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TycoonCollectibleFinderGui"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    State.GuiInstance = screenGui

    local main = Instance.new("Frame")
    main.Name = "MainWindow"
    main.Size = UDim2.new(0, 460, 0, 410)
    main.Position = UDim2.new(0.5, -230, 0.5, -205)
    main.BackgroundColor3 = Color3.fromRGB(18, 19, 24)
    main.ClipsDescendants = true
    main.Parent = screenGui

    CreateCorner(main, 12)
    CreateStroke(main, Color3.fromRGB(50, 53, 65), 1.5)

    State.SpinWin = CreateStaticLogWindow("SpinLogsWin", "Spin Rewards Log", UDim2.new(0, 15, 0, 45), "Spin")
    State.BrewWin = CreateStaticLogWindow("BrewLogsWin", "Brew Rewards Log", UDim2.new(0, 15, 0, 260), "Brew")

    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 38)
    titleBar.BackgroundColor3 = Color3.fromRGB(26, 28, 35)
    titleBar.Parent = main
    CreateCorner(titleBar, 12)

    local dragging, dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    local titleText = Instance.new("TextLabel")
    titleText.Size = UDim2.new(0.6, 0, 1, 0)
    titleText.Position = UDim2.new(0, 14, 0, 0)
    titleText.BackgroundTransparency = 1
    titleText.Text = "Tycoon Pro Automation"
    titleText.TextColor3 = Color3.fromRGB(245, 245, 250)
    titleText.Font = Enum.Font.GothamBold
    titleText.TextSize = 14
    titleText.TextXAlignment = Enum.TextXAlignment.Left
    titleText.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 28, 0, 28)
    closeBtn.Position = UDim2.new(1, -32, 0.5, -14)
    closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
    closeBtn.Text = "X"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 12
    closeBtn.Parent = titleBar
    CreateCorner(closeBtn, 6)

    closeBtn.MouseButton1Click:Connect(function()
        main.Visible = false
    end)

    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.new(0, 28, 0, 28)
    minBtn.Position = UDim2.new(1, -66, 0.5, -14)
    minBtn.BackgroundColor3 = Color3.fromRGB(45, 48, 60)
    minBtn.Text = "-"
    minBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 14
    minBtn.Parent = titleBar
    CreateCorner(minBtn, 6)

    local contentHolder = Instance.new("Frame")
    contentHolder.Name = "ContentHolder"
    contentHolder.Size = UDim2.new(1, 0, 1, -38)
    contentHolder.Position = UDim2.new(0, 0, 0, 38)
    contentHolder.BackgroundTransparency = 1
    contentHolder.Parent = main

    minBtn.MouseButton1Click:Connect(function()
        State.IsMinimized = not State.IsMinimized
        if State.IsMinimized then
            main.Size = UDim2.new(0, 460, 0, 38)
            contentHolder.Visible = false
            minBtn.Text = "+"
        else
            main.Size = UDim2.new(0, 460, 0, 410)
            contentHolder.Visible = true
            minBtn.Text = "-"
        end
    end)

    local toggleConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if State.IsListeningForKey then return end
        if not gameProcessed and input.KeyCode == CONFIG.Settings.ToggleKey then
            main.Visible = not main.Visible
        end
    end)
    table.insert(State.Connections, toggleConn)

    local navBar = Instance.new("Frame")
    navBar.Size = UDim2.new(1, -20, 0, 32)
    navBar.Position = UDim2.new(0, 10, 0, 10)
    navBar.BackgroundColor3 = Color3.fromRGB(13, 14, 18)
    navBar.Parent = contentHolder
    CreateCorner(navBar, 6)

    local contentFrame = Instance.new("Frame")
    contentFrame.Name = "ContentFrame"
    contentFrame.Size = UDim2.new(1, -20, 1, -104)
    contentFrame.Position = UDim2.new(0, 10, 0, 50)
    contentFrame.BackgroundTransparency = 1
    contentFrame.Parent = contentHolder

    local tabButtons = {}
    local function CreateTabButton(name, text, widthScale, xPos)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(widthScale, -2, 1, 0)
        btn.Position = xPos
        btn.BackgroundColor3 = State.ActiveTab == name and Color3.fromRGB(45, 48, 60) or Color3.fromRGB(200, 22, 28)
        btn.Text = text
        btn.TextColor3 = Color3.fromRGB(220, 220, 230)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.Parent = navBar
        CreateCorner(btn, 5)
        tabButtons[name] = btn

        btn.MouseButton1Click:Connect(function()
            for _, b in pairs(tabButtons) do b.BackgroundColor3 = Color3.fromRGB(20, 22, 28) end
            btn.BackgroundColor3 = Color3.fromRGB(45, 48, 60)
            SwitchTab(name)
        end)
    end

    CreateTabButton("Finder", "Finder", 0.19, UDim2.new(0, 0, 0, 0))
    CreateTabButton("Waypoints", "Waypts", 0.19, UDim2.new(0.20, 0, 0, 0))
    CreateTabButton("Grinding", "Grind", 0.19, UDim2.new(0.40, 0, 0, 0))
    CreateTabButton("Player", "Player", 0.19, UDim2.new(0.60, 0, 0, 0))
    CreateTabButton("Settings", "Config", 0.22, UDim2.new(0.80, 0, 0, 0))

    local statsPanel = Instance.new("Frame")
    statsPanel.Size = UDim2.new(1, -20, 0, 36)
    statsPanel.Position = UDim2.new(0, 10, 1, -44)
    statsPanel.BackgroundColor3 = Color3.fromRGB(13, 14, 18)
    statsPanel.Parent = contentHolder
    CreateCorner(statsPanel, 6)
    CreateStroke(statsPanel, Color3.fromRGB(35, 37, 46), 1)

    local statsLabel = Instance.new("TextLabel")
    statsLabel.Size = UDim2.new(1, -10, 1, 0)
    statsLabel.Position = UDim2.new(0, 5, 0, 0)
    statsLabel.BackgroundTransparency = 1
    statsLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
    statsLabel.Font = Enum.Font.GothamBold
    statsLabel.TextSize = 11
    statsLabel.TextWrapped = true
    statsLabel.Text = "Crates: 0 | Pails: 0 | Farm: 00:00 | Runtime: 00:00"
    statsLabel.Parent = statsPanel
    State.StatsLabelRef = statsLabel

    local finderView = Instance.new("Frame")
    finderView.Name = "FinderView"
    finderView.Size = UDim2.new(1, 0, 1, 0)
    finderView.BackgroundTransparency = 1
    finderView.Parent = contentFrame
    State.Views["Finder"] = finderView

    local controlsBar = Instance.new("Frame")
    controlsBar.Size = UDim2.new(1, 0, 0, 30)
    controlsBar.BackgroundTransparency = 1
    controlsBar.Parent = finderView

    local autoFarmToggle = Instance.new("TextButton")
    autoFarmToggle.Size = UDim2.new(0.48, 0, 1, 0)
    autoFarmToggle.BackgroundColor3 = CONFIG.Settings.AutoFarmEnabled and Color3.fromRGB(46, 160, 67) or Color3.fromRGB(200, 50, 50)
    autoFarmToggle.Text = "AUTO-FARM: " .. (CONFIG.Settings.AutoFarmEnabled and "ON" or "OFF")
    autoFarmToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
    autoFarmToggle.Font = Enum.Font.GothamBold
    autoFarmToggle.TextSize = 11
    autoFarmToggle.Parent = controlsBar
    CreateCorner(autoFarmToggle, 6)

    autoFarmToggle.MouseButton1Click:Connect(function()
        CONFIG.Settings.AutoFarmEnabled = not CONFIG.Settings.AutoFarmEnabled
        autoFarmToggle.BackgroundColor3 = CONFIG.Settings.AutoFarmEnabled and Color3.fromRGB(46, 160, 67) or Color3.fromRGB(200, 50, 50)
        autoFarmToggle.Text = "AUTO-FARM: " .. (CONFIG.Settings.AutoFarmEnabled and "ON" or "OFF")
        if CONFIG.Settings.AutoFarmEnabled then
            State.AutoFarmStartTime = tick()
        else
            State.CurrentTrackedTarget = nil
            State.AutoWalkEnabled = false
            StopAutoWalk()
        end
        ScanForCollectibles()
        PopulateFinderList()
    end)

    local filterBtn = Instance.new("TextButton")
    filterBtn.Size = UDim2.new(0.24, -4, 1, 0)
    filterBtn.Position = UDim2.new(0.5, 2, 0, 0)
    filterBtn.BackgroundColor3 = Color3.fromRGB(30, 33, 42)
    filterBtn.Text = "Filter: All"
    filterBtn.TextColor3 = Color3.fromRGB(200, 200, 210)
    filterBtn.Font = Enum.Font.Gotham
    filterBtn.TextSize = 11
    filterBtn.Parent = controlsBar
    CreateCorner(filterBtn, 6)

    filterBtn.MouseButton1Click:Connect(function()
        if State.CategoryFilter == "All" then State.CategoryFilter = "MysteryCrate"
        elseif State.CategoryFilter == "MysteryCrate" then State.CategoryFilter = "CandyPail"
        else State.CategoryFilter = "All" end
        filterBtn.Text = "Filter: " .. (State.CategoryFilter == "All" and "All" or (State.CategoryFilter == "MysteryCrate" and "Crates" or "Pails"))
        PopulateFinderList()
    end)

    local scanBtn = Instance.new("TextButton")
    scanBtn.Size = UDim2.new(0.24, -2, 1, 0)
    scanBtn.Position = UDim2.new(0.76, 2, 0, 0)
    scanBtn.BackgroundColor3 = Color3.fromRGB(31, 111, 235)
    scanBtn.Text = "Scan"
    scanBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    scanBtn.Font = Enum.Font.GothamBold
    scanBtn.TextSize = 11
    scanBtn.Parent = controlsBar
    CreateCorner(scanBtn, 6)

    scanBtn.MouseButton1Click:Connect(function()
        ScanForCollectibles()
        PopulateFinderList()
    end)

    local scrollContainer = Instance.new("ScrollingFrame")
    scrollContainer.Name = "ItemScroll"
    scrollContainer.Size = UDim2.new(1, 0, 1, -38)
    scrollContainer.Position = UDim2.new(0, 0, 0, 38)
    scrollContainer.BackgroundTransparency = 1
    scrollContainer.ScrollBarThickness = 4
    scrollContainer.Parent = finderView

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 6)
    listLayout.Parent = scrollContainer

    listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        scrollContainer.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 10)
    end)

    local waypointsView = Instance.new("Frame")
    waypointsView.Name = "WaypointsView"
    waypointsView.Size = UDim2.new(1, 0, 1, 0)
    waypointsView.BackgroundTransparency = 1
    waypointsView.Visible = false
    waypointsView.Parent = contentFrame
    State.Views["Waypoints"] = waypointsView

    local wpInfoLabel = Instance.new("TextLabel")
    wpInfoLabel.Name = "InfoLabel"
    wpInfoLabel.Size = UDim2.new(1, 0, 0, 60)
    wpInfoLabel.Position = UDim2.new(0, 0, 0, 10)
    wpInfoLabel.BackgroundTransparency = 1
    wpInfoLabel.Font = Enum.Font.GothamBold
    wpInfoLabel.TextSize = 13
    wpInfoLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
    wpInfoLabel.Text = "No target selected.\nClick Track & Go in Finder or enable Auto-Farm."
    wpInfoLabel.Parent = waypointsView

    local clearBtn = Instance.new("TextButton")
    clearBtn.Size = UDim2.new(0.6, 0, 0, 36)
    clearBtn.Position = UDim2.new(0.2, 0, 0.6, -18)
    clearBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
    clearBtn.Text = "Stop Auto-Walking"
    clearBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    clearBtn.Font = Enum.Font.GothamBold
    clearBtn.TextSize = 12
    clearBtn.Parent = waypointsView
    CreateCorner(clearBtn, 6)

    clearBtn.MouseButton1Click:Connect(function()
        State.CurrentTrackedTarget = nil
        State.AutoWalkEnabled = false
        CONFIG.Settings.AutoFarmEnabled = false
        autoFarmToggle.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
        autoFarmToggle.Text = "AUTO-FARM: OFF"
        StopAutoWalk()
        wpInfoLabel.Text = "Target cleared.\nClick Track & Go in Finder or enable Auto-Farm."
    end)

    local grindingView = Instance.new("ScrollingFrame")
    grindingView.Name = "GrindingView"
    grindingView.Size = UDim2.new(1, 0, 1, 0)
    grindingView.BackgroundTransparency = 1
    grindingView.Visible = false
    grindingView.CanvasSize = UDim2.new(0, 0, 0, 210)
    grindingView.ScrollBarThickness = 4
    grindingView.Parent = contentFrame
    State.Views["Grinding"] = grindingView

    local function CreateGrindingToggle(parentView, name, yPos, configKey)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(0.65, 0, 0, 26)
        lbl.Position = UDim2.new(0, 0, 0, yPos)
        lbl.BackgroundTransparency = 1
        lbl.Text = name
        lbl.TextColor3 = Color3.fromRGB(220, 220, 230)
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 12
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = parentView

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 60, 0, 26)
        btn.Position = UDim2.new(1, -60, 0, yPos)
        btn.BackgroundColor3 = CONFIG.Settings[configKey] and Color3.fromRGB(46, 160, 67) or Color3.fromRGB(200, 50, 50)
        btn.Text = CONFIG.Settings[configKey] and "ON" or "OFF"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.Parent = parentView
        CreateCorner(btn, 6)

        btn.MouseButton1Click:Connect(function()
            CONFIG.Settings[configKey] = not CONFIG.Settings[configKey]
            btn.BackgroundColor3 = CONFIG.Settings[configKey] and Color3.fromRGB(46, 160, 67) or Color3.fromRGB(200, 50, 50)
            btn.Text = CONFIG.Settings[configKey] and "ON" or "OFF"
        end)
    end

    CreateGrindingToggle(grindingView, "Auto Rebirth", 5, "AutoRebirthEnabled")
    CreateGrindingToggle(grindingView, "Auto Spin Wheel", 38, "AutoSpinWheelEnabled")

    local spinLogsBtn = Instance.new("TextButton")
    spinLogsBtn.Size = UDim2.new(0, 80, 0, 22)
    spinLogsBtn.Position = UDim2.new(1, -145, 0, 40)
    spinLogsBtn.BackgroundColor3 = Color3.fromRGB(31, 111, 235)
    spinLogsBtn.Text = "Show Logs"
    spinLogsBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    spinLogsBtn.Font = Enum.Font.GothamBold
    spinLogsBtn.TextSize = 10
    spinLogsBtn.Parent = grindingView
    CreateCorner(spinLogsBtn, 4)
    spinLogsBtn.MouseButton1Click:Connect(function()
        State.SpinWin.Visible = not State.SpinWin.Visible
    end)

    CreateGrindingToggle(grindingView, "Auto Claim Quests", 71, "AutoClaimQuestsEnabled")
    CreateGrindingToggle(grindingView, "Auto Claim Daily", 104, "AutoClaimDailyEnabled")
    CreateGrindingToggle(grindingView, "Auto Brew Cauldron", 137, "AutoBrewEnabled")

    local brewLogsBtn = Instance.new("TextButton")
    brewLogsBtn.Size = UDim2.new(0, 80, 0, 22)
    brewLogsBtn.Position = UDim2.new(1, -145, 0, 139)
    brewLogsBtn.BackgroundColor3 = Color3.fromRGB(31, 111, 235)
    brewLogsBtn.Text = "Show Logs"
    brewLogsBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    brewLogsBtn.Font = Enum.Font.GothamBold
    brewLogsBtn.TextSize = 10
    brewLogsBtn.Parent = grindingView
    CreateCorner(brewLogsBtn, 4)
    brewLogsBtn.MouseButton1Click:Connect(function()
        State.BrewWin.Visible = not State.BrewWin.Visible
    end)

    local playerView = Instance.new("ScrollingFrame")
    playerView.Name = "PlayerView"
    playerView.Size = UDim2.new(1, 0, 1, 0)
    playerView.BackgroundTransparency = 1
    playerView.Visible = false
    playerView.CanvasSize = UDim2.new(0, 0, 0, 190)
    playerView.ScrollBarThickness = 4
    playerView.Parent = contentFrame
    State.Views["Player"] = playerView

    CreateGrindingToggle(playerView, "Enable Player ESP (Wallhack)", 5, "PlayerESPEnabled")
    CreateGrindingToggle(playerView, "Enable Custom Speed (+)", 38, "WalkSpeedEnabled")

    local speedSliderLbl = Instance.new("TextLabel")
    speedSliderLbl.Size = UDim2.new(1, 0, 0, 18)
    speedSliderLbl.Position = UDim2.new(0, 0, 0, 68)
    speedSliderLbl.BackgroundTransparency = 1
    speedSliderLbl.Text = "Speed Bonus: +" .. CONFIG.Settings.WalkSpeedBonus .. " (0 - 100)"
    speedSliderLbl.TextColor3 = Color3.fromRGB(170, 170, 180)
    speedSliderLbl.Font = Enum.Font.Gotham
    speedSliderLbl.TextSize = 11
    speedSliderLbl.TextXAlignment = Enum.TextXAlignment.Left
    speedSliderLbl.Parent = playerView

    local speedBar = Instance.new("Frame")
    speedBar.Size = UDim2.new(1, 0, 0, 10)
    speedBar.Position = UDim2.new(0, 0, 0, 88)
    speedBar.BackgroundColor3 = Color3.fromRGB(30, 33, 42)
    speedBar.Parent = playerView
    CreateCorner(speedBar, 5)

    local speedFill = Instance.new("Frame")
    speedFill.Size = UDim2.new(CONFIG.Settings.WalkSpeedBonus / 100, 0, 1, 0)
    speedFill.BackgroundColor3 = Color3.fromRGB(31, 111, 235)
    speedFill.Parent = speedBar
    CreateCorner(speedFill, 5)

    local speedDragging = false
    speedBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then speedDragging = true end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then speedDragging = false end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if speedDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local posRatio = math.clamp((input.Position.X - speedBar.AbsolutePosition.X) / speedBar.AbsoluteSize.X, 0, 1)
            speedFill.Size = UDim2.new(posRatio, 0, 1, 0)
            local calculatedVal = math.round(posRatio * 100)
            CONFIG.Settings.WalkSpeedBonus = calculatedVal
            speedSliderLbl.Text = "Speed Bonus: +" .. calculatedVal .. " (0 - 100)"
        end
    end)

    local jumpToggleY = 114
    CreateGrindingToggle(playerView, "Enable Custom Jump (+)", jumpToggleY, "JumpPowerEnabled")

    local jumpSliderLbl = Instance.new("TextLabel")
    jumpSliderLbl.Size = UDim2.new(1, 0, 0, 18)
    jumpSliderLbl.Position = UDim2.new(0, 0, 0, jumpToggleY + 31)
    jumpSliderLbl.BackgroundTransparency = 1
    jumpSliderLbl.Text = "Jump Bonus: +" .. CONFIG.Settings.JumpPowerBonus .. " (0 - 150)"
    jumpSliderLbl.TextColor3 = Color3.fromRGB(170, 170, 180)
    jumpSliderLbl.Font = Enum.Font.Gotham
    jumpSliderLbl.TextSize = 11
    jumpSliderLbl.TextXAlignment = Enum.TextXAlignment.Left
    jumpSliderLbl.Parent = playerView

    local jumpBar = Instance.new("Frame")
    jumpBar.Size = UDim2.new(1, 0, 0, 10)
    jumpBar.Position = UDim2.new(0, 0, 0, jumpToggleY + 51)
    jumpBar.BackgroundColor3 = Color3.fromRGB(30, 33, 42)
    jumpBar.Parent = playerView
    CreateCorner(jumpBar, 5)

    local jumpFill = Instance.new("Frame")
    jumpFill.Size = UDim2.new(CONFIG.Settings.JumpPowerBonus / 150, 0, 1, 0)
    jumpFill.BackgroundColor3 = Color3.fromRGB(220, 140, 50)
    jumpFill.Parent = jumpBar
    CreateCorner(jumpFill, 5)

    local jumpDragging = false
    jumpBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then jumpDragging = true end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then jumpDragging = false end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if jumpDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local posRatio = math.clamp((input.Position.X - jumpBar.AbsolutePosition.X) / jumpBar.AbsoluteSize.X, 0, 1)
            jumpFill.Size = UDim2.new(posRatio, 0, 1, 0)
            local calculatedVal = math.round(posRatio * 150)
            CONFIG.Settings.JumpPowerBonus = calculatedVal
            jumpSliderLbl.Text = "Jump Bonus: +" .. calculatedVal .. " (0 - 150)"
        end
    end)

    local settingsView = Instance.new("ScrollingFrame")
    settingsView.Name = "SettingsView"
    settingsView.Size = UDim2.new(1, 0, 1, 0)
    settingsView.BackgroundTransparency = 1
    settingsView.Visible = false
    settingsView.CanvasSize = UDim2.new(0, 0, 0, 220)
    settingsView.ScrollBarThickness = 4
    settingsView.Parent = contentFrame
    State.Views["Settings"] = settingsView

    local function CreateToggleSetting(parentView, name, yPos, configKey)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(0.7, 0, 0, 30)
        lbl.Position = UDim2.new(0, 0, 0, yPos)
        lbl.BackgroundTransparency = 1
        lbl.Text = name
        lbl.TextColor3 = Color3.fromRGB(220, 220, 230)
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 12
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = parentView

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 60, 0, 26)
        btn.Position = UDim2.new(1, -60, 0, yPos + 2)
        btn.BackgroundColor3 = CONFIG.Settings[configKey] and Color3.fromRGB(46, 160, 67) or Color3.fromRGB(200, 50, 50)
        btn.Text = CONFIG.Settings[configKey] and "ON" or "OFF"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.Parent = parentView
        CreateCorner(btn, 6)

        btn.MouseButton1Click:Connect(function()
            CONFIG.Settings[configKey] = not CONFIG.Settings[configKey]
            btn.BackgroundColor3 = CONFIG.Settings[configKey] and Color3.fromRGB(46, 160, 67) or Color3.fromRGB(200, 50, 50)
            btn.Text = CONFIG.Settings[configKey] and "ON" or "OFF"
            ScanForCollectibles()
        end)
    end

    CreateToggleSetting(settingsView, "Anti-AFK Bypass", 5, "AntiAfkEnabled")
    CreateToggleSetting(settingsView, "Mod Detector", 42, "ModDetectorEnabled")
    CreateToggleSetting(settingsView, "Enable Visual Highlighting", 79, "HighlightsEnabled")
    CreateToggleSetting(settingsView, "Display Floating Text Labels", 116, "DisplayLabels")

    local bindLbl = Instance.new("TextLabel")
    bindLbl.Size = UDim2.new(0.5, 0, 0, 30)
    bindLbl.Position = UDim2.new(0, 0, 0, 153)
    bindLbl.BackgroundTransparency = 1
    bindLbl.Text = "Toggle Menu Keybind"
    bindLbl.TextColor3 = Color3.fromRGB(220, 220, 230)
    bindLbl.Font = Enum.Font.Gotham
    bindLbl.TextSize = 12
    bindLbl.TextXAlignment = Enum.TextXAlignment.Left
    bindLbl.Parent = settingsView

    local bindBtn = Instance.new("TextButton")
    bindBtn.Size = UDim2.new(0, 100, 0, 26)
    bindBtn.Position = UDim2.new(1, -100, 0, 155)
    bindBtn.BackgroundColor3 = Color3.fromRGB(31, 111, 235)
    bindBtn.Text = tostring(CONFIG.Settings.ToggleKey.Name)
    bindBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    bindBtn.Font = Enum.Font.GothamBold
    bindBtn.TextSize = 11
    bindBtn.Parent = settingsView
    CreateCorner(bindBtn, 6)

    bindBtn.MouseButton1Click:Connect(function()
        State.IsListeningForKey = true
        bindBtn.Text = "Press any key..."
        local conn
        conn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                CONFIG.Settings.ToggleKey = input.KeyCode
                bindBtn.Text = tostring(input.KeyCode.Name)
                State.IsListeningForKey = false
                conn:Disconnect()
            end
        end)
    end)

    local unloadBtn = Instance.new("TextButton")
    unloadBtn.Size = UDim2.new(1, 0, 0, 36)
    unloadBtn.Position = UDim2.new(0, 0, 0, 200)
    unloadBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
    unloadBtn.Text = "Completely Unload Script"
    unloadBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    unloadBtn.Font = Enum.Font.GothamBold
    unloadBtn.TextSize = 12
    unloadBtn.Parent = settingsView
    CreateCorner(unloadBtn, 6)

    local isConfirmingUnload = false
    unloadBtn.MouseButton1Click:Connect(function()
        if not isConfirmingUnload then
            isConfirmingUnload = true
            unloadBtn.Text = "Click Again to Confirm Unload"
            unloadBtn.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
            task.delay(3, function()
                isConfirmingUnload = false
                if unloadBtn then
                    unloadBtn.Text = "Completely Unload Script"
                    unloadBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
                end
            end)
        else
            UnloadScript()
        end
    end)

    CreateWaypointUI()
end

PopulateFinderList = function()
    local finderView = State.Views["Finder"]
    if not finderView then return end

    local scrollContainer = finderView:FindFirstChild("ItemScroll")
    if not scrollContainer then return end

    for _, child in ipairs(scrollContainer:GetChildren()) do
        if child:IsA("Frame") or child:IsA("TextLabel") then child:Destroy() end
    end

    local filtered = {}
    for _, item in ipairs(State.DetectedCollectibles) do
        local matchesCategory = (State.CategoryFilter == "All") or (item.Category == State.CategoryFilter)
        local matchesSearch = (State.SearchQuery == "") or (string.find(item.Name:lower(), State.SearchQuery:lower(), 1, true) ~= nil)
        if matchesCategory and matchesSearch then table.insert(filtered, item) end
    end

    if #filtered == 0 then
        local emptyText = Instance.new("TextLabel")
        emptyText.Size = UDim2.new(1, 0, 0, 50)
        emptyText.BackgroundTransparency = 1
        emptyText.Text = "No Crates or Candy Pails found.\nItems must spawn in Workspace."
        emptyText.TextColor3 = Color3.fromRGB(150, 150, 160)
        emptyText.Font = Enum.Font.Gotham
        emptyText.TextSize = 12
        emptyText.Parent = scrollContainer
        return
    end

    for _, item in ipairs(filtered) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -6, 0, 36)
        row.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
        row.Parent = scrollContainer
        CreateCorner(row, 6)

        local colorBar = Instance.new("Frame")
        colorBar.Size = UDim2.new(0, 4, 1, 0)
        colorBar.BackgroundColor3 = item.Category == "CandyPail" and CONFIG.CandyPail.Color or CONFIG.MysteryCrate.Color
        colorBar.Parent = row
        CreateCorner(colorBar, 2)

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(0.5, -10, 1, 0)
        nameLabel.Position = UDim2.new(0, 10, 0, 0)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = item.Name
        nameLabel.TextColor3 = Color3.fromRGB(230, 230, 240)
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextSize = 12
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Parent = row

        local distLabel = Instance.new("TextLabel")
        distLabel.Size = UDim2.new(0.25, 0, 1, 0)
        distLabel.Position = UDim2.new(0.5, 0, 0, 0)
        distLabel.BackgroundTransparency = 1
        distLabel.Text = tostring(item.Distance) .. " studs"
        distLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
        distLabel.Font = Enum.Font.Gotham
        distLabel.TextSize = 11
        distLabel.Parent = row

        local trackBtn = Instance.new("TextButton")
        trackBtn.Size = UDim2.new(0.22, -6, 0, 24)
        trackBtn.Position = UDim2.new(0.78, 0, 0.5, -12)
        trackBtn.BackgroundColor3 = (State.CurrentTrackedTarget == item.Instance) and Color3.fromRGB(46, 160, 67) or Color3.fromRGB(45, 48, 60)
        trackBtn.Text = (State.CurrentTrackedTarget == item.Instance) and "Walking..." or "Track & Go"
        trackBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        trackBtn.Font = Enum.Font.GothamBold
        trackBtn.TextSize = 10
        trackBtn.Parent = row
        CreateCorner(trackBtn, 5)

        trackBtn.MouseButton1Click:Connect(function()
            if State.CurrentTrackedTarget == item.Instance then
                State.CurrentTrackedTarget = nil
                State.AutoWalkEnabled = false
                StopAutoWalk()
            else
                State.CurrentTrackedTarget = item.Instance
                State.AutoWalkEnabled = true
            end
            PopulateFinderList()
        end)
    end
end

local function Initialize()
    BuildGUI()
    SetupAntiAfk()
    SetupModDetector()
    ScanForCollectibles()
    PopulateFinderList()

    local lastScan = 0
    local renderConn = RunService.RenderStepped:Connect(function(dt)
        lastScan = lastScan + dt
        if CONFIG.Settings.AutoRefresh and lastScan >= CONFIG.Settings.RefreshInterval then
            lastScan = 0
            ScanForCollectibles()
            if State.ActiveTab == "Finder" then PopulateFinderList() end
        end

        UpdateWaypointTracking()
        StepAutoWalk()
        StepAntiAfk(dt)
        ApplyPlayerModifications()
        UpdatePlayerESP()

        if State.StatsLabelRef then
            local scriptRuntime = math.floor(tick() - State.ScriptStartTime)
            local autoFarmTime = 0
            if CONFIG.Settings.AutoFarmEnabled then
                autoFarmTime = math.floor(tick() - State.AutoFarmStartTime)
            end

            State.StatsLabelRef.Text = string.format(
                "Crates: %d | Pails: %d | Farm: %s | Runtime: %s",
                State.CratesClaimed,
                State.PailsClaimed,
                FormatTime(autoFarmTime),
                FormatTime(scriptRuntime)
            )
        end
    end)
    table.insert(State.Connections, renderConn)

    local charConn = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(1)
        State.HasCapturedOriginals = false
        ScanForCollectibles()
        if State.ActiveTab == "Finder" then PopulateFinderList() end
    end)
    table.insert(State.Connections, charConn)
end

Initialize()
