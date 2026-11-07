-- Vergil Reborn: native inventory, agents, camera, and managed combat.
local Environment = type(getgenv) == "function" and getgenv() or _G
if type(Environment.VergilCleanup) == "function" then
    pcall(Environment.VergilCleanup)
end

local Library: any
do
    local ok, result = pcall(function()
        local source = game:HttpGet("https://raw.githubusercontent.com/14273l/Vergil-poopy/refs/heads/main/Library")
        local chunk, compileError = loadstring(source, "VergilLibrary")
        assert(chunk, compileError)
        return chunk()
    end)
    assert(ok and type(result) == "table", "[Vergil] UI library failed to load: " .. tostring(result))
    Library = result
end
-- Normal gameplay callbacks cannot reliably tween CoreGui-owned UI on this executor.
-- Keep the requested library, but give its holders a PlayerGui-owned render path.
local libraryPlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
for _, holder in ipairs({Library.Holder, Library.PopupHolder, Library.DragHolder, Library.SnowHolder}) do
    if typeof(holder) == "Instance" then holder.Parent = libraryPlayerGui end
end

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local Lighting          = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "[Vergil] Run this script in a Roblox client after joining a game")

local cleanup
local Runtime: any = {
    Unloaded = false, Focused = true, Paused = false,
    Connections = {}, Threads = {}, Bindings = {}, Cleaners = {}, Errors = {},
    ScanInterval = 0.5, VisualInterval = 1 / 60,
    Started = os.clock(), LibraryExit = Library.Exit,
}

function Runtime:Call(name, callback, ...)
    local ok, result = pcall(callback, ...)
    if not ok then
        local entry = self.Errors[name] or { Count = 0, LastWarning = -math.huge }
        entry.Count = entry.Count + 1
        entry.Message = tostring(result):sub(1, 600)
        self.Errors[name] = entry
        if os.clock() - entry.LastWarning >= 5 then
            entry.LastWarning = os.clock()
            warn("[Vergil] " .. name .. ": " .. entry.Message)
        end
    end
    return ok, result
end

function Runtime:NativeCall(name, callback, ...)
    -- Some executors resume a yielding game module with a different identity.
    local identity
    if type(getthreadidentity) == "function" then
        local ok, value = pcall(getthreadidentity)
        if ok then identity = value end
    end
    local ok, result = self:Call(name, callback, ...)
    if identity and type(setthreadidentity) == "function" then pcall(setthreadidentity, identity) end
    return ok, result
end

function Runtime:Hook(name, target, callback)
    if type(target) ~= "function" or type(hookfunction) ~= "function" then
        self:Notify(name .. " requires hookfunction")
        return false
    end
    local alreadyHooked
    if type(isfunctionhooked) == "function" then
        local ok, value = pcall(isfunctionhooked, target)
        if ok then alreadyHooked = value end
    end
    local original
    if type(clonefunction) == "function" then
        local ok, value = pcall(clonefunction, target)
        if ok and type(value) == "function" then original = value end
    end
    local ok, value = self:Call(name .. " hook", hookfunction, target, function(...)
        assert(type(original) == "function", "[Vergil] missing original for " .. name)
        if self.Unloaded then return original(...) end
        return callback(original, ...)
    end)
    if not ok then return false end
    if type(value) == "function" then original = value end
    if type(original) ~= "function" then
        if type(restorefunction) == "function" then pcall(restorefunction, target) end
        return false
    end
    table.insert(self.Cleaners, function()
        local restored = false
        if alreadyHooked ~= true and type(restorefunction) == "function" then
            restored = self:Call(name .. " restore", restorefunction, target)
        end
        if not restored then self:Call(name .. " restore fallback", hookfunction, target, original) end
    end)
    return true
end

function Runtime:Connect(signal, name, callback)
    local connection = signal:Connect(function(...)
        if not self.Unloaded then self:Call(name, callback, ...) end
    end)
    table.insert(self.Connections, connection)
    return connection
end

function Runtime:Spawn(name, callback)
    local thread
    thread = task.defer(function()
        if not self.Unloaded then self:Call(name, callback) end
        self.Threads[thread] = nil
    end)
    self.Threads[thread] = true
    return thread
end

function Runtime:Bind(name, priority, callback)
    RunService:UnbindFromRenderStep(name)
    self.Bindings[name] = true
    RunService:BindToRenderStep(name, priority, function(...)
        if not self.Unloaded then self:Call(name, callback, ...) end
    end)
end

function Runtime:Stop()
    self.Unloaded = true
    for _, connection in ipairs(self.Connections) do connection:Disconnect() end
    table.clear(self.Connections)
    for name in pairs(self.Bindings) do
        RunService:UnbindFromRenderStep(name)
    end
    table.clear(self.Bindings)
    for thread in pairs(self.Threads) do
        if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
            pcall(task.cancel, thread)
        end
    end
    table.clear(self.Threads)
end

function Runtime:Notify(message)
    if type(Library.Notification) == "function" and not Library.Unloaded then
        self:Call("notification", Library.Notification, Library, { Name = message, Time = 4 })
    else
        warn("[Vergil] " .. message)
    end
end

local function combatReason()
    if Runtime.Unloaded then return "unloaded" end
    if Runtime.Paused then return "F8 pause" end
    if not Runtime.Focused then return "window unfocused" end
    if Runtime.DraggingHUD then return "dragging HUD" end
    if Library.MenuOpen then return "Vergil menu open" end
    if UserInputService:GetFocusedTextBox() then return "typing" end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return "not alive" end
    -- This is the native STRAFE deployment flag, also used by its gameplay camera.
    -- The UI GameState mode can still say MENU during transitions or in another require context.
    if game.GameId == 9187332740 and char:GetAttribute("TeleportedToMap") ~= true then return "not deployed" end
    return nil
end
local function combatActive()
    return combatReason() == nil
end

local function getCamera()
    return Workspace.CurrentCamera
end

local Window = Library:Window({ Name = 'Vergil Reborn' })
Window:Watermark({ Name = "Vergil Reborn" })
Window:KeybindList({ Name = 'hotkeys' })

local Combat  = Window:Page({ Name = "combat" })
local Visuals = Window:Page({ Name = "visuals" })
local Misc    = Window:Page({ Name = "misc" })

----------------------------------------------------------------
-- VIEWMODEL
----------------------------------------------------------------
local GunState  = { Enabled = true, Material = Enum.Material.Neon, Color = Color3.fromRGB(255,255,255) }
local ArmsState = { Enabled = true, Hide = false, Material = Enum.Material.Neon, Color = Color3.fromRGB(255,255,255) }

local function getGroup(part, root)
    local p = part
    local group
    while p and p ~= root do
        -- Arms may themselves contain a Parts folder.
        if p.Name == "Arms"  then return "arms"  end
        if p.Name == "Parts" then group = "parts" end
        if p.Name == "Model" and (p:IsA("Model") or p:IsA("Folder"))
           and p.Parent and p.Parent:FindFirstChild("GunComponents") then group = "parts" end
        p = p.Parent
    end
    return group
end

local Backups = setmetatable({}, { __mode = "k" })
local ArmHideBackups = setmetatable({}, { __mode = "k" })

local function backup(part)
    local bk = Backups[part]
    if bk then return bk end

    bk = {
        Material   = part.Material,
        Color      = part.Color,
        TextureID  = nil,
        SAs        = {},
        Decals     = {},
        CanCollide = part.CanCollide,
        Massless   = part.Massless,
        CanQuery   = part.CanQuery,
        CastShadow = part.CastShadow,
    }
    Backups[part] = bk

    if part:IsA("MeshPart") and part.TextureID ~= "" then
        bk.TextureID = part.TextureID
    end

    for _, ch in ipairs(part:GetChildren()) do
        if ch:IsA("SurfaceAppearance") then
            table.insert(bk.SAs, ch)
        elseif ch:IsA("Decal") or ch:IsA("Texture") then
            table.insert(bk.Decals, { Obj = ch, Transparency = ch.Transparency })
        end
    end

    return bk
end

local function applyStyle(part, material, color)
    local bk = backup(part)

    if part:IsA("MeshPart") and part.TextureID ~= "" then
        part.TextureID = ""
    end

    for _, ch in ipairs(part:GetChildren()) do
        if ch:IsA("SurfaceAppearance") then
            if not table.find(bk.SAs, ch) then
                table.insert(bk.SAs, ch)
            end
            ch.Parent = nil
        end
    end

    for _, ch in ipairs(part:GetChildren()) do
        if (ch:IsA("Decal") or ch:IsA("Texture")) and ch.Transparency < 1 then
            local known = false
            for _, d in ipairs(bk.Decals) do
                if d.Obj == ch then
                    known = true
                    break
                end
            end
            if not known then
                table.insert(bk.Decals, { Obj = ch, Transparency = ch.Transparency })
            end
            ch.Transparency = 1
        end
    end

    if part.Material ~= material then part.Material = material end
    if part.Color ~= color then part.Color = color end
    if part.CanCollide then part.CanCollide = false end
    if not part.Massless then part.Massless = true end
    if part.CanQuery then part.CanQuery = false end
    if part.CastShadow then part.CastShadow = false end
end

local function restorePart(part)
    local bk = Backups[part]
    if not bk then return end

    if bk.TextureID and part:IsA("MeshPart") then
        part.TextureID = bk.TextureID
    end

    for _, sa in ipairs(bk.SAs) do
        if sa and not sa.Parent and part.Parent then
            sa.Parent = part
        end
    end

    for _, d in ipairs(bk.Decals) do
        if d.Obj then
            d.Obj.Transparency = d.Transparency
        end
    end

    if part.Material ~= bk.Material then part.Material = bk.Material end
    if part.Color ~= bk.Color then part.Color = bk.Color end
    if part.CanCollide ~= bk.CanCollide then part.CanCollide = bk.CanCollide end
    if part.Massless ~= bk.Massless then part.Massless = bk.Massless end
    if part.CanQuery ~= bk.CanQuery then part.CanQuery = bk.CanQuery end
    if part.CastShadow ~= bk.CastShadow then part.CastShadow = bk.CastShadow end

    Backups[part] = nil
end

local function restoreGroup(group)
    local cam = getCamera()
    local vm = cam and cam:FindFirstChild("Viewmodel")
    if not vm then return end

    for _, obj in ipairs(vm:GetDescendants()) do
        if obj:IsA("BasePart") and getGroup(obj, vm) == group then
            restorePart(obj)
        end
    end
end

----------------------------------------------------------------
-- SILENT AIM UTILITY
----------------------------------------------------------------
local utility: any = {
    target        = nil,
    SilentAim     = false,
    VisibleCheck  = false,
    FOV           = 120,
    ShowCircle    = true,
    Players       = Players,
    ReplicatedStorage = ReplicatedStorage,
    Workspace     = Workspace,
    RunService    = RunService,
    UserInputService = UserInputService,
    ControllerHooks = setmetatable({}, {__mode = "k"}), HookStatus = "waiting for local controller",
}

function utility:isFriendlyCharacter(c)
    if not c then return false end
    if c == LocalPlayer.Character then return true end
    local player = self.Players:GetPlayerFromCharacter(c)
    local id = c:GetAttribute("BotUniqueId") or (player and player.UserId)
    if id and self.GameState and type(self.GameState.isTeammate) == "function" then
        local ok, result = pcall(self.GameState.isTeammate, id)
        if ok and type(result) == "boolean" then return result end
    end
    return player ~= nil and not player.Neutral and not LocalPlayer.Neutral
        and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team
end

function utility:GetCamera()
    local ok, cam = pcall(function() return self.Workspace.CurrentCamera end)
    if ok then return cam end
    return nil
end

function utility:CreateParams()
    local char = (self.LocalPlayer or LocalPlayer).Character
    if not char then return nil end

    local ignore = { char }
    local cam = self:GetCamera()
    if cam then table.insert(ignore, cam) end
    for _, name in ipairs({ "Effects", "IgnoreList", "Ragdolls" }) do
        local folder = self.Workspace:FindFirstChild(name)
        if folder then table.insert(ignore, folder) end
    end
    local map = self.Workspace:FindFirstChild("CurrentMap")
    local pickups = map and map:FindFirstChild("HealthPickups")
    if pickups then table.insert(ignore, pickups) end
    if self.GameState and type(self.GameState.getTeammateCharacters) == "function" then
        local ok, teammates = pcall(self.GameState.getTeammateCharacters)
        if ok and type(teammates) == "table" then
            for _, teammate in ipairs(teammates) do if typeof(teammate) == "Instance" then table.insert(ignore, teammate) end end
        end
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignore
    params.IgnoreWater = true
    return params
end

function utility:isVisible(t, from)
    if not t or not t.Parent then return false end

    local cam = self:GetCamera()
    if not cam then return false end

    local params = self:CreateParams()
    if not params then return false end

    local origin = typeof(from) == "Vector3" and from or cam.CFrame.Position
    local direction = t.Position - origin
    if direction.Magnitude <= 1e-4 then return true end

    local char = t.Parent
    if not char then return false end
    local ignore = params.FilterDescendantsInstances
    -- Match STRAFE's native raycast: invisible helpers do not block bullets;
    -- actual walls, including partially transparent walls, always block.
    for _ = 1, 10 do
        params.FilterDescendantsInstances = ignore
        local result = self.Workspace:Raycast(origin, direction, params)
        if not result then return true end
        if result.Instance == t or result.Instance:IsDescendantOf(char) then return true end
        if result.Instance.Transparency ~= 1 then return false end
        ignore[#ignore + 1] = result.Instance
    end
    return false
end

function utility:IsAutoTargetVisible(part)
    if not self:isVisible(part) then return false end
    local char = LocalPlayer.Character
    local head = char and char:FindFirstChild("Head")
    return head ~= nil and self:isVisible(part, head.Position)
end

local cachedPlayers, lastPlayersScan = {}, -1e9

function utility:getPlayers()
    local now = os.clock()
    if now - lastPlayersScan < Runtime.ScanInterval then
        return cachedPlayers
    end
    lastPlayersScan = now

    local list, seen = {}, {}

    local function add(char)
        local cam = self:GetCamera()
        if char and char:IsA("Model") and char.Parent and not seen[char]
           and char.Name ~= "MenuCharacter" and char.Name ~= "EffectLoader"
           and char:GetAttribute("TeleportedToMap") ~= false
           and not (cam and char:IsDescendantOf(cam))
           and not (self.Workspace:FindFirstChild("Ragdolls") and char:IsDescendantOf(self.Workspace.Ragdolls)) then
            seen[char] = true
            table.insert(list, char)
        end
    end

    for _, player in ipairs(self.Players:GetPlayers()) do add(player.Character) end

    local ok = pcall(function()
        for _, h in ipairs(self.Workspace:QueryDescendants("Humanoid")) do
            add(h.Parent)
        end
    end)

    if not ok then
        for _, obj in ipairs(self.Workspace:GetDescendants()) do
            if obj:IsA("Humanoid") then add(obj.Parent) end
        end
    end

    cachedPlayers = list
    return list
end

function utility:GetClosestPlayer()
    if not self.SilentAim or not combatActive() then return nil end
    return self:GetClosestToMouse(self:GetCamera(), self.FOV, self.VisibleCheck)
end

local function findHitscanFunction(scanGc)
    local classes = ReplicatedStorage:FindFirstChild("Classes")
    local handler = classes and classes:FindFirstChild("Handler")
    if handler then
        local ok, module = pcall(require, handler)
        if ok and type(module) == "table" and type(module.fireHitscanShot) == "function" then
            return module.fireHitscanShot
        end
    end
    if type(filtergc) == "function" then
        local ok, res = pcall(filtergc, "function", { Name = "fireHitscanShot" }, true)
        if not ok then
            ok, res = pcall(filtergc, "function", { Name = "fireHitscanShot" })
        end
        if ok and res then
            if type(res) == "table" then res = res[1] end
            if type(res) == "function" then return res end
        end
    end

    if scanGc and type(getgc) == "function" then
        local okGc, gc = pcall(getgc, true)
        if not okGc then okGc, gc = pcall(getgc) end
        if okGc and type(gc) == "table" then
            for _, obj in pairs(gc) do
                if type(obj) == "function" then
                    local okInfo, name = false, nil
                    if type(debug) == "table" and type(debug.info) == "function" then
                        okInfo, name = pcall(function() return debug.info(obj, "n") end)
                    end
                    if okInfo and type(name) == "string" and name:find("fireHitscanShot", 1, true) then
                        return obj
                    end
                end
            end
        end
    end

    return nil
end

function utility:InstallController(controller)
    if Runtime.Unloaded or type(controller) ~= "table" or controller.player ~= LocalPlayer or controller.destroyed then return false end
    local existing = self.ControllerHooks[controller]
    if existing and rawget(controller, "fireHitscanShot") == existing.Wrapper then return true end
    local original = controller.fireHitscanShot
    if type(original) ~= "function" then return false end
    local record = {Original = original, Raw = rawget(controller, "fireHitscanShot")}
    record.Wrapper = function(owner, gun, ...)
        if Runtime.Unloaded or owner.player ~= LocalPlayer then return original(owner, gun, ...) end
        self.ShotsIntercepted = (self.ShotsIntercepted or 0) + 1
        local autoShot = self.AutoAimEnabled and self.AutoController == owner
        local active = combatActive()
        local target
        if autoShot then target = self.AutoTarget
        elseif self.SilentAim and active then
            target = self:GetClosestToMouse(self:GetCamera(), self.FOV, self.VisibleCheck)
            self.target = target
        end
        local hum = target and target.Parent and target.Parent:FindFirstChildOfClass("Humanoid")
        local valid = active and hum and hum.Health > 0 and not self:isFriendlyCharacter(target.Parent)
        if autoShot and (not valid or not self:IsAutoTargetVisible(target)) then
            self.ShotsSuppressed = (self.ShotsSuppressed or 0) + 1
            return
        end
        if valid and (autoShot or self:RollHitChance()) then
            local previous = owner.camera
            local camera = typeof(previous) == "Instance" and previous:IsA("Camera") and previous or self:GetCamera()
            if camera and (target.Position-camera.CFrame.Position).Magnitude > 1e-4 then
                -- Only the native shot's camera context is redirected. The real camera,
                -- its render pipeline and CameraGuard are never written to or patched.
                local shotCamera = setmetatable({CFrame = CFrame.lookAt(camera.CFrame.Position, target.Position)}, {
                    __index = function(_, key)
                        local value = camera[key]
                        if type(value) == "function" then return function(_, ...) return value(camera, ...) end end
                        return value
                    end,
                })
                owner.camera = shotCamera
                local results = table.pack(pcall(original, owner, gun, ...))
                owner.camera = previous
                if not results[1] then error(results[2], 0) end
                self.ShotsRedirected = (self.ShotsRedirected or 0) + 1
                self.LastShotTarget = target.Parent.Name
                self.HookStatus = "redirected " .. target.Parent.Name
                return table.unpack(results, 2, results.n)
            end
        end
        if self.SilentAim and not target then self.HookStatus = active and "no target in FOV" or combatReason() end
        return original(owner, gun, ...)
    end
    controller.fireHitscanShot = record.Wrapper
    self.ControllerHooks[controller] = record
    self.hooked = true;self.HookStatus = "local shot context ready"
    return true
end

function utility:UnhookControllers()
    for controller, record in pairs(self.ControllerHooks) do
        if rawget(controller, "fireHitscanShot") == record.Wrapper then controller.fireHitscanShot = record.Raw end
        self.ControllerHooks[controller] = nil
    end
    self.hooked = false;self.hooking = false
end

function utility:hook()
    if self.hooking or Runtime.Unloaded then return end
    self.hooking = true
    Runtime:Spawn("local aim controller discovery", function()
        while not Runtime.Unloaded do
            if (self.SilentAim or self.AutoAimEnabled) and Runtime.GetLocalController then
                local controller = Runtime.GetLocalController()
                if controller then self:InstallController(controller) end
            end
            task.wait(0.15)
        end
        self.hooking = false
    end)
end

function utility:init()
    if self.initialized or Runtime.Unloaded then return end

    self.LocalPlayer = self.Players.LocalPlayer
    if not self.LocalPlayer then
        return warn("[Vergil] failed to get LocalPlayer")
    end

    self.initialized = true

    local classes = self.ReplicatedStorage:FindFirstChild("Classes")
    local ui = classes and classes:FindFirstChild("UserInterface")
    local react = ui and ui:FindFirstChild("ReactApp")
    local gs = react and react:FindFirstChild("GameState")

    if gs then
        local ok, result = pcall(require, gs)
        if ok then
            self.GameState = result
            Runtime.GameState = result
        else
            warn("[Vergil] failed to require GameState; team checks disabled")
        end
    else
        warn("[Vergil] failed to get GameState; team checks disabled")
    end

    self.Camera = self:GetCamera()
    if not self.Camera then
        warn("[Vergil] failed to get camera")
    end

    Runtime:Spawn("silent aim hook", function()
        self:hook()
    end)

    return
end

----------------------------------------------------------------
-- CHAMS
----------------------------------------------------------------
local ChamsState = {
    Enabled       = false,
    TeamCheck     = true,
    IncludeNPCs   = true,
    VisibleColor  = { Color3.fromRGB(155, 155, 255), 0.0 },
    OccludedColor = { Color3.fromRGB(255, 255, 255), 0.8 },
}

local ChamsCache   = {}
local IgnoreNames  = { HumanoidRootPart = true }

local function createAdornment(part, vis)
    local adorn = Instance.new("BoxHandleAdornment")
    local offset = (vis == 1) and -0.05 or 0.05
    local size = part.Size + Vector3.new(offset, offset, offset)
    adorn.Size = Vector3.new(
        math.max(size.X, 0.01), math.max(size.Y, 0.01), math.max(size.Z, 0.01))
    adorn.Adornee     = part
    adorn.Parent      = part
    adorn.ZIndex      = (vis == 1) and 2 or 1
    adorn.AlwaysOnTop = (vis == 1)
    adorn.Visible     = false
    return adorn
end

local function isTeammateChar(char)
    local ok, res = pcall(function() return utility:isFriendlyCharacter(char) end)
    if ok then return res end
    return false
end

local function shouldChams(char)
    if not ChamsState.Enabled then return false end
    if char == LocalPlayer.Character then return false end
    if not ChamsState.IncludeNPCs and Players:GetPlayerFromCharacter(char) == nil then return false end
    if ChamsState.TeamCheck and isTeammateChar(char) then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    return true
end

local function applyChams(char)
    for _, part in ipairs(char:GetChildren()) do
        if part:IsA("BasePart") and not IgnoreNames[part.Name] then
            local ad = ChamsCache[part]
            if not ad then
                ad = {
                    createAdornment(part, 1),
                    createAdornment(part, 2),
                }
                ChamsCache[part] = ad
            end
            ad[1].Visible      = true
            ad[2].Visible      = true
            ad[1].Color3       = ChamsState.OccludedColor[1]
            ad[1].Transparency = ChamsState.OccludedColor[2]
            ad[2].Color3       = ChamsState.VisibleColor[1]
            ad[2].Transparency = ChamsState.VisibleColor[2]
        end
    end
end

local chamsWasActive = false

local function chamsStep()
    if ChamsState.Enabled then
        for _, ad in pairs(ChamsCache) do
            ad[1].Visible = false
            ad[2].Visible = false
        end

        for _, char in ipairs(utility:getPlayers()) do
            if char.Parent and shouldChams(char) then
                applyChams(char)
            end
        end

        chamsWasActive = true
    elseif chamsWasActive then
        for _, ad in pairs(ChamsCache) do
            ad[1].Visible = false
            ad[2].Visible = false
        end
        chamsWasActive = false
    end

    for part, ad in pairs(ChamsCache) do
        if not part.Parent then
            ad[1]:Destroy()
            ad[2]:Destroy()
            ChamsCache[part] = nil
        end
    end
end

----------------------------------------------------------------
-- WORLD VISUALS - lighting + atmosphere
----------------------------------------------------------------
local LightState = {
    Enabled        = false,
    Ambient        = Color3.fromRGB(255, 255, 255),
    OutdoorAmbient = Color3.fromRGB(255, 255, 255),
    Brightness     = 2,
    ClockTime      = 14,
    FogEnd         = 100000,
    FogStart       = 0,
}

local LightingBackup = nil

local function snapshotLighting()
    if LightingBackup then return end
    LightingBackup = {
        Ambient        = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        Brightness     = Lighting.Brightness,
        ClockTime      = Lighting.ClockTime,
        FogEnd         = Lighting.FogEnd,
        FogStart       = Lighting.FogStart,
        FogColor       = Lighting.FogColor,
    }
end

local function applyLighting()
    if not LightState.Enabled then return end
    Lighting.Ambient        = LightState.Ambient
    Lighting.OutdoorAmbient = LightState.OutdoorAmbient
    Lighting.Brightness     = LightState.Brightness
    Lighting.ClockTime      = LightState.ClockTime
    Lighting.FogEnd         = math.max(LightState.FogEnd, LightState.FogStart)
    Lighting.FogStart       = math.min(LightState.FogStart, LightState.FogEnd)
end

local function restoreLighting()
    if not LightingBackup then return end
    Lighting.Ambient        = LightingBackup.Ambient
    Lighting.OutdoorAmbient = LightingBackup.OutdoorAmbient
    Lighting.Brightness     = LightingBackup.Brightness
    Lighting.ClockTime      = LightingBackup.ClockTime
    Lighting.FogEnd         = LightingBackup.FogEnd
    Lighting.FogStart       = LightingBackup.FogStart
    Lighting.FogColor       = LightingBackup.FogColor
    LightingBackup = nil
end

local AtmState = {
    Enabled = false,
    Density = 0.3,
    Haze    = 0,
    Glare   = 0,
    Color   = Color3.fromRGB(199, 199, 199),
    Decay   = Color3.fromRGB(106, 112, 125),
    Offset  = 0,
}

local AtmBackups = {}
local AtmTarget = nil

local function findAtmosphere()
    return Lighting:FindFirstChildOfClass("Atmosphere")
        or Workspace:FindFirstChildOfClass("Atmosphere")
end

local function copyAtmosphere(atm)
    return {
        Density = atm.Density,
        Haze    = atm.Haze,
        Glare   = atm.Glare,
        Color   = atm.Color,
        Decay   = atm.Decay,
        Offset  = atm.Offset,
    }
end

local function snapshotAtmosphere()
    local atm = findAtmosphere()
    if atm and not AtmBackups[atm] then AtmBackups[atm] = copyAtmosphere(atm) end
    AtmTarget = atm
end

local function ensureAtmosphere()
    if AtmTarget and AtmTarget.Parent then
        return AtmTarget
    end

    local atm = findAtmosphere()
    if atm then
        AtmTarget  = atm
        if not AtmBackups[atm] then AtmBackups[atm] = copyAtmosphere(atm) end
    else
        atm = Instance.new("Atmosphere")
        atm.Parent = Lighting
        AtmTarget  = atm
        AtmBackups[atm] = { Created = true }
    end
    return atm
end

local function applyAtmosphere()
    if not AtmState.Enabled then return end
    local atm = ensureAtmosphere()
    atm.Density = AtmState.Density
    atm.Haze    = AtmState.Haze
    atm.Glare   = AtmState.Glare
    atm.Color   = AtmState.Color
    atm.Decay   = AtmState.Decay
    atm.Offset  = math.clamp(AtmState.Offset, -1, 1)
end

local function restoreAtmosphere()
    for atm, values in pairs(AtmBackups) do
        Runtime:Call("restore atmosphere", function()
            if values.Created then
                atm:Destroy()
            else
                for key, value in pairs(values) do atm[key] = value end
            end
        end)
        AtmBackups[atm] = nil
    end
    AtmTarget  = nil
end

----------------------------------------------------------------
-- FOV LOCK
----------------------------------------------------------------
local FOVState = {
    Enabled  = false,
    Value    = 120,
    Backups = setmetatable({}, { __mode = "k" }),
}

local function enforceFOV()
    if not FOVState.Enabled then return end
    local cam = getCamera()
    if cam then
        if not FOVState.Backups[cam] then FOVState.Backups[cam] = cam.FieldOfView end
        local value = math.clamp(FOVState.Value, 1, 120)
        if math.abs(cam.FieldOfView - value) > 0.001 then cam.FieldOfView = value end
    end
end

local function restoreFOV()
    for cam, value in pairs(FOVState.Backups) do
        Runtime:Call("restore camera FOV", function() cam.FieldOfView = value end)
        FOVState.Backups[cam] = nil
    end
end
----------------------------------------------------------------
-- SHARED SCREEN HELPERS
----------------------------------------------------------------
local vim
pcall(function() vim = game:GetService("VirtualInputManager") end)

local function project(cam, pos)
    local sp, on = cam:WorldToViewportPoint(pos)
    return Vector2.new(sp.X, sp.Y), on, sp.Z
end

local function guiPoint(gui, point)
    -- CoreGui/gethui can have a negative absolute origin (58px on this Mac).
    -- Position offsets are GUI-local, while camera projections are viewport pixels.
    return point - gui.AbsolutePosition
end

local function px(v)
    return math.floor(v + 0.5)
end

local function mk(cls, parent, props)
    local o = Instance.new(cls)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local function setLine(frame, a, b, thickness, color)
    local d = b - a
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
    frame.Size = UDim2.fromOffset(d.Magnitude, thickness)
    frame.Rotation = math.deg(math.atan2(d.Y, d.X))
    frame.BackgroundColor3 = color
end

local function isNpc(char)
    return Players:GetPlayerFromCharacter(char) == nil
end

----------------------------------------------------------------
-- FEATURE STATE
----------------------------------------------------------------
local AimAssistState = {
    Enabled = false, Smoothness = 0.35, FOV = 140,
    VisibleCheck = false, Hold = true, Key = "E",
    Color = Color3.fromRGB(255, 200, 80), ShowCircle = true, Sticky = false,
}

local TargetingState = {
    Part = "Head", Parts = { "Head" }, Priority = "crosshair", IncludeNPCs = true, MaxDistance = 0,
}

local TargetPartNames = {
    "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart",
    "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "LeftHand", "RightHand",
    "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot",
}
local TargetPartAliases = {
    UpperTorso = "Torso", LowerTorso = "Torso",
    LeftUpperArm = "Left Arm", LeftLowerArm = "Left Arm", LeftHand = "Left Arm",
    RightUpperArm = "Right Arm", RightLowerArm = "Right Arm", RightHand = "Right Arm",
    LeftUpperLeg = "Left Leg", LeftLowerLeg = "Left Leg", LeftFoot = "Left Leg",
    RightUpperLeg = "Right Leg", RightLowerLeg = "Right Leg", RightFoot = "Right Leg",
}
utility.HitChance = 100
utility.HitChanceRandom = Random.new()

function utility:RollHitChance(roll)
    local chance = math.clamp(tonumber(self.HitChance) or 100, 0, 100)
    if chance <= 0 then return false end
    if chance >= 100 then return true end
    return (roll or self.HitChanceRandom:NextNumber(0, 100)) < chance
end

local TriggerState = {
    Enabled = false, Delay = 0.06, FOV = 8, VisibleCheck = false,
}

local EspState = {
    Enabled = false, Box = true, Corner = false, Skeleton = false,
    HealthBar = true, Glow = false, Tracers = false, Offscreen = false,
    Names = true, Distance = true, Dynamic = true,
    TeamCheck = true, IncludeNPCs = true, MaxDistance = 0,
    BoxColor = Color3.fromRGB(255, 255, 255),
    CornerColor = Color3.fromRGB(255, 255, 255),
    SkeletonColor = Color3.fromRGB(255, 255, 255),
    TracerColor = Color3.fromRGB(255, 255, 255),
    GlowColor = Color3.fromRGB(155, 155, 255),
}

local aimColor = Color3.fromRGB(255, 255, 255)

local Studio: any = {
    Rainbow = false, RainbowSpeed = 0.12,
    Crosshair = { Enabled = false, Style = "cross", Length = 9, Gap = 5, Thickness = 2,
        Rotate = false, Pulse = false, Dynamic = true, FollowMouse = false,
        Color = Color3.fromRGB(175, 160, 255), TargetColor = Color3.fromRGB(255, 85, 125) },
    TargetHUD = false, PostFX = false, Palette = "vergil violet", Bloom = 0.25,
}

function Studio:Color(base)
    return self.Rainbow and Color3.fromHSV((os.clock() * self.RainbowSpeed) % 1, 0.75, 1) or base
end

----------------------------------------------------------------
-- SILENT AIM UI
----------------------------------------------------------------
local AimSection = Combat:Section({ Name = "silent aim", Side = 1 })

AimSection:Toggle({
    Name = "enabled", Flag = "aim_enabled", Default = false,
    Callback = function(v)
        utility.SilentAim = v
        if not v then utility.target = nil end
        if v then utility:hook() end
    end
})

AimSection:Toggle({
    Name = "visible check", Flag = "aim_vischeck", Default = false,
    Callback = function(v) utility.VisibleCheck = v end
})

AimSection:Toggle({
    Name = "fov circle", Flag = "aim_circle", Default = true,
    Callback = function(v) utility.ShowCircle = v end
})

AimSection:Slider({
    Name = "fov", Flag = "aim_fov",
    Min = 10, Max = 800, Default = 120,
    Decimals = 1,
    Callback = function(v) utility.FOV = v end
})

AimSection:Slider({
    Name = "hit chance", Flag = "aim_hitchance", Min = 0, Max = 100, Default = 100,
    Decimals = 1, Suffix = "%",
    Callback = function(v) utility.HitChance = math.clamp(v, 0, 100) end,
})
AimSection:Label({ Name = "One roll per shot; failed rolls use normal aim" })
local aimStatusLabel = AimSection:Label({Name = "waiting for local controller"})
Runtime:Connect(RunService.Heartbeat, "silent aim status", function()
    if os.clock() - (utility.StatusAt or 0) >= 0.5 then
        utility.StatusAt = os.clock()
        aimStatusLabel:SetText(utility.SilentAim and (combatReason() or utility.HookStatus) or "off")
    end
end)

AimSection:Label({ Name = "fov color" }):Colorpicker({
    Name = "aim_color", Flag = "aim_color",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) aimColor = c end
})

----------------------------------------------------------------
-- FOV CIRCLES
----------------------------------------------------------------
local function resolveGuiParent()
    local function canParent(parent)
        local probe = Instance.new("ScreenGui")
        local ok = pcall(function() probe.Parent = parent end)
        probe:Destroy()
        return ok and parent ~= nil
    end
    -- Render callbacks can run with normal game permissions. Own the HUD in
    -- PlayerGui so target/crosshair updates do not require CoreGui's Plugin capability.
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if playerGui and canParent(playerGui) then return playerGui end
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui and canParent(hui) then return hui end
    end

    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core and canParent(core) then return core end

    return LocalPlayer:WaitForChild("PlayerGui")
end

local guiParent = resolveGuiParent()

for _, oldName in ipairs({ "VergilFOV", "VergilESP", "VergilHUD", "VergilDebugOverlay", "VergilRadar", "VergilStudio" }) do
    local old = guiParent:FindFirstChild(oldName)
    if old then old:Destroy() end
end

local fovGui = Instance.new("ScreenGui")
fovGui.Name = "VergilFOV"
fovGui.IgnoreGuiInset = true
fovGui.ResetOnSpawn = false
fovGui.DisplayOrder = 9999
fovGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
fovGui.Parent = guiParent

local function makeRing()
    local f = Instance.new("Frame")
    f.BackgroundTransparency = 1
    f.BorderSizePixel = 0
    f.AnchorPoint = Vector2.new(0.5, 0.5)
    f.Visible = false
    f.Parent = fovGui

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(1, 0)
    c.Parent = f

    local s = Instance.new("UIStroke")
    s.Thickness = 1.5
    s.Transparency = 0.1
    s.Parent = f

    return f, s
end

local aimRing, aimRingStroke = makeRing()
local aaRing,  aaRingStroke  = makeRing()

local function ringStep()
    local mouse = UserInputService:GetMouseLocation()

    if not Runtime.Paused and utility.SilentAim and utility.ShowCircle then
        local r = utility.FOV or 120
        aimRing.Visible  = true
        aimRing.Size     = UDim2.fromOffset(r * 2, r * 2)
        aimRing.Position = UDim2.fromOffset(mouse.X, mouse.Y)
        aimRingStroke.Color = Studio:Color(aimColor)
    else
        aimRing.Visible = false
    end

    if not Runtime.Paused and AimAssistState.Enabled and AimAssistState.ShowCircle then
        local r = AimAssistState.FOV or 140
        aaRing.Visible  = true
        aaRing.Size     = UDim2.fromOffset(r * 2, r * 2)
        aaRing.Position = UDim2.fromOffset(mouse.X, mouse.Y)
        aaRingStroke.Color = Studio:Color(AimAssistState.Color)
    else
        aaRing.Visible = false
    end
end

----------------------------------------------------------------
-- NAME PROTECT
----------------------------------------------------------------
local NameProtect = {
    Enabled = false, Mode = "numbered", Custom = "you",
    Map = {}, Counter = 0,
}
local npSeen = setmetatable({}, { __mode = "k" })

local function npName(plr)
    if plr == LocalPlayer then return NameProtect.Custom end
    if NameProtect.Mode == "all" then return "protected" end
    local m = NameProtect.Map[plr.UserId]
    if not m then
        NameProtect.Counter = NameProtect.Counter + 1
        m = "Player" .. NameProtect.Counter
        NameProtect.Map[plr.UserId] = m
    end
    return m
end

local function npScan()
    if not NameProtect.Enabled then
        for lbl, data in pairs(npSeen) do
            if lbl.Parent and lbl.Text == data.applied then
                lbl.Text = data.orig
            end
            npSeen[lbl] = nil
        end
        return
    end

    for lbl in pairs(npSeen) do
        if not lbl.Parent then npSeen[lbl] = nil end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        local char = plr.Character
        if not char then continue end
        for _, gui in ipairs(char:GetDescendants()) do
            if gui:IsA("BillboardGui") then
                for _, lbl in ipairs(gui:GetDescendants()) do
                    if lbl:IsA("TextLabel") then
                        local d = npSeen[lbl]
                        local original = d and lbl.Text == d.applied and d.orig or lbl.Text
                        local fake = npName(plr)
                        local replaced = original
                        local names = { plr.Name, plr.DisplayName }
                        table.sort(names, function(a, b) return #a > #b end)
                        for _, name in ipairs(names) do
                            if name ~= "" then
                                local escaped = name:gsub("(%W)", "%%%1")
                                replaced = replaced:gsub("%f[%w_]" .. escaped .. "%f[^%w_]", function()
                                    return fake
                                end)
                            end
                        end
                        if replaced ~= original then
                            npSeen[lbl] = { orig = original, applied = replaced }
                            if lbl.Text ~= replaced then lbl.Text = replaced end
                        elseif d then
                            npSeen[lbl] = nil
                        end
                    end
                end
            end
        end
    end
end

Runtime:Spawn("name protection", function()
    while not Runtime.Unloaded do
        if NameProtect.Enabled or next(npSeen) then
            Runtime:Call("name protection scan", npScan)
        end
        task.wait(0.25)
    end
end)

----------------------------------------------------------------
-- TARGET ACQUISITION
----------------------------------------------------------------
function utility:GetTargetPart(char)
    return self:GetTargetParts(char)[1]
end

function utility:GetTargetParts(char)
    local result, seen = {}, {}
    for _, name in ipairs(TargetingState.Parts) do
        local part = char:FindFirstChild(name)
        if not part and TargetPartAliases[name] then part = char:FindFirstChild(TargetPartAliases[name]) end
        if part and part:IsA("BasePart") and not seen[part] then result[#result + 1] = part; seen[part] = true end
    end
    return result
end

function utility:TargetScore(cam, char, mouse, fov, vischeck)
    if not char or not char.Parent or char == LocalPlayer.Character then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil end
    if not TargetingState.IncludeNPCs and isNpc(char) then return nil end
    if self:isFriendlyCharacter(char) then return nil end

    local bestPart, bestScore, bestScreen = nil, math.huge, math.huge
    for _, part in ipairs(self:GetTargetParts(char)) do
        local distance = (part.Position - cam.CFrame.Position).Magnitude
        if TargetingState.MaxDistance > 0 and distance > TargetingState.MaxDistance then continue end
        local sp, on, z = project(cam, part.Position)
        local screenDistance = (sp - mouse).Magnitude
        if not on or z <= 0 or screenDistance > fov then continue end
        if vischeck and not self:isVisible(part) then continue end
        local score = screenDistance
        if TargetingState.Priority == "distance" then score = distance end
        if TargetingState.Priority == "health" then score = hum.Health end
        if score < bestScore or (score == bestScore and screenDistance < bestScreen) then
            bestPart, bestScore, bestScreen = part, score, screenDistance
        end
    end
    return bestPart, bestScore, bestScreen
end

function utility:GetClosestToMouse(cam, fov, vischeck, preferred)
    if not cam then return nil end
    local mouse = UserInputService:GetMouseLocation()
    if preferred and preferred.Parent then
        local part = self:TargetScore(cam, preferred.Parent, mouse, fov, vischeck)
        if part then return part end
    end

    local closest, bestScore, bestScreen = nil, math.huge, math.huge
    for _, char in ipairs(self:getPlayers()) do
        local part, score, screenDistance = self:TargetScore(cam, char, mouse, fov, vischeck)
        if part and (score < bestScore or (score == bestScore and screenDistance < bestScreen)) then
            closest, bestScore, bestScreen = part, score, screenDistance
        end
    end
    return closest
end

----------------------------------------------------------------
-- AIM ASSIST
----------------------------------------------------------------
local heldInputs = {}

local function inputId(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        return "RightMouse"
    end
    local key = input.KeyCode
    if key and key ~= Enum.KeyCode.Unknown then
        return key.Name
    end
    return nil
end

Runtime:Connect(UserInputService.InputBegan, "input began", function(input, gameProcessed)
    if gameProcessed then return end
    local id = inputId(input)
    if id then heldInputs[id] = true end
end)

Runtime:Connect(UserInputService.InputEnded, "input ended", function(input)
    local id = inputId(input)
    if id then heldInputs[id] = nil end
end)

Runtime:Connect(UserInputService.WindowFocusReleased, "focus lost", function()
    Runtime.Focused = false
    for id in pairs(heldInputs) do heldInputs[id] = nil end
    if Runtime.ReleaseMouse then Runtime.ReleaseMouse() end
end)

Runtime:Connect(UserInputService.WindowFocused, "focus gained", function()
    Runtime.Focused = true
end)

local aimTarget = nil

local function aimStep(dt)
    if not combatActive() or not AimAssistState.Enabled
       or (AimAssistState.Hold and not heldInputs[AimAssistState.Key]) then
        aimTarget = nil
        return
    end

    local cam = getCamera()
    if not cam then aimTarget = nil; return end

    aimTarget = utility:GetClosestToMouse(cam, AimAssistState.FOV, AimAssistState.VisibleCheck,
        AimAssistState.Sticky and aimTarget or nil)
    if not aimTarget then return end

    local origin = cam.CFrame.Position
    local direction = aimTarget.Position - origin
    if direction.Magnitude <= 1e-4 then return end

    local desired = CFrame.lookAt(origin, aimTarget.Position)
    local alpha = 1 - math.clamp(AimAssistState.Smoothness, 0, 0.99) ^ (math.clamp(dt or 1 / 60, 0, 0.1) * 60)
    cam.CFrame = cam.CFrame:Lerp(desired, alpha)
end

----------------------------------------------------------------
-- TRIGGER BOT
----------------------------------------------------------------
local TriggerPress = { Down = false, X = 0, Y = 0, Target = nil, Since = 0, Last = 0 }

local function releaseTrigger()
    if TriggerPress.Down then
        if vim then vim:SendMouseButtonEvent(TriggerPress.X, TriggerPress.Y, 0, false, game, 1) end
        TriggerPress.Down = false
    end
end
Runtime.ReleaseMouse = releaseTrigger

local function triggerStep()
    if not TriggerState.Enabled or not combatActive() then
        TriggerPress.Target = nil
        releaseTrigger()
        return
    end
    if TriggerPress.Down then return end
    if not vim then
        TriggerState.Enabled = false
        Runtime:Notify("Trigger input is unavailable in this executor")
        return
    end

    local cam = getCamera()
    if not cam then return end
    local mouse = UserInputService:GetMouseLocation()
    local target = utility:GetClosestToMouse(cam, TriggerState.FOV, TriggerState.VisibleCheck)
    local now = os.clock()
    if target ~= TriggerPress.Target then
        TriggerPress.Target, TriggerPress.Since = target, now
    end
    if not target or now - TriggerPress.Since < TriggerState.Delay
       or now - TriggerPress.Last < TriggerState.Delay then return end

    TriggerPress.Last = now
    TriggerPress.X, TriggerPress.Y = math.floor(mouse.X), math.floor(mouse.Y)
    TriggerPress.Down = true
    local ok = Runtime:Call("trigger input", function()
        vim:SendMouseButtonEvent(TriggerPress.X, TriggerPress.Y, 0, true, game, 1)
    end)
    if not ok then
        TriggerState.Enabled = false
        Runtime:Call("release trigger", releaseTrigger)
        return
    end
    Runtime:Spawn("trigger release", function()
        task.wait(0.02)
        releaseTrigger()
    end)
end
----------------------------------------------------------------
-- ESP CORE
----------------------------------------------------------------
local espGui = Instance.new("ScreenGui")
espGui.Name = "VergilESP"
espGui.IgnoreGuiInset = true
espGui.ResetOnSpawn = false
espGui.DisplayOrder = 9998
espGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
espGui.Parent = guiParent

local EspCache = {}

local BoneMotors = {
    ["Root"] = true, ["RootJoint"] = true, ["Neck"] = true, ["Waist"] = true,
    ["LeftShoulder"] = true, ["RightShoulder"] = true,
    ["LeftElbow"] = true, ["RightElbow"] = true,
    ["LeftWrist"] = true, ["RightWrist"] = true,
    ["LeftHip"] = true, ["RightHip"] = true,
    ["LeftKnee"] = true, ["RightKnee"] = true,
    ["LeftAnkle"] = true, ["RightAnkle"] = true,
    ["Left Shoulder"] = true, ["Right Shoulder"] = true,
    ["Left Hip"] = true, ["Right Hip"] = true,
}

local FallbackBones = {
    { "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" },
    { "LeftLowerArm", "LeftHand" }, { "UpperTorso", "RightUpperArm" },
    { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
    { "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" },
    { "LeftLowerLeg", "LeftFoot" }, { "LowerTorso", "RightUpperLeg" },
    { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
    { "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
    { "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}

local function collectMotors(char)
    local list = {}
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA("Motor6D") and BoneMotors[obj.Name]
           and obj.Part0 and obj.Part1 then
            table.insert(list, obj)
        end
    end
    return list
end

local function createEsp(char)
    local e = { lines = {}, corners = {}, motors = collectMotors(char), motorsUpdated = os.clock() }

    e.glow = mk("Frame", espGui, {
        BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
    })
    e.glowStroke = mk("UIStroke", e.glow, { Thickness = 4, Transparency = 0.55 })

    e.box = mk("Frame", espGui, {
        BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
    })
    e.boxStroke = mk("UIStroke", e.box, { Thickness = 1, Transparency = 0 })

    for i = 1, 8 do
        e.corners[i] = mk("Frame", espGui, {
            BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false,
        })
    end

    for i = 1, 24 do
        e.lines[i] = mk("Frame", espGui, {
            AnchorPoint = Vector2.new(0, 0.5), BorderSizePixel = 0, Visible = false,
        })
    end

    e.hpBg = mk("Frame", espGui, {
        BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4,
        BorderSizePixel = 0, Visible = false,
    })
    e.hpFill = mk("Frame", espGui, {
        BackgroundColor3 = Color3.fromRGB(0, 255, 90), BorderSizePixel = 0, Visible = false,
    })

    e.tracer = mk("Frame", espGui, {
        AnchorPoint = Vector2.new(0, 0.5), BorderSizePixel = 0, Visible = false,
    })

    e.offLine = mk("Frame", espGui, {
        AnchorPoint = Vector2.new(0, 0.5), BorderSizePixel = 0, Visible = false,
    })
    e.offLabel = mk("TextLabel", espGui, {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11,
        TextColor3 = Color3.new(1, 1, 1), TextStrokeTransparency = 0.4,
        Visible = false, Size = UDim2.fromOffset(120, 14), AnchorPoint = Vector2.new(0.5, 0.5),
    })

    e.name = mk("TextLabel", espGui, {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
        TextColor3 = Color3.new(1, 1, 1), TextStrokeTransparency = 0.35,
        AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(200, 14), Visible = false,
    })
    e.dist = mk("TextLabel", espGui, {
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
        TextColor3 = Color3.fromRGB(200, 200, 200), TextStrokeTransparency = 0.5,
        AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(200, 14), Visible = false,
    })

    EspCache[char] = e
    return e
end

local function hideEsp(e)
    for key, value in pairs(e) do
        if key ~= "motors" then
            if typeof(value) == "Instance" then
                if value:IsA("GuiObject") then value.Visible = false end
            elseif typeof(value) == "table" then
                for _, obj in ipairs(value) do
                    if typeof(obj) == "Instance" and obj:IsA("GuiObject") then
                        obj.Visible = false
                    end
                end
            end
        end
    end
end

local function destroyEsp(e)
    for key, value in pairs(e) do
        if key ~= "motors" then
            if typeof(value) == "Instance" then
                value:Destroy()
            elseif typeof(value) == "table" then
                for _, obj in ipairs(value) do
                    if typeof(obj) == "Instance" then obj:Destroy() end
                end
            end
        end
    end
end
local function computeBounds(cam, char)
    if EspState.Dynamic then
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        local got = false
        for _, part in ipairs(char:GetChildren()) do
            if part:IsA("BasePart") and not IgnoreNames[part.Name] then
                local cf = part.CFrame
                local half = part.Size * 0.5
                for sx = -1, 1, 2 do
                    for sy = -1, 1, 2 do
                        for sz = -1, 1, 2 do
                            local sp, _, depth = project(cam, cf * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
                            if depth > 0.05 then
                                minX, maxX = math.min(minX, sp.X), math.max(maxX, sp.X)
                                minY, maxY = math.min(minY, sp.Y), math.max(maxY, sp.Y)
                                got = true
                            end
                        end
                    end
                end
            end
        end
        if not got then return nil end
        local vp = cam.ViewportSize
        return math.clamp(minX, -vp.X, vp.X * 2), math.clamp(minY, -vp.Y, vp.Y * 2),
            math.clamp(maxX, -vp.X, vp.X * 2), math.clamp(maxY, -vp.Y, vp.Y * 2)
    end

    local head = char:FindFirstChild("Head")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not head or not hrp then return nil end
    local top, _, topDepth = project(cam, head.Position + Vector3.new(0, 0.55, 0))
    local bottom, _, bottomDepth = project(cam, hrp.Position - Vector3.new(0, 2.6, 0))
    if topDepth <= 0.05 or bottomDepth <= 0.05 then return nil end
    local h = math.abs(bottom.Y - top.Y)
    if h < 4 then return nil end
    local w = h * 0.5
    local center = (top.X + bottom.X) / 2
    return center - w / 2, math.min(top.Y, bottom.Y), center + w / 2, math.max(top.Y, bottom.Y)
end

local function renderSkeleton(cam, char, e)
    local drawn = 0
    if os.clock() - e.motorsUpdated >= 1 then
        e.motors, e.motorsUpdated = collectMotors(char), os.clock()
    end
    local function bone(a, b)
        local first, _, firstDepth = project(cam, a)
        local second, _, secondDepth = project(cam, b)
        if firstDepth <= 0.05 or secondDepth <= 0.05 then return end
        drawn = drawn + 1
        local frame = e.lines[drawn]
        if frame then
            frame.Visible = true
            setLine(frame, guiPoint(espGui, first), guiPoint(espGui, second), 1, EspState.SkeletonColor)
        end
    end
    if #e.motors > 0 then
        for _, motor in ipairs(e.motors) do
            if motor.Parent and motor.Part0 and motor.Part1 then
                -- C0/C1 describe the same joint in world space; use the limb centers.
                bone(motor.Part0.Position, motor.Part1.Position)
            end
        end
    else
        for _, pair in ipairs(FallbackBones) do
            local a, b = char:FindFirstChild(pair[1]), char:FindFirstChild(pair[2])
            if a and b then
                bone(a.Position, b.Position)
            end
        end
    end
end

local function renderEsp(cam, char, e)
    local head = char:FindFirstChild("Head")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not head or not hrp or not hum or hum.Health <= 0 then return false end
    local distance = (hrp.Position - cam.CFrame.Position).Magnitude
    if EspState.MaxDistance > 0 and distance > EspState.MaxDistance then return false end

    local vp = cam.ViewportSize
    local sp, on, z = project(cam, head.Position)
    local visible = on and z > 0

    local minX, minY, maxX, maxY = computeBounds(cam, char)
    local hasBox = minX and maxX and maxX > minX and maxY > minY
    if hasBox then
        visible = maxX >= 0 and minX <= vp.X and maxY >= 0 and minY <= vp.Y
        hasBox = visible
    end
    if hasBox then
        minX, minY, maxX, maxY = px(minX), px(minY), px(maxX), px(maxY)
        local origin = espGui.AbsolutePosition
        minX, maxX = minX - origin.X, maxX - origin.X
        minY, maxY = minY - origin.Y, maxY - origin.Y
    end
    local showOff = EspState.Offscreen and not visible
    if not hasBox and not showOff then return false end

    if hasBox then
        local w, h = maxX - minX, maxY - minY

        if EspState.Glow then
            e.glow.Visible = true
            e.glow.Position = UDim2.fromOffset(minX - 2, minY - 2)
            e.glow.Size = UDim2.fromOffset(w + 4, h + 4)
            e.glowStroke.Color = EspState.GlowColor
        end

        if EspState.Box then
            e.box.Visible = true
            e.box.Position = UDim2.fromOffset(minX, minY)
            e.box.Size = UDim2.fromOffset(w, h)
            e.boxStroke.Color = EspState.BoxColor
        end

        if EspState.Corner then
            local cl = math.clamp(math.min(w, h) * 0.22, 4, 16)
            local t = 1.5
            local specs = {
                { minX, minY, cl, t }, { minX, minY, t, cl },
                { maxX - cl, minY, cl, t }, { maxX - t, minY, t, cl },
                { minX, maxY - t, cl, t }, { minX, maxY - cl, t, cl },
                { maxX - cl, maxY - t, cl, t }, { maxX - t, maxY - cl, t, cl },
            }
            for i, s in ipairs(specs) do
                local f = e.corners[i]
                f.Visible = true
                f.Position = UDim2.fromOffset(s[1], s[2])
                f.Size = UDim2.fromOffset(s[3], s[4])
                f.BackgroundColor3 = EspState.CornerColor
            end
        end

        if EspState.HealthBar then
            local bx = minX - 7
            e.hpBg.Visible = true
            e.hpBg.Position = UDim2.fromOffset(bx, minY)
            e.hpBg.Size = UDim2.fromOffset(3, h)
            local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
            local fh = h * frac
            e.hpFill.Visible = true
            e.hpFill.Position = UDim2.fromOffset(bx, minY + (h - fh))
            e.hpFill.Size = UDim2.fromOffset(3, fh)
            e.hpFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60):Lerp(
                Color3.fromRGB(0, 255, 90), frac)
        end

        if EspState.Skeleton then renderSkeleton(cam, char, e) end
    end

    if visible and EspState.Tracers then
        e.tracer.Visible = true
        setLine(e.tracer, guiPoint(espGui, Vector2.new(vp.X / 2, vp.Y - 60)),
            guiPoint(espGui, (project(cam, head.Position))), 1.5, EspState.TracerColor)
    end

    if showOff then
        local center = Vector2.new(vp.X / 2, vp.Y / 2)
        local dir = sp - center
        if z < 0 then dir = -dir end
        if dir.Magnitude < 1 then dir = Vector2.new(0, 1) end
        dir = dir.Unit
        local margin = 40
        local scale = math.min(
            (vp.X / 2 - margin) / math.max(math.abs(dir.X), 1e-3),
            (vp.Y / 2 - margin) / math.max(math.abs(dir.Y), 1e-3))
        local edge = center + dir * scale

        e.offLine.Visible = true
        setLine(e.offLine, guiPoint(espGui, edge - dir * 18), guiPoint(espGui, edge), 2, EspState.TracerColor)

        local plr = Players:GetPlayerFromCharacter(char)
        local label = plr and (NameProtect.Enabled and npName(plr) or plr.DisplayName) or char.Name
        if EspState.Distance then
            label = label .. " [" .. math.floor(distance) .. " studs]"
        end
        e.offLabel.Visible = true
        local labelPoint = guiPoint(espGui, edge + Vector2.new(0, 14))
        e.offLabel.Position = UDim2.fromOffset(labelPoint.X, labelPoint.Y)
        e.offLabel.TextColor3 = EspState.TracerColor
        e.offLabel.Text = label
    end

    if visible and hasBox then
        local plr = Players:GetPlayerFromCharacter(char)
        if EspState.Names then
            e.name.Visible = true
            e.name.Position = UDim2.fromOffset((minX + maxX) / 2, minY - 2)
            e.name.Text = plr and (NameProtect.Enabled and npName(plr) or plr.DisplayName) or char.Name
        end
        if EspState.Distance then
            e.dist.Visible = true
            e.dist.Position = UDim2.fromOffset((minX + maxX) / 2, maxY + 1)
            e.dist.Text = math.floor(distance) .. " studs"
        end
    end

    return true
end

local function espStep()
    local cam = getCamera()
    if not EspState.Enabled then
        for char, e in pairs(EspCache) do
            destroyEsp(e)
            EspCache[char] = nil
        end
        return
    end
    if not cam then
        for _, e in pairs(EspCache) do hideEsp(e) end
        return
    end

    for char, e in pairs(EspCache) do
        if not char.Parent then
            destroyEsp(e)
            EspCache[char] = nil
        end
    end

    for _, e in pairs(EspCache) do
        hideEsp(e)
    end

    for _, char in ipairs(utility:getPlayers()) do
        if char ~= LocalPlayer.Character and char.Parent then
            if not (EspState.TeamCheck and isTeammateChar(char)) then
                if EspState.IncludeNPCs or not isNpc(char) then
                    local e = EspCache[char]
                    if not e then
                        local ok, newE = Runtime:Call("create ESP", createEsp, char)
                        if ok then e = newE end
                    end
                    if e then
                        local ok = Runtime:Call("render ESP", renderEsp, cam, char, e)
                        if not ok then hideEsp(e) end
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------
-- HEALTH CHAMS
----------------------------------------------------------------
local HealthChamsState = {
    Enabled = false,
    Color = Color3.fromRGB(0, 255, 120),
    FolderPath = { "CurrentMap", "HealthPickups" },
    ModelName = "HealthPickup",
}
local healthHighlights = {}

local function hcFolder()
    local node = Workspace
    for _, name in ipairs(HealthChamsState.FolderPath) do
        node = node and node:FindFirstChild(name)
    end
    return node
end

local function hcClear()
    for adornee, hl in pairs(healthHighlights) do
        hl:Destroy()
        healthHighlights[adornee] = nil
    end
end

Runtime:Spawn("health pickups", function()
    while not Runtime.Unloaded do
        Runtime:Call("health pickup scan", function()
            if not HealthChamsState.Enabled then
                if next(healthHighlights) then hcClear() end
                return
            end

            local folder = hcFolder()
            local live = {}

            if folder then
                for _, pickup in ipairs(folder:GetChildren()) do
                    if pickup.Name == HealthChamsState.ModelName and pickup.Parent then
                        live[pickup] = true
                        local hl = healthHighlights[pickup]
                        if not hl then
                            hl = Instance.new("Highlight")
                            hl.Adornee = pickup
                            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                            hl.FillTransparency = 0.4
                            hl.OutlineTransparency = 0
                            hl.Parent = Workspace
                            healthHighlights[pickup] = hl
                        end
                        hl.FillColor = HealthChamsState.Color
                        hl.OutlineColor = HealthChamsState.Color
                    end
                end
            end

            for adornee, hl in pairs(healthHighlights) do
                if not live[adornee] or not adornee.Parent then
                    hl:Destroy()
                    healthHighlights[adornee] = nil
                end
            end
        end)
        task.wait(0.4)
    end
end)
----------------------------------------------------------------
-- AIM ASSIST UI
----------------------------------------------------------------
local AASection = Combat:Section({ Name = "aim assist", Side = 2 })

AASection:Toggle({
    Name = "enabled", Flag = "aa_enabled", Default = false,
    Callback = function(v) AimAssistState.Enabled = v end
})

AASection:Dropdown({
    Name = "hold key", Flag = "aa_key",
    Items = { "E", "Q", "C", "F", "LeftShift", "RightMouse" }, Default = "E",
    Callback = function(v) AimAssistState.Key = v end
})

AASection:Toggle({
    Name = "hold to aim", Flag = "aa_hold", Default = true,
    Callback = function(v) AimAssistState.Hold = v end
})

AASection:Toggle({
    Name = "keep current target", Flag = "aa_sticky", Default = false,
    Callback = function(v) AimAssistState.Sticky = v end
})

AASection:Toggle({
    Name = "visible check", Flag = "aa_vis", Default = false,
    Callback = function(v) AimAssistState.VisibleCheck = v end
})

AASection:Toggle({
    Name = "fov circle", Flag = "aa_circle", Default = true,
    Callback = function(v) AimAssistState.ShowCircle = v end
})

AASection:Slider({
    Name = "smoothing", Flag = "aa_smooth",
    Min = 0, Max = 0.95, Default = 0.35, Decimals = 0.01,
    Callback = function(v) AimAssistState.Smoothness = v end
})

AASection:Slider({
    Name = "fov", Flag = "aa_fov",
    Min = 10, Max = 800, Default = 140, Decimals = 1,
    Callback = function(v) AimAssistState.FOV = v end
})

AASection:Label({ Name = "fov color" }):Colorpicker({
    Name = "aa_color", Flag = "aa_color",
    Default = Color3.fromRGB(255, 200, 80),
    Callback = function(c) AimAssistState.Color = c end
})

----------------------------------------------------------------
-- TRIGGER BOT UI
----------------------------------------------------------------
local TBSection = Combat:Section({ Name = "trigger bot", Side = 2 })

TBSection:Toggle({
    Name = "enabled", Flag = "tb_enabled", Default = false,
    Callback = function(v) TriggerState.Enabled = v end
})

TBSection:Toggle({
    Name = "visible check", Flag = "tb_vis", Default = false,
    Callback = function(v) TriggerState.VisibleCheck = v end
})

TBSection:Slider({
    Name = "fov", Flag = "tb_fov",
    Min = 1, Max = 100, Default = 8, Decimals = 1,
    Callback = function(v) TriggerState.FOV = v end
})

TBSection:Slider({
    Name = "delay", Flag = "tb_delay",
    Min = 0.01, Max = 0.5, Default = 0.06, Decimals = 0.01,
    Callback = function(v) TriggerState.Delay = v end
})

----------------------------------------------------------------
-- ESP UI
----------------------------------------------------------------
local EspSection = Visuals:Section({ Name = "esp", Side = 2 })

EspSection:Toggle({
    Name = "enabled", Flag = "esp_enabled", Default = false,
    Callback = function(v) EspState.Enabled = v end
})

EspSection:Toggle({
    Name = "team check", Flag = "esp_team", Default = true,
    Callback = function(v) EspState.TeamCheck = v end
})

EspSection:Toggle({
    Name = "include npcs", Flag = "esp_npcs", Default = true,
    Callback = function(v) EspState.IncludeNPCs = v end
})

EspSection:Toggle({
    Name = "box", Flag = "esp_box", Default = true,
    Callback = function(v) EspState.Box = v end
})

EspSection:Toggle({
    Name = "dynamic box", Flag = "esp_dynamic", Default = true,
    Callback = function(v) EspState.Dynamic = v end
})

EspSection:Toggle({
    Name = "corner box", Flag = "esp_corner", Default = false,
    Callback = function(v) EspState.Corner = v end
})

EspSection:Toggle({
    Name = "skeleton", Flag = "esp_skeleton", Default = false,
    Callback = function(v) EspState.Skeleton = v end
})

EspSection:Toggle({
    Name = "health bar", Flag = "esp_healthbar", Default = true,
    Callback = function(v) EspState.HealthBar = v end
})

EspSection:Toggle({
    Name = "glow", Flag = "esp_glow", Default = false,
    Callback = function(v) EspState.Glow = v end
})

EspSection:Toggle({
    Name = "tracers", Flag = "esp_tracers", Default = false,
    Callback = function(v) EspState.Tracers = v end
})

EspSection:Toggle({
    Name = "offscreen indicators", Flag = "esp_offscreen", Default = false,
    Callback = function(v) EspState.Offscreen = v end
})

EspSection:Toggle({
    Name = "names", Flag = "esp_names", Default = true,
    Callback = function(v) EspState.Names = v end
})

EspSection:Toggle({
    Name = "distance", Flag = "esp_distance", Default = true,
    Callback = function(v) EspState.Distance = v end
})

EspSection:Label({ Name = "box color" }):Colorpicker({
    Name = "esp_box_color", Flag = "esp_box_color",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) EspState.BoxColor = c end
})

EspSection:Label({ Name = "corner color" }):Colorpicker({
    Name = "esp_corner_color", Flag = "esp_corner_color",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) EspState.CornerColor = c end
})

EspSection:Label({ Name = "skeleton color" }):Colorpicker({
    Name = "esp_skel_color", Flag = "esp_skel_color",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) EspState.SkeletonColor = c end
})

EspSection:Label({ Name = "tracer color" }):Colorpicker({
    Name = "esp_tracer_color", Flag = "esp_tracer_color",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) EspState.TracerColor = c end
})

EspSection:Label({ Name = "glow color" }):Colorpicker({
    Name = "esp_glow_color", Flag = "esp_glow_color",
    Default = Color3.fromRGB(155, 155, 255),
    Callback = function(c) EspState.GlowColor = c end
})

----------------------------------------------------------------
-- HEALTH CHAMS UI
----------------------------------------------------------------
local HCSection = Visuals:Section({ Name = "health chams", Side = 2 })

HCSection:Toggle({
    Name = "enabled", Flag = "hc_enabled", Default = false,
    Callback = function(v) HealthChamsState.Enabled = v end
})

HCSection:Label({ Name = "color" }):Colorpicker({
    Name = "hc_color", Flag = "hc_color",
    Default = Color3.fromRGB(0, 255, 120),
    Callback = function(c) HealthChamsState.Color = c end
})

----------------------------------------------------------------
-- NAME PROTECT UI
----------------------------------------------------------------
local NPSection = Misc:Section({ Name = "name protect", Side = 2 })

NPSection:Toggle({
    Name = "enabled", Flag = "np_enabled", Default = false,
    Callback = function(v) NameProtect.Enabled = v end
})

NPSection:Dropdown({
    Name = "mode", Flag = "np_mode",
    Items = { "numbered", "all same" }, Default = "numbered",
    Callback = function(v) NameProtect.Mode = (v == "all same") and "all" or "numbered" end
})

NPSection:Textbox({
    Name = "local name", Flag = "np_local", Default = "you", Finished = true,
    Callback = function(v)
        NameProtect.Custom = (v ~= nil and v ~= "") and tostring(v):sub(1, 40) or "you"
    end
})

----------------------------------------------------------------
-- CHAMS UI
----------------------------------------------------------------
local ChamsSection = Visuals:Section({ Name = "chams", Side = 1 })

ChamsSection:Toggle({
    Name = "enabled", Flag = "chams_enabled", Default = false,
    Callback = function(v) ChamsState.Enabled = v end
})

ChamsSection:Toggle({
    Name = "team check", Flag = "chams_team", Default = true,
    Callback = function(v) ChamsState.TeamCheck = v end
})

ChamsSection:Toggle({
    Name = "include npcs", Flag = "chams_npcs", Default = true,
    Callback = function(v) ChamsState.IncludeNPCs = v end
})

ChamsSection:Label({ Name = "visible color" }):Colorpicker({
    Name = "chams_vis", Flag = "chams_vis",
    Default = Color3.fromRGB(155, 155, 255),
    Callback = function(c) ChamsState.VisibleColor[1] = c end
})

ChamsSection:Label({ Name = "occluded color" }):Colorpicker({
    Name = "chams_occ", Flag = "chams_occ",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) ChamsState.OccludedColor[1] = c end
})

ChamsSection:Slider({
    Name = "visible transparency", Flag = "chams_vis_t",
    Min = 0, Max = 1, Default = 0,
    Decimals = 0.01,
    Callback = function(v) ChamsState.VisibleColor[2] = v end
})

ChamsSection:Slider({
    Name = "occluded transparency", Flag = "chams_occ_t",
    Min = 0, Max = 1, Default = 0.8,
    Decimals = 0.01,
    Callback = function(v) ChamsState.OccludedColor[2] = v end
})

----------------------------------------------------------------
-- LIGHTING UI
----------------------------------------------------------------
local LightSection = Visuals:Section({ Name = "lighting", Side = 2 })

LightSection:Toggle({
    Name = "enabled", Flag = "light_enabled", Default = false,
    Callback = function(v)
        if LightState.Enabled == v then return end
        LightState.Enabled = v
        if v then
            snapshotLighting()
            applyLighting()
        else
            restoreLighting()
        end
    end
})

LightSection:Label({ Name = "ambient" }):Colorpicker({
    Name = "light_ambient", Flag = "light_ambient",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) LightState.Ambient = c end
})

LightSection:Label({ Name = "outdoor ambient" }):Colorpicker({
    Name = "light_outdoor", Flag = "light_outdoor",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) LightState.OutdoorAmbient = c end
})

LightSection:Slider({
    Name = "brightness", Flag = "light_bright",
    Min = 0, Max = 5, Default = 2,
    Decimals = 0.01,
    Callback = function(v) LightState.Brightness = v end
})

LightSection:Slider({
    Name = "clock time", Flag = "light_clock",
    Min = 0, Max = 24, Default = 14,
    Decimals = 0.1,
    Callback = function(v) LightState.ClockTime = v end
})

LightSection:Slider({
    Name = "fog end", Flag = "light_fogend",
    Min = 0, Max = 100000, Default = 100000,
    Decimals = 1,
    Callback = function(v) LightState.FogEnd = v end
})

LightSection:Slider({
    Name = "fog start", Flag = "light_fogstart",
    Min = 0, Max = 5000, Default = 0,
    Decimals = 1,
    Callback = function(v) LightState.FogStart = v end
})

----------------------------------------------------------------
-- ATMOSPHERE UI
----------------------------------------------------------------
local AtmSection = Visuals:Section({ Name = "atmosphere", Side = 2 })

AtmSection:Toggle({
    Name = "enabled", Flag = "atm_enabled", Default = false,
    Callback = function(v)
        if AtmState.Enabled == v then return end
        AtmState.Enabled = v
        if v then
            snapshotAtmosphere()
            applyAtmosphere()
        else
            restoreAtmosphere()
        end
    end
})

AtmSection:Slider({
    Name = "density", Flag = "atm_density",
    Min = 0, Max = 1, Default = 0.3,
    Decimals = 0.01,
    Callback = function(v) AtmState.Density = v end
})

AtmSection:Slider({
    Name = "haze", Flag = "atm_haze",
    Min = 0, Max = 10, Default = 0,
    Decimals = 0.01,
    Callback = function(v) AtmState.Haze = v end
})

AtmSection:Slider({
    Name = "glare", Flag = "atm_glare",
    Min = 0, Max = 10, Default = 0,
    Decimals = 0.01,
    Callback = function(v) AtmState.Glare = v end
})

AtmSection:Slider({
    Name = "offset", Flag = "atm_offset",
    Min = -1, Max = 1, Default = 0,
    Decimals = 0.01,
    Callback = function(v) AtmState.Offset = v end
})

AtmSection:Label({ Name = "color" }):Colorpicker({
    Name = "atm_color", Flag = "atm_color",
    Default = Color3.fromRGB(199, 199, 199),
    Callback = function(c) AtmState.Color = c end
})

AtmSection:Label({ Name = "decay" }):Colorpicker({
    Name = "atm_decay", Flag = "atm_decay",
    Default = Color3.fromRGB(106, 112, 125),
    Callback = function(c) AtmState.Decay = c end
})

----------------------------------------------------------------
-- CAMERA / FOV UI
----------------------------------------------------------------
local CameraSection = Misc:Section({ Name = "camera", Side = 1 })

CameraSection:Toggle({
    Name = "fov lock", Flag = "fov_enabled", Default = false,
    Callback = function(v)
        if FOVState.Enabled == v then return end
        FOVState.Enabled = v
        if v then
            enforceFOV()
        else
            restoreFOV()
        end
    end
})

CameraSection:Slider({
    Name = "fov", Flag = "fov_value",
    Min = 40, Max = 120, Default = 120,
    Decimals = 0.1,
    Callback = function(v)
        FOVState.Value = v
        enforceFOV()
    end
})

----------------------------------------------------------------
-- STRAFE SKIN CHANGER (local viewmodel, native skin assets)
----------------------------------------------------------------
local SkinChanger: any = {
    Enabled = false, AutoCycle = false, CycleInterval = 10, LastCycle = os.clock(),
    Catalog = {}, Weapons = {}, Selections = {}, Records = setmetatable({}, { __mode = "k" }),
    Status = "loading skin catalog", ActiveModel = nil, ActiveWeapon = nil,
    Knife = { Enabled = false, Type = "Karambit", Types = {}, TypeSet = {}, Choices = {} },
    Gloves = { Enabled = false, Type = "Default", Types = {}, Catalog = {}, Choices = {}, Record = nil },
    LiveControllers = setmetatable({}, { __mode = "k" }),
    Builds = 0,
}

do
    local HttpService = game:GetService("HttpService")

    function SkinChanger:SetStatus(text)
        if self.Status == text then return end
        self.Status = text
    end

    function SkinChanger:GetParts(model)
        local parts = model:FindFirstChild("Parts")
        if parts then return parts end
        -- Dagger uses a legacy body container named Model.
        local legacy = model:FindFirstChild("Model")
        if legacy and (legacy:IsA("Model") or legacy:IsA("Folder")) and model:FindFirstChild("GunComponents") then
            return legacy
        end
        return nil
    end

    function SkinChanger:Initialize()
        local classes = ReplicatedStorage:FindFirstChild("Classes")
        local combat = classes and classes:FindFirstChild("Combat")
        local configScript = combat and combat:FindFirstChild("SkinsConfig")
        local managerScript = combat and combat:FindFirstChild("SkinManager")
        local models = ReplicatedStorage:FindFirstChild("Models")
        if not configScript or not managerScript or not models then
            self:SetStatus("STRAFE skin modules unavailable")
            return
        end
        local configOK, config = Runtime:Call("skin catalog", require, configScript)
        local managerOK, manager = Runtime:Call("skin manager", require, managerScript)
        if not configOK or not managerOK or type(config) ~= "table" or type(manager) ~= "table"
           or type(config.getSkinsForWeapon) ~= "function" or type(manager.applySkin) ~= "function"
           or type(manager.removeSkin) ~= "function" then
            self:SetStatus("skin API unavailable")
            return
        end
        self.Config, self.Manager = config, manager
        for _, model in ipairs(models:GetChildren()) do
            if not model:IsA("Model") then continue end
            local ok, skins = pcall(config.getSkinsForWeapon, model.Name)
            if not ok or type(skins) ~= "table" or #skins == 0 then continue end
            local entry = { Labels = { "game equipped" }, ByLabel = {}, ById = {}, Ids = {}, Meshes = {}, Template = model }
            for _, skin in ipairs(skins) do
                if type(skin) == "table" and type(skin.name) == "string" then
                    local label = string.format("%s [%s]", skin.displayName or skin.name, skin.rarity or "skin")
                    if entry.ByLabel[label] then label = label .. " (" .. skin.name .. ")" end
                    entry.ByLabel[label], entry.ById[skin.name] = skin.name, label
                    table.insert(entry.Labels, label)
                    if not skin.isStockSkin then table.insert(entry.Ids, skin.name) end
                    if skin.isStockSkin then entry.StockId = skin.name end
                end
            end
            table.sort(entry.Labels, function(a, b)
                if a == "game equipped" then return b ~= "game equipped" end
                if b == "game equipped" then return false end
                return a:lower() < b:lower()
            end)
            local parts = self:GetParts(model)
            if parts then
                for _, part in ipairs(parts:GetDescendants()) do
                    if part:IsA("MeshPart") and part.MeshId ~= "" then entry.Meshes[part.Name] = part.MeshId end
                end
            end
            self.Catalog[model.Name] = entry
            table.insert(self.Weapons, model.Name)
        end
        table.sort(self.Weapons)
        local skinsFolder = ReplicatedStorage:FindFirstChild("Skins")
        local knivesFolder = skinsFolder and skinsFolder:FindFirstChild("Knives")
        local weaponsScript = combat:FindFirstChild("WeaponsConfig")
        local weaponsOK, weapons
        -- Classify from the authoritative melee slot, not a particular skin folder.
        -- Seasonal melee assets such as Scythe live in HalloweenKnives.
        if weaponsScript then weaponsOK, weapons = pcall(require, weaponsScript) end
        self.WeaponDefinitions = weaponsOK and weapons or nil
        for _, weapon in ipairs(self.Weapons) do
            local isKnife = knivesFolder and knivesFolder:FindFirstChild(weapon) ~= nil
            local definition = self.WeaponDefinitions and self.WeaponDefinitions.getWeapon(weapon)
            if definition and definition.slotType == "melee" and definition.isEquippable ~= false then isKnife = true end
            if not isKnife and type(config.isKnifePool) == "function" then
                local ok, result = pcall(config.isKnifePool, weapon)
                isKnife = ok and result == true
            end
            if isKnife then
                self.Knife.TypeSet[weapon] = true
                table.insert(self.Knife.Types, weapon)
            end
        end
        if not self.Knife.TypeSet[self.Knife.Type] then self.Knife.Type = self.Knife.Types[1] end
        self:SetStatus(string.format("%d weapon catalogs ready", #self.Weapons))
    end

    function SkinChanger:SaveSelectionFlags()
        Library.Flags.skin_loadout = HttpService:JSONEncode(self.Selections)
    end

    function SkinChanger:Select(weapon, skinId)
        local entry = self.Catalog[weapon]
        if not entry or (skinId and not entry.ById[skinId]) then return false end
        self.Selections[weapon] = skinId
        self.LastCycle = os.clock()
        self:SaveSelectionFlags()
        self:RequestRefresh()
        return true
    end

    function SkinChanger:Restore(model)
        -- Native rigs belong to the game. The next equip rebuilds them with the
        -- current settings; never destroy a live rig or its animation references.
        if model == self.ActiveModel then self.ActiveModel = nil end
    end

    function SkinChanger:RestoreAll()
        self.ActiveModel, self.ActiveWeapon = nil, nil
        self.ActiveParts, self.ActiveModelName = nil, nil
        self:SetStatus("settings changed; re-equip the weapon to apply")
    end

    function SkinChanger:GetModel(vm)
        if vm:GetAttribute("VergilVisualCopy") then return nil end
        if self:GetParts(vm) then return vm end
        -- The equipped weapon is a direct child of STRAFE's Viewmodel. Avoid walking
        -- the entire rig and accidentally selecting a cosmetic copy during swaps.
        for _, child in ipairs(vm:GetChildren()) do
            if child:IsA("Model") and not child:GetAttribute("VergilVisualCopy") and self:GetParts(child) then return child end
        end
        for _, child in ipairs(vm:GetDescendants()) do
            if child:IsA("Model") and not child:GetAttribute("VergilVisualCopy") and self:GetParts(child) then return child end
        end
        return nil
    end

    function SkinChanger:DetectWeapon(model)
        local native = self.Records[model]
        if native then return native.BaseWeapon end
        for _, key in ipairs({ "WeaponName", "weaponName", "GunName", "Weapon" }) do
            local value = model:GetAttribute(key)
            if type(value) == "string" and self.Catalog[value] then return value end
        end
        if self.Catalog[model.Name] then return model.Name end
        local applied = model:GetAttribute("AppliedSkinName")
        if type(applied) == "string" and type(self.Config.getSkin) == "function" then
            local skin = self.Config.getSkin(applied)
            if skin and self.Catalog[skin.weaponName] then return skin.weaponName end
        end
        local parts = self:GetParts(model)
        if not parts then return nil end
        local meshes = {}
        for _, part in ipairs(parts:GetDescendants()) do
            if part:IsA("MeshPart") then meshes[part.Name] = part.MeshId end
        end
        local best, score, tied = nil, 0, false
        for weapon, entry in pairs(self.Catalog) do
            local matches = 0
            for name, mesh in pairs(entry.Meshes) do
                if meshes[name] == mesh then matches = matches + 1 end
            end
            if matches > score then best, score, tied = weapon, matches, false
            elseif matches == score and matches > 0 then tied = true end
        end
        return not tied and best or nil
    end

    function SkinChanger:ResolveOptions(weapon, options)
        local resolved = type(options) == "table" and table.clone(options) or {}
        local actual = weapon
        local inventory = self.Inventory
        local agents = inventory and inventory.Agents
        if agents and agents.Enabled and agents.Selected then resolved.characterName = agents.Selected end
        if inventory and inventory.Enabled then
            local loadout = inventory.State.getLoadout()
            local knifeType = inventory.LocalLoadout.melee or loadout.melee
            if self.Knife.TypeSet[weapon] and self.Knife.TypeSet[knifeType] then actual = knifeType end
            local equipped = inventory.LocalEquipped[actual]
            if equipped == nil then equipped = inventory.State.getEquippedSkinForWeapon(actual) end
            if equipped == nil and actual ~= weapon then equipped = inventory.LocalEquipped[weapon] end
            local item = equipped and inventory.ById[equipped]
            if item and item.weaponName ~= actual then item = nil end
            local catalog = self.Catalog[actual]
            resolved.skinName = item and item.skinName or (catalog and (catalog.StockId or catalog.Ids[1]))
            local gloveType = inventory.LocalLoadout.gloves or loadout.gloves or "Default"
            if not self.Gloves.Catalog[gloveType] then gloveType = "Default" end
            local entry = self.Gloves.Catalog[gloveType]
            local gloveId = inventory.LocalEquipped[gloveType]
            if gloveId == nil then gloveId = inventory.State.getEquippedSkinForWeapon(gloveType) end
            local gloveItem = gloveId and inventory.ById[gloveId]
            local gloveSkin = gloveItem and self.Config.getSkin(gloveItem.skinName)
            resolved.gloveType = entry and entry.Bare and "Default" or gloveType
            resolved.gloveVariant = gloveSkin and gloveSkin.surfaceAppearancePath:match("([^/]+)$")
                or (entry and entry.Variants[entry.Default].Name) or "Stock"
            resolved._VergilBareHands = entry and entry.Bare or nil
            return actual, resolved, self.Knife.TypeSet[weapon] == true, true
        end
        local overrideKnife = self.Knife.Enabled and self.Knife.TypeSet[weapon]
            and self.Knife.TypeSet[self.Knife.Type]
        if overrideKnife then
            actual = self.Knife.Type
            resolved.skinName = self.Knife.Choices[actual] or (self.Catalog[actual] and self.Catalog[actual].StockId)
        elseif self.Enabled and self.Selections[weapon] then
            resolved.skinName = self.Selections[weapon]
        end
        local gloveOverride = self.Gloves.Enabled and self.Gloves.Catalog[self.Gloves.Type]
        if gloveOverride then
            local entry = self.Gloves.Catalog[self.Gloves.Type]
            local id = self.Gloves.Choices[self.Gloves.Type] or entry.Default
            resolved.gloveType = entry.Bare and "Default" or self.Gloves.Type
            resolved.gloveVariant = entry.Bare and "Stock" or entry.Variants[id].Name
            resolved._VergilBareHands = entry.Bare or nil
        end
        return actual, resolved, overrideKnife == true, gloveOverride ~= nil and gloveOverride ~= false
    end

    function SkinChanger:InstallNativeBuilder()
        local combat = ReplicatedStorage:FindFirstChild("Classes")
        combat = combat and combat:FindFirstChild("Combat")
        local module = combat and combat:FindFirstChild("ViewmodelRig")
        if not module then self:SetStatus("native rig builder unavailable"); return end
        local ok, rig = Runtime:NativeCall("native rig builder", require, module)
        if not ok or type(rig) ~= "table" or type(rig.build) ~= "function" then return end
        self.Rig = rig
        if type(getupvalues) == "function" then
            local scanned, values = pcall(getupvalues, rig.build)
            if scanned then
                for _, value in pairs(values) do
                    if type(value) == "function" and debug.info(value, "n") == "weldToHandle" then
                        self.NativeWeld = value
                    elseif type(value) == "table" and type(rawget(value, "swapArmsOnModel")) == "function" then
                        self.NativeSwapArms = value.swapArmsOnModel
                    end
                end
            end
        end
        self.NativeReady = Runtime:Hook("native skin builder", rig.build, function(original, weapon, options)
            if self.AutoCycle and self.Enabled and not (self.Knife.Enabled and self.Knife.TypeSet[weapon])
               and os.clock() - self.LastCycle >= self.CycleInterval then
                local entry = self.Catalog[weapon]
                if entry and #entry.Ids > 0 then
                    self.Selections[weapon] = entry.Ids[math.random(1, #entry.Ids)]
                    self.LastCycle = os.clock()
                    Library.Flags.skin_loadout = HttpService:JSONEncode(self.Selections)
                end
            end
            local actual, resolved, knifeOverride, gloveOverride = self:ResolveOptions(weapon, options)
            local result = original(actual, resolved)
            if type(result) == "table" and typeof(result.gunModel) == "Instance" then
                -- STRAFE's builder applies knife skins internally. Firearm skins are
                -- normally applied later, so apply them to the real model before the
                -- game receives and caches its component/animation references.
                local inventoryActive = self.Inventory and self.Inventory.Enabled
                if not result.isMelee and resolved.skinName and
                   (inventoryActive or (self.Enabled and self.Selections[weapon])) then
                    local id = resolved.skinName
                    local _, assetType = self.Config.getSkinAsset(id)
                    local applied = self.Manager.applySkin(result.gunModel, id, { staticEmissive = true })
                    if applied == false then error("[Vergil] native gun skin failed: " .. id) end
                    if assetType == "model" then
                        if resolved.hasArms and self.NativeSwapArms then
                            self.NativeSwapArms(result.gunModel, resolved.characterName, resolved.gloveType)
                        end
                        if gloveOverride and self.Gloves.Applier then
                            self.Gloves.Applier.applyTo(result.gunModel, resolved.gloveType, resolved.gloveVariant, { staticEmissive = true })
                        end
                        if self.NativeWeld then
                            self.NativeWeld(result.gunModel)
                        else
                            local components = result.gunModel:FindFirstChild("GunComponents")
                            local handle = components and components:FindFirstChild("Handle")
                            local parts = self:GetParts(result.gunModel)
                            if handle and parts then
                                for _, part in ipairs(parts:GetDescendants()) do
                                    if part:IsA("BasePart") and part ~= handle then
                                        local motor = Instance.new("Motor6D")
                                        motor.Name, motor.Part0, motor.Part1 = part.Name, handle, part
                                        motor.C0 = handle.CFrame:ToObjectSpace(part.CFrame)
                                        motor.Parent = handle
                                    end
                                end
                            end
                        end
                        local components = result.gunModel:FindFirstChild("GunComponents")
                        local arms = result.gunModel:FindFirstChild("Arms")
                        local root = result.hrp
                        if root and components then
                            local handle = components:FindFirstChild("Handle")
                            local handleMotor = root:FindFirstChild("Handle")
                            if handleMotor and handleMotor:IsA("Motor6D") and handle then handleMotor.Part1 = handle end
                            if arms then
                                for _, side in ipairs({ "LeftArm", "RightArm" }) do
                                    local motor = root:FindFirstChild(side)
                                    local arm = arms:FindFirstChild(side)
                                    if motor and motor:IsA("Motor6D") and arm then motor.Part1 = arm end
                                end
                            end
                        end
                        for _, part in ipairs(result.gunModel:GetDescendants()) do
                            if part:IsA("BasePart") then part.Anchored, part.CanCollide = false, false end
                        end
                    end
                end
                if resolved._VergilBareHands then
                    local arms = result.gunModel:FindFirstChild("Arms")
                    if arms then
                        for _, object in ipairs(arms:GetDescendants()) do
                            if object.Name == "Glove" and (object:IsA("BasePart") or object:IsA("JointInstance")) then
                                object:Destroy()
                            end
                        end
                    end
                end
                local record = {
                    BaseWeapon = weapon, Weapon = actual, Applied = resolved.skinName,
                    KnifeOverride = knifeOverride, GloveOverride = gloveOverride,
                    GloveType = resolved.gloveType, GloveVariant = resolved.gloveVariant,
                    CharacterName = resolved.characterName,
                    Bare = resolved._VergilBareHands,
                    VM = result.viewmodel, OriginalOptions = options,
                    HasSkin = knifeOverride or (inventoryActive and resolved.skinName ~= nil)
                        or (self.Enabled and self.Selections[weapon] ~= nil),
                }
                self.Records[result.gunModel] = record
                self.Builds = self.Builds + 1
                self.LastNativeBuild = record
            end
            return result
        end)
        Runtime:Hook("native skin selection", self.Manager.applySkin, function(original, model, id, ...)
            local record = self.Records[model]
            local overridden = record and record.HasSkin and
                ((self.Inventory and self.Inventory.Enabled) or (record.KnifeOverride and self.Knife.Enabled)
                    or (not record.KnifeOverride and self.Enabled))
            if overridden then
                local _, desired = self:ResolveOptions(record.BaseWeapon, record.OriginalOptions)
                local selected = desired.skinName
                -- Inventory/equip callbacks may request the owned skin after building
                -- the rig. Keep the actual selected model and its existing joints.
                if selected and model:GetAttribute("AppliedSkinName") == selected then return true end
                local owner = self.LiveControllers[record.VM]
                if selected ~= record.Applied and owner and owner.equipped and not owner.destroyed then
                    self:RequestRefresh()
                    return true
                end
                if selected then id = selected end
            end
            return original(model, id, ...)
        end)
        if self.NativeReady then self:SetStatus("native models ready; equip/re-equip to apply") end
    end

    function SkinChanger:LiveOptions(model, weapon)
        local loadout = self.Inventory and self.Inventory.State.getLoadout() or {}
        return {
            hasArms = true, skinName = model:GetAttribute("AppliedSkinName"), emissive = "static",
            characterName = self.Inventory and self.Inventory.Agents and self.Inventory.Agents.Enabled
                and self.Inventory.Agents.Selected or nil,
            gloveType = loadout.gloves or "Default", gloveVariant = "Stock",
        }
    end

    function SkinChanger:TransplantRig(vm, model, root, built)
        assert(vm and model and root and built.hrp and built.gunModel and built.viewmodel, "missing live rig parts")
        assert(root:IsDescendantOf(vm), "cosmetic root must belong to the viewmodel, not the player character")
        local sourceModel, sourceVM, sourceRoot = built.gunModel, built.viewmodel, built.hrp
        assert(self:GetParts(sourceModel) and sourceModel:FindFirstChild("GunComponents"), "native model is incomplete")
        root.Parent = vm
        for _, part in ipairs(vm:GetDescendants()) do
            if part:IsA("BasePart") and Backups[part] then restorePart(part) end
            local hidden = ArmHideBackups[part]
            if hidden then
                part.Transparency, part.LocalTransparencyModifier = hidden.Transparency, hidden.Modifier
                ArmHideBackups[part] = nil
            end
        end
        local alignment = root.CFrame * sourceRoot.CFrame:Inverse()
        local positioned = {}
        for _, container in ipairs({ sourceVM, sourceModel }) do
            for _, part in ipairs(container:GetDescendants()) do
                if part:IsA("BasePart") and part ~= sourceRoot and not positioned[part] then
                    part.CFrame = alignment * part.CFrame
                    positioned[part] = true
                end
            end
        end
        local rootJoints = {}
        for _, child in ipairs(sourceRoot:GetChildren()) do
            if child:IsA("Motor6D") then rootJoints[#rootJoints + 1] = child end
        end
        -- Preserve the three instances already held by the live controller/caller.
        -- Replace their contents once, using the actual native parts and joints.
        for _, child in ipairs(model:GetChildren()) do if child ~= root then child:Destroy() end end
        if vm ~= model then
            for _, child in ipairs(vm:GetChildren()) do if child ~= model and child ~= root then child:Destroy() end end
        end
        for _, child in ipairs(sourceModel:GetChildren()) do
            if child ~= sourceRoot then
                child.Parent = child:IsA("AnimationController") and vm or model
            end
        end
        if sourceVM ~= sourceModel then
            for _, child in ipairs(sourceVM:GetChildren()) do
                if child ~= sourceRoot and child ~= sourceModel then child.Parent = vm end
            end
        end
        local retained = {}
        for _, incoming in ipairs(rootJoints) do
            local motor = root:FindFirstChild(incoming.Name)
            if not motor or not motor:IsA("Motor6D") then motor = Instance.new("Motor6D"); motor.Name = incoming.Name; motor.Parent = root end
            motor.Part0 = incoming.Part0 == sourceRoot and root or incoming.Part0
            motor.Part1 = incoming.Part1 == sourceRoot and root or incoming.Part1
            motor.C0, motor.C1, motor.Transform = incoming.C0, incoming.C1, incoming.Transform
            for key, value in pairs(incoming:GetAttributes()) do motor:SetAttribute(key, value) end
            retained[motor] = true
        end
        for _, child in ipairs(root:GetChildren()) do
            if child:IsA("Motor6D") and not retained[child] then child:Destroy() end
        end
        for _, name in ipairs({"AppliedSkinName", "CustomSoundId", "CustomSoundVolume"}) do
            model:SetAttribute(name, sourceModel:GetAttribute(name))
        end
        vm.PrimaryPart = root
        local components = model:FindFirstChild("GunComponents")
        if vm ~= model then model.PrimaryPart = components and components:FindFirstChild("Handle") end
        local record = self.Records[sourceModel]
        self.Records[sourceModel] = nil
        if record then record.VM = vm; record.Source = "live equip"; self.Records[model] = record end
        if sourceModel ~= sourceVM then sourceModel:Destroy() end
        sourceVM:Destroy()
        Runtime.ViewmodelScan = 0
        return record
    end

    function SkinChanger:BuildLive(weapon, vm, model, root)
        -- Handler.new's fifth argument is the character root. Only the actual
        -- viewmodel root may be used for cosmetic joints and transforms.
        root = vm:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("HumanoidRootPart")
        assert(root and root:IsA("BasePart") and root:IsDescendantOf(vm), "live viewmodel root missing")
        local ok, built = Runtime:NativeCall("build live cosmetic rig", self.Rig.build, weapon, self:LiveOptions(model, weapon))
        assert(ok, built)
        self:TransplantRig(vm, model, root, built)
        return built.gunModule
    end

    function SkinChanger:InstallLiveEquip()
        if self.LiveReady or not self.Rig then return end
        local classes = ReplicatedStorage:FindFirstChild("Classes")
        local module = classes and classes:FindFirstChild("Handler")
        if not module then return end
        local ok, class = Runtime:NativeCall("live weapon Handler", require, module)
        if not ok or type(class) ~= "table" or type(class.new) ~= "function" or type(class.equip) ~= "function" then return end
        -- Require the actual gameplay class. GC can contain stale constructor clones
        -- from previous executions, so discovery must not be based on those copies.
        local constructor = class.new
        self.LiveClass = class
        self.AnimatorClass = require(ReplicatedStorage.Classes.Animation.ViewmodelAnimator)
        self.LiveReady = Runtime:Hook("live cosmetic constructor", constructor,
            function(original, player, weapon, vm, model, root, ...)
                if player == LocalPlayer and (self.Enabled or self.Knife.Enabled or self.Gloves.Enabled or
                    (self.Inventory and self.Inventory.Enabled)) and self.Catalog[weapon] then
                    self:BuildLive(weapon, vm, model, root)
                end
                local controller = original(player, weapon, vm, model, root, ...)
                if player == LocalPlayer and type(controller) == "table" then
                    self.LiveControllers[vm] = controller
                    local record = self.Records[model]
                    if record then record.Controller = controller end
                end
                return controller
            end)
        Runtime:Hook("live cosmetic equip", class.equip, function(original, controller, module, ...)
            local record = controller.player == LocalPlayer and self.Records[controller.gunModel]
            if record and record.KnifeOverride and self.Knife.TypeSet[record.Weapon] then
                module = require(ReplicatedStorage.GunModules[record.Weapon])
            end
            return original(controller, module, ...)
        end)
        -- Adopt an already deployed controller when the script is loaded mid-match.
        local currentVM = getCamera() and getCamera():FindFirstChild("Viewmodel")
        if currentVM and type(getgc) == "function" then
            for _, value in pairs(getgc(true)) do
                if type(value) == "table" and rawget(value, "player") == LocalPlayer and rawget(value, "viewmodel") == currentVM
                    and type(value.equip) == "function" then self.LiveControllers[currentVM] = value; break end
            end
        end
    end

    function SkinChanger:RefreshCurrent()
        if Runtime.Unloaded or not self.LiveReady then return false end
        local vm = getCamera() and getCamera():FindFirstChild("Viewmodel")
        local controller = vm and self.LiveControllers[vm]
        if not controller or controller.destroyed or not controller.equipped then return false end
        local weapon, model, root = controller.weapon, controller.gunModel, controller.hrp
        local actual, desired = self:ResolveOptions(weapon, self:LiveOptions(model, weapon))
        local old = self.Records[model]
        if old and old.Weapon == actual and old.Applied == desired.skinName and old.GloveType == desired.gloveType
            and old.GloveVariant == desired.gloveVariant and old.Bare == desired._VergilBareHands
            and old.CharacterName == desired.characterName then return true end
        local ammo = controller.currentAmmo
        if controller.stopShooting then controller:stopShooting() end
        if controller.cancelReload then controller:cancelReload() end
        if controller.viewmodelAnimator and controller.viewmodelAnimator.Destroy then controller.viewmodelAnimator:Destroy() end
        for _, key in ipairs({"relicUnsubscribeEquipped", "relicUnsubscribeOverride", "attachmentUnsubscribe", "armsSettingUnsubscribe", "viewmodelSettingUnsubscribe"}) do
            if type(controller[key]) == "function" then controller[key](); controller[key] = nil end
        end
        local module = self:BuildLive(weapon, vm, model, root)
        controller.viewmodelAnimator = self.AnimatorClass.new(vm)
        if controller.meleeController then controller.meleeController.viewmodelAnimator = controller.viewmodelAnimator end
        local record = self.Records[model]
        if record then record.Controller = controller end
        local ok, err = Runtime:NativeCall("refresh live cosmetic equip", controller.equip, controller, module, ammo)
        assert(ok, err)
        return true
    end

    function SkinChanger:RequestRefresh()
        if self.RefreshQueued or Runtime.Unloaded then return end
        self.RefreshQueued = true
        Runtime:Spawn("refresh equipped cosmetics", function()
            task.wait(0.05)
            self.RefreshQueued = false
            if type(setthreadidentity) == "function" then pcall(setthreadidentity, 8) end
            self:RefreshCurrent()
        end)
    end

    function SkinChanger:Randomize(weapon)
        local entry = self.Catalog[weapon]
        if not entry or #entry.Ids == 0 then return end
        local choices = {}
        for _, id in ipairs(entry.Ids) do
            if id ~= self.Selections[weapon] then table.insert(choices, id) end
        end
        if #choices == 0 then choices = entry.Ids end
        self:Select(weapon, choices[math.random(1, #choices)])
    end

    function SkinChanger:Step(vm)
        if not vm then self.ActiveModel = nil; return false end
        local model = self:GetModel(vm)
        if not model then
            return false
        end
        self.ActiveModel = model
        if os.clock() - (self.LastPrune or 0) >= 1 then
            self.LastPrune = os.clock()
            for candidate in pairs(self.Records) do
                if candidate ~= model and not candidate.Parent then self.Records[candidate] = nil end
            end
        end
        local record = self.Records[model]
        if not record then
            if self.Enabled or self.Knife.Enabled or self.Gloves.Enabled then self:SetStatus("re-equip to apply native models") end
            return false
        end
        self.ActiveWeapon = record.BaseWeapon
        local actual, options = self:ResolveOptions(record.BaseWeapon, record.OriginalOptions)
        local changed = actual ~= record.Weapon or options.skinName ~= record.Applied
            or options.gloveType ~= record.GloveType or options.gloveVariant ~= record.GloveVariant
            or options._VergilBareHands ~= record.Bare
        self:SetStatus(changed and "settings changed; re-equip to apply"
            or (record.Weapon .. ": " .. (record.Applied or "game equipped") .. " [native rig]"))
        return record.HasSkin
    end

    SkinChanger:Initialize()
    Library.Flags.skin_loadout = "{}"
    Library.SetFlags.skin_loadout = function(value)
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tostring(value))
        if not ok or type(decoded) ~= "table" then
            Runtime:Notify("Invalid skin loadout in config")
            return
        end
        local selections = {}
        for weapon, id in pairs(decoded) do
            local entry = SkinChanger.Catalog[weapon]
            if entry and type(id) == "string" and entry.ById[id] then selections[weapon] = id end
        end
        SkinChanger.Selections = selections
        SkinChanger:SaveSelectionFlags()
    end
    table.insert(Runtime.Cleaners, function()
        SkinChanger.Enabled = false
        SkinChanger.Knife.Enabled = false
        SkinChanger:RestoreAll()
        table.clear(SkinChanger.Records)
    end)
end

----------------------------------------------------------------
-- ANY LOCAL KNIFE: independent of the owned/equipped knife type
----------------------------------------------------------------
do
    local HttpService = game:GetService("HttpService")
    local knife = SkinChanger.Knife

    function SkinChanger:SelectKnife(kind, id)
        local entry = self.Catalog[kind]
        if not self.Knife.TypeSet[kind] or (id and not entry.ById[id]) then return false end
        if id == entry.StockId then id = nil end
        self.Knife.Choices[kind] = id
        Library.Flags.knife_loadout = HttpService:JSONEncode(self.Knife.Choices)
        self:RequestRefresh()
        return true
    end

    Library.Flags.knife_loadout = "{}"
    Library.SetFlags.knife_loadout = function(value)
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tostring(value))
        if not ok or type(decoded) ~= "table" then
            Runtime:Notify("Invalid knife loadout in config")
            return
        end
        local choices = {}
        for kind, id in pairs(decoded) do
            local entry = SkinChanger.Catalog[kind]
            if knife.TypeSet[kind] and type(id) == "string" and entry.ById[id] and id ~= entry.StockId then
                choices[kind] = id
            end
        end
        knife.Choices = choices
        Library.Flags.knife_loadout = HttpService:JSONEncode(choices)
        SkinChanger:RequestRefresh()
    end
end

----------------------------------------------------------------
-- LOCAL GLOVES: passed directly to the game's native rig builder
----------------------------------------------------------------
do
    local HttpService = game:GetService("HttpService")
    local gloves = SkinChanger.Gloves

    function gloves:SetStatus(text)
        if self.Status == text then return end
        self.Status = text
    end

    function gloves:Initialize()
        local templates = ReplicatedStorage:FindFirstChild("Arms")
        local skins = ReplicatedStorage:FindFirstChild("Skins")
        local variants = skins and skins:FindFirstChild("Gloves")
        if not templates or not variants then self:SetStatus("glove assets unavailable"); return end
        local classes = ReplicatedStorage:FindFirstChild("Classes")
        local combat = classes and classes:FindFirstChild("Combat")
        local module = combat and combat:FindFirstChild("GloveVariantApplier")
        if module then
            local ok, applier = Runtime:NativeCall("glove API", require, module)
            if ok and type(applier) == "table" and type(applier.applyTo) == "function" then self.Applier = applier end
        end
        for _, template in ipairs(templates:GetChildren()) do
            local left, right = template:FindFirstChild("LeftArm"), template:FindFirstChild("RightArm")
            local folder = variants:FindFirstChild(template.Name)
            if not left or not left:IsA("BasePart") or not right or not right:IsA("BasePart") or not folder then continue end
            local metadata = {}
            if SkinChanger.Config then
                local ok, list = pcall(SkinChanger.Config.getSkinsForWeapon, template.Name)
                if ok and type(list) == "table" then
                    for _, skin in ipairs(list) do
                        if type(skin) ~= "table" then continue end
                        local variant = type(skin.surfaceAppearancePath) == "string" and skin.surfaceAppearancePath:match("([^/]+)$")
                        if variant then metadata[variant] = skin end
                    end
                end
            end
            local entry = { Template = template, Labels = {}, ByLabel = {}, ById = {}, Variants = {} }
            for _, asset in ipairs(folder:GetChildren()) do
                if not asset:IsA("SurfaceAppearance") then continue end
                local skin = metadata[asset.Name]
                local id = skin and skin.name or (template.Name .. "_" .. asset.Name)
                local label = (skin and skin.displayName or asset.Name) .. " [" .. (skin and skin.rarity or "finish") .. "]"
                if entry.ByLabel[label] then label = label .. " (" .. asset.Name .. ")" end
                entry.ByLabel[label], entry.ById[id] = id, label
                entry.Variants[id] = { Name = asset.Name, Asset = asset }
                table.insert(entry.Labels, label)
                if asset.Name == "Stock" then entry.Default = id end
            end
            table.sort(entry.Labels)
            entry.Default = entry.Default or entry.ByLabel[entry.Labels[1]]
            if entry.Default then
                self.Catalog[template.Name] = entry
                table.insert(self.Types, template.Name)
            end
        end
        table.sort(self.Types)
        local default = self.Catalog.Default
        if default then
            self.Catalog["bare hands"] = {
                Template = default.Template, Bare = true, Labels = { "bare hands" },
                ByLabel = { ["bare hands"] = "bare" }, ById = { bare = "bare hands" },
                Default = "bare", Variants = { bare = {} },
            }
            table.insert(self.Types, 1, "bare hands")
        end
        if not self.Catalog[self.Type] then self.Type = self.Types[1] end
        self:SetStatus("ready; enable to replace your gloves locally")
    end

    function gloves:Select(kind, id)
        local entry = self.Catalog[kind]
        if not entry or not entry.Variants[id] then return false end
        self.Choices[kind] = id
        Library.Flags.glove_loadout = HttpService:JSONEncode(self.Choices)
        SkinChanger:RequestRefresh()
        return true
    end

    function gloves:FindHands(vm)
        local model = SkinChanger:GetModel(vm)
        local arms = (model and model:FindFirstChild("Arms")) or vm:FindFirstChild("Arms")
        local root = vm:FindFirstChild("HumanoidRootPart")
        local sources = {}
        for _, side in ipairs({ "LeftArm", "RightArm" }) do
            local arm = arms and arms:FindFirstChild(side)
            if not arm and root then
                local motor = root:FindFirstChild(side)
                if motor and motor:IsA("Motor6D") then arm = motor.Part1 end
            end
            if arm and arm:IsA("BasePart") then sources[side] = arm end
        end
        return sources
    end

    function gloves:Restore()
        self.Record = nil
        self:SetStatus("settings changed; re-equip to apply")
    end

    function gloves:Owns(part)
        return self.Record ~= nil and part:IsDescendantOf(self.Record.Model)
    end

    function gloves:Step(vm)
        local model = vm and SkinChanger:GetModel(vm)
        local native = model and SkinChanger.Records[model]
        if not native or not native.GloveOverride then
            self.Record = nil
            self:SetStatus(self.Enabled and "re-equip to apply native gloves" or "glove override off")
            return false
        end
        self.Record = { Model = model, Kind = native.Bare and "bare hands" or native.GloveType, Variant = native.GloveVariant }
        self:SetStatus(self.Record.Kind .. ": " .. (native.GloveVariant or "Stock") .. " [native rig]")
        return true
    end

    gloves:Initialize()
    Library.Flags.glove_loadout = "{}"
    Library.SetFlags.glove_loadout = function(value)
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tostring(value))
        if not ok or type(decoded) ~= "table" then Runtime:Notify("Invalid glove loadout in config"); return end
        local choices = {}
        for kind, id in pairs(decoded) do
            local entry = gloves.Catalog[kind]
            if entry and type(id) == "string" and entry.Variants[id] then choices[kind] = id end
        end
        gloves.Choices = choices
        Library.Flags.glove_loadout = HttpService:JSONEncode(choices)
        SkinChanger:RequestRefresh()
    end
    table.insert(Runtime.Cleaners, function() gloves.Enabled = false; gloves:Restore() end)
    SkinChanger:InstallNativeBuilder()
end

----------------------------------------------------------------
-- LOCAL INVENTORY: use STRAFE's normal inventory and loadout UI
----------------------------------------------------------------
local LocalInventory: any = {
    Enabled = false, Entries = {}, ById = {}, BySkin = {}, LocalEquipped = {}, LocalLoadout = {},
    Publishing = false, Prefix = "vergil-local:",
}
SkinChanger.Inventory = LocalInventory

do
    local HttpService = game:GetService("HttpService")
    local section = Misc:Section({ Name = "game inventory unlocks", Side = 1 })
    local label = section:Label({ Name = "loading local inventory" })
    local classes = ReplicatedStorage:FindFirstChild("Classes")
    local react = classes and classes:FindFirstChild("UserInterface")
    react = react and react:FindFirstChild("ReactApp")
    local ok, state
    if react then ok, state = Runtime:NativeCall("inventory state", require, react:FindFirstChild("GameState")) end
    LocalInventory.State = ok and state or nil

    function LocalInventory:IsLocal(id)
        return type(id) == "string" and id:sub(1, #self.Prefix) == self.Prefix
    end

    function LocalInventory:BuildCatalog()
        local definitions = {}
        if type(getupvalues) == "function" then
            for _, value in pairs(getupvalues(SkinChanger.Config.getSkin)) do
                if type(value) == "table" then
                    for _, skin in pairs(value) do
                        if type(skin) == "table" and type(skin.name) == "string" and type(skin.weaponName) == "string" then
                            definitions[skin.name] = skin
                        end
                    end
                end
            end
        end
        for _, catalog in pairs(SkinChanger.Catalog) do
            for id in pairs(catalog.ById) do definitions[id] = SkinChanger.Config.getSkin(id) end
        end
        for _, catalog in pairs(SkinChanger.Gloves.Catalog) do
            for id in pairs(catalog.Variants) do
                local skin = SkinChanger.Config.getSkin(id)
                if skin then definitions[id] = skin end
            end
        end
        local names = {}
        for id in pairs(definitions) do names[#names + 1] = id end
        table.sort(names)
        for _, name in ipairs(names) do
            local skin = definitions[name]
            local entry = {
                id = self.Prefix .. name, skinName = name, weaponName = skin.weaponName,
                acquiredAt = 0, createdAt = 0, seed = 0, wear = 0, isLocal = true,
            }
            self.Entries[#self.Entries + 1] = entry
            self.ById[entry.id], self.BySkin[name] = entry, entry
        end
    end

    function LocalInventory:MergeSkins(incoming)
        local result, seen = {}, {}
        for _, item in ipairs(type(incoming) == "table" and incoming or {}) do
            if type(item) == "table" and not self:IsLocal(item.id) then
                result[#result + 1] = item
                self.ById[item.id] = item
                seen[item.id] = true
            end
        end
        for _, item in ipairs(self.Entries) do if not seen[item.id] then result[#result + 1] = item end end
        return result
    end

    function LocalInventory:MergeTypes(incoming, added)
        local result, seen = {}, {}
        for _, list in ipairs({type(incoming) == "table" and incoming or {}, added}) do
            for _, name in ipairs(list) do
                if type(name) == "string" and not seen[name] then result[#result + 1] = name; seen[name] = true end
            end
        end
        return result
    end

    function LocalInventory:MergeEquipped(incoming)
        local result = table.clone(type(incoming) == "table" and incoming or {})
        for weapon, id in pairs(self.LocalEquipped) do result[weapon] = id ~= false and id or nil end
        return result
    end

    function LocalInventory:NormalizeOverlay()
        local overlay = {}
        local melee = self.LocalLoadout.melee
        local gloves = self.LocalLoadout.gloves
        if type(melee) == "string" and SkinChanger.Knife.TypeSet[melee] then overlay.melee = melee end
        if type(gloves) == "string" and SkinChanger.Gloves.Catalog[gloves] then overlay.gloves = gloves end
        self.LocalLoadout = overlay
        return overlay
    end

    function LocalInventory:MergeLoadout(incoming)
        local result = table.clone(type(incoming) == "table" and incoming or {})
        -- Classes own their primary, secondary, attachments and killstreaks. Only
        -- synthetic cosmetic choices may override the selected class's loadout.
        for key, value in pairs(self:NormalizeOverlay()) do result[key] = value end
        return result
    end

    function LocalInventory:Publish()
        if not self.State or not self.Enabled then return end
        self.Publishing = true
        Runtime:NativeCall("publish local skin inventory", self.State.setSkinInventory, self:MergeSkins(self.ServerSkins), tick())
        Runtime:NativeCall("publish local knives", self.State.setUnlockedWeapons, self:MergeTypes(self.ServerWeapons, SkinChanger.Knife.Types))
        Runtime:NativeCall("publish knife ownership", self.State.setUnlockedKnives, self:MergeTypes(self.ServerKnives, SkinChanger.Knife.Types), tick())
        Runtime:NativeCall("publish local gloves", self.State.setUnlockedGloves, self:MergeTypes(self.ServerGloves, {"Default", "Bandages", "FloraciteGloves"}), tick())
        local loadout = self:MergeLoadout(self.ServerLoadout)
        Runtime:NativeCall("publish local loadout", self.State.setLoadout, loadout)
        Runtime:NativeCall("publish local equipped skins", self.State.setEquippedSkins, self:MergeEquipped(self.ServerEquipped), tick())
        self.Publishing = false
        label:SetText(string.format("%d skins | %d knife types | local inventory", #self.Entries, #SkinChanger.Knife.Types))
    end

    function LocalInventory:SetEnabled(enabled)
        if self.Enabled == enabled then return end
        if not self.State then Runtime:Notify("Inventory state is unavailable"); return end
        if enabled then
            local skins = self.State.getSkinInventory()
            local weapons = self.State.getUnlockedWeapons()
            local knives = self.State.getUnlockedKnives()
            local gloves = self.State.getUnlockedGloves()
            local equipped = self.State.getEquippedSkins()
            self.ServerSkins = table.clone(skins or {})
            self.ServerWeapons = table.clone(weapons or {})
            self.ServerKnives = table.clone(knives or {})
            self.ServerGloves = table.clone(gloves or {})
            self.ServerEquipped = table.clone(equipped or {})
            self.ServerLoadout = self.State.getLoadout()
            self.Enabled = true
            self:Publish()
        else
            self.Enabled = false
            Runtime:NativeCall("restore skin inventory", self.State.setSkinInventory, self.ServerSkins or {}, tick())
            Runtime:NativeCall("restore unlocked weapons", self.State.setUnlockedWeapons, self.ServerWeapons or {})
            Runtime:NativeCall("restore unlocked knives", self.State.setUnlockedKnives, self.ServerKnives or {}, tick())
            Runtime:NativeCall("restore unlocked gloves", self.State.setUnlockedGloves, self.ServerGloves or {}, tick())
            Runtime:NativeCall("restore equipped skins", self.State.setEquippedSkins, self.ServerEquipped or {}, tick())
            Runtime:NativeCall("restore loadout", self.State.setLoadout, self.ServerLoadout or {})
            label:SetText("local inventory unlocks off")
        end
        SkinChanger:RequestRefresh()
    end

    function LocalInventory:Equip(weapon, id)
        local item = id and self.ById[id]
        if id and not item then return false end
        weapon = weapon or (item and item.weaponName)
        if not weapon or (item and item.weaponName ~= weapon) then return false end
        self.LocalEquipped[weapon] = id or false
        if SkinChanger.Knife.TypeSet[weapon] then
            self.LocalLoadout.melee = weapon
            Runtime:NativeCall("select local inventory knife", self.State.setLoadoutWeapon, "melee", weapon)
        elseif SkinChanger.Gloves.Catalog[weapon] then
            self.LocalLoadout.gloves = weapon
            Runtime:NativeCall("select local inventory gloves", self.State.setLoadoutWeapon, "gloves", weapon)
        end
        -- Rebuild the live rig once before equipped-skin listeners see the new ID.
        Runtime:NativeCall("apply inventory skin to held weapon", SkinChanger.RefreshCurrent, SkinChanger)
        Runtime:NativeCall("select local inventory skin", self.State.setEquippedSkin, weapon, id)
        Runtime:NativeCall("finish local inventory equip", self.State.setSkinEquipResult, true, nil, weapon, id)
        self:SaveChoices()
        return true
    end

    function LocalInventory:SaveChoices()
        local choices = {}
        for weapon, id in pairs(self.LocalEquipped) do
            local item = id and self.ById[id]
            choices[weapon] = item and item.skinName or false
        end
        Library.Flags.inventory_skin_choices = HttpService:JSONEncode(choices)
        Library.Flags.inventory_loadout_choices = HttpService:JSONEncode(self:NormalizeOverlay())
    end

    function LocalInventory:HandleRemote(remote, args)
        if not self.Enabled or self.SendingRealLoadout then return false end
        if remote.Name == "EquipSkin" then
            local payload = type(args[1]) == "table" and args[1]
            local weapon = payload and (payload.weaponName or payload.weapon) or args[1]
            local id = payload and (payload.skinInstanceId or payload.skinId or payload.id) or args[2]
            if id ~= nil and not self.ById[id] then return false end
            if type(weapon) ~= "string" then return false end
            Runtime:Spawn("equip from local game inventory", function()
                if type(setthreadidentity) == "function" then pcall(setthreadidentity, 8) end
                if self.Enabled then self:Equip(weapon, id) end
            end)
            return true
        elseif remote.Name == "SaveLoadout" and type(args[1]) == "table" then
            local payload = table.clone(args[1])
            Runtime:Spawn("update local game loadout", function()
                if type(setthreadidentity) == "function" then pcall(setthreadidentity, 8) end
                if not self.Enabled then return end
                for _, key in ipairs({"melee", "gloves"}) do
                    if payload[key] ~= nil then self.LocalLoadout[key] = payload[key] end
                end
                self:NormalizeOverlay()
                self.Publishing = true
                Runtime:NativeCall("apply current class loadout", self.State.setLoadout, payload)
                self.Publishing = false
                -- Preserve the game's normal owned-firearm selection. Only synthetic
                -- knife/glove choices need a local overlay; suppressing every save
                -- left the menu on one weapon while gameplay still used another.
                local serverPayload = table.clone(payload)
                local function contains(list, name)
                    for _, value in ipairs(list or {}) do if value == name then return true end end
                    return false
                end
                if serverPayload.melee and serverPayload.melee ~= "Knife" and not contains(self.ServerKnives, serverPayload.melee) then
                    local owned = self.ServerLoadout and self.ServerLoadout.melee
                    serverPayload.melee = owned and contains(self.ServerKnives, owned) and owned or "Knife"
                end
                if serverPayload.gloves and serverPayload.gloves ~= "Default" and not contains(self.ServerGloves, serverPayload.gloves) then
                    local owned = self.ServerLoadout and self.ServerLoadout.gloves
                    serverPayload.gloves = owned and contains(self.ServerGloves, owned) and owned or "Default"
                end
                self.SendingRealLoadout = true
                local sent, err = pcall(function() remote:FireServer(serverPayload) end)
                self.SendingRealLoadout = false
                if not sent then error(err) end
                SkinChanger:RequestRefresh()
                self:SaveChoices()
            end)
            return true
        end
        return false
    end

    if LocalInventory.State and SkinChanger.Config then
        LocalInventory:BuildCatalog()
        local gs = LocalInventory.State
        -- Seasonal knives are in a separate pool, but still use melee equip UI.
        if type(SkinChanger.Config.isKnifePool) == "function" then
            Runtime:Hook("seasonal knife pool", SkinChanger.Config.isKnifePool, function(original, pool, ...)
                if LocalInventory.Enabled and pool == "halloweenKnives" then return true end
                return original(pool, ...)
            end)
        end
        Runtime:Hook("local inventory skins", gs.setSkinInventory, function(original, incoming, timestamp)
            if LocalInventory.Enabled then
                if not LocalInventory.Publishing then
                    local real = {}
                    for _, item in ipairs(incoming or {}) do if not LocalInventory:IsLocal(item.id) then real[#real + 1] = item end end
                    LocalInventory.ServerSkins = real
                end
                incoming = LocalInventory:MergeSkins(incoming)
                timestamp = math.max(tonumber(timestamp) or 0, tick())
            end
            return original(incoming, timestamp)
        end)
        Runtime:Hook("local inventory knives", gs.setUnlockedWeapons, function(original, incoming)
            if LocalInventory.Enabled then
                if not LocalInventory.Publishing then LocalInventory.ServerWeapons = table.clone(incoming or {}) end
                incoming = LocalInventory:MergeTypes(incoming, SkinChanger.Knife.Types)
            end
            return original(incoming)
        end)
        Runtime:Hook("local knife ownership store", gs.setUnlockedKnives, function(original, incoming, timestamp)
            if LocalInventory.Enabled then
                if not LocalInventory.Publishing then LocalInventory.ServerKnives = table.clone(incoming or {}) end
                incoming = LocalInventory:MergeTypes(incoming, SkinChanger.Knife.Types)
                timestamp = math.max(tonumber(timestamp) or 0, tick())
            end
            return original(incoming, timestamp)
        end)
        Runtime:Hook("local knife ownership check", gs.isKnifeUnlocked, function(original, weapon)
            if LocalInventory.Enabled and SkinChanger.Knife.TypeSet[weapon] then return true end
            return original(weapon)
        end)
        Runtime:Hook("local inventory gloves", gs.setUnlockedGloves, function(original, incoming, timestamp)
            if LocalInventory.Enabled then
                if not LocalInventory.Publishing then LocalInventory.ServerGloves = table.clone(incoming or {}) end
                incoming = LocalInventory:MergeTypes(incoming, {"Default", "Bandages", "FloraciteGloves"})
                timestamp = math.max(tonumber(timestamp) or 0, tick())
            end
            return original(incoming, timestamp)
        end)
        Runtime:Hook("local equipped inventory skins", gs.setEquippedSkins, function(original, incoming, timestamp)
            if LocalInventory.Enabled then
                if not LocalInventory.Publishing then
                    local real = {}
                    for weapon, id in pairs(incoming or {}) do if not LocalInventory:IsLocal(id) then real[weapon] = id end end
                    LocalInventory.ServerEquipped = real
                end
                incoming = LocalInventory:MergeEquipped(incoming)
                timestamp = math.max(tonumber(timestamp) or 0, tick())
            end
            return original(incoming, timestamp)
        end)
        Runtime:Hook("local inventory loadout", gs.setLoadout, function(original, incoming)
            if LocalInventory.Enabled then
                if not LocalInventory.Publishing then LocalInventory.ServerLoadout = table.clone(incoming or {}) end
                incoming = LocalInventory:MergeLoadout(incoming)
            end
            return original(incoming)
        end)
        if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" then
            local original, wrapper
            local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
            wrapper = function(remote, ...)
                if not Runtime.Unloaded and typeof(remote) == "Instance" and remote.Parent == remotesFolder then
                    local method = getnamecallmethod()
                    if method == "FireServer" then
                        if LocalInventory:HandleRemote(remote, table.pack(...)) then return end
                    elseif method == "InvokeServer" and remote.Name == "EquipCharacter" and LocalInventory.Agents and LocalInventory.Agents.Enabled then
                        return LocalInventory.Agents:Equip(...)
                    end
                end
                return original(remote, ...)
            end
            if type(newcclosure) == "function" then wrapper = newcclosure(wrapper) end
            local hooked, value = Runtime:Call("local inventory equip routing", hookmetamethod, game, "__namecall", wrapper)
            if hooked then
                original = value
                table.insert(Runtime.Cleaners, function()
                    local current = type(getrawmetatable) == "function" and getrawmetatable(game).__namecall
                    if not current or current == wrapper then pcall(hookmetamethod, game, "__namecall", original) end
                end)
            end
        end
        SkinChanger:InstallLiveEquip()
        Runtime:Spawn("live equip discovery", function()
            while not Runtime.Unloaded and not SkinChanger.LiveReady do
                SkinChanger:InstallLiveEquip()
                task.wait(2)
            end
        end)
        Library.Flags.inventory_skin_choices = "{}"
        Library.Flags.inventory_loadout_choices = "{}"
        Library.SetFlags.inventory_skin_choices = function(value)
            local valid, decoded = pcall(HttpService.JSONDecode, HttpService, tostring(value))
            if not valid or type(decoded) ~= "table" then return end
            LocalInventory.LocalEquipped = {}
            for weapon, name in pairs(decoded) do
                local item = type(name) == "string" and LocalInventory.BySkin[name]
                if item and item.weaponName == weapon then LocalInventory.LocalEquipped[weapon] = item.id
                elseif name == false then LocalInventory.LocalEquipped[weapon] = false end
            end
            LocalInventory:SaveChoices()
            LocalInventory:Publish()
            SkinChanger:RequestRefresh()
        end
        Library.SetFlags.inventory_loadout_choices = function(value)
            local valid, decoded = pcall(HttpService.JSONDecode, HttpService, tostring(value))
            if not valid or type(decoded) ~= "table" then return end
            LocalInventory.LocalLoadout = {}
            for _, key in ipairs({"melee", "gloves"}) do
                if type(decoded[key]) == "string" then LocalInventory.LocalLoadout[key] = decoded[key] end
            end
            LocalInventory:SaveChoices()
            LocalInventory:Publish()
            SkinChanger:RequestRefresh()
        end
        section:Toggle({ Name = "unlock cosmetics in game inventory locally", Flag = "inventory_local", Default = true,
            Callback = function(value) LocalInventory:SetEnabled(value) end })
        section:Button({ Name = "refresh local inventory", Callback = function() LocalInventory:Publish(); SkinChanger:RequestRefresh() end })
        section:Label({ Name = "Choose skins in STRAFE's inventory / loadout" })
        section:Label({ Name = "Includes seasonal melee weapons and Scythe finishes" })
        section:Label({ Name = "Local session cosmetics; account ownership is unchanged" })
        table.insert(Runtime.Cleaners, function() LocalInventory:SetEnabled(false) end)
    else
        label:SetText("game inventory state unavailable")
    end
end

----------------------------------------------------------------
-- LOCAL AGENTS: native agent ownership and equip state
----------------------------------------------------------------
do
    local gs = LocalInventory.State
    local folder = ReplicatedStorage.Classes:FindFirstChild("Characters")
    local agents: any = { Enabled = false, Names = {}, Set = {}, Selected = nil, Publishing = false }
    LocalInventory.Agents = agents
    local section = Misc:Section({ Name = "local agents", Side = 2 })
    if gs and folder then
        local config = require(folder.CharactersConfig)
        local applier = require(folder.CharacterApplier)
        for _, character in ipairs(config.ROSTER or {}) do
            if type(character.name) == "string" then agents.Names[#agents.Names + 1] = character.name; agents.Set[character.name] = true end
        end
        table.sort(agents.Names)
        function agents:Merge(data)
            local result = table.clone(data or {})
            result.owned = LocalInventory:MergeTypes(result.owned, self.Names)
            result.equipped = self.Selected or result.equipped
            result.isLoaded = true
            return result
        end
        function agents:Equip(name)
            if not self.Enabled or not self.Set[name] then return {success = false, reason = "Unknown agent"} end
            self.Selected = name
            Library.Flags.agent_selected = name
            local current = gs.getCharacterState()
            self.Publishing = true
            Runtime:NativeCall("equip local agent state", gs.setCharacterState, self:Merge(current))
            self.Publishing = false
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health > 0 then Runtime:NativeCall("apply local agent", applier.applyTo, character, name) end
            SkinChanger:RequestRefresh()
            return {success = true, equipped = name, characterName = name}
        end
        function agents:SetEnabled(value)
            if self.Enabled == value then return end
            if value then
                local current = gs.getCharacterState()
                self.Original = {equipped = current.equipped, owned = table.clone(current.owned or {}), isLoaded = current.isLoaded}
                self.Enabled = true
                self.Publishing = true
                Runtime:NativeCall("publish local agents", gs.setCharacterState, self:Merge(current))
                self.Publishing = false
                if self.Selected then self:Equip(self.Selected) end
            else
                self.Enabled = false
                if self.Original then Runtime:NativeCall("restore agent inventory", gs.setCharacterState, self.Original) end
                local character = LocalPlayer.Character
                if character and self.Original and self.Original.equipped then
                    Runtime:NativeCall("restore agent appearance", applier.applyTo, character, self.Original.equipped)
                end
            end
            SkinChanger:RequestRefresh()
        end
        Runtime:Hook("local agent inventory", gs.setCharacterState, function(original, incoming)
            if agents.Enabled then
                if not agents.Publishing and incoming then
                    if incoming.owned then agents.Original.owned = table.clone(incoming.owned) end
                    if incoming.equipped then agents.Original.equipped = incoming.equipped end
                    if incoming.isLoaded ~= nil then agents.Original.isLoaded = incoming.isLoaded end
                end
                incoming = agents:Merge(incoming)
            end
            return original(incoming)
        end)
        Runtime:Connect(LocalPlayer.CharacterAdded, "restore selected local agent", function(character)
            Runtime:Spawn("apply respawned local agent", function()
                local humanoid = character:WaitForChild("Humanoid", 5)
                if agents.Enabled and agents.Selected and humanoid and character == LocalPlayer.Character then
                    Runtime:NativeCall("apply respawned agent", applier.applyTo, character, agents.Selected)
                end
            end)
        end)
        Library.Flags.agent_selected = ""
        Library.SetFlags.agent_selected = function(name)
            if name == "" then agents.Selected = nil; Library.Flags.agent_selected = ""
            elseif agents.Set[name] then agents.Selected = name; Library.Flags.agent_selected = name; if agents.Enabled then agents:Equip(name) end end
        end
        section:Toggle({Name = "unlock all agents locally", Flag = "agents_local", Default = true, Callback = function(value) agents:SetEnabled(value) end})
        section:Label({Name = tostring(#agents.Names) .. " agents available in the normal Agents menu"})
        section:Label({Name = "Agent choices are local to this session"})
        table.insert(Runtime.Cleaners, function() agents:SetEnabled(false) end)
    else
        section:Label({Name = "Agent modules unavailable"})
    end
end

----------------------------------------------------------------
-- WEAPON MODIFIERS: native recoil controllers and spread helpers
----------------------------------------------------------------
local WeaponMods: any = {
    NoRecoil = false, NoSpread = false, Shotguns = false, FastReload = false, NoBlastCooldown = false,
    Configs = {}, SpreadBackups = {}, DirectionHooks = {}, DirectionFunctions = {}, Status = "loading",
    RapidFire = false, RateMultiplier = 3, InfiniteAmmo = false, Shots = 0,
    RateBackups = setmetatable({}, {__mode = "k"}), AmmoBackups = setmetatable({}, {__mode = "k"}),
    ReloadOwners = setmetatable({}, {__mode = "k"}), BoltOwners = setmetatable({}, {__mode = "k"}),
}

do
    local section = Combat:Section({ Name = "weapon modifiers", Side = 1 })
    local status = section:Label({ Name = "loading weapon modifiers" })
    local classes = ReplicatedStorage:FindFirstChild("Classes")
    local combat = classes and classes:FindFirstChild("Combat")

    function WeaponMods:LoadModule(name)
        local module = combat and combat:FindFirstChild(name)
        if not module then return nil end
        local ok, value = Runtime:NativeCall("weapon module " .. name, require, module)
        return ok and type(value) == "table" and value or nil
    end

    WeaponMods.Weapons = WeaponMods:LoadModule("WeaponsConfig")
    WeaponMods.ClassConfig = WeaponMods:LoadModule("WeaponClassConfig")
    WeaponMods.BodyRecoil = WeaponMods:LoadModule("RecoilController")
    WeaponMods.CameraRecoil = WeaponMods:LoadModule("CameraRecoilController")
    WeaponMods.ReloadManager = WeaponMods:LoadModule("ReloadManager")
    WeaponMods.Handler = require(ReplicatedStorage.Classes.Handler)
    function WeaponMods:IsLocal(controller)
        return type(controller) == "table" and controller.player == LocalPlayer and not controller.destroyed
    end
    function WeaponMods:Observe(controller)
        if not self:IsLocal(controller) then return end
        if controller.viewmodel then SkinChanger.LiveControllers[controller.viewmodel] = controller end
        if controller.reloadManager then self.ReloadOwners[controller.reloadManager] = controller end
        if controller.boltAnimator then self.BoltOwners[controller.boltAnimator] = controller end
        if controller.equipped then self.Controller = controller end
        utility:InstallController(controller)
    end
    function WeaponMods:GetController()
        local camera = getCamera()
        local vm = camera and camera:FindFirstChild("Viewmodel")
        if not vm then return nil end
        local controller = SkinChanger.LiveControllers[vm] or self.Controller
        if self:IsLocal(controller) and controller.equipped and controller.viewmodel == vm then return controller end
        if type(getgc) == "function" and os.clock() - (self.LastDiscover or -math.huge) >= 1 then
            self.LastDiscover = os.clock()
            for _, value in pairs(getgc(true)) do
                if type(value) == "table" and rawget(value, "player") == LocalPlayer and rawget(value, "viewmodel") == vm
                    and not rawget(value, "destroyed") and type(value.shoot) == "function" then
                    self:Observe(value)
                    return value.equipped and value or nil
                end
            end
        end
        return nil
    end
    Runtime.GetLocalController = function() return WeaponMods:GetController() end
    function WeaponMods:RestoreRate(controller)
        local record = self.RateBackups[controller]
        if not record then return end
        if controller.currentGunModule == record.Applied then controller.currentGunModule = record.Original end
        self.RateBackups[controller] = nil
    end
    function WeaponMods:ApplyRate(controller)
        if not self:IsLocal(controller) then return end
        if not self.RapidFire then self:RestoreRate(controller);return end
        local gun = controller.currentGunModule
        if type(gun) ~= "table" or (gun.gunType ~= "HITSCAN" and gun.gunType ~= "BEAM") then self:RestoreRate(controller);return end
        local record = self.RateBackups[controller]
        if record and gun ~= record.Applied then self.RateBackups[controller] = nil;record = nil end
        if not record then
            record = {Original = gun, Applied = table.clone(gun)}
            self.RateBackups[controller] = record
            controller.currentGunModule = record.Applied
        end
        -- Keep live spread/attachment/cosmetic updates while overriding only fire timing.
        for key, value in pairs(record.Original) do
            if key ~= "rpm" and key ~= "burstDelay" and key ~= "bolt" then record.Applied[key] = value end
        end
        local multiplier = math.clamp(tonumber(self.RateMultiplier) or 3, 1, 8)
        -- STRAFE calls this rpm, but it is seconds between shots, not rounds/minute.
        record.Applied.rpm = math.max(0.02, (tonumber(record.Original.rpm) or 0.1) / multiplier)
        if type(record.Original.burstDelay) == "number" then record.Applied.burstDelay = math.max(0.02, record.Original.burstDelay / multiplier) end
        if type(record.Original.bolt) == "table" then
            record.Applied.bolt = table.clone(record.Original.bolt)
            record.Applied.bolt.speed = (tonumber(record.Original.bolt.speed) or 1) * multiplier
        end
    end
    function WeaponMods:Refill(controller)
        if not self.InfiniteAmmo or not self:IsLocal(controller) or not controller.equipped then return false end
        local gun = controller.currentGunModule
        local maxAmmo = tonumber(controller.maxAmmo) or 0
        if type(gun) ~= "table" or (gun.gunType ~= "HITSCAN" and gun.gunType ~= "BEAM") or maxAmmo <= 0 then return false end
        local record = self.AmmoBackups[controller]
        if not record or record.Weapon ~= controller.weapon then
            record = {Weapon = controller.weapon, Ammo = tonumber(controller.currentAmmo) or 0, Used = 0,
                Manager = controller.reloadManager, ManagerAmmo = controller.reloadManager and controller.reloadManager.currentAmmo}
            self.AmmoBackups[controller] = record
        end
        local changed = controller.currentAmmo ~= maxAmmo
        controller.currentAmmo = maxAmmo
        if controller.reloadManager then
            controller.reloadManager.currentAmmo = maxAmmo
            controller.reloadManager.maxAmmo = maxAmmo
        end
        return changed
    end
    function WeaponMods:RestoreAmmo(controller)
        local record = self.AmmoBackups[controller]
        if not record then return end
        self.AmmoBackups[controller] = nil
        if not controller.destroyed and controller.weapon == record.Weapon then
            -- Resume with normal remaining ammo, rather than leaving a synthetic full mag.
            controller.currentAmmo = math.clamp(record.Ammo - record.Used, 0, tonumber(controller.maxAmmo) or record.Ammo)
            if record.Manager and record.Manager == controller.reloadManager then record.Manager.currentAmmo = controller.currentAmmo end
            if type(controller.updateAmmoUI) == "function" then controller:updateAmmoUI() end
        end
    end
    function WeaponMods:Maintain(controller)
        if not self:IsLocal(controller) then return end
        self:Observe(controller);self:ApplyRate(controller)
        if self.InfiniteAmmo then
            local changed = self:Refill(controller)
            if controller.reloadManager and controller.reloadManager:isReloading() and type(controller.cancelReload) == "function" then
                controller:cancelReload();controller.canFire = true
            end
            if changed and type(controller.updateAmmoUI) == "function" then controller:updateAmmoUI() end
        elseif self.AmmoBackups[controller] then self:RestoreAmmo(controller) end
    end
    Runtime:Hook("local weapon maintenance", WeaponMods.Handler.update, function(original, controller, ...)
        WeaponMods:Maintain(controller)
        return original(controller, ...)
    end)
    Runtime:Hook("local shoot timing", WeaponMods.Handler.shoot, function(original, controller, gun, ...)
        WeaponMods:Maintain(controller)
        if WeaponMods.RapidFire and WeaponMods:IsLocal(controller) then gun = controller.currentGunModule or gun end
        return original(controller, gun, ...)
    end)
    Runtime:Hook("local magazine display", WeaponMods.Handler.updateAmmoUI, function(original, controller, ...)
        WeaponMods:Refill(controller)
        return original(controller, ...)
    end)
    Runtime:Hook("local shot ammo", WeaponMods.Handler.fireHitscanShot, function(original, controller, gun, ...)
        if WeaponMods:IsLocal(controller) then WeaponMods:Observe(controller);WeaponMods:Refill(controller) end
        local before = controller.lastShotTime
        local results = table.pack(original(controller, gun, ...))
        if WeaponMods:IsLocal(controller) and controller.lastShotTime ~= before then
            WeaponMods.Shots = WeaponMods.Shots + 1
            local record = WeaponMods.InfiniteAmmo and WeaponMods.AmmoBackups[controller]
            if record then record.Used = record.Used + 1;WeaponMods:Refill(controller) end
        end
        return table.unpack(results, 1, results.n)
    end)
    local animation = classes and classes:FindFirstChild("Animation")
    local boltModule = animation and animation:FindFirstChild("BoltAnimator")
    if boltModule then
        local ok, bolt = Runtime:NativeCall("bolt animator", require, boltModule)
        if ok and type(bolt) == "table" and type(bolt.isPlaying) == "function" then
            Runtime:Hook("rapid fire bolt gate", bolt.isPlaying, function(original, animator, ...)
                local owner = WeaponMods.BoltOwners[animator]
                if WeaponMods.RapidFire and WeaponMods:IsLocal(owner) then return false end
                return original(animator, ...)
            end)
        end
    end
    if type(WeaponMods.Handler.canBlast) == "function" then
        function WeaponMods:ClearBlastCooldown(controller)
            if not controller or controller.player ~= LocalPlayer then return end
            local tracker = controller.blastCooldownTracker
            if type(tracker) == "table" then
                -- canBlast reads this shared tracker, not controller.lastBlastTime.
                tracker.lastBlastTime = -math.huge
                tracker.isCooldownActive = false
                tracker.cooldownStartTime = 0
                tracker.cooldownDuration = 0
            end
            controller.lastBlastTime = -math.huge
        end
        WeaponMods.BlastHook = Runtime:Hook("local Blast cooldown", WeaponMods.Handler.canBlast, function(original, controller, ...)
            if WeaponMods.NoBlastCooldown then WeaponMods:ClearBlastCooldown(controller) end
            return original(controller, ...)
        end)
        Runtime:Hook("reset Blast after firing", WeaponMods.Handler.fireBlast, function(original, controller, ...)
            local results = table.pack(original(controller, ...))
            if WeaponMods.NoBlastCooldown then WeaponMods:ClearBlastCooldown(controller) end
            return table.unpack(results, 1, results.n)
        end)
    end
    local modules = ReplicatedStorage:FindFirstChild("GunModules")
    if modules then
        for _, module in ipairs(modules:GetChildren()) do
            if module:IsA("ModuleScript") then
                local ok, value = pcall(require, module)
                if ok and type(value) == "table" then WeaponMods.Configs[module.Name] = value end
            end
        end
    end

    function WeaponMods:IsShotgun(weapon, config)
        if type(weapon) == "table" then config, weapon = weapon, nil end
        config = config or (weapon and self.Configs[weapon])
        if config and type(config.pellets) == "number" and config.pellets > 1 then return true end
        local data = weapon and self.Weapons and self.Weapons.getWeapon(weapon)
        return data ~= nil and data.weaponType == "Shotgun"
    end

    function WeaponMods:ShouldNoSpread(weapon, config)
        return self.NoSpread and (self.Shotguns or not self:IsShotgun(weapon, config))
    end

    function WeaponMods:CurrentWeapon()
        local vm = getCamera() and getCamera():FindFirstChild("Viewmodel")
        local model = vm and SkinChanger:GetModel(vm)
        return model and SkinChanger:DetectWeapon(model) or nil
    end

    function WeaponMods:UpdateSpread()
        for weapon, config in pairs(self.Configs) do
            local enabled = self:ShouldNoSpread(weapon, config) and config.gunType ~= "MELEE"
            if enabled then
                if not self.SpreadBackups[config] then self.SpreadBackups[config] = { Value = config.spread } end
                if config.spread ~= 0 then config.spread = 0 end
            else
                local backup = self.SpreadBackups[config]
                if backup then config.spread = backup.Value; self.SpreadBackups[config] = nil end
            end
        end
    end

    function WeaponMods:ClearSpring(spring)
        if type(spring) ~= "table" then return end
        spring.Position, spring.Velocity, spring.Target = Vector3.zero, Vector3.zero, Vector3.zero
    end

    local recoilHooks = 0
    for _, module in ipairs({ WeaponMods.BodyRecoil or {}, WeaponMods.CameraRecoil or {} }) do
        if type(module.applyKick) == "function" then
            if Runtime:Hook("weapon recoil kick", module.applyKick, function(original, ...)
                if WeaponMods.NoRecoil then return end
                return original(...)
            end) then recoilHooks = recoilHooks + 1 end
        end
        if type(module.update) == "function" then
            Runtime:Hook("weapon recoil spring", module.update, function(original, controller, ...)
                if WeaponMods.NoRecoil then
                    for _, key in ipairs({"gunRecoilSpring", "rotationRecoilSpring", "shotTwistSpring", "spring"}) do
                        WeaponMods:ClearSpring(controller[key])
                    end
                end
                return original(controller, ...)
            end)
        end
    end
    if WeaponMods.ClassConfig and type(WeaponMods.ClassConfig.getHipfireBloom) == "function" then
        WeaponMods.BloomHook = Runtime:Hook("hipfire bloom", WeaponMods.ClassConfig.getHipfireBloom,
            function(original, weapon, config, ...)
                if WeaponMods:ShouldNoSpread(weapon, config) then return 0 end
                return original(weapon, config, ...)
            end)
    end
    if WeaponMods.ReloadManager and type(WeaponMods.ReloadManager.update) == "function" then
        WeaponMods.ReloadHook = Runtime:Hook("fast native reload", WeaponMods.ReloadManager.update,
            function(original, manager, dt, config, ...)
                if WeaponMods.FastReload and manager.state and manager.state.isReloading then
                    local now = tick()
                    manager.state.startTime = now - math.max(tonumber(config and config.reloadTime) or 0, 60)
                    manager.state.endTime = now - 1
                    if manager.state.phaseEndTime then manager.state.phaseEndTime = now - 1 end
                end
                -- The normal controller performs ammo commits, shell phases, UI,
                -- and completion callbacks; only its timers are accelerated.
                return original(manager, dt, config, ...)
            end)
    end

    function WeaponMods:InstallDirections()
        for _, name in ipairs({ "getSpreadDirection", "getBloomDirection" }) do
            if self.DirectionHooks[name] then continue end
            local target
            if type(filtergc) == "function" then
                local ok, value = pcall(filtergc, "function", { Name = name }, true)
                if ok then target = type(value) == "table" and value[1] or value end
            end
            if type(target) ~= "function" and type(getgc) == "function" and not self.GCScanned then
                local ok, values = pcall(getgc, false)
                if ok then
                    for _, fn in pairs(values) do
                        if type(fn) == "function" and debug.info(fn, "n") == name then target = fn; break end
                    end
                end
            end
            if type(target) == "function" then
                self.DirectionHooks[name] = Runtime:Hook(name, target, function(original, direction, spread, ...)
                    local weapon = WeaponMods:CurrentWeapon()
                    if weapon and WeaponMods:ShouldNoSpread(weapon) then
                        return direction.Magnitude > 0 and direction.Unit or direction
                    end
                    return original(direction, spread, ...)
                end)
                if self.DirectionHooks[name] then self.DirectionFunctions[name] = target end
            end
        end
        self.GCScanned = true
    end

    WeaponMods.Status = string.format("recoil controllers: %d | bloom: %s", recoilHooks, WeaponMods.BloomHook and "ready" or "unavailable")
    status:SetText(WeaponMods.Status)
    section:Toggle({ Name = "no recoil", Flag = "weapon_no_recoil", Default = false,
        Callback = function(v) WeaponMods.NoRecoil = v end })
    section:Toggle({ Name = "no spread", Flag = "weapon_no_spread", Default = false,
        Callback = function(v)
            WeaponMods.NoSpread = v
            WeaponMods:UpdateSpread()
            if v then Runtime:Spawn("spread helper installation", function() WeaponMods:InstallDirections() end) end
        end })
    section:Toggle({ Name = "apply no spread to shotguns", Flag = "weapon_no_spread_shotguns", Default = false,
        Callback = function(v) WeaponMods.Shotguns = v; WeaponMods:UpdateSpread() end })
    section:Toggle({ Name = "fast reload", Flag = "weapon_fast_reload", Default = false,
        Callback = function(v) WeaponMods.FastReload = v end })
    section:Toggle({Name = "rapid fire", Flag = "weapon_rapid_fire", Default = false, Callback = function(value)
        WeaponMods.RapidFire = value
        if not value then for controller in pairs(WeaponMods.RateBackups) do WeaponMods:RestoreRate(controller) end
        else local controller = WeaponMods:GetController();if controller then WeaponMods:Maintain(controller) end end
    end})
    section:Slider({Name = "fire rate multiplier", Flag = "weapon_fire_multiplier", Min = 1, Max = 8, Default = 3, Decimals = 0.5,
        Callback = function(value) WeaponMods.RateMultiplier = value;local controller = WeaponMods:GetController();if controller then WeaponMods:ApplyRate(controller) end end})
    section:Toggle({Name = "infinite ammo", Flag = "weapon_infinite_ammo", Default = false, Callback = function(value)
        WeaponMods.InfiniteAmmo = value
        if not value then for controller in pairs(WeaponMods.AmmoBackups) do WeaponMods:RestoreAmmo(controller) end
        else local controller = WeaponMods:GetController();if controller then WeaponMods:Maintain(controller) end end
    end})
    section:Label({Name = "Magazine and reload-manager ammo stay synchronized"})
    section:Label({Name = "Native shots retain the game's server-side validation"})
    section:Toggle({ Name = "no Blast cooldown", Flag = "weapon_no_blast_cooldown", Default = true,
        Callback = function(v)
            WeaponMods.NoBlastCooldown = v
            if v and WeaponMods.ClearBlastCooldown then
                for _, controller in pairs(SkinChanger.LiveControllers) do WeaponMods:ClearBlastCooldown(controller) end
            end
        end })
    section:Label({ Name = "Server Blast limits may still apply" })
    section:Label({ Name = "Shotguns retain their spread unless included above" })
    section:Label({ Name = "No spread affects hipfire bloom and pellet directions" })

    Runtime:Spawn("spread helper discovery", function()
        while not Runtime.Unloaded do
            if WeaponMods.NoSpread then WeaponMods:InstallDirections() end
            task.wait(2)
        end
    end)
    Runtime:Connect(RunService.Heartbeat, "spread maintenance", function()
        if os.clock() - (WeaponMods.LastApply or 0) >= 0.5 then
            WeaponMods.LastApply = os.clock()
            WeaponMods:UpdateSpread()
        end
    end)
    table.insert(Runtime.Cleaners, function()
        WeaponMods.NoRecoil, WeaponMods.NoSpread, WeaponMods.FastReload, WeaponMods.NoBlastCooldown = false, false, false, false
        WeaponMods.RapidFire, WeaponMods.InfiniteAmmo = false, false
        for controller in pairs(WeaponMods.RateBackups) do WeaponMods:RestoreRate(controller) end
        for controller in pairs(WeaponMods.AmmoBackups) do WeaponMods:RestoreAmmo(controller) end
        WeaponMods:UpdateSpread()
    end)
end

----------------------------------------------------------------
-- GUN / ARMS
----------------------------------------------------------------
local GunSection = Misc:Section({ Name = "gun model changer", Side = 1 })

GunSection:Toggle({ Name = "enabled", Flag = "gun_changer", Default = true,
    Callback = function(v)
        GunState.Enabled = v
        if not v then restoreGroup("parts") end
    end })

GunSection:Dropdown({ Name = "material", Flag = "gun_material",
    Items = { "Neon", "ForceField" }, Default = "Neon",
    Callback = function(v) GunState.Material = Enum.Material[v] or Enum.Material.Neon end })

GunSection:Label({ Name = "color" }):Colorpicker({
    Name = "gun_color", Flag = "gun_color",
    Default = Color3.fromRGB(255,255,255),
    Callback = function(c) GunState.Color = c end })

local ArmsSection = Misc:Section({ Name = "arms", Side = 2 })

ArmsSection:Toggle({ Name = "hide arms", Flag = "hide_arms", Default = false,
    Callback = function(v) ArmsState.Hide = v end })

ArmsSection:Toggle({ Name = "arms model changer", Flag = "arms_changer", Default = true,
    Callback = function(v)
        ArmsState.Enabled = v
        if not v then restoreGroup("arms") end
    end })

ArmsSection:Dropdown({ Name = "arms material", Flag = "arms_material",
    Items = { "Neon", "ForceField" }, Default = "Neon",
    Callback = function(v) ArmsState.Material = Enum.Material[v] or Enum.Material.Neon end })

ArmsSection:Label({ Name = "arms color" }):Colorpicker({
    Name = "arms_color", Flag = "arms_color",
    Default = Color3.fromRGB(255,255,255),
    Callback = function(c) ArmsState.Color = c end })

local MovementState = {
    Enabled = false,
    WalkSpeed = 16,
    JumpHeight = 7.2,
    Backups = setmetatable({}, { __mode = "k" }),
}

local function localHumanoid()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function applyMovement()
    if not MovementState.Enabled then return end
    local hum = localHumanoid()
    if not hum then return end
    if not MovementState.Backups[hum] then
        MovementState.Backups[hum] = {
            WalkSpeed = hum.WalkSpeed, JumpHeight = hum.JumpHeight, JumpPower = hum.JumpPower,
        }
    end
    if hum.WalkSpeed ~= MovementState.WalkSpeed then
        hum.WalkSpeed = MovementState.WalkSpeed
    end
    if hum.UseJumpPower then
        hum.JumpPower = math.sqrt(2 * math.max(Workspace.Gravity, 0) * MovementState.JumpHeight)
    elseif hum.JumpHeight ~= MovementState.JumpHeight then
        hum.JumpHeight = MovementState.JumpHeight
    end
end

local function resetMovement()
    for hum, values in pairs(MovementState.Backups) do
        Runtime:Call("restore movement", function()
            for key, value in pairs(values) do hum[key] = value end
        end)
        MovementState.Backups[hum] = nil
    end
end

local RadarState = {
    Enabled = false,
    Size = 180,
    Range = 250,
    TeamCheck = true,
}

local radarGui = mk("ScreenGui", guiParent, {
    Name = "VergilRadar",
    IgnoreGuiInset = true,
    ResetOnSpawn = false,
    DisplayOrder = 9997,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

local radarFrame = mk("Frame", radarGui, {
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -20, 1, -20),
    Size = UDim2.fromOffset(RadarState.Size, RadarState.Size),
    BackgroundColor3 = Color3.fromRGB(8, 10, 16),
    BackgroundTransparency = 0.35,
    BorderSizePixel = 0,
    Visible = false,
})
mk("UICorner", radarFrame, { CornerRadius = UDim.new(0.5, 0) })
mk("UIStroke", radarFrame, {
    Color = Color3.fromRGB(0, 220, 255),
    Transparency = 0.55,
})
mk("Frame", radarFrame, {
    Position = UDim2.new(0.5, 0, 0, 0),
    Size = UDim2.new(0, 1, 1, 0),
    BackgroundColor3 = Color3.fromRGB(0, 220, 255),
    BackgroundTransparency = 0.82,
    BorderSizePixel = 0,
})
mk("Frame", radarFrame, {
    Position = UDim2.new(0, 0, 0.5, 0),
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = Color3.fromRGB(0, 220, 255),
    BackgroundTransparency = 0.82,
    BorderSizePixel = 0,
})
local radarDots = {}

local function updateRadar()
    if not RadarState.Enabled then
        if radarFrame.Visible then radarFrame.Visible = false end
        return
    end

    local cam = getCamera()
    local lpChar = LocalPlayer.Character
    local lpRoot = lpChar and lpChar:FindFirstChild("HumanoidRootPart")
    if not cam or not lpRoot then
        radarFrame.Visible = false
        return
    end

    radarFrame.Visible = true
    radarFrame.Size = UDim2.fromOffset(RadarState.Size, RadarState.Size)
    local radius = RadarState.Size / 2 - 10
    local center = Vector2.new(RadarState.Size / 2, RadarState.Size / 2)

    local cf = cam.CFrame
    local forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
    local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
    forward = forward.Magnitude > 0.01 and forward.Unit or Vector3.new(0, 0, -1)
    right = right.Magnitude > 0.01 and right.Unit or Vector3.new(1, 0, 0)

    local target = aimTarget or utility.target
    local targetChar = target and target.Parent
    local seen = {}

    for _, char in ipairs(utility:getPlayers()) do
        if char ~= lpChar and char.Parent then
            local hrp = char:FindFirstChild("HumanoidRootPart")
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hrp and hum and hum.Health > 0 then
                if not (RadarState.TeamCheck and isTeammateChar(char)) then
                    seen[char] = true
                    local dot = radarDots[char]
                    if not dot then
                        dot = mk("Frame", radarFrame, {
                            Size = UDim2.fromOffset(5, 5),
                            AnchorPoint = Vector2.new(0.5, 0.5),
                            BackgroundColor3 = Color3.fromRGB(255, 70, 70),
                            BorderSizePixel = 0,
                            Visible = false,
                        })
                        mk("UICorner", dot, { CornerRadius = UDim.new(1, 0) })
                        radarDots[char] = dot
                    end

                    local offset = hrp.Position - lpRoot.Position
                    local x = offset:Dot(right)
                    local y = -offset:Dot(forward)
                    local point = Vector2.new(x, y) * (radius / math.max(RadarState.Range, 1))
                    if point.Magnitude > radius then
                        point = point.Unit * radius
                    end

                    dot.Position = UDim2.fromOffset(center.X + point.X, center.Y + point.Y)
                    if char == targetChar then
                        dot.BackgroundColor3 = Color3.fromRGB(255, 220, 0)
                    elseif Players:GetPlayerFromCharacter(char) then
                        dot.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
                    else
                        dot.BackgroundColor3 = Color3.fromRGB(255, 160, 40)
                    end
                    dot.Visible = true
                end
            end
        end
    end

    for char, dot in pairs(radarDots) do
        if not seen[char] or not char.Parent then
            dot:Destroy()
            radarDots[char] = nil
        end
    end
end

local lastMoveApply = 0
Runtime:Connect(RunService.Heartbeat, "maintenance", function()
    if os.clock() - lastMoveApply >= 0.1 then
        lastMoveApply = os.clock()
        if MovementState.Enabled then Runtime:Call("movement", applyMovement) end
        Runtime:Call("chams", chamsStep)
    end
end)

Runtime:Connect(LocalPlayer.CharacterAdded, "respawn", function()
    lastPlayersScan = -math.huge
    utility.target, aimTarget, TriggerPress.Target = nil, nil, nil
end)

cleanup = function()
    if Runtime.Cleaned then return end
    Runtime.Cleaned = true
    Runtime:Stop()

    MovementState.Enabled = false
    RadarState.Enabled = false
    utility.SilentAim = false
    utility.target = nil
    AimAssistState.Enabled = false
    TriggerState.Enabled = false
    EspState.Enabled = false
    ChamsState.Enabled = false
    HealthChamsState.Enabled = false
    LightState.Enabled = false
    AtmState.Enabled = false
    FOVState.Enabled = false
    NameProtect.Enabled = false
    GunState.Enabled = false
    ArmsState.Enabled = false
    ArmsState.Hide = false

    Runtime:Call("release trigger", releaseTrigger)
    Runtime:Call("restore local aim controllers", utility.UnhookControllers, utility)
    utility.hooking = false
    for i = #Runtime.Cleaners, 1, -1 do Runtime:Call("feature cleanup", Runtime.Cleaners[i]) end
    table.clear(Runtime.Cleaners)

    Runtime:Call("reset movement", resetMovement)
    Runtime:Call("restore lighting", restoreLighting)
    Runtime:Call("restore atmosphere", restoreAtmosphere)
    Runtime:Call("clear pickups", hcClear)
    Runtime:Call("restore names", npScan)
    Runtime:Call("restore FOV", restoreFOV)

    pcall(function()
        local parts = {}
        for part in pairs(Backups) do
            table.insert(parts, part)
        end
        for _, part in ipairs(parts) do
            Runtime:Call("restore viewmodel part", restorePart, part)
        end
    end)
    pcall(function()
        for part, bk in pairs(ArmHideBackups) do
            if part and part.Parent then
                part.Transparency = bk.Transparency
                part.LocalTransparencyModifier = bk.Modifier
            end
            ArmHideBackups[part] = nil
        end
    end)
    pcall(function() restoreGroup("parts") end)
    pcall(function() restoreGroup("arms") end)

    pcall(function()
        for _, ad in pairs(ChamsCache) do
            ad[1]:Destroy()
            ad[2]:Destroy()
        end
        for part in pairs(ChamsCache) do
            ChamsCache[part] = nil
        end
    end)

    pcall(function()
        for char, e in pairs(EspCache) do
            destroyEsp(e)
            EspCache[char] = nil
        end
    end)

    pcall(function() fovGui:Destroy() end)
    pcall(function() espGui:Destroy() end)
    pcall(function() radarGui:Destroy() end)

    table.clear(heldInputs)
    table.clear(radarDots)
    if Environment.VergilCleanup == cleanup then Environment.VergilCleanup = nil end
    if Environment.VergilDebugAPI and Environment.VergilDebugAPI.Runtime == Runtime then
        Environment.VergilDebugAPI = nil
    end
    if Environment.VergilAPI and Environment.VergilAPI.Runtime == Runtime then Environment.VergilAPI = nil end
    if not Library.Unloaded and type(Runtime.LibraryExit) == "function" then
        Runtime:Call("UI cleanup", Runtime.LibraryExit, Library)
    end
end

local RadarSection = Visuals:Section({ Name = "radar", Side = 1 })

RadarSection:Toggle({
    Name = "enabled", Flag = "radar_enabled", Default = false,
    Callback = function(v) RadarState.Enabled = v end,
})

RadarSection:Toggle({
    Name = "team check", Flag = "radar_team", Default = true,
    Callback = function(v) RadarState.TeamCheck = v end,
})

RadarSection:Slider({
    Name = "size", Flag = "radar_size",
    Min = 120, Max = 320, Default = 180, Decimals = 1,
    Callback = function(v) RadarState.Size = v end,
})

RadarSection:Slider({
    Name = "range", Flag = "radar_range",
    Min = 50, Max = 600, Default = 250, Decimals = 1, Suffix = " studs",
    Callback = function(v) RadarState.Range = v end,
})

local MoveSection = Misc:Section({ Name = "movement", Side = 2 })

MoveSection:Toggle({
    Name = "enabled", Flag = "move_enabled", Default = false,
    Callback = function(v)
        MovementState.Enabled = v
        if v then
            applyMovement()
        else
            resetMovement()
        end
    end,
})

MoveSection:Slider({
    Name = "walk speed", Flag = "move_walkspeed",
    Min = 8, Max = 100, Default = 16, Decimals = 1,
    Callback = function(v)
        MovementState.WalkSpeed = v
        applyMovement()
    end,
})

MoveSection:Slider({
    Name = "jump height", Flag = "move_jumpheight",
    Min = 1, Max = 100, Default = 7.2, Decimals = 0.1,
    Callback = function(v)
        MovementState.JumpHeight = v
        applyMovement()
    end,
})

----------------------------------------------------------------
-- VISUAL STUDIO: animated crosshair, target card, and presets
----------------------------------------------------------------
do
    local page = Window:Page({ Name = "studio" })
    local gui = mk("ScreenGui", guiParent, {
        Name = "VergilStudio", IgnoreGuiInset = true, ResetOnSpawn = false,
        DisplayOrder = 9996, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    -- Keep menu popups above all of the game's overlay widgets.
    for index, holder in ipairs({ Library.Holder, Library.PopupHolder, Library.DragHolder }) do
        holder.DisplayOrder = 10100 + index
    end

    local cross = mk("Frame", gui, {
        BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Visible = false,
    })
    local segments = {}
    for i = 1, 4 do
        segments[i] = mk("Frame", cross, { BorderSizePixel = 0, Visible = false })
        mk("UIStroke", segments[i], { Color = Color3.new(0, 0, 0), Thickness = 1, Transparency = 0.4 })
    end
    local dot = mk("Frame", cross, { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0 })
    mk("UICorner", dot, { CornerRadius = UDim.new(1, 0) })
    local ring = mk("Frame", cross, {
        AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Visible = false,
    })
    mk("UICorner", ring, { CornerRadius = UDim.new(1, 0) })
    local ringStroke = mk("UIStroke", ring, { Thickness = 2 })

    local card = mk("Frame", gui, {
        AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -90),
        Size = UDim2.fromOffset(280, 84), BackgroundColor3 = Color3.fromRGB(15, 16, 25),
        BackgroundTransparency = 0.12, BorderSizePixel = 0, Visible = false, Active = true,
    })
    mk("UICorner", card, { CornerRadius = UDim.new(0, 8) })
    local cardStroke = mk("UIStroke", card, { Thickness = 1, Transparency = 0.2 })
    local avatar = mk("ImageLabel", card, {
        Position = UDim2.fromOffset(10, 12), Size = UDim2.fromOffset(48, 48),
        BackgroundColor3 = Color3.fromRGB(27, 28, 42), BorderSizePixel = 0, Image = "",
    })
    mk("UICorner", avatar, { CornerRadius = UDim.new(0, 6) })
    local title = mk("TextLabel", card, {
        Position = UDim2.fromOffset(70, 10), Size = UDim2.fromOffset(200, 19),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 14,
        TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Text = "",
    })
    local details = mk("TextLabel", card, {
        Position = UDim2.fromOffset(70, 32), Size = UDim2.fromOffset(200, 17),
        BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 12,
        TextColor3 = Color3.fromRGB(200, 203, 218), TextXAlignment = Enum.TextXAlignment.Left, Text = "",
    })
    local healthBack = mk("Frame", card, {
        Position = UDim2.fromOffset(70, 59), Size = UDim2.fromOffset(198, 7),
        BackgroundColor3 = Color3.fromRGB(40, 42, 55), BorderSizePixel = 0,
    })
    local healthTrail = mk("Frame", healthBack, {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 185, 70), BorderSizePixel = 0,
    })
    local health = mk("Frame", healthBack, {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(100, 240, 150), BorderSizePixel = 0,
    })
    local thumbs, displayTarget, previousCharacter, trailFraction = {}, nil, nil, 1
    local lastTargetScan = -math.huge

    local function draggable(frame)
        local start, position
        Runtime:Connect(frame.InputBegan, "HUD drag start", function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                start, position = UserInputService:GetMouseLocation(), frame.Position
                Runtime.DraggingHUD = true
            end
        end)
        Runtime:Connect(UserInputService.InputChanged, "HUD drag", function(input)
            if not start or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
            local cam = getCamera()
            if not cam then return end
            local vp, size = cam.ViewportSize, frame.AbsoluteSize
            local delta = UserInputService:GetMouseLocation() - start
            local x = position.X.Scale * vp.X + position.X.Offset + delta.X
            local y = position.Y.Scale * vp.Y + position.Y.Offset + delta.Y
            local minX, minY = size.X * frame.AnchorPoint.X, size.Y * frame.AnchorPoint.Y
            frame.Position = UDim2.fromOffset(math.clamp(x, minX, math.max(minX, vp.X - size.X + minX)),
                math.clamp(y, minY, math.max(minY, vp.Y - size.Y + minY)))
        end)
        Runtime:Connect(UserInputService.InputEnded, "HUD drag end", function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 and start then
                start = nil
                Runtime.DraggingHUD = false
            end
        end)
        Runtime:Connect(UserInputService.WindowFocusReleased, "HUD drag cancel", function()
            start = nil
            Runtime.DraggingHUD = false
        end)
    end
    draggable(card)
    draggable(radarFrame)

    Studio.Palettes = {
        ["clean"] = { Color = Color3.fromRGB(235, 240, 255), Tint = Color3.new(1, 1, 1), Contrast = 0, Saturation = 0 },
        ["vergil violet"] = { Color = Color3.fromRGB(175, 155, 255), Tint = Color3.fromRGB(229, 219, 255), Contrast = 0.08, Saturation = 0.12 },
        ["cyberpunk"] = { Color = Color3.fromRGB(0, 235, 255), Tint = Color3.fromRGB(212, 232, 255), Contrast = 0.16, Saturation = 0.25 },
        ["sunset"] = { Color = Color3.fromRGB(255, 170, 95), Tint = Color3.fromRGB(255, 221, 192), Contrast = 0.06, Saturation = 0.1 },
    }
    local correction, bloom

    function Studio:UpdateEffects()
        if not self.PostFX then
            if correction then correction.Enabled = false end
            if bloom then bloom.Enabled = false end
            return
        end
        if not correction or not correction.Parent then
            correction = mk("ColorCorrectionEffect", Lighting, { Name = "VergilColorGrade", Enabled = false })
        end
        if not bloom or not bloom.Parent then
            bloom = mk("BloomEffect", Lighting, { Name = "VergilBloom", Enabled = false, Size = 24, Threshold = 1.2 })
        end
        local palette = self.Palettes[self.Palette] or self.Palettes.clean
        correction.TintColor = palette.Tint
        correction.Contrast, correction.Saturation = palette.Contrast, palette.Saturation
        correction.Enabled = true
        bloom.Intensity, bloom.Enabled = self.Bloom, self.Bloom > 0
    end

    function Studio:ApplyPreset(name)
        local palette = self.Palettes[name]
        if not palette then return false end
        local values = {
            studio_palette = name, studio_fx = name ~= "clean", studio_bloom = 0.25,
            cross_enabled = true, cross_color = palette.Color, cross_style = "cross",
            cross_rotate = name == "cyberpunk", cross_pulse = name == "vergil violet",
            studio_targethud = true, studio_rainbow = false,
            gun_color = palette.Color, arms_color = palette.Color,
            aim_color = palette.Color, aa_color = palette.Color,
            theme_Accent = palette.Color,
        }
        for flag, value in pairs(values) do
            local setter = Library.SetFlags[flag]
            if setter then setter(value) end
        end
        self:UpdateEffects()
        Runtime:Notify("Applied " .. name .. " preset")
        return true
    end

    function Studio:Step(dt)
        local cam = getCamera()
        cross.Visible = self.Crosshair.Enabled and cam ~= nil
        if cross.Visible then
            local state = self.Crosshair
            local center = state.FollowMouse and UserInputService:GetMouseLocation() or cam.ViewportSize / 2
            cross.Position = UDim2.fromOffset(center.X, center.Y)
            local gap = state.Gap
            if state.Pulse then gap = gap + (math.sin(os.clock() * 3) + 1) * 2 end
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if state.Dynamic and root then gap = gap + math.min(root.AssemblyLinearVelocity.Magnitude / 8, 8) end
            local selected = aimTarget or utility.target
            local color = self:Color(state.Color)
            if selected and selected.Parent and not Runtime.Paused then color = state.TargetColor end
            local angle = state.Rotate and os.clock() * math.rad(50) or 0
            for i, line in ipairs(segments) do
                line.Visible = state.Style == "cross" or (state.Style == "t-shape" and i ~= 4)
                if line.Visible then
                    local direction = Vector2.new(math.cos(angle + (i - 1) * math.pi / 2), math.sin(angle + (i - 1) * math.pi / 2))
                    setLine(line, direction * gap, direction * (gap + state.Length), state.Thickness, color)
                end
            end
            dot.Size = UDim2.fromOffset(state.Thickness + 1, state.Thickness + 1)
            dot.BackgroundColor3 = color
            ring.Visible = state.Style == "ring"
            if ring.Visible then
                ring.Size = UDim2.fromOffset((gap + state.Length) * 2, (gap + state.Length) * 2)
                ringStroke.Color, ringStroke.Thickness = color, state.Thickness
            end
        end

        if not self.TargetHUD or not cam then card.Visible = false; return end
        if os.clock() - lastTargetScan >= 0.1 then
            lastTargetScan = os.clock()
            displayTarget = aimTarget or utility.target or utility:GetClosestToMouse(cam, 180, true)
        end
        local char = displayTarget and displayTarget.Parent
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then card.Visible = false; return end
        card.Visible = true
        local player = Players:GetPlayerFromCharacter(char)
        local fraction = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
        if char ~= previousCharacter then trailFraction, previousCharacter = fraction, char end
        trailFraction = trailFraction + (fraction - trailFraction) * (1 - math.exp(-dt * 5))
        health.Size = UDim2.fromScale(fraction, 1)
        healthTrail.Size = UDim2.fromScale(math.max(fraction, trailFraction), 1)
        health.BackgroundColor3 = Color3.fromRGB(255, 80, 100):Lerp(Color3.fromRGB(100, 240, 150), fraction)
        local palette = self.Palettes[self.Palette] or self.Palettes.clean
        cardStroke.Color = self:Color(palette.Color)
        title.Text = player and (NameProtect.Enabled and npName(player) or player.DisplayName) or char.Name
        details.Text = string.format("%d / %d HP  |  %d studs", math.ceil(hum.Health), math.ceil(hum.MaxHealth),
            math.floor((displayTarget.Position - cam.CFrame.Position).Magnitude))
        if player and not NameProtect.Enabled then
            local id = player.UserId
            if thumbs[id] == nil then
                thumbs[id] = false
                Runtime:Spawn("target portrait", function()
                    local ok, image = pcall(Players.GetUserThumbnailAsync, Players, id,
                        Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
                    if ok and not Runtime.Unloaded then thumbs[id] = image end
                end)
            end
            avatar.Image = thumbs[id] or ""
        else
            avatar.Image = ""
        end
    end

    local crossSection = page:Section({ Name = "animated crosshair", Side = 1 })
    crossSection:Toggle({ Name = "enabled", Flag = "cross_enabled", Default = false,
        Callback = function(v) Studio.Crosshair.Enabled = v end })
    crossSection:Dropdown({ Name = "style", Flag = "cross_style", Items = { "cross", "t-shape", "dot", "ring" }, Default = "cross",
        Callback = function(v) Studio.Crosshair.Style = v end })
    for _, item in ipairs({
        { "spin", "cross_rotate", "Rotate", false }, { "pulse", "cross_pulse", "Pulse", false },
        { "movement expansion", "cross_dynamic", "Dynamic", true }, { "follow mouse", "cross_mouse", "FollowMouse", false },
    }) do
        crossSection:Toggle({ Name = item[1], Flag = item[2], Default = item[4],
            Callback = function(v) Studio.Crosshair[item[3]] = v end })
    end
    for _, item in ipairs({
        { "length", "cross_length", "Length", 2, 30, 9 }, { "gap", "cross_gap", "Gap", 0, 25, 5 },
        { "thickness", "cross_thickness", "Thickness", 1, 5, 2 },
    }) do
        crossSection:Slider({ Name = item[1], Flag = item[2], Min = item[4], Max = item[5], Default = item[6], Decimals = 1,
            Callback = function(v) Studio.Crosshair[item[3]] = v end })
    end
    crossSection:Label({ Name = "color" }):Colorpicker({ Name = "cross_color", Flag = "cross_color", Default = Studio.Crosshair.Color,
        Callback = function(v) Studio.Crosshair.Color = v end })
    crossSection:Label({ Name = "active target color" }):Colorpicker({ Name = "cross_targetcolor", Flag = "cross_targetcolor", Default = Studio.Crosshair.TargetColor,
        Callback = function(v) Studio.Crosshair.TargetColor = v end })

    local effects = page:Section({ Name = "visual presets", Side = 2 })
    effects:Dropdown({ Name = "palette", Flag = "studio_palette", Items = { "clean", "vergil violet", "cyberpunk", "sunset" }, Default = "vergil violet",
        Callback = function(v) Studio.Palette = v; Studio:UpdateEffects() end })
    effects:Button({ Name = "apply visual preset", Callback = function() Studio:ApplyPreset(Studio.Palette) end })
    effects:Toggle({ Name = "cinematic color + bloom", Flag = "studio_fx", Default = false,
        Callback = function(v) Studio.PostFX = v; Studio:UpdateEffects() end })
    effects:Slider({ Name = "bloom intensity", Flag = "studio_bloom", Min = 0, Max = 1, Default = 0.25, Decimals = 0.01,
        Callback = function(v) Studio.Bloom = v; Studio:UpdateEffects() end })
    effects:Toggle({ Name = "rainbow accents", Flag = "studio_rainbow", Default = false,
        Callback = function(v) Studio.Rainbow = v end })
    effects:Slider({ Name = "rainbow speed", Flag = "studio_rainbow_speed", Min = 0.02, Max = 0.5, Default = 0.12, Decimals = 0.01,
        Callback = function(v) Studio.RainbowSpeed = v end })

    local widgets = page:Section({ Name = "target card & widgets", Side = 2 })
    widgets:Toggle({ Name = "target info card", Flag = "studio_targethud", Default = false,
        Callback = function(v) Studio.TargetHUD = v end })
    widgets:Label({ Name = "Card tracks aim target / visible crosshair target" })
    widgets:Label({ Name = "Drag the target card or radar" })
    widgets:Button({ Name = "reset widget positions", Callback = function()
        card.Position = UDim2.new(0.5, 0, 1, -90)
        radarFrame.Position = UDim2.new(1, -20, 1, -20)
    end })

    table.insert(Runtime.Cleaners, function()
        Studio.Crosshair.Enabled, Studio.TargetHUD, Studio.PostFX = false, false, false
        if correction then correction:Destroy() end
        if bloom then bloom:Destroy() end
        gui:Destroy()
    end)
end

do
    local targeting = Combat:Section({ Name = "target selection", Side = 1 })
    local partDropdown = targeting:Dropdown({ Name = "aim parts", Flag = "target_parts", Multi = true,
        Items = TargetPartNames, Default = { "Head" },
        Callback = function(v)
            local parts, seen = {}, {}
            for _, name in ipairs(v) do
                if table.find(TargetPartNames, name) and not seen[name] then parts[#parts + 1] = name; seen[name] = true end
            end
            TargetingState.Parts = parts
            TargetingState.Part = parts[1]
            aimTarget, utility.target = nil, nil
        end })
    targeting:Label({ Name = "Uses the best selected part inside your FOV" })
    targeting:Label({ Name = "No selected parts = no aim target" })
    -- Older configs stored a single string. Migrate it without discarding new
    -- multi-select values when a config contains both forms.
    Library.SetFlags.target_part = function(value)
        if type(value) == "string" and table.find(TargetPartNames, value) then partDropdown:Set({ value }) end
    end
    local baseLoadConfig = Library.LoadConfig
    Library.LoadConfig = function(self, config)
        local ok, decoded = pcall(function() return game:GetService("HttpService"):JSONDecode(config) end)
        if ok and type(decoded) == "table" and decoded.target_parts ~= nil then
            decoded.target_part = nil
            config = game:GetService("HttpService"):JSONEncode(decoded)
        elseif ok and type(decoded) == "table" and type(decoded.target_part) == "string" then
            decoded.target_parts, decoded.target_part = { decoded.target_part }, nil
            config = game:GetService("HttpService"):JSONEncode(decoded)
        end
        return baseLoadConfig(self, config)
    end
    targeting:Dropdown({ Name = "priority", Flag = "target_priority", Items = { "crosshair", "distance", "health" }, Default = "crosshair",
        Callback = function(v) TargetingState.Priority = v end })
    targeting:Toggle({ Name = "include npcs", Flag = "target_npcs", Default = true,
        Callback = function(v) TargetingState.IncludeNPCs = v end })
    targeting:Slider({ Name = "max distance (0 = unlimited)", Flag = "target_distance", Min = 0, Max = 2000, Default = 0, Decimals = 1,
        Callback = function(v) TargetingState.MaxDistance = v end })
    EspSection:Slider({ Name = "max distance (0 = unlimited)", Flag = "esp_maxdistance", Min = 0, Max = 3000, Default = 0, Decimals = 1,
        Callback = function(v) EspState.MaxDistance = v end })

    local controls = Misc:Section({ Name = "session controls", Side = 1 })
    controls:Toggle({ Name = "pause combat", Flag = "combat_paused", Default = false,
        Callback = function(v)
            Runtime.Paused = v
            if v then
                aimTarget, utility.target, TriggerPress.Target = nil, nil, nil
                table.clear(heldInputs)
                releaseTrigger()
                if Runtime.StopAutoShoot then Runtime.StopAutoShoot() end
            end
        end })
    controls:Toggle({ Name = "performance mode (24 Hz ESP)", Flag = "performance_mode", Default = false,
        Callback = function(v)
            Runtime.VisualInterval, Runtime.ScanInterval = v and 1 / 24 or 1 / 60, v and 1 or 0.5
        end })
    controls:Dropdown({ Name = "unload key", Flag = "unload_key", Items = { "End", "Delete", "F10" }, Default = "End",
        Callback = function(v) Runtime.UnloadKey = v end })
    controls:Label({ Name = "F8 pauses / resumes combat" })
    controls:Button({ Name = "unload + cleanup", Callback = cleanup })
    Runtime:Connect(UserInputService.InputBegan, "session hotkeys", function(input, processed)
        if processed or UserInputService:GetFocusedTextBox() then return end
        if input.KeyCode.Name == Runtime.UnloadKey then cleanup()
        elseif input.KeyCode == Enum.KeyCode.F8 then
            Library.SetFlags.combat_paused(not Runtime.Paused)
            Runtime:Notify(Runtime.Paused and "Combat paused" or "Combat resumed")
        end
    end)
end

----------------------------------------------------------------
-- CAMERA AND AUTO-SHOOT CONTROLS
----------------------------------------------------------------
local ThirdPerson: any = { Enabled = false, Distance = 8, HideViewmodel = true, Hidden = {}, CameraBackups = {}, LastCharacter = nil }
local SpinBot: any = {Enabled = false, Speed = 360, Angle = 0}
local AutoShoot: any = { Enabled = false, Range = 500, IncludeNPCs = true, Interval = 0.08, Last = -math.huge,
    Target = nil, Controller = nil, Requests = 0, Status = "off" }

do
    local section = Misc:Section({ Name = "third person", Side = 1 })
    function ThirdPerson:Restore()
        for part, modifier in pairs(self.Hidden) do
            Runtime:Call("restore camera visibility", function() part.LocalTransparencyModifier = modifier end)
            self.Hidden[part] = nil
        end
        if self.PlayerBackup then
            LocalPlayer.CameraMode = self.PlayerBackup.Mode
            LocalPlayer.CameraMinZoomDistance = self.PlayerBackup.Min
            LocalPlayer.CameraMaxZoomDistance = self.PlayerBackup.Max
            self.PlayerBackup = nil
        end
        for camera, original in pairs(self.CameraBackups) do
            Runtime:Call("restore camera view", function()
                if camera.CFrame == original.Applied then camera.CFrame = original.CFrame end
            end)
            self.CameraBackups[camera] = nil
        end
        self.LastCharacter, self.LastCamera = nil, nil
    end
    function ThirdPerson:Step()
        if not self.Enabled then return end
        local camera, character = getCamera(), LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local head = character and character:FindFirstChild("Head")
        local vm = camera and camera:FindFirstChild("Viewmodel")
        -- STRAFE's gameplay camera may be Scriptable; the menu has no viewmodel.
        if not camera or not head or not humanoid or humanoid.Health <= 0 or not vm or not WeaponMods:GetController() then
            self:Restore()
            return
        end
        if (self.LastCharacter and self.LastCharacter ~= character) or (self.LastCamera and self.LastCamera ~= camera) then
            self:Restore()
        end
        self.LastCharacter, self.LastCamera = character, camera
        if not self.PlayerBackup then self.PlayerBackup = { Mode = LocalPlayer.CameraMode, Min = LocalPlayer.CameraMinZoomDistance, Max = LocalPlayer.CameraMaxZoomDistance } end
        LocalPlayer.CameraMode = Enum.CameraMode.Classic
        LocalPlayer.CameraMaxZoomDistance = math.max(LocalPlayer.CameraMaxZoomDistance, self.Distance)
        LocalPlayer.CameraMinZoomDistance = self.Distance
        local previous = self.CameraBackups[camera]
        local base = previous and camera.CFrame == previous.Applied and previous.CFrame or camera.CFrame
        local origin = head.Position
        local desired = origin - base.LookVector * self.Distance + Vector3.new(0, 1, 0)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = {character, camera}
        local hit = Workspace:Raycast(origin, desired - origin, params)
        if hit then desired = hit.Position + hit.Normal * 0.25 end
        local applied = CFrame.lookAt(desired, desired + base.LookVector, base.UpVector)
        self.CameraBackups[camera] = { CFrame = base, Applied = applied }
        camera.CFrame = applied
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") then
                if self.Hidden[part] == nil then self.Hidden[part] = part.LocalTransparencyModifier end
                part.LocalTransparencyModifier = 0
            end
        end
        if vm then
            for _, part in ipairs(vm:GetDescendants()) do
                if part:IsA("BasePart") then
                    if self.Hidden[part] == nil then self.Hidden[part] = part.LocalTransparencyModifier end
                    part.LocalTransparencyModifier = self.HideViewmodel and 1 or self.Hidden[part]
                end
            end
        end
        for part in pairs(self.Hidden) do
            if not part.Parent then self.Hidden[part] = nil end
        end
    end
    section:Toggle({ Name = "enabled", Flag = "third_person", Default = false,
        Callback = function(value) ThirdPerson.Enabled = value; if not value then ThirdPerson:Restore() end end })
    section:Slider({ Name = "camera distance", Flag = "third_person_distance", Min = 3, Max = 20, Default = 8, Decimals = 0.5,
        Callback = function(value) ThirdPerson.Distance = value end })
    section:Toggle({ Name = "hide first-person weapon", Flag = "third_person_hide_vm", Default = true,
        Callback = function(value) ThirdPerson.HideViewmodel = value end })
    table.insert(Runtime.Cleaners, function() ThirdPerson.Enabled = false; ThirdPerson:Restore() end)
end

do
    local section = Misc:Section({Name = "spin bot", Side = 2})
    function SpinBot:Restore()
        if self.Humanoid then
            Runtime:Call("restore spin rotation", function() self.Humanoid.AutoRotate = self.AutoRotate end)
        end
        if self.Root and self.Root.Parent and self.Applied and self.Root.CFrame.Rotation == self.Applied then
            Runtime:Call("restore spin facing", function() self.Root.CFrame = CFrame.new(self.Root.Position) * self.OriginalRotation end)
        end
        self.Humanoid, self.Root, self.Applied, self.OriginalRotation = nil, nil, nil, nil
    end
    function SpinBot:Step(dt)
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local camera = getCamera()
        if not self.Enabled or not combatActive() or not hum or hum.Health <= 0 or not root
            or not camera or not camera:FindFirstChild("Viewmodel") or not WeaponMods:GetController() then self:Restore();return end
        if self.Root ~= root then
            self:Restore()
            self.Root, self.Humanoid = root, hum
            self.AutoRotate, self.OriginalRotation = hum.AutoRotate, root.CFrame.Rotation
            self.Angle = math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
        end
        hum.AutoRotate = false
        self.Angle = (self.Angle + math.rad(math.clamp(self.Speed,60,1440)) * math.min(dt,0.1)) % (2 * math.pi)
        self.Applied = CFrame.Angles(0,self.Angle,0)
        root.CFrame = CFrame.new(root.Position) * self.Applied
    end
    section:Toggle({Name = "enabled", Flag = "spin_bot", Default = false, Callback = function(value)
        SpinBot.Enabled = value;if not value then SpinBot:Restore() end
    end})
    section:Slider({Name = "degrees per second", Flag = "spin_bot_speed", Min = 60, Max = 1440, Default = 360, Decimals = 30,
        Callback = function(value) SpinBot.Speed = value end})
    section:Label({Name = "Rotates your character; camera aim stays separate"})
    Runtime:Connect(LocalPlayer.CharacterAdded,"restore respawned spin bot",function() SpinBot:Restore() end)
    table.insert(Runtime.Cleaners,function() SpinBot.Enabled = false;SpinBot:Restore() end)
end

do
    local section = Combat:Section({ Name = "360 auto shoot", Side = 2 })
    function AutoShoot:Stop()
        local controller = self.Controller
        self.Controller, self.Target, utility.AutoTarget, utility.AutoController = nil, nil, nil, nil
        if controller and not controller.destroyed and type(controller.stopShooting) == "function" then
            Runtime:NativeCall("stop 360 auto shoot", controller.stopShooting, controller)
            if type(controller.cancelBurst) == "function" then Runtime:NativeCall("cancel 360 burst", controller.cancelBurst, controller) end
        end
    end
    Runtime.StopAutoShoot = function() AutoShoot:Stop() end
    function AutoShoot:GetTarget(controller)
        local camera = utility:GetCamera()
        if not camera then return nil end
        local best, closest = nil, math.huge
        local gun = controller and controller.currentGunModule
        local range = TargetingState.MaxDistance > 0 and math.min(self.Range, TargetingState.MaxDistance) or self.Range
        if gun and type(gun.range) == "number" then range = math.min(range, gun.range) end
        for _, character in ipairs(utility:getPlayers()) do
            if character == LocalPlayer.Character or not character.Parent or utility:isFriendlyCharacter(character) then continue end
            if not self.IncludeNPCs and isNpc(character) then continue end
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            if not humanoid or humanoid.Health <= 0 then continue end
            for _, part in ipairs(utility:GetTargetParts(character)) do
                local distance = (part.Position - camera.CFrame.Position).Magnitude
                -- No viewport, mouse-distance or camera-facing check: genuine 360 LOS.
                if distance <= range and distance < closest and utility:IsAutoTargetVisible(part) then best, closest = part, distance end
            end
        end
        return best
    end
    function AutoShoot:Step()
        if not self.Enabled or not combatActive() then
            self:Stop()
            self.Status = not self.Enabled and "off" or (combatReason() or "paused")
            return
        end
        local controller = WeaponMods:GetController()
        if controller then WeaponMods:Maintain(controller);utility:InstallController(controller) end
        local gun = controller and controller.currentGunModule
        local humanoid = localHumanoid()
        if not humanoid or humanoid.Health <= 0 or not controller or not controller.equipped or controller.destroyed
            or not gun or gun.gunType ~= "HITSCAN" or (controller.currentAmmo or 0) <= 0
            or (controller.reloadManager and controller.reloadManager:isReloading()) then
            self:Stop()
            self.Status = "waiting for a live weapon"
            return
        end
        if self.Controller and self.Controller ~= controller then self:Stop() end
        if os.clock() - self.Last >= self.Interval or not self.Target or not self.Target.Parent then
            self.Last = os.clock()
            self.Target = self:GetTarget(controller)
        end
        utility.AutoTarget = self.Target
        if not self.Target or not utility:IsAutoTargetVisible(self.Target) then self:Stop();self.Status = "no clear line of sight";return end
        self.Controller, utility.AutoController = controller, controller
        self.Status = "tracking " .. self.Target.Parent.Name
        local now = tick()
        if gun.fireMode == "AUTO" and controller.shooting then return end
        if gun.fireMode == "SEMI" and now - (controller.semiCooldown or 0) < (gun.rpm or 0.1) then return end
        if gun.fireMode == "BURST" and ((controller.burstShotsRemaining or 0) > 0
            or now - (controller.burstCooldown or 0) < (gun.burstDelay or 0.3)) then return end
        -- The current Handler.shoot argument is a config table, never a boolean.
        local ok = Runtime:NativeCall("360 native shoot", controller.shoot, controller, gun)
        if not ok then self:Stop(); return end
        self.Requests = self.Requests + 1
        if gun.fireMode == "SEMI" and type(controller.stopShooting) == "function" then
            Runtime:NativeCall("release 360 semi shot", controller.stopShooting, controller)
        end
    end
    section:Toggle({Name = "enabled", Flag = "auto_shoot_360", Default = false, Callback = function(value)
        AutoShoot.Enabled = value
        utility.AutoAimEnabled = value
        AutoShoot.Last = -math.huge
        if value and not utility.hooked then Runtime:Spawn("auto-shoot aim hook", function() utility:hook() end) end
        if not value then AutoShoot:Stop() end
    end})
    section:Slider({Name = "maximum distance", Flag = "auto_shoot_range", Min = 25, Max = 1500, Default = 500, Decimals = 1,
        Callback = function(value) AutoShoot.Range = value end})
    section:Toggle({Name = "include NPCs", Flag = "auto_shoot_npcs", Default = true, Callback = function(value) AutoShoot.IncludeNPCs = value end})
    section:Slider({Name = "scan/fire interval", Flag = "auto_shoot_interval", Min = 0.03, Max = 0.5, Default = 0.08, Decimals = 0.01,
        Callback = function(value) AutoShoot.Interval = value end})
    section:Label({Name = "360 degrees means line of sight in any direction"})
    section:Label({Name = "Targets need clear camera AND character line of sight"})
    section:Label({Name = "Manual silent-aim hit chance does not limit auto shoot"})
    local autoStatus = section:Label({Name = "off"})
    Runtime:Connect(RunService.Heartbeat, "auto-shoot status", function()
        if os.clock() - (AutoShoot.StatusAt or 0) >= 0.5 then
            AutoShoot.StatusAt = os.clock();autoStatus:SetText(AutoShoot.Status)
        end
    end)
    Runtime:Connect(UserInputService.WindowFocusReleased, "stop unfocused auto shoot", function() AutoShoot:Stop() end)
    Runtime:Connect(LocalPlayer.CharacterAdded, "stop respawned auto shoot", function() AutoShoot:Stop() end)
    table.insert(Runtime.Cleaners, function() AutoShoot.Enabled = false; utility.AutoAimEnabled = false; AutoShoot:Stop() end)
end

----------------------------------------------------------------
-- FINALIZE
----------------------------------------------------------------
Window:InitWindow()

Runtime:Spawn("initialize", function()
    utility:init()
end)

local function viewmodelStep(vm)
    local cam = getCamera()
    -- Render bindings pass dt; the API may pass a specific viewmodel instead.
    vm = typeof(vm) == "Instance" and vm or (cam and cam:FindFirstChild("Viewmodel"))
    local skinActive = SkinChanger:Step(vm)
    local gloveActive = SkinChanger.Gloves:Step(vm)
    if not vm then return end
    if not GunState.Enabled and not ArmsState.Enabled and not ArmsState.Hide and not next(ArmHideBackups) then return end

    if Runtime.Viewmodel ~= vm or os.clock() - (Runtime.ViewmodelScan or 0) >= 0.25 then
        Runtime.Viewmodel, Runtime.ViewmodelScan, Runtime.ViewmodelParts = vm, os.clock(), {}
        for _, obj in ipairs(vm:GetDescendants()) do
            if obj:IsA("BasePart") then table.insert(Runtime.ViewmodelParts, { obj, getGroup(obj, vm) }) end
        end
    end
    for _, entry in ipairs(Runtime.ViewmodelParts) do
        local obj, group = entry[1], entry[2]
        if obj.Parent then
            if group == "arms" then
                if ArmsState.Hide then
                    local bk = ArmHideBackups[obj]
                    if not bk then
                        bk = {
                            Transparency = obj.Transparency,
                            Modifier = obj.LocalTransparencyModifier,
                        }
                        ArmHideBackups[obj] = bk
                    end
                    if obj.Transparency < 1 then obj.Transparency = 1 end
                    if obj.LocalTransparencyModifier < 1 then obj.LocalTransparencyModifier = 1 end
                else
                    local bk = ArmHideBackups[obj]
                    if bk then
                        obj.Transparency = bk.Transparency
                        obj.LocalTransparencyModifier = bk.Modifier
                        ArmHideBackups[obj] = nil
                    end
                    if ArmsState.Enabled and not skinActive and not gloveActive then
                        applyStyle(obj, ArmsState.Material, Studio:Color(ArmsState.Color))
                    end
                end
            elseif group == "parts" then
                if GunState.Enabled and not skinActive then
                    applyStyle(obj, GunState.Material, Studio:Color(GunState.Color))
                end
            end
        end
    end
end

Runtime:Bind("VergilViewmodel", Enum.RenderPriority.Last.Value + 1, viewmodelStep)

Runtime:Bind("VergilWorld", Enum.RenderPriority.Camera.Value + 1, function()
    Runtime:Call("FOV lock", enforceFOV)
    if LightState.Enabled then Runtime:Call("lighting", applyLighting) end
    if AtmState.Enabled then Runtime:Call("atmosphere", applyAtmosphere) end
end)

Runtime:Bind("VergilAim", Enum.RenderPriority.Camera.Value + 2, function(dt)
    utility.target = utility:GetClosestPlayer()
    aimStep(dt)
end)

Runtime.VisualElapsed = 0
Runtime:Bind("VergilESP", Enum.RenderPriority.Last.Value + 3, function(dt)
    Runtime.VisualElapsed = Runtime.VisualElapsed + dt
    if Runtime.VisualElapsed >= Runtime.VisualInterval then
        Runtime.VisualElapsed = Runtime.VisualElapsed % Runtime.VisualInterval
        espStep()
    end
end)

Runtime:Bind("VergilRings", Enum.RenderPriority.Camera.Value + 4, function()
    Runtime:Call("FOV circles", ringStep)
    Runtime:Call("trigger", triggerStep)
end)

RunService:UnbindFromRenderStep("VergilDebug")
Runtime:Bind("VergilRadar", Enum.RenderPriority.Last.Value + 4, updateRadar)
Runtime:Bind("VergilThirdPerson", Enum.RenderPriority.Last.Value + 2, function() ThirdPerson:Step() end)
Runtime:Bind("VergilAutoShoot", Enum.RenderPriority.Last.Value + 5, function() AutoShoot:Step() end)
Runtime:Bind("VergilStudio", Enum.RenderPriority.Last.Value + 6, function(dt) Studio:Step(dt) end)
Runtime:Bind("VergilSpinBot", Enum.RenderPriority.Last.Value + 7, function(dt) SpinBot:Step(dt) end)

Library.Exit = function()
    cleanup()
end

Environment.VergilCleanup = cleanup
Environment.VergilAPI = {
        Cleanup = cleanup,
        Window = Window,
        Runtime = Runtime,
        Radar = RadarState,
        Movement = MovementState,
        FOV = FOVState,
        Lighting = LightState,
        Atmosphere = AtmState,
        NameProtect = NameProtect,
        SkinChanger = SkinChanger,
        Inventory = LocalInventory,
        Agents = LocalInventory.Agents,
        ThirdPerson = ThirdPerson,
        SpinBot = SpinBot,
        AutoShoot = AutoShoot,
        Knife = SkinChanger.Knife,
        Gloves = SkinChanger.Gloves,
        WeaponMods = WeaponMods,
        Studio = Studio,
        Targeting = TargetingState,
        Utility = utility,
        CombatReason = combatReason,
        AimAssist = AimAssistState,
        Trigger = TriggerState,
        Esp = EspState,
        Chams = ChamsState,
        UpdateRadar = updateRadar,
        UpdateViewmodel = viewmodelStep,
        ComputeBounds = computeBounds,
        UpdateEsp = espStep,
        GetEspRecord = function(char) return EspCache[char] end,
        SetFlag = function(flag, value)
            assert(not Runtime.Unloaded, "Vergil is unloaded")
            local setter = Library.SetFlags[flag]
            assert(setter, "Unknown Vergil flag: " .. tostring(flag))
            setter(value)
        end,
}
