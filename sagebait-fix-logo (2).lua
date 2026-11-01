local function bootstrapCompatibility()
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local fenv = getfenv(1)
    local missing = {}

    local function grab(name)
        for _, source in ipairs({ fenv, genv, _G }) do
            local found, value = pcall(function()
                return source[name]
            end)
            if found and type(value) == "function" then
                return value
            end
        end
        return nil
    end

    local function grabTable(name)
        local found, value = pcall(function()
            return fenv[name] or genv[name]
        end)
        if found and type(value) == "table" then
            return value
        end
        return nil
    end

    local function publish(name, value)
        if not value then
            table.insert(missing, name)
            return
        end
        pcall(function()
            genv[name] = value
        end)
        pcall(function()
            fenv[name] = value
        end)
    end

    local connectionsOf = grab("getconnections") or grab("get_signal_cons")
    publish("getconnections", connectionsOf)
    local writeable = grab("make_writeable")
    local readonly = grab("make_readonly")
    local debugMeta = debug and debug.getmetatable

    publish("getrawmetatable", grab("getrawmetatable") or grab("get_raw_metatable") or debugMeta)

    publish("setreadonly", grab("setreadonly") or grab("set_readonly") or (writeable and readonly and function(target, state)
        if state then
            readonly(target)
        else
            writeable(target)
        end
    end))

    publish("getnamecallmethod", grab("getnamecallmethod") or grab("get_namecall_method"))

    local setIdentity = grab("setthreadidentity") or grab("set_thread_identity")
    local readIdentity = grab("getthreadidentity") or grab("get_thread_identity")

    if setIdentity then
        publish("setthreadidentity", setIdentity)
    end
    if readIdentity then
        publish("getthreadidentity", readIdentity)
    end

    local native = grab("firesignal") or grab("fire_signal")
    local viaConnections = connectionsOf and function(signal, ...)
        for _, connection in ipairs(connectionsOf(signal)) do
            pcall(connection.Fire, connection, ...)
        end
    end

    if native and viaConnections then
        local probe = Instance.new("BindableEvent")
        local landed = false
        probe.Event:Connect(function()
            landed = true
        end)
        pcall(native, probe.Event, true)
        task.wait(0.1)
        probe:Destroy()
        if not landed then
            native = nil
        end
    end

    local fire = native or viaConnections
    publish("firesignal", fire and function(signal, ...)
        if not setIdentity then
            return fire(signal, ...)
        end
        local restore = readIdentity and readIdentity()
        pcall(setIdentity, 2)
        pcall(fire, signal, ...)
        if restore then
            pcall(setIdentity, restore)
        end
    end)

    publish("loadstring", grab("loadstring") or grab("load"))

    local send = grab("request") or grab("http_request")
    if not send then
        local syntax = grabTable("syn") or grabTable("http") or grabTable("fluxus")
        send = syntax and syntax.request
    end

    publish("httpGet", function(url)
        local reached, body = pcall(function()
            return game:HttpGet(url)
        end)
        if reached and type(body) == "string" and #body > 0 then
            return body
        end
        if send then
            local sent, response = pcall(send, { Url = url, Method = "GET" })
            if sent and type(response) == "table" and type(response.Body) == "string" then
                return response.Body
            end
        end
        error("TWINHUB: no working HTTP method for " .. tostring(url), 0)
    end)

    local hidden = grab("gethui") or grab("get_hidden_gui")
    local guard = grab("protect_gui")
    if not guard then
        local syntax = grabTable("syn")
        guard = syntax and syntax.protect_gui
    end
    publish("hidegui", function(gui)
        if guard then pcall(guard, gui) end
        if hidden then
            local reached, container = pcall(hidden)
            if reached and typeof(container) == "Instance" then
                gui.Parent = container
                return
            end
        end
        local pulled, core = pcall(game.GetService, game, "CoreGui")
        if pulled and core then
            local placed = pcall(function() gui.Parent = core end)
            if placed then return end
        end
        gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end)

    if #missing > 0 then
        warn("TWINHUB: this executor has no " .. table.concat(missing, ", ") .. " - features that need them stay off")
    end
end

bootstrapCompatibility()

local hookNamecall

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local prior = rawget(genv, "TWINHUB_SESSION") or genv.TWINHUB_SESSION
    local carried = type(prior) == "table" and prior.vault or nil
    if type(prior) == "table" and type(prior.unload) == "function" then
        pcall(prior.unload)
    end
    local session = {}
    session.vault = carried

    -- Central __namecall registry: one real hook on the metatable, any number of
    -- named handlers stacked on top of it. Newest handler runs first (same order
    -- the old per-feature hooks had), unload walks the stack LIFO.
    local hub = { stack = {}, byId = {}, installed = false, dead = false }
    local dispatch

    dispatch = function(level, self, method, ...)
        while level > 0 do
            local entry = hub.stack[level]
            if entry and entry.alive then
                return entry.callback(entry.below, self, method, ...)
            end
            level = level - 1
        end
        return hub.original(self, ...)
    end

    local function central(self, ...)
        return dispatch(#hub.stack, self, getnamecallmethod(), ...)
    end

    local function writeNamecall(meta, value)
        pcall(setreadonly, meta, false)
        local written = pcall(function()
            meta.__namecall = value
        end)
        pcall(setreadonly, meta, true)
        return written
    end

    -- callback(callNext, self, method, ...): call callNext(self, method, ...) to continue the chain.
    -- Registering the same id again only swaps the callback, it never stacks a second hook.
    -- Returns a release function (or nil when the executor can't hook).
    hookNamecall = function(id, callback, onUnload)
        if hub.dead then return nil end
        if type(id) ~= "string" or type(callback) ~= "function" then return nil end

        local current = hub.byId[id]
        if current and current.alive then
            current.callback = callback
            current.onUnload = onUnload or current.onUnload
            return current.release
        end

        if not (getrawmetatable and setreadonly and getnamecallmethod) then return nil end

        if not hub.installed then
            local meta = getrawmetatable(game)
            if not meta then return nil end
            local live = meta.__namecall
            if live ~= central then
                hub.original = live
                if not writeNamecall(meta, central) then return nil end
            end
            hub.mt = meta
            hub.installed = true
        end

        local entry = {
            id = id,
            callback = callback,
            onUnload = onUnload,
            alive = true,
            index = #hub.stack + 1,
        }
        entry.below = function(self, method, ...)
            return dispatch(entry.index - 1, self, method, ...)
        end
        entry.release = function()
            if not entry.alive then return end
            entry.alive = false
            if hub.byId[id] == entry then
                hub.byId[id] = nil
            end
            if type(entry.onUnload) == "function" then
                pcall(entry.onUnload)
            end
            while #hub.stack > 0 and not hub.stack[#hub.stack].alive do
                hub.stack[#hub.stack] = nil
            end
        end

        hub.stack[entry.index] = entry
        hub.byId[id] = entry
        return entry.release
    end

    -- LIFO teardown: last handler installed is the first one released, then the
    -- original metamethod goes back. If another script wrapped us in the meantime
    -- we leave the central hook in place as a pure pass-through instead of cutting
    -- their wrapper out of the chain.
    session.unhook = function()
        hub.dead = true
        for level = #hub.stack, 1, -1 do
            local entry = hub.stack[level]
            hub.stack[level] = nil
            if entry then
                entry.alive = false
                hub.byId[entry.id] = nil
                if type(entry.onUnload) == "function" then
                    pcall(entry.onUnload)
                end
            end
        end
        if hub.installed and hub.mt and rawget(hub.mt, "__namecall") == central then
            writeNamecall(hub.mt, hub.original)
        end
        hub.installed = false
    end
    session.unload = function()
        if session.vault and session.vault.inventory then
            pcall(function()
                local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
                local inventory = Knit.GetController("InventoryController")
                if inventory and inventory.Inventory then
                    inventory.Inventory:set(session.vault.inventory)
                end
            end)
        end
        if session.ui and session.ui.Unload then
            pcall(function()
                session.ui:Unload()
            end)
        end
        for _, link in ipairs(session.links or {}) do
            pcall(function()
                link:Disconnect()
            end)
        end
        pcall(function()
            local tagged = {}
            for _, name in ipairs(session.tags or {}) do
                tagged[name] = true
            end
            if not next(tagged) then return end
            local holders = {}
            if type(gethui) == "function" then
                local reached, container = pcall(gethui)
                if reached and container then table.insert(holders, container) end
            end
            table.insert(holders, game:GetService("CoreGui"))
            if workspace.CurrentCamera then
                table.insert(holders, workspace.CurrentCamera)
            end
            local players = game:GetService("Players")
            if players.LocalPlayer then
                local pg = players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
                if pg then table.insert(holders, pg) end
            end
            for _, holder in ipairs(holders) do
                for _, child in ipairs(holder:GetChildren()) do
                    if tagged[child.Name] then
                        child:Destroy()
                    end
                end
            end
            for _, model in ipairs(workspace:GetChildren()) do
                if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
                    for _, child in ipairs(model:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
            end
            for _, other in ipairs(players:GetPlayers()) do
                if other.Character then
                    for _, child in ipairs(other.Character:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
            end
        end)
        pcall(session.unhook)
    end
    session.links = {}
    session.tags = {}
    genv.TWINHUB_SESSION = session
end

local Library = (function()
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local TweenService = game:GetService("TweenService")
    local GuiService = game:GetService("GuiService")
    local HttpService = game:GetService("HttpService")
    local LocalPlayer = Players.LocalPlayer

    local Theme = {
        Accent = Color3.fromRGB(219, 219, 219),
        AccentSoft = Color3.fromRGB(75, 75, 75),
        Shell = Color3.fromRGB(19, 19, 19),
        ShellTop = Color3.fromRGB(19, 19, 19),
        Panel = Color3.fromRGB(16, 16, 16),
        Raised = Color3.fromRGB(32, 32, 32),
        Sunken = Color3.fromRGB(11, 11, 11),
        Line = Color3.fromRGB(60, 60, 60),
        LineSoft = Color3.fromRGB(38, 38, 38),
        Text = Color3.fromRGB(236, 236, 236),
        SubText = Color3.fromRGB(150, 150, 150),
        Faint = Color3.fromRGB(88, 88, 88),
    }

    local PILL = UDim.new(1, 0)
    local EASE = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

    local Lib = {
        Options = {},
        Toggles = {},
        Theme = Theme,
        CornerRadius = 14,
        ForceCheckbox = false,
        ShowToggleFrameInKeybinds = true,
        NotifySide = "Right",
        Unloaded = false,
        ToggleKeybind = nil,
        DefaultToggleKey = "RightShift",
    }

    local conns = {}
    local panels = {}
    local pickers = {}
    local pages = {}
    local configFolder = "TWINHUB"

    local function new(class, props, parent)
        local inst = Instance.new(class)
        for key, value in pairs(props) do
            inst[key] = value
        end
        if parent then
            inst.Parent = parent
        end
        return inst
    end

    local function round(inst, radius, tracked)
        local corner = new("UICorner", { CornerRadius = radius }, inst)
        if tracked then
            table.insert(panels, corner)
        end
        return corner
    end

    local function outline(inst, color, thickness, transparency)
        return new("UIStroke", {
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            LineJoinMode = Enum.LineJoinMode.Round,
            Color = color or Theme.Line,
            Thickness = thickness or 1,
            Transparency = transparency or 0,
        }, inst)
    end

    local function pad(inst, left, right, top, bottom)
        return new("UIPadding", {
            PaddingLeft = UDim.new(0, left or 0),
            PaddingRight = UDim.new(0, right or 0),
            PaddingTop = UDim.new(0, top or 0),
            PaddingBottom = UDim.new(0, bottom or 0),
        }, inst)
    end

    local function stack(inst, gap, dir)
        return new("UIListLayout", {
            FillDirection = dir or Enum.FillDirection.Vertical,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, gap or 0),
        }, inst)
    end

    local function glide(inst, props, speed)
        local anim = TweenService:Create(inst, speed and TweenInfo.new(speed, Enum.EasingStyle.Quart, Enum.EasingDirection.Out) or EASE, props)
        anim:Play()
        return anim
    end

    local function bind(signal, fn)
        local link = signal:Connect(fn)
        table.insert(conns, link)
        return link
    end

    local function tag()
        return string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
    end

    local Root = new("ScreenGui", {
        Name = tag(),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        AutoLocalize = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    })

    do
        local placed = false
        if type(hidegui) == "function" then
            placed = pcall(hidegui, Root)
        end
        if not placed or not Root.Parent then
            Root.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end
        pcall(function()
            UserInputService.MouseIconEnabled = true
        end)
    end

    local TipCard = new("Frame", {
        BackgroundColor3 = Theme.Raised,
        BorderSizePixel = 0,
        AutomaticSize = Enum.AutomaticSize.XY,
        Size = UDim2.fromOffset(0, 0),
        Visible = false,
        ZIndex = 190,
    }, Root)
    round(TipCard, UDim.new(0, 6))
    outline(TipCard, Theme.Accent, 1, 0.6)
    pad(TipCard, 10, 10, 6, 6)

    local TipText = new("TextLabel", {
        BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.XY,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "",
        ZIndex = 191,
    }, TipCard)

    local NotifyHolder = new("Frame", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -18, 0, 18),
        Size = UDim2.fromOffset(300, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ZIndex = 180,
    }, Root)
    stack(NotifyHolder, 8)

    local KeybindFrame = new("Frame", {
        Position = UDim2.fromOffset(24, 120),
        Size = UDim2.fromOffset(190, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 60,
    }, Root)
    round(KeybindFrame, UDim.new(0, Lib.CornerRadius), true)
    outline(KeybindFrame, Theme.LineSoft, 1)
    pad(KeybindFrame, 14, 14, 12, 14)
    stack(KeybindFrame, 8)

    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Theme.Accent,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Keybinds",
        LayoutOrder = 0,
        ZIndex = 61,
    }, KeybindFrame)

    local KeybindList = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        ZIndex = 61,
    }, KeybindFrame)
    stack(KeybindList, 4)

    Lib.KeybindFrame = KeybindFrame
    Lib.Root = Root

    local function pointer()
        return UserInputService:GetMouseLocation() + Vector2.new(0, GuiService:GetGuiInset().Y)
    end

    local function attachTip(frame, text)
        if not text or text == "" then
            return
        end
        bind(frame.MouseEnter, function()
            TipText.Text = text
            local at = pointer()
            TipCard.Position = UDim2.fromOffset(at.X + 16, at.Y + 18)
            TipCard.Visible = true
        end)
        bind(frame.MouseMoved, function()
            if TipCard.Visible then
                local at = pointer()
                TipCard.Position = UDim2.fromOffset(at.X + 16, at.Y + 18)
            end
        end)
        bind(frame.MouseLeave, function()
            TipCard.Visible = false
        end)
    end

    function Lib:Notify(payload, seconds)
        local text = payload
        if type(payload) == "table" then
            text = payload.Description or payload.Title or payload.Text or ""
            seconds = seconds or payload.Time
        end

        local card = new("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            BackgroundTransparency = 1,
            ZIndex = 181,
        }, NotifyHolder)
        round(card, UDim.new(0, 8))
        local edge = outline(card, Theme.Line, 1, 1)
        pad(card, 16, 12, 10, 10)

        local bar = new("Frame", {
            Position = UDim2.fromOffset(-9, 12),
            Size = UDim2.fromOffset(3, 16),
            BackgroundColor3 = Theme.Accent,
            BorderSizePixel = 0,
            BackgroundTransparency = 1,
            ZIndex = 182,
        }, card)
        round(bar, PILL)

        local body = new("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 13,
            TextColor3 = Theme.Text,
            TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            Text = tostring(text),
            ZIndex = 182,
        }, card)

        glide(card, { BackgroundTransparency = 0 })
        glide(edge, { Transparency = 0 })
        glide(bar, { BackgroundTransparency = 0 })
        glide(body, { TextTransparency = 0 })

        task.delay(seconds or 4, function()
            if not card.Parent then
                return
            end
            glide(card, { BackgroundTransparency = 1 })
            glide(edge, { Transparency = 1 })
            glide(bar, { BackgroundTransparency = 1 })
            glide(body, { TextTransparency = 1 })
            task.wait(0.24)
            card:Destroy()
        end)
    end

    function Lib:SetNotifySide(side)
        Lib.NotifySide = side
        if side == "Left" then
            NotifyHolder.AnchorPoint = Vector2.new(0, 0)
            NotifyHolder.Position = UDim2.new(0, 18, 0, 18)
        else
            NotifyHolder.AnchorPoint = Vector2.new(1, 0)
            NotifyHolder.Position = UDim2.new(1, -18, 0, 18)
        end
    end

    local function refreshKeybindList()
        for _, child in ipairs(KeybindList:GetChildren()) do
            if child:IsA("Frame") then
                child:Destroy()
            end
        end
        local order = 0
        for _, picker in ipairs(pickers) do
            if not picker.NoUI and picker.Value and picker.Value ~= "" then
                order = order + 1
                local row = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 20),
                    BackgroundTransparency = 1,
                    LayoutOrder = order,
                    ZIndex = 62,
                }, KeybindList)
                new("TextLabel", {
                    Size = UDim2.new(1, -54, 1, 0),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamMedium,
                    TextSize = 12,
                    TextColor3 = Theme.SubText,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = picker.Label,
                    ZIndex = 62,
                }, row)
                local chip = new("Frame", {
                    AnchorPoint = Vector2.new(1, 0.5),
                    Position = UDim2.new(1, 0, 0.5, 0),
                    Size = UDim2.fromOffset(52, 18),
                    BackgroundColor3 = Theme.Sunken,
                    BorderSizePixel = 0,
                    ZIndex = 62,
                }, row)
                round(chip, UDim.new(0, 5))
                outline(chip, Theme.Line, 1)
                new("TextLabel", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamBold,
                    TextSize = 10,
                    TextColor3 = Theme.Accent,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = picker.Value,
                    ZIndex = 63,
                }, chip)
            end
        end
    end

    local function dragify(handle, target)
        local holding, origin, base = false, nil, nil
        bind(handle.InputBegan, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                holding = true
                origin = input.Position
                base = target.Position
            end
        end)
        bind(handle.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                holding = false
            end
        end)
        bind(UserInputService.InputChanged, function(input)
            if not holding then
                return
            end
            if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                local shift = input.Position - origin
                target.Position = UDim2.new(base.X.Scale, base.X.Offset + shift.X, base.Y.Scale, base.Y.Offset + shift.Y)
            end
        end)
    end

    dragify(KeybindFrame, KeybindFrame)

    local function makeGroup(holder)
        local Group = { Holder = holder, Order = 0 }

        local function slot(height, auto)
            Group.Order = Group.Order + 1
            local frame = new("Frame", {
                Size = UDim2.new(1, 0, 0, height or 0),
                BackgroundTransparency = 1,
                LayoutOrder = Group.Order,
            }, holder)
            if auto then
                frame.AutomaticSize = Enum.AutomaticSize.Y
            end
            return frame
        end

        local function caption(parent, text)
            return new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 14),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = text,
                LayoutOrder = 0,
            }, parent)
        end

        function Group:AddToggle(index, opts)
            opts = opts or {}
            local row = slot(30)

            local label = new("TextLabel", {
                Size = UDim2.new(1, -60, 1, 0),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = opts.Text or index,
            }, row)

            local box = Lib.ForceCheckbox
            local track = new("Frame", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 0, 0.5, 0),
                Size = box and UDim2.fromOffset(16, 16) or UDim2.fromOffset(38, 20),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
            }, row)
            round(track, box and UDim.new(0, 4) or PILL)
            local edge = outline(track, Theme.Line, 1)

            local knob = new("Frame", {
                Position = box and UDim2.fromOffset(4, 4) or UDim2.fromOffset(3, 3),
                Size = box and UDim2.fromOffset(8, 8) or UDim2.fromOffset(14, 14),
                BackgroundColor3 = Theme.Faint,
                BorderSizePixel = 0,
            }, track)
            round(knob, box and UDim.new(0, 2) or PILL)

            local hit = new("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
            }, row)
            attachTip(hit, opts.Tooltip)

            local Toggle = { Value = false, Type = "Toggle", Index = index, Callbacks = {} }

            local function paint()
                if Toggle.Value then
                    glide(track, { BackgroundColor3 = Theme.AccentSoft })
                    glide(edge, { Color = Theme.Accent })
                    glide(knob, { BackgroundColor3 = Theme.Accent })
                    glide(label, { TextColor3 = Theme.Text })
                    if not box then
                        glide(knob, { Position = UDim2.fromOffset(21, 3) })
                    end
                else
                    glide(track, { BackgroundColor3 = Theme.Sunken })
                    glide(edge, { Color = Theme.Line })
                    glide(knob, { BackgroundColor3 = Theme.Faint })
                    glide(label, { TextColor3 = Theme.SubText })
                    if not box then
                        glide(knob, { Position = UDim2.fromOffset(3, 3) })
                    end
                end
            end

            function Toggle:SetValue(value, silent)
                Toggle.Value = value and true or false
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, Toggle.Value)
                end
                for _, fn in ipairs(Toggle.Callbacks) do
                    task.spawn(fn, Toggle.Value)
                end
            end

            function Toggle:OnChanged(fn)
                table.insert(Toggle.Callbacks, fn)
                task.spawn(fn, Toggle.Value)
                return Toggle
            end

            bind(hit.MouseButton1Click, function()
                Toggle:SetValue(not Toggle.Value)
            end)

            Toggle:SetValue(opts.Default and true or false, true)
            if opts.Default then
                if opts.Callback then
                    task.spawn(opts.Callback, true)
                end
            end

            Lib.Toggles[index] = Toggle
            return Toggle
        end

        function Group:AddSlider(index, opts)
            opts = opts or {}
            local wrap = slot(44)
            attachTip(wrap, opts.Tooltip)

            local label = new("TextLabel", {
                Size = UDim2.new(1, -70, 0, 16),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = opts.Text or index,
            }, wrap)

            local readout = new("TextLabel", {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, 0, 0, 0),
                Size = UDim2.fromOffset(70, 16),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = Theme.Accent,
                TextXAlignment = Enum.TextXAlignment.Right,
                Text = "0",
            }, wrap)

            local track = new("Frame", {
                Position = UDim2.new(0, 0, 0, 26),
                Size = UDim2.new(1, 0, 0, 4),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
            }, wrap)
            round(track, PILL)

            local fill = new("Frame", {
                Size = UDim2.new(0, 0, 1, 0),
                BackgroundColor3 = Theme.Accent,
                BorderSizePixel = 0,
            }, track)
            round(fill, PILL)

            local knob = new("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.fromOffset(12, 12),
                BackgroundColor3 = Theme.Text,
                BorderSizePixel = 0,
                ZIndex = 3,
            }, track)
            round(knob, PILL)

            local minimum = opts.Min or 0
            local maximum = opts.Max or 100
            local digits = opts.Rounding or 0
            local step = 10 ^ digits

            local Slider = { Value = opts.Default or minimum, Type = "Slider", Index = index, Min = minimum, Max = maximum, Callbacks = {} }

            local function paint()
                local span = maximum - minimum
                local ratio = span > 0 and math.clamp((Slider.Value - minimum) / span, 0, 1) or 0
                fill.Size = UDim2.new(ratio, 0, 1, 0)
                knob.Position = UDim2.new(ratio, 0, 0.5, 0)
                readout.Text = tostring(Slider.Value) .. (opts.Suffix or "")
            end

            function Slider:SetValue(value, silent)
                value = tonumber(value) or minimum
                value = math.clamp(value, minimum, maximum)
                value = math.floor(value * step + 0.5) / step
                Slider.Value = value
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Slider.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Slider:OnChanged(fn)
                table.insert(Slider.Callbacks, fn)
                task.spawn(fn, Slider.Value)
                return Slider
            end

            local sliding = false

            local function seek(x)
                local width = track.AbsoluteSize.X
                if width <= 0 then
                    return
                end
                local ratio = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
                Slider:SetValue(minimum + (maximum - minimum) * ratio)
            end

            bind(track.InputBegan, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    sliding = true
                    glide(knob, { Size = UDim2.fromOffset(16, 16) })
                    seek(input.Position.X)
                end
            end)
            bind(UserInputService.InputEnded, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    if sliding then
                        sliding = false
                        glide(knob, { Size = UDim2.fromOffset(12, 12) })
                    end
                end
            end)
            bind(UserInputService.InputChanged, function(input)
                if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                    seek(input.Position.X)
                end
            end)

            Slider:SetValue(opts.Default or minimum, true)
            if opts.Default ~= nil and opts.Callback then
                task.spawn(opts.Callback, Slider.Value)
            end

            Lib.Options[index] = Slider
            return Slider
        end

        function Group:AddDropdown(index, opts)
            opts = opts or {}
            local wrap = slot(0, true)
            stack(wrap, 6)
            attachTip(wrap, opts.Tooltip)

            caption(wrap, opts.Text or index)

            local button = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 32),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamMedium,
                TextSize = 13,
                TextColor3 = Theme.Text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = 1,
            }, wrap)
            round(button, UDim.new(0, 8))
            local edge = outline(button, Theme.Line, 1)
            pad(button, 12, 30, 0, 0)

            local arrow = new("TextLabel", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, -12, 0.5, 0),
                Size = UDim2.fromOffset(12, 12),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamBold,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                Text = ">",
                Rotation = 90,
            }, button)

            local panel = new("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Visible = false,
                LayoutOrder = 2,
                ClipsDescendants = true,
            }, wrap)
            round(panel, UDim.new(0, 8))
            outline(panel, Theme.Line, 1)

            local scroll = new("ScrollingFrame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, panel)
            stack(scroll, 2)
            pad(scroll, 4, 6, 4, 4)

            local Dropdown = { Value = nil, Type = "Dropdown", Index = index, Values = opts.Values or {}, Callbacks = {}, Open = false }
            local rows = {}

            local function paint()
                button.Text = tostring(Dropdown.Value or "--")
                for value, row in pairs(rows) do
                    if value == Dropdown.Value then
                        glide(row.Frame, { BackgroundColor3 = Theme.AccentSoft })
                        glide(row.Edge, { Transparency = 0, Color = Theme.Accent })
                        glide(row.Label, { TextColor3 = Theme.Text })
                    else
                        glide(row.Frame, { BackgroundColor3 = Theme.Raised })
                        glide(row.Edge, { Transparency = 1, Color = Theme.Line })
                        glide(row.Label, { TextColor3 = Theme.SubText })
                    end
                end
            end

            function Dropdown:SetValue(value, silent)
                Dropdown.Value = value
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Dropdown.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Dropdown:OnChanged(fn)
                table.insert(Dropdown.Callbacks, fn)
                task.spawn(fn, Dropdown.Value)
                return Dropdown
            end

            local function collapse()
                Dropdown.Open = false
                panel.Visible = false
                panel.Size = UDim2.new(1, 0, 0, 0)
                glide(arrow, { Rotation = 90 })
                glide(edge, { Color = Theme.Line })
            end

            function Dropdown:SetValues(values)
                Dropdown.Values = values or {}
                rows = {}
                for _, child in ipairs(scroll:GetChildren()) do
                    if child:IsA("TextButton") then
                        child:Destroy()
                    end
                end
                for order, value in ipairs(Dropdown.Values) do
                    local entry = new("TextButton", {
                        Size = UDim2.new(1, 0, 0, 26),
                        BackgroundColor3 = Theme.Raised,
                        BorderSizePixel = 0,
                        Font = Enum.Font.GothamMedium,
                        TextSize = 13,
                        TextColor3 = Theme.SubText,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Text = "",
                        AutoButtonColor = false,
                        LayoutOrder = order,
                    }, scroll)
                    round(entry, UDim.new(0, 6))
                    local entryEdge = outline(entry, Theme.Line, 1, 1)
                    local entryLabel = new("TextLabel", {
                        Size = UDim2.new(1, -24, 1, 0),
                        Position = UDim2.fromOffset(12, 0),
                        BackgroundTransparency = 1,
                        Font = Enum.Font.GothamMedium,
                        TextSize = 13,
                        TextColor3 = Theme.SubText,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Text = tostring(value),
                    }, entry)
                    rows[value] = { Frame = entry, Edge = entryEdge, Label = entryLabel }
                    bind(entry.MouseButton1Click, function()
                        Dropdown:SetValue(value)
                        collapse()
                    end)
                end
                paint()
            end

            bind(button.MouseButton1Click, function()
                Dropdown.Open = not Dropdown.Open
                if Dropdown.Open then
                    local height = math.clamp(#Dropdown.Values * 28 + 8, 36, 176)
                    panel.Visible = true
                    panel.Size = UDim2.new(1, 0, 0, 0)
                    glide(panel, { Size = UDim2.new(1, 0, 0, height) })
                    glide(arrow, { Rotation = 270 })
                    glide(edge, { Color = Theme.Accent })
                else
                    collapse()
                end
            end)

            Dropdown:SetValues(opts.Values or {})
            Dropdown:SetValue(opts.Default, true)
            if opts.Default ~= nil and opts.Callback then
                task.spawn(opts.Callback, opts.Default)
            end

            Lib.Options[index] = Dropdown
            return Dropdown
        end

        function Group:AddInput(index, opts)
            opts = opts or {}
            local wrap = slot(0, true)
            stack(wrap, 6)
            attachTip(wrap, opts.Tooltip)

            caption(wrap, opts.Text or index)

            local field = new("TextBox", {
                Size = UDim2.new(1, 0, 0, 32),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamMedium,
                TextSize = 13,
                TextColor3 = Theme.Text,
                PlaceholderColor3 = Theme.Faint,
                PlaceholderText = opts.Placeholder or "",
                TextXAlignment = Enum.TextXAlignment.Left,
                ClearTextOnFocus = false,
                Text = opts.Default or "",
                LayoutOrder = 1,
            }, wrap)
            round(field, UDim.new(0, 8))
            local edge = outline(field, Theme.Line, 1)
            pad(field, 12, 12, 0, 0)

            local Input = { Value = opts.Default or "", Type = "Input", Index = index, Callbacks = {} }

            local function push(value)
                Input.Value = value
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Input.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Input:SetValue(value, silent)
                value = tostring(value or "")
                field.Text = value
                if silent then
                    Input.Value = value
                    return
                end
                push(value)
            end

            function Input:OnChanged(fn)
                table.insert(Input.Callbacks, fn)
                task.spawn(fn, Input.Value)
                return Input
            end

            bind(field.Focused, function()
                glide(edge, { Color = Theme.Accent })
            end)

            bind(field.FocusLost, function()
                glide(edge, { Color = Theme.Line })
                local value = field.Text
                if opts.Numeric and value ~= "" and not tonumber(value) then
                    field.Text = Input.Value
                    return
                end
                push(value)
            end)

            if not opts.Finished then
                bind(field:GetPropertyChangedSignal("Text"), function()
                    if field:IsFocused() then
                        local value = field.Text
                        if opts.Numeric and value ~= "" and not tonumber(value) then
                            return
                        end
                        push(value)
                    end
                end)
            end

            Lib.Options[index] = Input
            return Input
        end

        function Group:AddButton(a, b)
            local text, action
            if type(a) == "table" then
                text = a.Text
                action = a.Func or a.Callback
            else
                text = a
                action = b
            end

            local wrap = slot(34)
            local button = new("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamBold,
                TextSize = 13,
                TextColor3 = Theme.Text,
                Text = text or "Button",
                AutoButtonColor = false,
            }, wrap)
            round(button, UDim.new(0, 8))
            local edge = outline(button, Theme.Line, 1)

            bind(button.MouseEnter, function()
                glide(button, { BackgroundColor3 = Theme.AccentSoft })
                glide(edge, { Color = Theme.Accent })
            end)
            bind(button.MouseLeave, function()
                glide(button, { BackgroundColor3 = Theme.Raised })
                glide(edge, { Color = Theme.Line })
            end)
            bind(button.MouseButton1Click, function()
                glide(button, { BackgroundColor3 = Theme.Accent }, 0.08)
                task.delay(0.1, function()
                    glide(button, { BackgroundColor3 = Theme.Raised })
                end)
                if action then
                    task.spawn(action)
                end
            end)

            local Button = { Instance = button }
            function Button:SetText(value)
                button.Text = value
            end
            return Button
        end

        function Group:AddDivider()
            local wrap = slot(10)
            local line = new("Frame", {
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.new(1, 0, 0, 1),
                BackgroundColor3 = Theme.LineSoft,
                BorderSizePixel = 0,
            }, wrap)
            return { Instance = line }
        end

        function Group:AddLabel(text, wrapped)
            local wrap = slot(0, true)

            local label = new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextWrapped = wrapped and true or false,
                Text = text or "",
            }, wrap)

            local Label = { Instance = label }

            function Label:SetText(value)
                label.Text = value
                return Label
            end

            function Label:AddKeyPicker(index, opts)
                opts = opts or {}
                label.Size = UDim2.new(1, -66, 0, 0)

                local chip = new("TextButton", {
                    AnchorPoint = Vector2.new(1, 0),
                    Position = UDim2.new(1, 0, 0, 0),
                    Size = UDim2.fromOffset(62, 22),
                    BackgroundColor3 = Theme.Sunken,
                    BorderSizePixel = 0,
                    Font = Enum.Font.GothamBold,
                    TextSize = 12,
                    TextColor3 = Theme.Accent,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = "",
                    AutoButtonColor = false,
                }, wrap)
                round(chip, UDim.new(0, 6))
                local edge = outline(chip, Theme.Line, 1)

                local Picker = {
                    Value = opts.Default or "",
                    Mode = opts.Mode or "Toggle",
                    Type = "KeyPicker",
                    Index = index,
                    Label = opts.Text or text or index,
                    NoUI = opts.NoUI and true or false,
                    Active = false,
                    Callbacks = {},
                    Listening = false,
                }

                local function paint()
                    chip.Text = Picker.Listening and "..." or (Picker.Value ~= "" and Picker.Value or "None")
                    glide(edge, { Color = Picker.Listening and Theme.Accent or Theme.Line })
                end

                function Picker:SetValue(value, silent)
                    if type(value) == "table" then
                        Picker.Mode = value[2] or Picker.Mode
                        value = value[1]
                    end
                    Picker.Value = tostring(value or "")
                    paint()
                    refreshKeybindList()
                    if not silent then
                        for _, fn in ipairs(Picker.Callbacks) do
                            task.spawn(fn, Picker.Value)
                        end
                    end
                end

                function Picker:OnChanged(fn)
                    table.insert(Picker.Callbacks, fn)
                    return Picker
                end

                function Picker:GetState()
                    return Picker.Active
                end

                bind(chip.MouseButton1Click, function()
                    Picker.Listening = true
                    paint()
                end)

                bind(UserInputService.InputBegan, function(input, processed)
                    if Picker.Listening then
                        if input.UserInputType == Enum.UserInputType.Keyboard then
                            Picker.Listening = false
                            if input.KeyCode == Enum.KeyCode.Backspace then
                                Picker:SetValue("")
                            else
                                Picker:SetValue(input.KeyCode.Name)
                            end
                        end
                        return
                    end
                    if processed or Picker.Value == "" then
                        return
                    end
                    if UserInputService:GetFocusedTextBox() then
                        return
                    end
                    if input.UserInputType ~= Enum.UserInputType.Keyboard then
                        return
                    end
                    if input.KeyCode.Name ~= Picker.Value then
                        return
                    end
                    if Picker.Mode == "Toggle" then
                        Picker.Active = not Picker.Active
                    else
                        Picker.Active = true
                    end
                    if opts.Callback then
                        task.spawn(opts.Callback, Picker.Active)
                    end
                end)

                bind(UserInputService.InputEnded, function(input)
                    if Picker.Mode == "Hold" and input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode.Name == Picker.Value then
                        Picker.Active = false
                        if opts.Callback then
                            task.spawn(opts.Callback, false)
                        end
                    end
                end)

                table.insert(pickers, Picker)
                Picker:SetValue(opts.Default or "", true)
                Lib.Options[index] = Picker
                return Picker
            end

            return Label
        end

        return Group
    end

    local Shell, Scale, TabRail, PageHolder, ActiveTab

    function Lib:CreateWindow(config)
        config = config or {}

        Shell = new("Frame", {
            Name = tag(),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(680, 520),
            BackgroundColor3 = Theme.Shell,
            BackgroundTransparency = 0.05,
            BorderSizePixel = 0,
            ClipsDescendants = true,
            Visible = false,
        }, Root)
        round(Shell, UDim.new(0, 16), true)
        outline(Shell, Theme.Accent, 1, 0.75)
        Scale = new("UIScale", { Scale = 1 }, Shell)

        local function refit()
            if not Scale then return end
            local view = Root.AbsoluteSize
            if view.X < 1 or view.Y < 1 then
                local camera = workspace.CurrentCamera
                view = camera and camera.ViewportSize or Vector2.new(1280, 720)
            end
            local fit = math.min(1, (view.X - 24) / 680, (view.Y - 24) / 520)
            Scale.Scale = math.clamp(math.min(Lib.DPI or 1, fit), 0.35, 2)
        end
        Lib.Refit = refit
        bind(Root:GetPropertyChangedSignal("AbsoluteSize"), refit)
        task.defer(refit)
        new("UIGradient", {
            Rotation = 90,
            Color = ColorSequence.new(Color3.fromRGB(58, 58, 58), Theme.Shell),
        }, Shell)

        local top = new("Frame", {
            Size = UDim2.new(1, 0, 0, 56),
            BackgroundTransparency = 1,
        }, Shell)
        dragify(top, Shell)

        local logo = new("ImageLabel", {
            Position = UDim2.fromOffset(18, 15),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            ScaleType = Enum.ScaleType.Fit,
            Image = config.Icon and ("rbxassetid://" .. tostring(config.Icon)) or "",
        }, top)
        round(logo, PILL)
        outline(logo, Theme.Accent, 1)

        new("TextLabel", {
            Position = UDim2.fromOffset(54, 13),
            Size = UDim2.fromOffset(240, 18),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 16,
            TextColor3 = Theme.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = config.Title or "Menu",
        }, top)

        new("TextLabel", {
            Position = UDim2.fromOffset(54, 31),
            Size = UDim2.fromOffset(300, 14),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            TextColor3 = Theme.SubText,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = config.Footer or "",
        }, top)

        local hideButton = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -18, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamBold,
            TextSize = 13,
            TextColor3 = Theme.SubText,
            Text = "X",
            AutoButtonColor = false,
        }, top)
        round(hideButton, UDim.new(0, 8))
        local hideEdge = outline(hideButton, Theme.Line, 1)
        bind(hideButton.MouseEnter, function()
            glide(hideButton, { BackgroundColor3 = Theme.AccentSoft })
            glide(hideEdge, { Color = Theme.Accent })
        end)
        bind(hideButton.MouseLeave, function()
            glide(hideButton, { BackgroundColor3 = Theme.Raised })
            glide(hideEdge, { Color = Theme.Line })
        end)
        bind(hideButton.MouseButton1Click, function()
            Shell.Visible = false
        end)

        local headerLine = new("Frame", {
            Position = UDim2.fromOffset(0, 56),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
        }, Shell)
        new("UIGradient", {
            Color = ColorSequence.new(Theme.Accent, Theme.LineSoft),
            Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.8) }),
        }, headerLine)

        local tabBar = new("Frame", {
            Position = UDim2.fromOffset(0, 57),
            Size = UDim2.new(1, 0, 0, 43),
            BackgroundTransparency = 1,
        }, Shell)

        TabRail = new("ScrollingFrame", {
            Position = UDim2.fromOffset(12, 0),
            Size = UDim2.new(1, -24, 1, 0),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.X,
            ScrollBarThickness = 0,
            ScrollingDirection = Enum.ScrollingDirection.X,
        }, tabBar)
        stack(TabRail, 4, Enum.FillDirection.Horizontal)

        local railEdge = new("Frame", {
            Position = UDim2.fromOffset(0, 100),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = Theme.LineSoft,
            BorderSizePixel = 0,
        }, Shell)

        PageHolder = new("Frame", {
            Position = UDim2.fromOffset(0, 101),
            Size = UDim2.new(1, 0, 1, -101),
            BackgroundTransparency = 1,
        }, Shell)

        local minimized = false
        local fullSize = Shell.Size

        local minButton = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -50, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            TextColor3 = Theme.SubText,
            Text = "-",
            AutoButtonColor = false,
        }, top)
        round(minButton, UDim.new(0, 8))
        local minEdge = outline(minButton, Theme.Line, 1)

        bind(minButton.MouseEnter, function()
            glide(minButton, { BackgroundColor3 = Theme.AccentSoft })
            glide(minEdge, { Color = Theme.Accent })
        end)
        bind(minButton.MouseLeave, function()
            glide(minButton, { BackgroundColor3 = Theme.Raised })
            glide(minEdge, { Color = Theme.Line })
        end)

        local function setMinimized(state)
            minimized = state and true or false
            if minButton and minButton.Parent then
                minButton.Text = minimized and "+" or "-"
            end
            if not minimized then
                tabBar.Visible = true
                railEdge.Visible = true
                PageHolder.Visible = true
            end
            glide(Shell, { Size = minimized and UDim2.new(fullSize.X.Scale, fullSize.X.Offset, 0, 56) or fullSize }, 0.22)
            if minimized then
                task.delay(0.24, function()
                    if minimized then
                        tabBar.Visible = false
                        railEdge.Visible = false
                        PageHolder.Visible = false
                    end
                end)
            end
        end

        bind(minButton.MouseButton1Click, function()
            setMinimized(not minimized)
        end)

        local Window = { Instance = Shell }

        function Window:SetMinimized(state)
            setMinimized(state)
        end

        function Window:IsMinimized()
            return minimized
        end

        function Window:AddTab(name)
            local button = new("TextButton", {
                Size = UDim2.new(0, 0, 1, 0),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamBold,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                Text = name,
                AutoButtonColor = false,
                LayoutOrder = #pages + 1,
            }, TabRail)
            pad(button, 12, 12, 0, 0)

            local mark = new("Frame", {
                AnchorPoint = Vector2.new(0, 1),
                Position = UDim2.new(0, 0, 1, 0),
                Size = UDim2.new(0, 0, 0, 2),
                BackgroundColor3 = Theme.Accent,
                BorderSizePixel = 0,
            }, button)

            local page = new("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Visible = false,
            }, PageHolder)
            pad(page, 18, 18, 12, 0)

            local left = new("ScrollingFrame", {
                Size = UDim2.new(0.5, -7, 1, 0),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, page)
            stack(left, 14)
            pad(left, 2, 10, 2, 16)

            local right = new("ScrollingFrame", {
                Position = UDim2.new(0.5, 7, 0, 0),
                Size = UDim2.new(0.5, -7, 1, 0),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, page)
            stack(right, 14)
            pad(right, 2, 10, 2, 16)

            local Tab = { Page = page, Left = left, Right = right, Button = button }

            function Tab:Select()
                for _, other in ipairs(pages) do
                    other.Page.Visible = false
                    glide(other.Button, { TextColor3 = Theme.SubText })
                    glide(other.Mark, { Size = UDim2.new(0, 0, 0, 2) })
                end
                page.Visible = true
                glide(button, { TextColor3 = Theme.Text })
                glide(mark, { Size = UDim2.new(1, 0, 0, 2) })
                ActiveTab = Tab
            end

            local function makeBox(column, title)
                local box = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundColor3 = Theme.Panel,
                    BorderSizePixel = 0,
                    LayoutOrder = #column:GetChildren(),
                }, column)
                round(box, UDim.new(0, Lib.CornerRadius), true)
                outline(box, Theme.LineSoft, 1)
                pad(box, 16, 16, 14, 16)

                local head = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 22),
                    BackgroundTransparency = 1,
                    LayoutOrder = 0,
                }, box)

                new("TextLabel", {
                    Size = UDim2.new(1, 0, 1, 0),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamBold,
                    TextSize = 12,
                    TextColor3 = Theme.Accent,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = string.upper(title or ""),
                }, head)

                new("Frame", {
                    AnchorPoint = Vector2.new(0, 1),
                    Position = UDim2.new(0, 0, 1, 0),
                    Size = UDim2.new(1, 0, 0, 1),
                    BackgroundColor3 = Theme.LineSoft,
                    BorderSizePixel = 0,
                }, head)

                local body = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundTransparency = 1,
                    LayoutOrder = 1,
                }, box)
                stack(body, 12)
                pad(body, 0, 0, 10, 0)

                stack(box, 0)
                return makeGroup(body)
            end

            function Tab:AddLeftGroupbox(title)
                return makeBox(left, title)
            end

            function Tab:AddRightGroupbox(title)
                return makeBox(right, title)
            end

            bind(button.MouseButton1Click, function()
                Tab:Select()
            end)
            bind(button.MouseEnter, function()
                if ActiveTab ~= Tab then
                    glide(button, { TextColor3 = Theme.Text })
                end
            end)
            bind(button.MouseLeave, function()
                if ActiveTab ~= Tab then
                    glide(button, { TextColor3 = Theme.SubText })
                end
            end)

            table.insert(pages, { Page = page, Button = button, Edge = mark, Label = button, Mark = mark })
            if #pages == 1 then
                Tab:Select()
            end
            return Tab
        end

        function Window:SetCornerRadius(radius)
            Lib.CornerRadius = radius
            for _, corner in ipairs(panels) do
                corner.CornerRadius = UDim.new(0, radius)
            end
        end

        function Window:Toggle()
            Shell.Visible = not Shell.Visible
        end

        Lib.Window = Window
        Lib:SetNotifySide(config.NotifySide or "Right")

        Shell.Visible = true
        Shell.Size = UDim2.fromOffset(680, 480)
        glide(Shell, { Size = UDim2.fromOffset(680, 520) }, 0.28)

        return Window
    end

    bind(UserInputService.InputBegan, function(input, processed)
        if processed or Lib.Unloaded or not Shell then
            return
        end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then
            return
        end
        if UserInputService:GetFocusedTextBox() then
            return
        end
        local wanted = Lib.ToggleKeybind and Lib.ToggleKeybind.Value or Lib.DefaultToggleKey
        if wanted ~= "" and input.KeyCode.Name == wanted then
            Shell.Visible = not Shell.Visible
        end
    end)

    function Lib:SetDPIScale(percent)
        Lib.DPI = math.clamp((tonumber(percent) or 100) / 100, 0.5, 2)
        if Lib.Refit then
            Lib.Refit()
        elseif Scale then
            Scale.Scale = Lib.DPI
        end
    end

    function Lib:Unload()
        Lib.Unloaded = true
        for _, link in ipairs(conns) do
            pcall(function()
                link:Disconnect()
            end)
        end
        conns = {}

        local genv = (type(getgenv) == "function" and getgenv()) or _G
        local session = rawget(genv, "TWINHUB_SESSION") or genv.TWINHUB_SESSION
        if type(session) == "table" then
            if type(session.unhook) == "function" then
                pcall(session.unhook)
            end
            for _, link in ipairs(session.links or {}) do
                pcall(function()
                    link:Disconnect()
                end)
            end
            session.links = {}
            pcall(function()
                local tagged = {}
                for _, name in ipairs(session.tags or {}) do
                    tagged[name] = true
                end
                if not next(tagged) then return end
                local holders = {}
                if type(gethui) == "function" then
                    local reached, container = pcall(gethui)
                    if reached and container then table.insert(holders, container) end
                end
                table.insert(holders, game:GetService("CoreGui"))
                if workspace.CurrentCamera then
                    table.insert(holders, workspace.CurrentCamera)
                end
                if LocalPlayer then
                    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                    if pg then table.insert(holders, pg) end
                end
                for _, holder in ipairs(holders) do
                    for _, child in ipairs(holder:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
                for _, model in ipairs(workspace:GetChildren()) do
                    if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
                        for _, child in ipairs(model:GetChildren()) do
                            if tagged[child.Name] then
                                child:Destroy()
                            end
                        end
                    end
                end
                for _, other in ipairs(Players:GetPlayers()) do
                    if other.Character then
                        for _, child in ipairs(other.Character:GetChildren()) do
                            if tagged[child.Name] then
                                child:Destroy()
                            end
                        end
                    end
                end
            end)
        end

        Root:Destroy()
    end

    local function fileApi()
        local write = rawget(_G, "writefile") or writefile
        local read = rawget(_G, "readfile") or readfile
        local list = rawget(_G, "listfiles") or listfiles
        local exists = rawget(_G, "isfile") or isfile
        local folder = rawget(_G, "isfolder") or isfolder
        local mkdir = rawget(_G, "makefolder") or makefolder
        local remove = rawget(_G, "delfile") or delfile
        if type(write) ~= "function" or type(read) ~= "function" or type(list) ~= "function" then
            return nil
        end
        return { write = write, read = read, list = list, exists = exists, folder = folder, mkdir = mkdir, remove = remove }
    end

    function Lib:SetConfigFolder(name)
        configFolder = name
    end

    local function ensureFolder(api)
        if api.folder and api.mkdir then
            if not api.folder(configFolder) then
                api.mkdir(configFolder)
            end
            if not api.folder(configFolder .. "/configs") then
                api.mkdir(configFolder .. "/configs")
            end
        end
    end

    local function collect()
        local dump = { toggles = {}, options = {} }
        for index, toggle in pairs(Lib.Toggles) do
            dump.toggles[index] = toggle.Value
        end
        for index, option in pairs(Lib.Options) do
            if option.Type == "KeyPicker" then
                dump.options[index] = { option.Value, option.Mode }
            else
                dump.options[index] = option.Value
            end
        end
        return dump
    end

    local function restore(dump)
        for index, value in pairs(dump.toggles or {}) do
            local toggle = Lib.Toggles[index]
            if toggle then
                toggle:SetValue(value)
            end
        end
        for index, value in pairs(dump.options or {}) do
            local option = Lib.Options[index]
            if option and option.SetValue then
                option:SetValue(value)
            end
        end
    end

    function Lib:SaveConfig(name)
        local api = fileApi()
        if not api or not name or name == "" then
            return false
        end
        ensureFolder(api)
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, collect())
        if not ok then
            return false
        end
        return pcall(api.write, configFolder .. "/configs/" .. name .. ".json", encoded)
    end

    function Lib:LoadConfig(name)
        local api = fileApi()
        if not api or not name or name == "" then
            return false
        end
        local ok, raw = pcall(api.read, configFolder .. "/configs/" .. name .. ".json")
        if not ok or type(raw) ~= "string" then
            return false
        end
        local parsed, dump = pcall(HttpService.JSONDecode, HttpService, raw)
        if not parsed or type(dump) ~= "table" then
            return false
        end
        restore(dump)
        return true
    end

    function Lib:ListConfigs()
        local api = fileApi()
        local found = {}
        if not api then
            return found
        end
        ensureFolder(api)
        local ok, entries = pcall(api.list, configFolder .. "/configs")
        if not ok or type(entries) ~= "table" then
            return found
        end
        for _, path in ipairs(entries) do
            local name = string.match(path, "([^/\\]+)%.json$")
            if name then
                table.insert(found, name)
            end
        end
        return found
    end

    function Lib:LoadAutoloadConfig()
        local api = fileApi()
        if not api then
            return
        end
        local ok, name = pcall(api.read, configFolder .. "/autoload.txt")
        if ok and type(name) == "string" and name ~= "" then
            Lib:LoadConfig(name)
        end
    end

    function Lib:BuildConfigSection(tab)
        local group = tab:AddRightGroupbox("Configuration")
        local api = fileApi()

        if not api then
            group:AddLabel("This executor has no file API, configs are off", true)
            return group
        end

        local nameBox = group:AddInput("ConfigName", {
            Default = "",
            Text = "Config name",
            Placeholder = "default",
        })

        local picker = group:AddDropdown("ConfigList", {
            Values = Lib:ListConfigs(),
            Default = nil,
            Text = "Saved configs",
        })

        group:AddButton({
            Text = "Create",
            Func = function()
                if Lib:SaveConfig(nameBox.Value) then
                    picker:SetValues(Lib:ListConfigs())
                    Lib:Notify("Saved config " .. nameBox.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Load",
            Func = function()
                if picker.Value and Lib:LoadConfig(picker.Value) then
                    Lib:Notify("Loaded config " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Overwrite",
            Func = function()
                if picker.Value and Lib:SaveConfig(picker.Value) then
                    Lib:Notify("Overwrote config " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Delete",
            Func = function()
                if picker.Value and api.remove then
                    pcall(api.remove, configFolder .. "/configs/" .. picker.Value .. ".json")
                    picker:SetValues(Lib:ListConfigs())
                    picker:SetValue(nil, true)
                    Lib:Notify("Deleted config")
                end
            end,
        })

        group:AddButton({
            Text = "Refresh list",
            Func = function()
                picker:SetValues(Lib:ListConfigs())
            end,
        })

        local autoLabel = group:AddLabel("Autoload: none", true)

        group:AddButton({
            Text = "Set as autoload",
            Func = function()
                if picker.Value then
                    pcall(api.write, configFolder .. "/autoload.txt", picker.Value)
                    autoLabel:SetText("Autoload: " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Clear autoload",
            Func = function()
                pcall(api.write, configFolder .. "/autoload.txt", "")
                autoLabel:SetText("Autoload: none")
            end,
        })

        local ok, current = pcall(api.read, configFolder .. "/autoload.txt")
        if ok and type(current) == "string" and current ~= "" then
            autoLabel:SetText("Autoload: " .. current)
        end

        return group
    end

    return Lib
end)()

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.TWINHUB_SESSION
    if type(session) == "table" then
        session.ui = Library
    end
end

local Options = Library.Options
local Toggles = Library.Toggles

Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local _AC = require(game:GetService("ReplicatedFirst").Controllers.AnimationController)

local MARK = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
local MARK2 = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.TWINHUB_SESSION
    if type(session) == "table" and type(session.tags) == "table" then
        table.insert(session.tags, MARK)
        table.insert(session.tags, MARK2)
    end
end

local function track(connection)
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.TWINHUB_SESSION
    if type(session) == "table" and type(session.links) == "table" then
        table.insert(session.links, connection)
    end
    return connection
end

local hitboxEnabled = false
local hitboxScale = 5.0
local hitboxReach = 5.0
local hitboxHooked = false
local hitboxFollow = nil
local hitboxColor = Color3.fromRGB(0, 0, 255)
local hitboxTransparency = 0.3
local hitboxBoxes = {}
local SpikeReach = { reach = 300.0, expiry = 0 }

local redirectSpikeEnabled = false
local redirectSpikeInstalled = false
local sanjuTiltEnabled = false
local sanjuTiltInstalled = false
local maxChargeEnabled = false
local maxChargeHookActive = false
local newSilentSpikeEnabled = false
local newSpikeButton = nil
local stopBallButton = nil
local aimButton = nil
local stopBallVisible = false
local aimVisible = false
local dashButton = nil
local akariDashEnabled = false
local leadFeetEnabled = false
local leadFeetButton = nil
local leadFeetLink = nil
local espJumpEnabled = false
local espHighlights = {}
local espConnections = {}
local desyncEnabled = false
local desyncConnection = nil
local autoReceiveEnabled = false
local Receive = { range = 10, lead = 0.35, stamp = 0, gap = 0.2 }
local maxServeEnabled = false
local maxServeHookActive = false
local airMovement = false
local airMovementSpeed = 16
local bodyVelocity = nil
local autoShiftLockEnabled = false
local shiftLockConnection = nil
local hitEffectEnabled = false
local selectedEffect = "SupernovaScoreEffect"
local hasFired = false
local isLocalHit = false
local hitConnection = nil
local hitConnection2 = nil
local hitRemovedConnection = nil
local playerCardEnabled = false
local selectedCard = "UltimateChampionPlayerCard"
local hasFiredCard = false
local isProcessing = false
local cardConnection = nil
local cardList = {}
local selectedJersey = "DragonTuxedoJersey"
local pickedTeam = nil
local jerseyList = {}
local selectedBallSkin = "ClassicBall"
local ballSkinList = {}
local autoSpin = false
local autoAbilitySpin = false
local desiredStyles = {}
local desiredAbilities = {}
local spinType = "Normal"
local abilitySpinType = "Normal"
local autoApplyJersey = false
local autoApplyBallSkin = false
local fakeSpikeEnabled = false
local protectEnabled = false
local tshAnimationEnabled = false
local hidariAnimationEnabled = false
local kazanaBlueEnabled = false
local kazanaWhiteEnabled = false

local originals = {}
local clones = {}
local seen = {}

local linesEnabled = false
local lineDistance = 50
local lines = {}
local lineColors = {
    Color3.fromRGB(255, 0, 0),
    Color3.fromRGB(0, 255, 0),
    Color3.fromRGB(0, 0, 255),
    Color3.fromRGB(255, 165, 0),
    Color3.fromRGB(128, 0, 128),
    Color3.fromRGB(255, 255, 0),
    Color3.fromRGB(139, 0, 0),
    Color3.fromRGB(0, 100, 0)
}

local changedProperties = {}
local oldQualityLevel
local oldSavedQualityLevel
local antilagConnections = {}

local BallService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService
local Serve = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RF.Serve
local EffectsRemote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.Effects
local doMove = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
local GameEffectRemote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RE.Effect

local TWINHUB = {
    NameTag = "T\u{200B}win Protect",
    Title = "<font color='#FF0000'><b>T\u{200B}win</b></font>",
    NotifConn = nil,
    NotifConn2 = nil,
}

local function installSpikeEffectHook()
    hookNamecall("spikeEffect", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" then
                if tshAnimationEnabled and firesignal and LocalPlayer and LocalPlayer.Character then
                    firesignal(EffectsRemote.OnClientEvent, {
                        ["Character"] = LocalPlayer.Character,
                        ["Sound"] = "PowerSpike",
                        ["Effect"] = "SpecialChargeSpikeVFX",
                    })
                elseif hidariAnimationEnabled and firesignal and LocalPlayer and LocalPlayer.Character then
                    firesignal(EffectsRemote.OnClientEvent, {
                        ["Character"] = LocalPlayer.Character,
                        ["Sound"] = "PowerSpike",
                        ["Effect"] = "HidariSpikeVFX",
                    })
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
end

if getrawmetatable and setreadonly and getnamecallmethod then
    installSpikeEffectHook()
end

local function updateNametag()
    local player = LocalPlayer
    if player and player.Character then
        local nameTag = player.Character:FindFirstChild("Nametag")
        if nameTag then
            local label = nameTag:FindFirstChild("PlayerName")
            if label and label:IsA("TextLabel") then
                label.Text = TWINHUB.NameTag
            end
        end
    end
end

local function updateTitle()
    local player = LocalPlayer
    if player then
        player:SetAttribute("User_Title", TWINHUB.Title)
    end
end

local function processNotification(notification)
    if not notification then return end
    local player = LocalPlayer
    if not player then return end
    task.wait(0.2)
    local textLabel = notification:FindFirstChild("TextLabel")
    if not textLabel then
        for _, child in ipairs(notification:GetDescendants()) do
            if child:IsA("TextLabel") then
                textLabel = child
                break
            end
        end
    end
    if not textLabel then return end
    local text = textLabel.Text or ""
    if string.find(text, player.Name) then
        textLabel.Text = string.gsub(text, player.Name, TWINHUB.NameTag)
    end
end

local function setupNotifications()
    if TWINHUB.NotifConn then 
        TWINHUB.NotifConn:Disconnect() 
        TWINHUB.NotifConn = nil 
    end
    if TWINHUB.NotifConn2 then 
        TWINHUB.NotifConn2:Disconnect() 
        TWINHUB.NotifConn2 = nil 
    end
    local player = LocalPlayer
    if not player then return end
    local gui = player.PlayerGui:FindFirstChild("Interface")
    if gui then
        gui = gui:FindFirstChild("Persistent")
        if gui then
            gui = gui:FindFirstChild("Notifications")
        end
    end
    if not gui then return end
    for _, child in ipairs(gui:GetChildren()) do
        processNotification(child)
    end
    TWINHUB.NotifConn = gui.ChildAdded:Connect(function(child)
        task.wait(0.2)
        processNotification(child)
    end)
    TWINHUB.NotifConn2 = gui.DescendantAdded:Connect(function(child)
        if child:IsA("TextLabel") then
            task.wait(0.1)
            local player = LocalPlayer
            if not player then return end
            local text = child.Text or ""
            if string.find(text, player.Name) then
                child.Text = string.gsub(text, player.Name, TWINHUB.NameTag)
            end
        end
    end)
end

local function protectPlayerCard()
    if not protectEnabled then return end
    local playerName = string.upper(LocalPlayer.Name)
    local flashFrame = LocalPlayer.PlayerGui:FindFirstChild("Interface")
    if flashFrame then
        flashFrame = flashFrame:FindFirstChild("Persistent")
        if flashFrame then
            flashFrame = flashFrame:FindFirstChild("FlashPlayerCardFrame")
        end
    end
    if not flashFrame then return end
    local username = flashFrame:FindFirstChild("Username", true)
    if username and username:IsA("TextLabel") then
        local currentText = string.upper(username.Text or "")
        if string.find(currentText, playerName) then
            username.Text = TWINHUB.NameTag
        end
    end
end

local function fireCardRemote()
    if hasFiredCard or isProcessing then return end
    local Remote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PlayerCardService.RE.OnFlashCard
    if Remote and firesignal then
        isProcessing = true
        hasFiredCard = true
        pcall(firesignal, Remote.OnClientEvent, {
            ["PlayerCardItemId"] = selectedCard,
            ["Context"] = {
                ["Custom"] = {},
                ["PlacementId"] = "ScoredPoint",
            },
            ["Player"] = LocalPlayer,
        })
        task.wait(0.3)
        hasFiredCard = false
        isProcessing = false
    end
end

local function changePlayerCard()
    if not playerCardEnabled then return end
    if isProcessing then return end
    local flashFrame = LocalPlayer.PlayerGui.Interface.Persistent:FindFirstChild("FlashPlayerCardFrame")
    if not flashFrame then return end
    local username = flashFrame:FindFirstChild("Username", true)
    if username and username:IsA("TextLabel") then
        local currentText = string.upper(username.Text or "")
        local playerName = string.upper(LocalPlayer.Name)
        if string.find(currentText, playerName) then
            flashFrame:Destroy()
            task.wait(0.1)
            fireCardRemote()
        end
    end
end

local function enablePlayerCard()
    if cardConnection then return end
    cardConnection = LocalPlayer.PlayerGui.Interface.Persistent.ChildAdded:Connect(function(child)
        if child.Name == "FlashPlayerCardFrame" then
            task.wait(0.1)
            changePlayerCard()
        end
    end)
end

local function disablePlayerCard()
    if cardConnection then
        cardConnection:Disconnect()
        cardConnection = nil
    end
end

_G.PlayerCard = {
    Enable = enablePlayerCard,
    Disable = disablePlayerCard,
    SetCard = function(cardName)
        selectedCard = cardName
    end,
    GetCard = function()
        return selectedCard
    end
}

local function toggleProtection(state)
    protectEnabled = state
    if state then
        updateNametag()
        updateTitle()
        setupNotifications()
        protectPlayerCard()
    else
        if TWINHUB.NotifConn then TWINHUB.NotifConn:Disconnect() TWINHUB.NotifConn = nil end
        if TWINHUB.NotifConn2 then TWINHUB.NotifConn2:Disconnect() TWINHUB.NotifConn2 = nil end
        if LocalPlayer.Character then
            local char = LocalPlayer.Character
            local nameTag = char:FindFirstChild("Nametag")
            if nameTag then
                local label = nameTag:FindFirstChild("PlayerName")
                if label and label:IsA("TextLabel") then
                    label.Text = LocalPlayer.Name
                end
            end
        end
        local player = LocalPlayer
        if player then
            player:SetAttribute("User_Title", "")
        end
    end
end

track(LocalPlayer.CharacterAdded:Connect(function(character)
    if not protectEnabled then return end
    local tag = character:WaitForChild("Nametag", 10)
    if not tag or not protectEnabled or LocalPlayer.Character ~= character then return end
    tag:WaitForChild("PlayerName", 5)
    if not protectEnabled or LocalPlayer.Character ~= character then return end
    updateNametag()
    task.wait(0.5)
    if protectEnabled and LocalPlayer.Character == character then
        updateNametag()
    end
end))

local function findFirstPart(model)
    if model.PrimaryPart then
        return model.PrimaryPart
    end
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Name ~= MARK and descendant.Name ~= MARK2 then
            return descendant
        end
    end
    return nil
end

local function ballModels()
    local found = CollectionService:GetTagged("Ball")
    if found[1] then
        return found
    end
    local list = {}
    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
            list[#list + 1] = model
        end
    end
    return list
end

local function getBallId()
    for _, model in ipairs(ballModels()) do
        local id = model.Name:match("^CLIENT_BALL_(%d+)$")
        if id then
            return tonumber(id)
        end
    end
    return nil
end

local function reachableBall(params, character, reach)
    if not character then return nil end
    local closest, shortest = nil, reach or hitboxReach
    for _, model in ipairs(params.FilterDescendantsInstances) do
        if model:IsA("Model") then
            local driver = model.PrimaryPart or findFirstPart(model)
            if driver then
                for _, piece in ipairs(character:GetChildren()) do
                    if piece:IsA("BasePart") then
                        local gap = (piece.Position - driver.Position).Magnitude
                        if gap <= shortest then
                            closest, shortest = driver, gap
                        end
                    end
                end
            end
        end
    end
    return closest
end

local function installHitboxHook()
    if hitboxHooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("hitbox", function(callNext, self, method, ...)
        if self == Workspace and method == "GetPartsInPart" then
            local spiking = SpikeReach.expiry > os.clock()
            if hitboxEnabled or spiking then
                local probe, params = ...
                if typeof(probe) == "Instance" and typeof(params) == "OverlapParams"
                    and params.FilterType == Enum.RaycastFilterType.Include then
                    local results = callNext(self, method, probe, params)
                    if type(results) == "table" and not results[1] then
                        local driver = reachableBall(params, LocalPlayer.Character, spiking and SpikeReach.reach or hitboxReach)
                        if driver then
                            results[1] = driver
                        end
                    end
                    return results
                end
            end
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        hitboxHooked = true
    end
end

local function adornHolder()
    local camera = Workspace.CurrentCamera or Camera
    local folder = camera:FindFirstChild(MARK)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = MARK
        folder.Parent = camera
    end
    return folder
end

local function installHitboxFollow()
    if hitboxFollow then return end
    hitboxFollow = track(RunService.RenderStepped:Connect(function()
        for driver, shell in pairs(hitboxBoxes) do
            if driver.Parent and shell.Parent then
                shell.CFrame = driver.CFrame
            end
        end
    end))
end

local function updateHitboxes(scale)
    if not hitboxEnabled then return end
    hitboxReach = scale or hitboxReach
    installHitboxHook()
    installHitboxFollow()
    local folder = adornHolder()
    local live = {}
    for _, model in ipairs(ballModels()) do
        local driver = model.PrimaryPart or findFirstPart(model)
        if driver then
            live[driver] = true
            local shell = hitboxBoxes[driver]
            if not shell or not shell.Parent then
                shell = Instance.new("Part")
                shell.Name = MARK
                shell.Shape = Enum.PartType.Ball
                shell.Material = Enum.Material.ForceField
                shell.Anchored = true
                shell.CanCollide = false
                shell.CanTouch = false
                shell.CanQuery = false
                shell.CastShadow = false
                shell.Massless = true
                shell.Reflectance = 0
                shell.Parent = folder
                hitboxBoxes[driver] = shell
            end
            shell.Size = Vector3.new(2, 2, 2) * hitboxReach
            shell.CFrame = driver.CFrame
            shell.Color = hitboxColor
            shell.Transparency = hitboxTransparency
        end
    end
    for driver, shell in pairs(hitboxBoxes) do
        if not live[driver] then
            if shell.Parent then
                shell:Destroy()
            end
            hitboxBoxes[driver] = nil
        end
    end
end

local function removeHitboxes()
    for driver, shell in pairs(hitboxBoxes) do
        if shell.Parent then
            shell:Destroy()
        end
        hitboxBoxes[driver] = nil
    end
    local camera = Workspace.CurrentCamera or Camera
    local folder = camera:FindFirstChild(MARK)
    if folder then
        folder:Destroy()
    end
end

track(Workspace.ChildAdded:Connect(function(child)
    if child:IsA("Model") and child.Name:match("^CLIENT_BALL_%d+$") then
        for _ = 1, 40 do
            if findFirstPart(child) then
                break
            end
            task.wait(0.05)
        end
        if hitboxEnabled and child.Parent then
            updateHitboxes(hitboxScale)
        end
    end
end))

if hitboxEnabled then
    updateHitboxes(hitboxScale)
end

local function removeLine(player)
    local data = lines[player]
    if data then
        if data.beam then data.beam:Destroy() end
        if data.target and data.target.Parent then data.target:Destroy() end
        if data.attachment and data.attachment.Parent then data.attachment:Destroy() end
        lines[player] = nil
    end
end

local function updateLine(player, index)
    if not linesEnabled then
        removeLine(player)
        return
    end
    local character = player.Character
    if not character or not character:FindFirstChild("Head") or not character:FindFirstChild("HumanoidRootPart") then
        removeLine(player)
        return
    end
    local head = character.Head
    local rootPart = character.HumanoidRootPart
    if not lines[player] then
        local attachment = Instance.new("Attachment", head)
        local target = Instance.new("Part")
        target.Anchored = true
        target.CanCollide = false
        target.Transparency = 1
        target.Size = Vector3.new(0.1, 0.1, 0.1)
        target.Parent = Workspace
        local targetAttachment = Instance.new("Attachment", target)
        local beam = Instance.new("Beam")
        beam.Attachment0 = attachment
        beam.Attachment1 = targetAttachment
        beam.Width0 = 0.25
        beam.Width1 = 0.25
        beam.FaceCamera = true
        beam.LightEmission = 1
        beam.Transparency = NumberSequence.new(0.3)
        beam.Color = ColorSequence.new(lineColors[(index - 1) % #lineColors + 1])
        beam.Parent = head
        lines[player] = { beam = beam, target = target, attachment = attachment }
    end
    local data = lines[player]
    data.target.Position = head.Position + rootPart.CFrame.LookVector * lineDistance
end

track(RunService.RenderStepped:Connect(function()
    if linesEnabled then
        for index, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Team ~= LocalPlayer.Team then
                updateLine(player, index)
            else
                removeLine(player)
            end
        end
    else
        for player in pairs(lines) do
            removeLine(player)
        end
    end
end))

track(Players.PlayerRemoving:Connect(removeLine))

_G.Lines = {
    SetEnabled = function(value)
        linesEnabled = value
        if not value then
            for player in pairs(lines) do
                removeLine(player)
            end
        end
    end,
    SetDistance = function(value)
        lineDistance = value
    end,
    IsEnabled = function()
        return linesEnabled
    end,
    GetDistance = function()
        return lineDistance
    end
}

local function isOnGround()
    local character = LocalPlayer.Character
    if not character then return false end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return false end
    local humanoid = character:FindFirstChild("Humanoid")
    if not humanoid then return false end
    if humanoid.FloorMaterial == Enum.Material.Air then return false end
    local state = humanoid:GetState()
    return state ~= Enum.HumanoidStateType.Freefall and state ~= Enum.HumanoidStateType.Jumping
end

local function getNearestBall()
    local nearestBall = nil
    local nearestDistance = math.huge
    local character = LocalPlayer.Character
    if not character then return nil, nil end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return nil, nil end
    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
            for _, part in ipairs(model:GetDescendants()) do
                if part:IsA("BasePart") then
                    local distance = (part.Position - rootPart.Position).Magnitude
                    if distance < nearestDistance then
                        nearestDistance = distance
                        nearestBall = part
                    end
                    break
                end
            end
        end
    end
    return nearestBall, nearestDistance
end

local function ballDrift(part)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if reached then
        local found, controller = pcall(Knit.GetController, "BallController")
        if found and type(controller) == "table" and type(controller.ActiveBalls) == "table" then
            for _, record in pairs(controller.ActiveBalls) do
                local model = record.Ball
                if model and model.Parent and model:IsAncestorOf(part) and typeof(record.Velocity) == "Vector3" then
                    return record.Velocity
                end
            end
        end
    end
    local now = os.clock()
    local spot, when = Receive.spot, Receive.when
    local same = Receive.part == part
    Receive.part, Receive.spot, Receive.when = part, part.Position, now
    if same and spot and now > when then
        return (part.Position - spot) / (now - when)
    end
    return Vector3.zero
end

local function autoReceive()
    if not autoReceiveEnabled then return end
    if not isOnGround() then return end
    local character = LocalPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return end

    local now = os.clock()
    if now - Receive.stamp < Receive.gap then return end

    local ball = getNearestBall()
    if not ball then return end

    local offset = ball.Position - rootPart.Position
    local drift = ballDrift(ball) - rootPart.AssemblyLinearVelocity
    local pull = Vector3.new(0, -Workspace.Gravity, 0)

    local closest = offset.Magnitude
    for step = 1, 12 do
        local moment = step / 12 * Receive.lead
        local reach = (offset + drift * moment + pull * (0.5 * moment * moment)).Magnitude
        if reach < closest then
            closest = reach
        end
    end

    if closest > Receive.range then return end

    local loaded, handlers = pcall(require, game:GetService("ReplicatedFirst").Controllers.GameController.Handlers)
    if loaded and type(handlers) == "table" and handlers.States then
        local states = handlers.States
        if states.IsBusy:get() or states.IsServing:get() then
            return
        end
    end

    if firesignal then
        firesignal(doMove.OnClientEvent, "Set", false, false)
        Receive.stamp = now
    end
end

track(RunService.Heartbeat:Connect(autoReceive))

track(LocalPlayer.CharacterAdded:Connect(function()
    Receive.stamp = 0
    Receive.part = nil
end))


local function enableRedirectSpike()
    redirectSpikeEnabled = true
    if redirectSpikeInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("redirectSpike", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and redirectSpikeEnabled then
                local dir = Camera.CFrame.LookVector
                data.LookVector = dir
                data.Direction = dir
                if data.MoveDirection then
                    data.MoveDirection = dir
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        redirectSpikeInstalled = true
    end
end

local function disableRedirectSpike()
    redirectSpikeEnabled = false
end

local AutoCorner = {
    enabled = false,
    side = "Auto",
    reach = "All",
}

local function enableSanjuTilt()
    sanjuTiltEnabled = true
    if sanjuTiltInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("sanjuTilt", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and sanjuTiltEnabled then
                if data.TiltDirection and data.LookVector then
                    local tiltDir = data.TiltDirection
                    if math.abs(tiltDir.X) > 0.01 or math.abs(tiltDir.Z) > 0.01 then
                        local lookVec = data.LookVector
                        local bend = Vector3.new(tiltDir.X, 0, tiltDir.Z)
                        data.LookVector = Vector3.new(
                            lookVec.X + bend.X * 0.3,
                            lookVec.Y,
                            lookVec.Z + bend.Z * 0.3
                        ).Unit
                        data.TiltDirection = Vector3.new(
                            tiltDir.X * 1.35,
                            tiltDir.Y,
                            tiltDir.Z * 1.35
                        )
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        sanjuTiltInstalled = true
    end
end

local function disableSanjuTilt()
    sanjuTiltEnabled = false
end

AutoCorner.physics = function()
    local reached, module = pcall(require, ReplicatedStorage.Common.Physics)
    return reached and module or nil
end

AutoCorner.bounds = function()
    local physics = AutoCorner.physics()
    if physics and physics._getCourtlines then
        local found, lines = pcall(physics._getCourtlines)
        if found and lines and lines:IsA("BasePart") then
            return lines.Position, lines.Size * 0.5, lines.Position.Y
        end
    end
    local map = Workspace:FindFirstChild("Map")
    local court = map and map:FindFirstChild("Court")
    if court then
        return court.Position, court.Size * 0.5 - Vector3.new(1, 0, 1), court.Position.Y + court.Size.Y * 0.5
    end
    return nil
end

AutoCorner.trackBall = function(ball, before, elapsed)
    if elapsed <= 0 then return end
    local drift = ball.Position - before
    AutoCorner.drift = drift / elapsed
end

AutoCorner.origin = function()
    local ball = getNearestBall()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not ball then
        return root and root.Position or Vector3.zero
    end

    local drift = AutoCorner.drift
    if not root or typeof(drift) ~= "Vector3" or drift.Magnitude < 1 then
        return ball.Position
    end

    local gap = ball.Position - root.Position
    local closing = drift - root.AssemblyLinearVelocity
    local speed = closing:Dot(closing)
    if speed < 1 then
        return ball.Position
    end

    local reach = math.clamp(-gap:Dot(closing) / speed, 0, 0.45)
    return ball.Position + drift * reach
end

local function cornerPoint()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local centre, half, surfaceY = AutoCorner.bounds()
    if not root or not centre then return nil end

    local halfX = math.max(half.X - 2, 1)
    local halfZ = math.max(half.Z - 2, 1)

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local deepZ = centre.Z + sign * halfZ
    local leftX = centre.X + sign * halfX
    local rightX = centre.X - sign * halfX

    local pivot = AutoCorner.origin()
    local attackLine = half.Z / 3
    local standoff = math.abs(root.Position.Z - netZ)
    local hugging = 1 - math.clamp(standoff / attackLine, 0, 1)
    AutoCorner.lean = hugging

    local shortZ = centre.Z + sign * halfZ * 0.3
    local reach = AutoCorner.reach
    local wantsNear = reach == "Nearest" or (reach ~= "Back" and hugging > 0)

    local side = AutoCorner.side
    if side == "Left" then
        return Vector3.new(leftX, surfaceY, wantsNear and shortZ or deepZ)
    elseif side == "Right" then
        return Vector3.new(rightX, surfaceY, wantsNear and shortZ or deepZ)
    end

    local corners = {}
    if reach ~= "Nearest" then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, deepZ), reward = 0 }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, deepZ), reward = 0 }
    end
    if wantsNear then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, shortZ), reward = 0.45 * hugging }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, shortZ), reward = 0.45 * hugging }
    end

    local eye = Workspace.CurrentCamera or Camera
    local heading = eye and eye.CFrame.LookVector or root.CFrame.LookVector
    heading = Vector3.new(heading.X, 0, heading.Z)
    if heading.Magnitude < 0.01 then
        return corners[1].at
    end
    heading = heading.Unit

    local physics = AutoCorner.physics()
    local bounds = physics and physics._getCourtlines and physics._getCourtlines()

    local guards = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and (not LocalPlayer.Team or player.Team ~= LocalPlayer.Team) then
            local guardRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if guardRoot then
                guards[#guards + 1] = Vector3.new(guardRoot.Position.X, surfaceY, guardRoot.Position.Z)
            end
        end
    end

    local aligned = {}
    for _, corner in ipairs(corners) do
        local legal = true
        if bounds and physics.isPositionInCourt then
            local ok, inside = pcall(physics.isPositionInCourt, corner.at, bounds, 0, nil)
            legal = not ok or inside
        end
        if legal then
            local line = Vector3.new(corner.at.X - pivot.X, 0, corner.at.Z - pivot.Z)
            if line.Magnitude > 0.01 then
                local dot = line.Unit:Dot(heading)
                aligned[#aligned + 1] = { spot = corner.at, dot = dot, reward = corner.reward }
            end
        end
    end
    if #aligned == 0 then return corners[1].at end

    local pick
    for _, entry in ipairs(aligned) do
        if not pick or entry.dot > pick.dot then pick = entry end
    end
    local wanted = pick.spot.X >= centre.X

    local best, bestScore
    for _, entry in ipairs(aligned) do
        if (entry.spot.X >= centre.X) == wanted then
            local nearest = 60
            for _, guard in ipairs(guards) do
                local gap = (guard - entry.spot).Magnitude
                if gap < nearest then nearest = gap end
            end
            local score = math.min(nearest, 45) / 45 + entry.reward
            if not bestScore or score > bestScore then
                bestScore = score
                best = entry.spot
            end
        end
    end
    return best or pick.spot
end

AutoCorner.facing = function()
    local spot = cornerPoint()
    if not spot then return nil end
    local pivot = AutoCorner.origin()
    local flat = Vector3.new(spot.X - pivot.X, 0, spot.Z - pivot.Z)

    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        local net = collide and collide:FindFirstChild("Net")
        local netZ = net and net.Position.Z
        if netZ then
            local ownSide = (root.Position.Z > netZ) and 1 or -1
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(spot.X - root.Position.X, 0, spot.Z - root.Position.Z)
            end
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(flat.X, 0, -ownSide * math.max(math.abs(flat.Z), 1))
            end
        end
    end

    if flat.Magnitude < 0.01 then return nil end
    return flat.Unit
end

AutoCorner.installAim = function()
    if AutoCorner.aimed then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("autoCornerAim", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if AutoCorner.enabled and type(data) == "table" and (data.Move == "Spike" or data.Move == "ServeSpike") then
                local steer = AutoCorner.steer
                if typeof(steer) == "Vector3" then
                    local flat = Vector3.new(steer.X, 0, steer.Z)
                    if flat.Magnitude > 0.01 then
                        flat = flat.Unit
                        local aim = (flat - Vector3.new(0, 0.35, 0)).Unit
                        data.LookVector = aim
                        data.Direction = aim
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        AutoCorner.aimed = true
    end
end

local function enableMaxCharge()
    maxChargeEnabled = true
    if maxChargeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxCharge", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and maxChargeEnabled then
                data.Charge = 1.0
                data.SpecialCharge = 1.0
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        maxChargeHookActive = true
    end
end

local function disableMaxCharge()
    maxChargeEnabled = false
end

local Hush = {
    active = false,
    links = {},
    damped = {},
    paused = {},
    loud = {
        [Enum.AnimationPriority.Action] = true,
        [Enum.AnimationPriority.Action2] = true,
        [Enum.AnimationPriority.Action3] = true,
        [Enum.AnimationPriority.Action4] = true,
    },
}

Hush.gag = function(signal)
    if type(getconnections) ~= "function" then return end
    local listed, cons = pcall(getconnections, signal)
    if not listed or type(cons) ~= "table" then return end
    for _, con in ipairs(cons) do
        pcall(function()
            if con.Enabled ~= false then
                con:Disable()
                Hush.paused[#Hush.paused + 1] = con
            end
        end)
    end
end

Hush.quiet = function(inst)
    if not inst:IsA("Sound") then return end
    Hush.damped[#Hush.damped + 1] = { inst = inst, level = inst.Volume }
    pcall(function()
        inst.Volume = 0
        inst:Stop()
    end)
end

Hush.start = function()
    if Hush.active then return end
    Hush.active = true

    Hush.gag(EffectsRemote.OnClientEvent)
    Hush.gag(GameEffectRemote.OnClientEvent)

    Hush.animUntil = os.clock() + 0.2
    local character = LocalPlayer.Character
    local animator = character and character:FindFirstChildWhichIsA("Animator", true)
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            if Hush.loud[track.Priority] then
                pcall(track.Stop, track, 0)
            end
        end
        Hush.links[#Hush.links + 1] = animator.AnimationPlayed:Connect(function(track)
            if not Hush.active or os.clock() > Hush.animUntil then return end
            if Hush.loud[track.Priority] then
                pcall(track.Stop, track, 0)
            end
        end)
    end

    for _, root in ipairs({ Workspace, game:GetService("SoundService"), character }) do
        if root then
            Hush.links[#Hush.links + 1] = root.DescendantAdded:Connect(function(inst)
                if Hush.active then
                    Hush.quiet(inst)
                end
            end)
        end
    end
end

Hush.stop = function()
    if not Hush.active then return end
    Hush.active = false
    for _, link in ipairs(Hush.links) do
        pcall(function() link:Disconnect() end)
    end
    Hush.links = {}
    for _, con in ipairs(Hush.paused) do
        pcall(function() con:Enable() end)
    end
    Hush.paused = {}
    for _, record in ipairs(Hush.damped) do
        if record.inst.Parent then
            pcall(function() record.inst.Volume = record.level end)
        end
    end
    Hush.damped = {}
end

local function enemyAim()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local centre, half, surfaceY = AutoCorner.bounds()
    if not centre then return nil end

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z
    local netTop = net and (net.Position.Y + net.Size.Y * 0.5) or surfaceY

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local ball = getNearestBall()
    local origin = ball and ball.Position or (root.Position + Vector3.new(0, 6, 0))
    local headroom = origin.Y - netTop
    local standoff = math.max(math.abs(netZ - origin.Z), 2)
    local drop = math.clamp(0.45 * headroom / standoff, -0.05, 0.30)

    local halfZ = math.max(half.Z - 2, 1)
    local target = Vector3.new(centre.X + (origin.X - centre.X) * 0.25, surfaceY, centre.Z + sign * halfZ * 0.55)

    local flat = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
    if flat.Magnitude < 0.01 then return nil end
    return (flat.Unit - Vector3.new(0, drop, 0)).Unit
end

local Silent = { steer = nil, expiry = 0, hooked = false }

Silent.install = function()
    if Silent.hooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("silentSpike", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            local steer = Silent.steer
            if steer ~= nil then
                if os.clock() >= Silent.expiry then
                    Silent.steer = nil
                    Silent.expiry = 0
                elseif type(data) == "table" and typeof(steer) == "Vector3" then
                    if data.Move == "Spike" or data.Move == "ServeSpike" then
                        data.LookVector = steer
                        data.Direction = steer
                        local ground = Vector3.new(steer.X, 0, steer.Z)
                        if typeof(data.TiltDirection) == "Vector3" and ground.Magnitude > 0.01 then
                            local power = Vector3.new(data.TiltDirection.X, 0, data.TiltDirection.Z).Magnitude
                            if power > 0.05 then
                                local lean = ground.Unit * power
                                data.TiltDirection = Vector3.new(lean.X, data.TiltDirection.Y, lean.Z)
                            end
                        end
                        -- one shot: the next spike the player throws must not be steered
                        Silent.steer = nil
                        Silent.expiry = 0
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        Silent.hooked = true
    end
end

local function fireNewSpike()
    if not newSilentSpikeEnabled then return end
    if not firesignal then return end
    local newRemote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
    Hush.start()
    installHitboxHook()
    SpikeReach.expiry = os.clock() + 0.3
    local dir = enemyAim() or Camera.CFrame.LookVector
    local expiry = os.clock() + 0.8
    Silent.steer = dir
    Silent.expiry = expiry
    Silent.install()
    firesignal(newRemote.OnClientEvent, "Spike", false, false, dir)
    task.spawn(function()
        task.wait(0.3)
        Hush.stop()
    end)
    task.delay(0.8, function()
        if Silent.expiry == expiry then
            Silent.steer = nil
            Silent.expiry = 0
        end
    end)
end

local function createNewSpikeButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    newSpikeButton = Instance.new("TextButton")
    newSpikeButton.Size = UDim2.new(0, 50, 0, 50)
    newSpikeButton.Position = UDim2.new(0.5, -25, 0.85, -25)
    newSpikeButton.BackgroundColor3 = Color3.fromRGB(255, 165, 0)
    newSpikeButton.Text = "Spike"
    newSpikeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    newSpikeButton.TextScaled = true
    newSpikeButton.Font = Enum.Font.GothamBold
    newSpikeButton.Parent = screenGui
    newSpikeButton.BackgroundTransparency = 0.2
    newSpikeButton.BorderSizePixel = 0
    newSpikeButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = newSpikeButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    newSpikeButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = newSpikeButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    newSpikeButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            newSpikeButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    newSpikeButton.MouseButton1Click:Connect(function()
        fireNewSpike()
    end)
    newSpikeButton.Visible = false
    return newSpikeButton
end

newSpikeButton = createNewSpikeButton()

local function enableDesync()
    if desyncConnection then return end
    local doMove = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
    desyncConnection = UserInputService.JumpRequest:Connect(function()
        if desyncEnabled then
            task.wait(0.03)
            if firesignal then
                firesignal(doMove.OnClientEvent, "Spike", false, false)
            end
        end
    end)
    desyncEnabled = true
end

local function disableDesync()
    if desyncConnection then
        desyncConnection:Disconnect()
        desyncConnection = nil
    end
    desyncEnabled = false
end

track(UserInputService.JumpRequest:Connect(function()
    if not kazanaBlueEnabled and not kazanaWhiteEnabled then
        return
    end
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then
        return
    end
    if os.clock() - (seen.__kazanaAt or 0) < 0.35 then
        return
    end
    seen.__kazanaAt = os.clock()

    local white = kazanaWhiteEnabled
    local effectFolder = ReplicatedStorage.Assets:FindFirstChild("Effects")
    local module = effectFolder and effectFolder:FindFirstChild(white and "KazanaWhite" or "KazanaBlue")
    if not module then
        return
    end

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        require(module)(character)
        require(ReplicatedStorage.Tools.Sound).fromName(white and "Kazana_White" or "Kazana_Blue")({})
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end))

local function playDashEffect(direction)
    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local Effect = require(ReplicatedStorage.Content.Effect)
        Effect:Play("KuraiDashFX")({
            Player = LocalPlayer,
            Direction = direction,
        })
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

local function akariDash()
    if not akariDashEnabled then return end
    local character = LocalPlayer.Character
    if not character then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local direction, distance = nil, 10
    local ball = getNearestBall()
    if ball then
        local flat = Vector3.new(ball.Position.X - hrp.Position.X, 0, ball.Position.Z - hrp.Position.Z)
        if flat.Magnitude > 0.01 then
            direction = flat.Unit
            distance = math.clamp(flat.Magnitude - 1, 0, 16)
        end
    end
    if not direction then
        local forward = Camera.CFrame.LookVector
        direction = Vector3.new(forward.X, 0, forward.Z).Unit
    end
    playDashEffect(direction)
    local tween = game:GetService("TweenService"):Create(hrp, TweenInfo.new(0.2, Enum.EasingStyle.Linear), {
        CFrame = CFrame.new(hrp.Position + (direction * distance)) * CFrame.Angles(0, math.rad(hrp.Orientation.Y), 0)
    })
    tween:Play()
end

local function createDashButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    dashButton = Instance.new("TextButton")
    dashButton.Size = UDim2.new(0, 50, 0, 50)
    dashButton.Position = UDim2.new(0.15, -25, 0.8, -25)
    dashButton.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
    dashButton.Text = "⚡"
    dashButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    dashButton.TextScaled = true
    dashButton.Font = Enum.Font.GothamBold
    dashButton.Parent = screenGui
    dashButton.BackgroundTransparency = 0.2
    dashButton.BorderSizePixel = 0
    dashButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = dashButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    dashButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = dashButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    dashButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            dashButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    dashButton.MouseButton1Click:Connect(akariDash)
    dashButton.Visible = false
    return dashButton
end

createDashButton()

local function stopBall()
    if not BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local lookVector = Vector3.new(0, -1, 0)
    local Interact = BallService.RF.Interact
    if Interact then
        Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = "Block",
            ["SpecialCharge"] = 0,
            ["TiltDirection"] = Vector3.new(-0.1260179579257965, 1, 0.992027997970581),
            ["LookVector"] = lookVector,
            ["MoveDirection"] = Vector3.new(0, 0, 0),
            ["ClientCanRunSpecial"] = false,
            ["From"] = "Client",
            ["BallId"] = ballId,
            ["Timestamp"] = tick(),
            ["CustomClient"] = {},
        })
    end
end

local function createStopBallButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    stopBallButton = Instance.new("TextButton")
    stopBallButton.Size = UDim2.new(0, 50, 0, 50)
    stopBallButton.Position = UDim2.new(0.35, -25, 0.8, -25)
    stopBallButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
    stopBallButton.Text = "Stop"
    stopBallButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    stopBallButton.TextScaled = true
    stopBallButton.Font = Enum.Font.GothamBold
    stopBallButton.Parent = screenGui
    stopBallButton.BackgroundTransparency = 0.2
    stopBallButton.BorderSizePixel = 0
    stopBallButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = stopBallButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    stopBallButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = stopBallButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    stopBallButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            stopBallButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    stopBallButton.MouseButton1Click:Connect(function()
        stopBall()
    end)
    stopBallButton.Visible = stopBallVisible
    return stopBallButton
end

local AutoCounter = (function()
    local ReplicatedFirst = game:GetService("ReplicatedFirst")

    local state = {
        enabled = false,
        move = "Auto",
        netRange = 9,
        lateral = 14,
        reach = 16,
        delay = 0.05,
        cooldown = 0.5,
        autoJump = true,
    }

    local handlers = nil
    local controller = nil
    local firing = false
    local lastFire = 0

    local function elevate(fn)
        local restore = getthreadidentity and getthreadidentity()
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        local ok = pcall(fn)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
        return ok
    end

    local function bind()
        if handlers and controller then return true end
        elevate(function()
            handlers = require(ReplicatedFirst.Controllers.GameController.Handlers)
            controller = require(ReplicatedStorage.Packages.Knit).GetController("GameController")
        end)
        return handlers ~= nil and controller ~= nil
    end

    local function getNet()
        local tagged = CollectionService:GetTagged("Net")[1]
        if tagged and tagged:IsA("BasePart") then
            return tagged
        end
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        return collide and collide:FindFirstChild("Net")
    end

    local function ownSide(root, netZ)
        local team = LocalPlayer.Team
        local index = team and team:GetAttribute("Index")
        if index == 1 then return -1 end
        if index == 2 then return 1 end
        return (root.Position.Z >= netZ) and 1 or -1
    end

    local function findThreat(root, net)
        local netZ = net.Position.Z
        local netTop = net.Position.Y + net.Size.Y * 0.5
        local side = ownSide(root, netZ)

        local myGap = (root.Position.Z - netZ) * side
        if myGap < 0 or myGap > state.netRange then return nil end

        local ball = getNearestBall()
        if not ball then return nil end
        if ball.Position.Y < netTop - 3 then return nil end
        if math.abs(ball.Position.Z - netZ) > state.netRange + 6 then return nil end
        if math.abs(ball.Position.X - root.Position.X) > state.lateral then return nil end

        local myTeam = LocalPlayer.Team
        for _, player in ipairs(Players:GetPlayers()) do
            local hostile = player ~= LocalPlayer and (myTeam == nil or player.Team ~= myTeam)
            if hostile then
                local character = player.Character
                local enemyRoot = character and character:FindFirstChild("HumanoidRootPart")
                if enemyRoot and character:GetAttribute("Jumping") then
                    local enemyGap = (enemyRoot.Position.Z - netZ) * side
                    if enemyGap < 0 and -enemyGap <= state.netRange + 4
                        and (ball.Position - enemyRoot.Position).Magnitude <= state.reach
                        and math.abs(enemyRoot.Position.X - root.Position.X) <= state.lateral then
                        return ball, netZ, side
                    end
                end
            end
        end
        return nil
    end

    local function pickMove(ball, netZ, side)
        if state.move ~= "Auto" then return state.move end
        if (ball.Position.Z - netZ) * side > 0 then return "Spike" end
        return "Block"
    end

    local function fire(move)
        if not bind() then return end
        local states = handlers.States
        if states.IsBusy:get() or states.IsStunned:get() or states.IsServing:get() then return end
        if not states.IsPlaying:get() then return end
        if ReplicatedStorage:GetAttribute("ServedByTeam") then return end

        firing = true
        task.spawn(function()
            if state.autoJump and not states.IsJumping:get() then
                elevate(function() controller:PerformJump() end)
            end
            if state.delay > 0 then
                task.wait(state.delay)
            end
            elevate(function()
                controller:DoMove({
                    ActionName = move,
                    IsAerial = true,
                    InputState = Enum.UserInputState.Begin,
                    Metadata = {},
                })
            end)
            lastFire = os.clock()
            firing = false
        end)
    end

    local function step()
        if Library.Unloaded then return end
        if not state.enabled or firing then return end
        if os.clock() - lastFire < state.cooldown then return end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local net = getNet()
        if not net then return end
        local ball, netZ, side = findThreat(root, net)
        if not ball then return end
        fire(pickMove(ball, netZ, side))
    end

    track(RunService.Heartbeat:Connect(step))

    return { state = state }
end)()

local function getNearestTeammate()
    local nearest = nil
    local shortestDistance = math.huge
    local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not playerRoot then return nil end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Team == LocalPlayer.Team then
            local character = player.Character
            if character then
                local rootPart = character:FindFirstChild("HumanoidRootPart")
                if rootPart then
                    local distance = (rootPart.Position - playerRoot.Position).Magnitude
                    if distance < shortestDistance then
                        shortestDistance = distance
                        nearest = player
                    end
                end
            end
        end
    end
    return nearest
end

local function aim()
    if not BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local nearestTeammate = getNearestTeammate()
    if not nearestTeammate then return end
    local targetRoot = nearestTeammate.Character:FindFirstChild("HumanoidRootPart")
    local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not targetRoot or not playerRoot then return end
    local direction = (targetRoot.Position - playerRoot.Position).Unit
    local tiltDir = Vector3.new(direction.X, 1, direction.Z)
    local lookVec = Vector3.new(direction.X, 0, direction.Z)
    if lookVec.Magnitude > 0 then
        lookVec = lookVec.Unit
    else
        lookVec = Vector3.new(0.17569558322429657, 9.214759444375886e-08, -0.9844445586204529)
    end
    local Interact = BallService.RF.Interact
    if Interact then
        Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = "JumpSet",
            ["SpecialCharge"] = 0.9999996364706223,
            ["TiltDirection"] = tiltDir,
            ["LookVector"] = lookVec,
            ["MoveDirection"] = Vector3.new(0, 0, 0),
            ["ClientCanRunSpecial"] = false,
            ["From"] = "Client",
            ["Timestamp"] = tick(),
            ["BallId"] = ballId,
            ["CustomClient"] = {},
        })
    end
end

local function createAimButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    aimButton = Instance.new("TextButton")
    aimButton.Size = UDim2.new(0, 50, 0, 50)
    aimButton.Position = UDim2.new(0.65, -25, 0.8, -25)
    aimButton.BackgroundColor3 = Color3.fromRGB(50, 150, 255)
    aimButton.Text = "Aim"
    aimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    aimButton.TextScaled = true
    aimButton.Font = Enum.Font.GothamBold
    aimButton.Parent = screenGui
    aimButton.BackgroundTransparency = 0.2
    aimButton.BorderSizePixel = 0
    aimButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = aimButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    aimButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = aimButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    aimButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            aimButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    aimButton.MouseButton1Click:Connect(function()
        aim()
    end)
    aimButton.Visible = aimVisible
    return aimButton
end

track(RunService.RenderStepped:Connect(function()
    if not airMovement then
        if bodyVelocity then
            bodyVelocity:Destroy()
            bodyVelocity = nil
        end
        return
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then
        return
    end

    if not bodyVelocity or bodyVelocity.Parent ~= root then
        if bodyVelocity then
            bodyVelocity:Destroy()
        end
        bodyVelocity = Instance.new("BodyVelocity")
        bodyVelocity.Name = MARK
        bodyVelocity.MaxForce = Vector3.zero
        bodyVelocity.Velocity = Vector3.zero
        bodyVelocity.P = 12500
        bodyVelocity.Parent = root
    end

    local direction = humanoid.MoveDirection
    if direction.Magnitude == 0 then
        if seen.__controls == nil then
            local reached, controls = pcall(function()
                return require(LocalPlayer.PlayerScripts.PlayerModule):GetControls()
            end)
            seen.__controls = (reached and controls) or false
        end
        if seen.__controls then
            local read, raw = pcall(seen.__controls.GetMoveVector, seen.__controls)
            if read and typeof(raw) == "Vector3" and raw.Magnitude > 0 then
                local camera = Workspace.CurrentCamera
                if camera then
                    raw = camera.CFrame:VectorToWorldSpace(raw)
                end
                direction = Vector3.new(raw.X, 0, raw.Z)
            end
        end
    end

    if humanoid.FloorMaterial == Enum.Material.Air and direction.Magnitude > 0 then
        bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
        bodyVelocity.Velocity = direction.Unit * airMovementSpeed
    else
        bodyVelocity.MaxForce = Vector3.zero
        bodyVelocity.Velocity = Vector3.zero
    end
end))
local function isEnemy(player)
    if player == LocalPlayer then return false end
    if not player.Team or not LocalPlayer.Team then return false end
    return player.Team ~= LocalPlayer.Team
end

local function applyESP(player)
    if not player.Character or espHighlights[player] then return end
    local tone = Color3.fromRGB(255, 72, 72)
    local highlight = Instance.new("Highlight")
    highlight.Name = MARK
    highlight.Adornee = player.Character
    highlight.FillColor = tone
    highlight.FillTransparency = 0.72
    highlight.OutlineTransparency = 0
    highlight.OutlineColor = tone
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = player.Character
    espHighlights[player] = highlight
end

local function removeESP(player)
    if espHighlights[player] then
        espHighlights[player]:Destroy()
        espHighlights[player] = nil
    end
end

local function cleanupConnections(player)
    if espConnections[player] then
        for _, connection in pairs(espConnections[player]) do
            connection:Disconnect()
        end
        espConnections[player] = nil
    end
    removeESP(player)
end

local function setupESP(player)
    if player == LocalPlayer then return end
    local function onCharacterAdded(character)
        cleanupConnections(player)
        local humanoid = character:WaitForChild("Humanoid", 3)
        local head = character:FindFirstChild("Head")
        if not humanoid or not head then return end
        local stateConnection = humanoid.StateChanged:Connect(function(_, newState)
            if not espJumpEnabled or not isEnemy(player) then
                removeESP(player)
                return
            end
            if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
                applyESP(player)
            elseif newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
                removeESP(player)
            end
        end)
        local heartbeatConnection = RunService.Heartbeat:Connect(function()
            if not espJumpEnabled or not player.Character or not isEnemy(player) then
                removeESP(player)
                return
            end
            local state = humanoid:GetState()
            if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
                applyESP(player)
            else
                removeESP(player)
            end
        end)
        espConnections[player] = { track(stateConnection), track(heartbeatConnection) }
    end
    if player.Character then
        onCharacterAdded(player.Character)
    end
    track(player.CharacterAdded:Connect(onCharacterAdded))
end

for _, player in ipairs(Players:GetPlayers()) do
    setupESP(player)
end
track(Players.PlayerAdded:Connect(setupESP))

local function enableMaxServe()
    maxServeEnabled = true
    if maxServeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxServe", function(callNext, self, method, ...)
        if self == Serve and method == "InvokeServer" and maxServeEnabled then
            local args = {...}
            args[2] = 5
            return callNext(self, method, unpack(args))
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        maxServeHookActive = true
    end
end

local function disableMaxServe()
    maxServeEnabled = false
end

local function leadFeetSlam()
    if not leadFeetEnabled then return end
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local root = character.PrimaryPart
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return end

    local tuning = { Acceleration = -10000, TerminalVelocity = -300, Duration = 2 }
    local controller = nil

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local ability = require(ReplicatedStorage.Content.Ability.LeadFeet)
        if type(ability) == "table" and type(ability.Metadata) == "table" then
            tuning = ability.Metadata
        end
        controller = require(ReplicatedStorage.Packages.Knit).GetController("GameController")
        if controller then
            controller.IsBusy:set(false)
        end
        require(ReplicatedStorage.Content.Effect):Play("LeadFeetFX")({ Player = LocalPlayer })
        require(game:GetService("ReplicatedFirst").Controllers.GameController.Actions.Move.Jump).stop()
        if controller then
            controller.IsBusy:set(true)
        end
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end

    if leadFeetLink then
        leadFeetLink:Disconnect()
        leadFeetLink = nil
    end

    local expiry = os.clock() + (tuning.Duration or 2)
    leadFeetLink = RunService.Heartbeat:Connect(function(delta)
        if not root.Parent or humanoid.FloorMaterial ~= Enum.Material.Air or os.clock() >= expiry then
            if controller then
                controller.IsBusy:set(false)
            end
            if leadFeetLink then
                leadFeetLink:Disconnect()
                leadFeetLink = nil
            end
            return
        end
        local velocity = root.AssemblyLinearVelocity
        local drop = math.max(velocity.Y + (tuning.Acceleration or -10000) * delta, tuning.TerminalVelocity or -300)
        root.AssemblyLinearVelocity = Vector3.new(velocity.X, drop, velocity.Z)
    end)
end

local function createLeadFeetButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    leadFeetButton = Instance.new("TextButton")
    leadFeetButton.Size = UDim2.new(0, 50, 0, 50)
    leadFeetButton.Position = UDim2.new(0.25, -25, 0.8, -25)
    leadFeetButton.BackgroundColor3 = Color3.fromRGB(0, 255, 200)
    leadFeetButton.Text = "LF"
    leadFeetButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    leadFeetButton.TextScaled = true
    leadFeetButton.Font = Enum.Font.GothamBold
    leadFeetButton.Parent = screenGui
    leadFeetButton.BackgroundTransparency = 0.2
    leadFeetButton.BorderSizePixel = 0
    leadFeetButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = leadFeetButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    leadFeetButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = leadFeetButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    leadFeetButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            leadFeetButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    leadFeetButton.MouseButton1Click:Connect(leadFeetSlam)
    leadFeetButton.Visible = false
    return leadFeetButton
end

createLeadFeetButton()

local function loadJerseys()
    jerseyList = {
        "BlueOnesieJersey", "ClassicJersey", "CursedTournamentTop100Jersey", "CursedTournamentTop1Jersey", "CursedTournamentTop1KJersey", "DragonTuxedoJersey", "NeonJersey", "PajamasJersey", "PastelJersey", "PinkOnesieJersey", "PirateJersey", "RainbowJersey", "RefJersey", "SkeletonJersey", "SkeletonJerseySeason19", "SparkleTimeJersey", "T1TournamentJersey", "TournamentJersey", "TournamentTop100BeachJersey", "TournamentTop10BeachJersey", "TournamentTop1BeachJersey", "TuxedoJersey", "VampireJersey"
    }
    return jerseyList
end

loadJerseys()

local function loadBallSkins()
    ballSkinList = {
        "2026ChocolateEggBall", "2026EasterEggBall", "AcornBall", "AlienBall", "AngelHeadBall", "AngelicBall", "AngryEmojiBall", "AnimeVolleyBall", "ArrowBall", "AuroraBall", "BananaBall", "Basketball", "BeachBall", "BeachGlobeBall", "BlackBall", "BlueAndYellowBall", "BooBall", "BrainBall", "BronzeCannonBall", "BronzeCloverBall", "BronzeCoconutBall", "BronzeEggBall", "BronzeFestivalBall", "BronzeHeartBall", "BronzeOrnamentBall", "BronzeRibcageBall", "BronzeSeashellBall", "BunnyBall", "BunnyEggBall", "CakeBall", "CameraBall", "CandleBall", "CauldronBall", "CelestialOrbBall", "ChocolateBunnyHeadBall", "ChocolateCoveredBall", "ChocolateCoveredNerdBall", "ChocolateEggBall", "ChocolateHeartBall", "ChristmasLightsBall", "ClassicBall", "CloverBall", "ClownBall", "CoalBall", "CoconutBall", "CoralReefBall", "CrabBall", "CrackedBall", "CrackedEasterEggBall", "CraftyBall", "CryoFlareBall", "CursedKrakenEyeBall", "CuteKittyBall", "DarkBatBall", "DecoratedEasterEggBall", "DemonBall", "DevilBall", "DevilHeadBall", "DiamondAcornBall", "DiamondBall", "DiamondCannonBall", "DiamondCloverBall", "DiamondCoconutBall", "DiamondEggBall", "DiamondEyeBall", "DiamondFestivalBall", "DiamondHeartBall", "DiamondRibcageBall", "DiamondSantaBall", "DiamondSeashellBall", "DiamondSnowGlobeBall", "DiamondSnowmanBall", "DiscoBall", "EasterEggBall", "ElectrifiedBall", "EvilEyeBall", "FestivalBall", "FlameBall", "FlowerBall", "FlowerBlossomBall", "FourLeafCloverBall", "Frostball", "GalaxyBall", "GamerBall", "GhostBall", "GiftBall", "GingerbreadBall", "GodBall", "GoldCannonBall", "GoldCoconutBall", "GoldCoinBall", "GoldFestivalBall", "GoldHeartBall", "GoldRibcageBall", "GoldSeashellBall", "GoldenBall", "GoldenClockBall", "GoldenCloverBall", "GoldenDiamondBall", "GoldenEggBall", "GoldenPearlBall", "GoldenSkullBall", "GoldenSnowmanBall", "GoldenStarBall", "GoldenSunEggBall", "GradientBall", "HackerBall", "HamburgerBall", "HauntedBall", "HeadBall", "HeartBall", "HologramBall", "HolyHellBall", "HorseshoeBall", "HourglassBall", "IceCreamBall", "JellyfishBall", "KarasunoBall", "KareemBall", "KoiBall", "Level150Ball", "Level50Ball", "LifebuoyBall", "MagicCrystalBall", "MangoBall", "MechBall", "MoneyBall", "MonkeyBall", "MoonBall", "MoonFireBall", "NebulaBall", "NerdBall", "NewYearsDragonBall", "NinjaBall", "OrnamentBall", "OvergrownCrystalBall", "PaintSplatterBall", "PartyHatBall", "PartySunglassesBall", "PastelSwirlEggBall", "PearlBall", "PhantomBall", "PhoenixBall", "PhonkBall", "PinataBall", "PineappleBall", "PinkBall", "PinkBlossomBall", "PinkFlamingoBall", "PinkSummerHatBall", "PirateHatBall", "PixelBall", "PolyhedralBall", "PotOfGoldBall", "PotionBall", "PumpkinBall", "PurplePhoenixBall", "RainbowBall", "RainbowPrismBall", "RattlingJawBall", "ReaperBall", "RedDragonBall", "RedEyeBall", "RedGreenAndWhiteBall", "ReindeerBall", "RigBall", "RippedBall", "RubberDuckyBall", "SaturnBall", "ScarecrowBall", "ShellBall", "ShinyBunnyEggBall", "ShinyChocolateEggBall", "SilverBall", "SilverCannonBall", "SilverCloverBall", "SilverCoconutBall", "SilverEggBall", "SilverFestivalBall", "SilverHeartBall", "SilverLanternBall", "SilverMikageHeadBall", "SilverRibbonBall", "SilverRibcageBall", "SilverSeashellBall", "SilverTurkeyBall", "SlimeBall", "SnowGlobeBall", "Snowball", "SnowmanBall", "SoccerBall", "SoulBall", "SpikyBall", "SpiritBall", "StainedGlassBall", "SubspaceBall", "SummerHatBall", "SunBall", "SunglassesBall", "SuperSunBall", "TennisBall", "TigerBall", "TimeBall", "TitaniumBall", "TranslucentTurkeyBall", "TrollFaceBall", "TurkeyBall", "TuxedoBall", "UltraFastModeBall", "VIPBall", "ValentineCardBall", "WaterBall", "WhiteEggBall", "WingedBall", "WizardHatBall"
    }
    return ballSkinList
end

loadBallSkins()

local function applyJersey(id)
    local character = LocalPlayer.Character
    if not character or not character:FindFirstChild("UpperTorso") then
        return false
    end

    local jerseyFolder = ReplicatedStorage:FindFirstChild("Assets")
    jerseyFolder = jerseyFolder and jerseyFolder:FindFirstChild("Jersey")
    if not jerseyFolder then
        return false
    end

    if not seen.__jerseyHook then
        seen.__jerseyChar = character
        seen.__jerseyHook = track(LocalPlayer.CharacterAdded:Connect(function(character2)
            local oldChar = seen.__jerseyChar
            if oldChar and oldChar ~= character2 then
                originals[oldChar] = nil
            end
            seen.__jerseyChar = character2
            pickedTeam = nil
            if character2:WaitForChild("UpperTorso", 10) and autoApplyJersey then
                task.wait(1)
                applyJersey(selectedJersey)
            end
        end))
    end

    local function clearWorn()
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child.Name == "_jerseyInstances"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                child:Destroy()
            end
        end
    end

    if not autoApplyJersey then
        local backup = originals[character]
        if backup then
            clearWorn()
            for _, saved in ipairs(backup) do
                local restored = saved:Clone()
                if restored:IsA("SurfaceGui") then
                    restored.Adornee = character:FindFirstChild("UpperTorso")
                end
                restored.Parent = character
            end
            originals[character] = nil
        end
        pickedTeam = nil
        return true
    end

    if not originals[character] then
        local backup = {}
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                table.insert(backup, child:Clone())
            end
        end
        originals[character] = backup
    end

    local function resolveTeam()
        local worn = character:FindFirstChildOfClass("Shirt")
        if not worn then
            return nil
        end
        for _, asset in ipairs(jerseyFolder:GetChildren()) do
            for _, team in ipairs(asset:GetChildren()) do
                local shirt = team:FindFirstChild("Shirt")
                if shirt and shirt:IsA("Shirt") and shirt.ShirtTemplate == worn.ShirtTemplate then
                    return team.Name
                end
            end
        end
        return nil
    end

    local loaded, Jersey = pcall(require, ReplicatedStorage.Tools.Jersey)
    if not loaded or type(Jersey) ~= "table" or not Jersey.set then
        return false
    end

    pickedTeam = pickedTeam or resolveTeam()

    local applied, err = pcall(Jersey.set, {
        Player = LocalPlayer,
        Character = character,
        Id = id or selectedJersey,
        TeamName = pickedTeam,
    })
    if not applied then
        warn("[TWINHUB] jersey apply failed: " .. tostring(err))
        return false
    end

    pickedTeam = pickedTeam or resolveTeam()
    return true
end

local function sweep()
    local ballFolder = ReplicatedStorage:FindFirstChild("Assets")
    ballFolder = ballFolder and ballFolder:FindFirstChild("Ball")
    if not ballFolder then
        return
    end

    local function strip(model)
        local holder = clones[model]
        if holder then
            holder:Destroy()
            clones[model] = nil
        end
        local saved = originals[model]
        if saved then
            for piece, record in pairs(saved) do
                if piece.Parent then
                    pcall(function()
                        piece[record.field] = record.value
                    end)
                end
            end
            originals[model] = nil
        end
    end

    local function skin(model)
        local driver = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
        local source = ballFolder:FindFirstChild(selectedBallSkin)
        if not driver or not source then
            return
        end

        strip(model)

        local saved = {}
        local function stash(piece, field, value)
            saved[piece] = { field = field, value = piece[field] }
            piece[field] = value
        end
        for _, piece in ipairs(model:GetDescendants()) do
            if piece:IsA("BasePart") then
                if piece.Name ~= MARK then
                    stash(piece, "Transparency", 1)
                end
            elseif piece:IsA("Decal") or piece:IsA("Texture") then
                stash(piece, "Transparency", 1)
            elseif piece:IsA("Trail") or piece:IsA("ParticleEmitter") or piece:IsA("Beam") or piece:IsA("Light") or piece:IsA("Smoke") or piece:IsA("Fire") or piece:IsA("Sparkles") then
                stash(piece, "Enabled", false)
            end
        end
        originals[model] = saved

        local holder = source:Clone()
        holder.Name = MARK2
        holder.Parent = model
        local pieces = {}
        if holder:IsA("BasePart") then
            pieces[#pieces + 1] = holder
        end
        for _, candidate in ipairs(holder:GetDescendants()) do
            if candidate:IsA("BasePart") then
                pieces[#pieces + 1] = candidate
            end
        end

        local anchor = holder:IsA("Model") and holder.PrimaryPart or nil
        if not anchor then
            local bestScore
            for _, candidate in ipairs(pieces) do
                if candidate:IsA("BasePart") then
                    local vol = candidate.Size.X * candidate.Size.Y * candidate.Size.Z
                    local roundish = math.abs(candidate.Size.X - candidate.Size.Y) < 0.5 and math.abs(candidate.Size.Y - candidate.Size.Z) < 0.5
                    local score = vol
                    if candidate:IsA("Part") and candidate.Shape == Enum.PartType.Ball then
                        score = score * 6
                    elseif roundish then
                        score = score * 3
                    end
                    if not bestScore or score > bestScore then
                        bestScore = score
                        anchor = candidate
                    end
                end
            end
        end
        if anchor then
            local offset = holder:GetPivot():ToObjectSpace(anchor.CFrame)
            holder:PivotTo(driver.CFrame * offset:Inverse())
        else
            holder:PivotTo(driver.CFrame)
        end

        for _, part in ipairs(pieces) do
            part.Anchored = false
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            part.Massless = true
            local weld = Instance.new("WeldConstraint")
            weld.Part0 = driver
            weld.Part1 = part
            weld.Parent = part
        end

        clones[model] = holder
    end

    local tracked = {}
    for model in pairs(clones) do
        table.insert(tracked, model)
    end
    for _, model in ipairs(tracked) do
        strip(model)
    end

    if not autoApplyBallSkin then
        return
    end

    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_") then
            skin(model)
        end
    end

    if not seen.__ballHook then
        seen.__ballHook = Workspace.ChildAdded:Connect(function(child)
            if not autoApplyBallSkin or not child:IsA("Model") or not child.Name:match("^CLIENT_BALL_") then
                return
            end
            task.spawn(function()
                for _ = 1, 40 do
                    if child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart") then
                        break
                    end
                    task.wait(0.05)
                end
                if autoApplyBallSkin and child.Parent then
                    sweep()
                end
            end)
        end)
    end
end

local Kisuki = { enabled = false, hooked = false, charge = 1 }

Kisuki.effect = function(strong)
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local effects = assets and assets:FindFirstChild("Effects")
    local module = effects and effects:FindFirstChild("SuperDive")
    if not module then return end

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        task.spawn(require(module), character, { IsStrong = strong })
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

Kisuki.install = function()
    if Kisuki.hooked then return end
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, controller = pcall(Knit.GetController, "GameController")
    if not found or type(controller) ~= "table" or type(controller.Dive) ~= "function" then return end

    local passthrough = controller.Dive
    controller.Dive = function(self, params, ...)
        if not Kisuki.enabled then
            return passthrough(self, params, ...)
        end

        local blend = math.clamp(Kisuki.charge, 0, 1)
        local styled, special = pcall(require, ReplicatedStorage.Content.Style.Kimiro.Special)
        local tuning = styled and type(special) == "table" and special.Metadata
        if type(tuning) == "table" then
            params = type(params) == "table" and params or {}
            params.MaxForce = tuning.MaxForce
            params.TimeScale = tuning.TimeScale
            params.StretchSpeedFactor = tuning.StretchSpeedFactor
            params.EasingStyle = tuning.EasingStyle
            params.Debounce = tuning.Debounce
            if not params.Target and typeof(tuning.Power) == "NumberRange" then
                local character = LocalPlayer.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                local heading = humanoid and humanoid.MoveDirection or Vector3.zero
                if heading.Magnitude < 0.5 and character then
                    heading = character:GetPivot().LookVector
                end
                heading = Vector3.new(heading.X, 0, heading.Z)
                if heading.Magnitude > 0.01 then
                    local reach = tuning.Power.Min + (tuning.Power.Max - tuning.Power.Min) * blend
                    params.Target = heading.Unit * reach
                end
            end
        end

        local outcome = passthrough(self, params, ...)
        if outcome ~= nil then
            Kisuki.effect(blend >= 0.5)
        end
        return outcome
    end
    Kisuki.hooked = true
end

local Vault = { real = nil, want = {} }

Vault.mark = function(kind, on)
    Vault.want[kind] = on or nil
    if on then
        Vault.wear()
    end

    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Inventory then return end

    local held, current = pcall(function()
        return inventory.Inventory:get()
    end)
    if not held or type(current) ~= "table" then return end

    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = type(genv.TWINHUB_SESSION) == "table" and genv.TWINHUB_SESSION or nil

    if not Vault.real then
        local carried = session and session.vault or nil
        if carried and carried.inventory then
            Vault.real = carried.inventory
            Vault.realTitle = carried.title
            Vault.realEquipped = carried.equipped or {}
        else
            local snapshot = {}
            for id, count in pairs(current) do
                snapshot[id] = count
            end
            Vault.real = snapshot
            Vault.realTitle = LocalPlayer:GetAttribute("User_Title")
            local heldWorn, worn = pcall(function()
                return inventory.Equipped:get()
            end)
            local realEquipped = {}
            if heldWorn and type(worn) == "table" then
                for slot, value in pairs(worn) do
                    realEquipped[slot] = value
                end
            end
            Vault.realEquipped = realEquipped
            if session then
                session.vault = {
                    inventory = Vault.real,
                    title = Vault.realTitle,
                    equipped = Vault.realEquipped,
                }
            end
        end
    end

    local wanted = false
    for _ in pairs(Vault.want) do
        wanted = true
        break
    end
    if not wanted then
        pcall(function()
            inventory.Inventory:set(Vault.real)
        end)
        Vault.real = nil
        if session then
            session.vault = nil
        end
        return
    end

    local catalogued, Item = pcall(require, ReplicatedStorage.Content.Item)
    local entities = ReplicatedStorage.Content.Item:FindFirstChild("Entities")
    if not catalogued or not entities then return end

    local stocked = {}
    for id, count in pairs(Vault.real) do
        stocked[id] = count
    end
    for _, child in ipairs(entities:GetChildren()) do
        if child:IsA("ModuleScript") and not stocked[child.Name] then
            local read, entry = pcall(require, child)
            if read and type(entry) == "table" and entry.Type then
                for kindName in pairs(Vault.want) do
                    if entry.Type == Item.Type[kindName] then
                        stocked[child.Name] = 1
                        break
                    end
                end
            end
        end
    end
    pcall(function()
        inventory.Inventory:set(stocked)
    end)
end

Vault.typeOf = function(id)
    local module = ReplicatedStorage.Content.Item:FindFirstChild("Entities")
    module = module and module:FindFirstChild(id)
    if not module then return nil end
    local read, entry = pcall(require, module)
    if read and type(entry) == "table" and entry.Type then
        return entry.Type, entry
    end
    return nil
end

Vault.paint = function(kind, id, entry)
    local real = Vault.realEquipped or {}
    if kind == "Title" then
        pcall(function()
            local text = id and ((entry and entry.DisplayName) or id) or Vault.realTitle
            LocalPlayer:SetAttribute("User_Title", text)
        end)
    elseif kind == "ScoreEffect" then
        selectedEffect = id or real.ScoreEffect or "SupernovaScoreEffect"
    elseif kind == "Ball" then
        selectedBallSkin = id or real.Ball or "ClassicBall"
        task.spawn(function()
            pcall(sweep)
        end)
    elseif kind == "Jersey" then
        selectedJersey = id or real.Jersey or "DragonTuxedoJersey"
        pickedTeam = nil
        task.spawn(function()
            pcall(applyJersey, selectedJersey)
        end)
    elseif kind == "PlayerCard" then
        selectedCard = id or real.PlayerCard or "UltimateChampionPlayerCard"
        task.spawn(function()
            pcall(fireCardRemote)
        end)
    end
end

Vault.setSlot = function(kind, id)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if not held or type(worn) ~= "table" then return end
    local dressed = {}
    for slot, value in pairs(worn) do
        dressed[slot] = value
    end
    dressed[kind] = id
    pcall(function()
        inventory.Equipped:set(dressed)
    end)
end

Vault.currentSlot = function(kind)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return nil end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return nil end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if held and type(worn) == "table" then
        return worn[kind]
    end
    return nil
end

Vault.dress = function(id)
    local kind, entry = Vault.typeOf(id)
    if not kind then return false end
    if kind == "Title" or kind == "ScoreEffect" or kind == "Ball" or kind == "Jersey" or kind == "PlayerCard" then
        Vault.paint(kind, id, entry)
    elseif kind ~= "ProfileArt" then
        return false
    end
    Vault.setSlot(kind, id)
    return true
end

Vault.revert = function(kind)
    local realId = Vault.realEquipped and Vault.realEquipped[kind] or nil
    Vault.paint(kind, nil)
    Vault.setSlot(kind, realId)
end

Vault.wear = function()
    if Vault.worn then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local located, remote = pcall(function()
        return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.InventoryService.RF.Equip
    end)
    if not located or not remote then return end

    local hooked = hookNamecall("vaultEquip", function(callNext, self, method, ...)
        if self == remote and method == "InvokeServer" then
            local id = (...)
            if type(id) == "string" and Vault.real then
                local kind, entry = Vault.typeOf(id)
                if not Vault.real[id] then
                    if kind and Vault.currentSlot(kind) == id then
                        Vault.revert(kind)
                        return true
                    end
                    Vault.dress(id)
                    return true
                elseif kind then
                    Vault.paint(kind, id, entry)
                end
            end
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        Vault.worn = true
    end
end

local Landing = {
    enabled = false,
    marker = nil,
    label = nil,
    tracked = nil,
    last = nil,
    stamp = 0,
    drift = Vector3.zero,
}

Landing.clear = function()
    if Landing.marker then
        Landing.marker:Destroy()
        Landing.marker = nil
        Landing.label = nil
    end
    Landing.tracked = nil
    Landing.last = nil
    Landing.drift = Vector3.zero
end

Landing.build = function()
    local disc = Instance.new("Part")
    disc.Name = MARK
    disc.Shape = Enum.PartType.Cylinder
    disc.Size = Vector3.new(0.2, 7, 7)
    disc.Anchored = true
    disc.CanCollide = false
    disc.CanQuery = false
    disc.CanTouch = false
    disc.Material = Enum.Material.Neon
    disc.Transparency = 0.35
    disc.CastShadow = false
    disc.Parent = Camera

    local board = Instance.new("BillboardGui")
    board.Size = UDim2.new(0, 90, 0, 30)
    board.StudsOffset = Vector3.new(0, 4, 0)
    board.AlwaysOnTop = true
    board.Parent = disc

    local text = Instance.new("TextLabel")
    text.Size = UDim2.fromScale(1, 1)
    text.BackgroundTransparency = 1
    text.TextScaled = true
    text.Font = Enum.Font.GothamBold
    text.TextStrokeTransparency = 0
    text.Parent = board

    Landing.marker = disc
    Landing.label = text
end

Landing.gravity = function()
    local pulled, value = pcall(function()
        local Game = require(ReplicatedStorage.Configuration.Game)
        local State = require(ReplicatedStorage.Common.State)
        return State.get(ReplicatedStorage, State.Id.Modifier, "BallGravity", Game.Physics.Gravity)
    end)
    if pulled and type(value) == "number" and value > 0 then
        return value
    end
    return 17
end

Landing.velocity = function(part)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if reached then
        local found, controller = pcall(Knit.GetController, "BallController")
        if found and type(controller) == "table" and type(controller.ActiveBalls) == "table" then
            for _, record in pairs(controller.ActiveBalls) do
                local model = record.Ball
                if model and model.Parent and model:IsAncestorOf(part) and typeof(record.Velocity) == "Vector3" then
                    return record.Velocity
                end
            end
        end
    end
    return Landing.drift
end

Landing.solve = function(pos, vel, gravity, floorY)
    local drop = pos.Y - floorY
    if drop < 0 then return nil end
    local disc = vel.Y * vel.Y + 2 * gravity * drop
    if disc < 0 then return nil end
    local flight = (vel.Y + math.sqrt(disc)) / gravity
    if flight ~= flight or flight <= 0 or flight > 15 then return nil end
    return flight
end

Landing.netHit = function(pos, vel, gravity, flight)
    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    if not net then return false end
    local netZ = net.Position.Z
    local gap = netZ - pos.Z
    if math.abs(vel.Z) < 0.01 then return false end
    local moment = gap / vel.Z
    if moment <= 0 or moment >= flight then return false end
    local height = pos.Y + vel.Y * moment - 0.5 * gravity * moment * moment
    local across = pos.X + vel.X * moment
    local top = net.Position.Y + net.Size.Y * 0.5
    local base = net.Position.Y - net.Size.Y * 0.5
    if height > top or height < base then return false end
    return math.abs(across - net.Position.X) <= net.Size.X * 0.5
end

Landing.predict = function(ball)
    local reached, module = pcall(require, ReplicatedStorage.Common.Physics)
    if not reached then return nil end

    local gravity = Landing.gravity()
    local pos = ball.Position
    local vel = Landing.velocity(ball)
    if typeof(vel) ~= "Vector3" then return nil end

    local floorY = module.LastFloorHeight
    if not floorY then
        local found, height = pcall(module.calculateFloorHeight, pos, true)
        floorY = found and height or nil
    end
    if not floorY then return nil end

    local flight = Landing.solve(pos, vel, gravity, floorY)
    if not flight then return nil end

    local spot = Vector3.new(pos.X + vel.X * flight, floorY, pos.Z + vel.Z * flight)
    local probed, ground = pcall(module.calculateFloorHeight, Vector3.new(spot.X, pos.Y, spot.Z), true)
    if probed and type(ground) == "number" and math.abs(ground - floorY) > 0.05 then
        local refined = Landing.solve(pos, vel, gravity, ground)
        if refined then
            flight = refined
            spot = Vector3.new(pos.X + vel.X * flight, ground, pos.Z + vel.Z * flight)
        end
    end

    return spot, module, flight, Landing.netHit(pos, vel, gravity, flight)
end

track(RunService.RenderStepped:Connect(function()
    if not Landing.enabled then
        if Landing.marker then Landing.clear() end
        return
    end

    local ball = getNearestBall()
    if not ball then
        if Landing.marker then Landing.marker.Transparency = 1 end
        Landing.last = nil
        return
    end

    local now = os.clock()
    if Landing.tracked == ball and Landing.last and now > Landing.stamp then
        Landing.drift = (ball.Position - Landing.last) / (now - Landing.stamp)
    end
    Landing.tracked = ball
    Landing.last = ball.Position
    Landing.stamp = now

    local spot, physics, flight, netted = Landing.predict(ball)
    if not spot then
        if Landing.marker then Landing.marker.Transparency = 1 end
        return
    end

    if not Landing.marker then Landing.build() end
    local bounds = physics._getCourtlines and physics._getCourtlines()
    local inside = true
    if bounds and physics.isPositionInCourt then
        local ok, verdict = pcall(physics.isPositionInCourt, spot, nil, ball.Size.X * 0.5, nil)
        inside = not ok or verdict
    end

    local tone, verdictText
    if netted then
        tone = Color3.fromRGB(250, 180, 40)
        verdictText = "NET"
    elseif inside then
        tone = Color3.fromRGB(60, 220, 90)
        verdictText = "IN"
    else
        tone = Color3.fromRGB(235, 60, 60)
        verdictText = "OUT"
    end

    local urgency = math.clamp(1 - flight / 2, 0, 1)
    local span = 6 + urgency * 3
    Landing.marker.Size = Vector3.new(0.2, span, span)
    Landing.marker.Transparency = 0.35 - urgency * 0.15
    Landing.marker.Color = tone
    Landing.marker.CFrame = CFrame.new(spot + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
    Landing.label.Text = verdictText .. "  " .. string.format("%.1fs", flight)
    Landing.label.TextColor3 = tone
end))

local effectList = {}
local function loadEffects()
    effectList = {
        "2026ScoreEffect", "AtomicExplosionScoreEffect", "AuroraScoreEffect", "BallPortalScoreEffect", "BananaSlipScoreEffect", "BeachSpiralScoreEffect", "BeachSplashScoreEffect", "BeatOfMadnessScoreEffect", "BinaryScoreEffect", "BlackHoleScoreEffect", "BloodMoonScoreEffect", "BlueHeartScoreEffect", "BotFaceEmojiScoreEffect", "BubbleScoreEffect", "BunnyHopScoreEffect", "CandyCaneScoreEffect", "CandyCrunchScoreEffect", "CannonBallRainScoreEffect", "CauldronSplashScoreEffect", "ChickScoreEffect", "ChocolateBeamScoreEffect", "ChocolateEggHatchingScoreEffect", "ChocolateSpiralScoreEffect", "ChocolateSplashScoreEffect", "CloudburstScoreEffect", "ColonThreeScoreEffect", "ColorfulFireScoreEffect", "CombiningHeartsScoreEffect", "ConfettiBurstScoreEffect", "CookieSplashScoreEffect", "CoolBunnyScoreEffect", "CoralScoreEffect", "CosmicSpiralScoreEffect", "CrabBeamScoreEffect", "CrabScurryScoreEffect", "CryoFlareScoreEffect", "CursedCrateScoreEffect", "CursedScoreEffect", "CyberWaveScoreEffect", "DarkStarScoreEffect", "DiamondScoreEffect", "DivineStrikeScoreEffect", "DynamiteScoreEffect", "EasterBeamScoreEffect", "EasterEggBasketScoreEffect", "EasterSwirlScoreEffect", "EggHatchScoreEffect", "EggMeteorScoreEffect", "EggRainScoreEffect", "ElectricScoreEffect", "EverybodyDanceScoreEffect", "FallingAcornScoreEffect", "FallingAnchorScoreEffect", "FallingAnvilScoreEffect", "FallingPianoScoreEffect", "FishExplosionScoreEffect", "FistSlamScoreEffect", "FlameScoreEffect", "FlamethrowerScoreEffect", "FloppyFishScoreEffect", "FountainScoreEffect", "FourLeafCloverSpiralScoreEffect", "GenieLampScoreEffect", "GhostVortexScoreEffect", "GiantEggDropScoreEffect", "GiantPlayerScoreEffect", "GiantSoccerKickScoreEffect", "GiantTongueScoreEffect", "GlowStickDanceScoreEffect", "GobbleStormScoreEffect", "GoldCoinPopScoreEffect", "GoldScoreEffect", "GoldenConfettiBurstScoreEffect", "GoldenEggPopScoreEffect", "GoldenWaveScoreEffect", "GravyWaveScoreEffect", "GreenEnergyScoreEffect", "GroundCrackScoreEffect", "HakkaScoreEffect", "HeartBeamScoreEffect", "HeartBubbleScoreEffect", "HeartScoreEffect", "HoneyScoreEffect", "IceCreamScoreEffect", "IceScoreEffect", "JohnDoeScoreEffect", "KittySpiralScoreEffect", "KrakenPullScoreEffect", "LaughingScoreEffect", "LavaSplashScoreEffect", "LeafExplosionScoreEffect", "Level100ScoreEffect", "Level200ScoreEffect", "LightShowScoreEffect", "LightningStrikeScoreEffect", "LuckyCloverScoreEffect", "LuckyStrikeScoreEffect", "MagicBurstScoreEffect", "MegaSunbeamScoreEffect", "MetaBlastScoreEffect", "MeteorScoreEffect", "MoneyExplosionScoreEffect", "MoonlightBeamScoreEffect", "MusicNoteStormScoreEffect", "NewYearsWrathScoreEffect", "NinjaStarScoreEffect", "NorthStarScoreEffect", "NukeScoreEffect", "OceanicSpiralScoreEffect", "PalmTreeHammockScoreEffect", "PastelRainbowScoreEffect", "PastelSwirlScoreEffect", "PineappleScoreEffect", "PinkCosmicSpiralScoreEffect", "PinkHeartScoreEffect", "PixelExplosionScoreEffect", "PlayerBubbleScoreEffect", "PlushieScoreEffect", "PotExplosionScoreEffect", "PotionSplashScoreEffect", "PumpkinPieBurstScoreEffect", "PumpkinSmashScoreEffect", "RainbowScoreEffect", "RainbowStarScoreEffect", "RainbowStrikeScoreEffect", "RandomFavoriteScoreEffect", "RankedWinsScoreEffect", "RedDragonScoreEffect", "RosePetalScoreEffect", "SantasWrathScoreEffect", "SeaCreatureExplosionScoreEffect", "Season0ProScoreEffect", "Season10ProScoreEffect", "Season11ProScoreEffect", "Season12ProScoreEffect", "Season13ProScoreEffect", "Season14ProScoreEffect", "Season15ProScoreEffect", "Season16ProScoreEffect", "Season17ProScoreEffect", "Season18ProScoreEffect", "Season19ProScoreEffect", "Season1ProScoreEffect", "Season2ProScoreEffect", "Season3ProScoreEffect", "Season4ProScoreEffect", "Season5ProScoreEffect", "Season6ProScoreEffect", "Season7ProScoreEffect", "Season8ProScoreEffect", "Season9ProScoreEffect", "ShockwaveBlastScoreEffect", "SixSeven2ScoreEffect", "SixSevenScoreEffect", "SkeletonGrabScoreEffect", "SkullScoreEffect", "SlimeSplashScoreEffect", "SnowTornadoScoreEffect", "SpellCasterScoreEffect", "SpiderInfestationScoreEffect", "SpiritExplosionScoreEffect", "SpringSunScoreEffect", "StPatricksBurstScoreEffect", "StormyWaveScoreEffect", "StrobeLightScoreEffect", "SupernovaScoreEffect", "TapDancerScoreEffect", "ThunderstormScoreEffect", "TimeStopperEasterScoreEffect", "TimeStopperScoreEffect", "TongueScoreEffect", "TrampolineScoreEffect", "TreasureChestScoreEffect", "TsunamiScoreEffect", "VioletBeamScoreEffect", "WaterSplashScoreEffect", "WatermelonSmashScoreEffect", "WhirlpoolScoreEffect", "WindBurstScoreEffect", "WolfEmojiScoreEffect", "XDScoreEffect", "XylophoneScoreEffect"
    }
    table.sort(effectList)
    return effectList
end

effectList = loadEffects()

local cardList = {}
local function loadCards()
    cardList = {}
    local ItemEntities = ReplicatedStorage.Content.Item.Entities
    if ItemEntities then
        for _, child in ipairs(ItemEntities:GetChildren()) do
            if child:IsA("ModuleScript") then
                local name = child.Name
                if string.match(name, "Card") or string.match(name, "PlayerCard") then
                    table.insert(cardList, name)
                end
            end
        end
    end
    table.sort(cardList)
    if #cardList == 0 then
        table.insert(cardList, "ContentCreatorPlayerCard")
    end
    return cardList
end

cardList = loadCards()

local function enableHitEffect()
    if hitConnection then return end
    hasFired = false
    isLocalHit = false
    local lastHitTime = 0
    local Remote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.HitGround
    Remote.OnClientEvent:Connect(function(...)
        local args = {...}
        local myName = LocalPlayer.Name
        for _, val in pairs(args) do
            if tostring(val) == myName then
                isLocalHit = true
                break
            end
        end
    end)
    local function fireHitRemote(hitPos)
        if hasFired then return end
        if not isLocalHit then return end
        if not hitEffectEnabled then return end
        if os.clock() - lastHitTime <= 0.5 then return end
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root and root.AssemblyLinearVelocity.Magnitude > 50 then return end
        lastHitTime = os.clock()
        hasFired = true
        local myUsername = LocalPlayer.Name
        local targetObject = workspace:FindFirstChild(myUsername) or workspace:FindFirstChild("uwuwuwiiwuw6")
        local effectId = selectedEffect
        local hardHit = true
        if effectId == "GroundHit1" or effectId == "GroundHit2" then
            hardHit = effectId == "GroundHit2"
            effectId = nil
        end
        if firesignal then
            firesignal(Remote.OnClientEvent, table.unpack({
                hitPos,
                hardHit,
                false,
                5,
                effectId,
                targetObject,
                Vector3.new(-0.000002088591600113432, 1, -0.000004710930170404026)
            }, 1, 7))
        end
        task.wait(0.5)
        hasFired = false
        isLocalHit = false
    end
    hitConnection = workspace.ChildAdded:Connect(function(child)
        if child.Name == "HitIndicator" then
            if child.Color == Color3.fromRGB(0, 255, 0) then
                fireHitRemote(child.Position)
            end
        end
    end)
    hitConnection2 = workspace.DescendantAdded:Connect(function(child)
        if child.Name == "HitIndicator" and child:IsA("BasePart") then
            if child.Color == Color3.fromRGB(0, 255, 0) then
                fireHitRemote(child.Position)
            end
        end
    end)
    hitRemovedConnection = workspace.DescendantRemoving:Connect(function(child)
        if child.Name == "HitIndicator" then
            hasFired = false
            isLocalHit = false
        end
    end)
end

local function setupCharacter(character)
    local humanoid = character:WaitForChild("Humanoid")
    local rootPart = character:WaitForChild("HumanoidRootPart")
    
    if shiftLockConnection then
        shiftLockConnection:Disconnect()
        shiftLockConnection = nil
    end

    shiftLockConnection = humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
        if humanoid.Jump and (autoShiftLockEnabled or AutoCorner.enabled) then
            task.defer(function()
                local tracked = AutoCorner.enabled and getNearestBall()
                local before = tracked and tracked.Position
                local stamp = os.clock()
                task.wait(0.03)
                if tracked and before and tracked.Parent then
                    AutoCorner.trackBall(tracked, before, os.clock() - stamp)
                end
                local lookVector = AutoCorner.enabled and AutoCorner.facing()
                if not lookVector and autoShiftLockEnabled then
                    lookVector = Vector3.new(Camera.CFrame.LookVector.X, 0, Camera.CFrame.LookVector.Z)
                end
                if lookVector and lookVector.Magnitude > 0 then
                    AutoCorner.steer = lookVector
                    if autoShiftLockEnabled or AutoCorner.enabled then
                        rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + lookVector.Unit)
                        humanoid.AutoRotate = false
                    end
                end
            end)
        else
            humanoid.AutoRotate = false
        end
    end)
end

local function toggleShiftLock(state)
    autoShiftLockEnabled = state
    if not state then
        local char = LocalPlayer.Character
        if char then
            local humanoid = char:FindFirstChild("Humanoid")
            if humanoid then
                humanoid.AutoRotate = false
            end
        end
    end
end

if LocalPlayer.Character then
    setupCharacter(LocalPlayer.Character)
end
track(LocalPlayer.CharacterAdded:Connect(setupCharacter))

local function doFakeSpike()
    if not fakeSpikeEnabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    if _AC and _AC.PlayAnimation then
        hum.Jump = true
        _AC:PlayAnimation("SpikeJump")

        task.delay(0.28, function()
            _AC:PlayAnimation("Spike")
        end)
    end
end

track(UserInputService.JumpRequest:Connect(function()
    if fakeSpikeEnabled then
        doFakeSpike()
    end
end))

local function startAutoSpin()
    coroutine.wrap(function()
        while autoSpin do
            local currentStyle = LocalPlayer.PlayerGui.Interface.Lobby.Styles.TopPanel.DisplayName.Text
            for _, style in ipairs(desiredStyles) do
                if currentStyle == style then
                    autoSpin = false
                    return
                end
            end
            local args = { [1] = (spinType == "Lucky") }
            local StyleService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.StyleService
            if StyleService then
                local RF = StyleService:FindFirstChild("RF")
                if RF then
                    local Roll = RF:FindFirstChild("Roll")
                    if Roll then
                        Roll:InvokeServer(unpack(args))
                    end
                end
            end
            task.wait(0)
        end
    end)()
end

local function startAutoAbilitySpin()
    coroutine.wrap(function()
        while autoAbilitySpin do
            local currentAbility = LocalPlayer.PlayerGui.Interface.Lobby.Abilities.TopPanel.DisplayName.Text
            for _, ability in ipairs(desiredAbilities) do
                if currentAbility == ability then
                    autoAbilitySpin = false
                    return
                end
            end
            local args = { [1] = (abilitySpinType == "Lucky") }
            local AbilityService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.AbilityService
            if AbilityService then
                local RF = AbilityService:FindFirstChild("RF")
                if RF then
                    local Roll = RF:FindFirstChild("Roll")
                    if Roll then
                        Roll:InvokeServer(unpack(args))
                    end
                end
            end
            task.wait(0)
        end
    end)()
end

local function enableAntiLag()
    local function safeGet(instance, propertyName)
        local reached, value = pcall(function()
            return instance[propertyName]
        end)
        if reached then
            return value
        end
        return nil
    end

    local function safeSet(instance, propertyName, value)
        instance[propertyName] = value
    end

    local function rememberProperty(instance, propertyName)
        if not instance then return end
        local data = changedProperties[instance]
        if not data then
            data = {}
            changedProperties[instance] = data
        end
        if data[propertyName] == nil then
            local current = safeGet(instance, propertyName)
            if current == nil then return false end
            data[propertyName] = current
        end
        return true
    end

    local function rememberAndSet(instance, propertyName, value)
        if not instance then return end
        if not rememberProperty(instance, propertyName) then return end
        safeSet(instance, propertyName, value)
    end

    local function shouldSkip(instance)
        if not instance then return true end
        local character = LocalPlayer.Character
        if character and instance:IsDescendantOf(character) then
            return true
        end
        return false
    end

    local function optimizeInstance(instance)
        if shouldSkip(instance) then return end
        
        if instance:IsA("BasePart") then
            rememberAndSet(instance, "Material", Enum.Material.SmoothPlastic)
            rememberAndSet(instance, "Reflectance", 0)
            rememberAndSet(instance, "CastShadow", false)
            if instance:IsA("MeshPart") then
                rememberAndSet(instance, "RenderFidelity", Enum.RenderFidelity.Performance)
                rememberAndSet(instance, "TextureID", "")
            end
        elseif instance:IsA("Decal") or instance:IsA("Texture") then
            rememberAndSet(instance, "Transparency", 1)
        elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") then
            rememberAndSet(instance, "Enabled", false)
        elseif instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
            rememberAndSet(instance, "Enabled", false)
        elseif instance:IsA("SpecialMesh") then
            rememberAndSet(instance, "TextureId", "")
        elseif instance:IsA("SurfaceAppearance") then
            rememberAndSet(instance, "ColorMap", "")
            rememberAndSet(instance, "MetalnessMap", "")
            rememberAndSet(instance, "NormalMap", "")
            rememberAndSet(instance, "RoughnessMap", "")
        end
    end

    local function optimizeLighting()
        rememberAndSet(Lighting, "Technology", Enum.Technology.Compatibility)
        rememberAndSet(Lighting, "GlobalShadows", false)
        rememberAndSet(Lighting, "FogEnd", 1e9)
        rememberAndSet(Lighting, "ShadowSoftness", 0)
        
        for _, effect in ipairs(Lighting:GetChildren()) do
            if effect:IsA("PostEffect") then
                rememberAndSet(effect, "Enabled", false)
            elseif effect:IsA("Atmosphere") then
                rememberAndSet(effect, "Density", 0)
                rememberAndSet(effect, "Haze", 0)
                rememberAndSet(effect, "Glare", 0)
            elseif effect:IsA("Sky") then
                rememberAndSet(effect, "CelestialBodiesShown", false)
                rememberAndSet(effect, "StarCount", 0)
            end
        end
    end

    local function optimizeTerrain()
        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if not terrain then return end
        
        rememberAndSet(terrain, "Decoration", false)
        rememberAndSet(terrain, "WaterWaveSize", 0)
        rememberAndSet(terrain, "WaterWaveSpeed", 0)
        rememberAndSet(terrain, "WaterReflectance", 0)
        rememberAndSet(terrain, "WaterTransparency", 1)
    end

    local function setLowestQuality()
        local rendering = settings().Rendering
        if oldQualityLevel == nil then
            oldQualityLevel = rendering.QualityLevel
        end
        rendering.QualityLevel = Enum.QualityLevel.Level01
        
        local userGameSettings = UserSettings():GetService("UserGameSettings")
        if oldSavedQualityLevel == nil then
            oldSavedQualityLevel = userGameSettings.SavedQualityLevel
        end
        userGameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
    end

    setLowestQuality()
    optimizeLighting()
    optimizeTerrain()
    
    for _, instance in ipairs(workspace:GetDescendants()) do
        optimizeInstance(instance)
    end
    
    local conn = workspace.DescendantAdded:Connect(function(instance)
        optimizeInstance(instance)
    end)
    table.insert(antilagConnections, conn)
end

local function disableAntiLag()
    for instance, props in pairs(changedProperties) do
        for prop, value in pairs(props) do
            instance[prop] = value
        end
    end
    changedProperties = {}
    
    if oldQualityLevel ~= nil then
        settings().Rendering.QualityLevel = oldQualityLevel
        oldQualityLevel = nil
    end
    
    if oldSavedQualityLevel ~= nil then
        UserSettings():GetService("UserGameSettings").SavedQualityLevel = oldSavedQualityLevel
        oldSavedQualityLevel = nil
    end
    
    for _, conn in ipairs(antilagConnections) do
        conn:Disconnect()
    end
    antilagConnections = {}
end

local Window = Library:CreateWindow({
    Title = "Twin Hub",
    Footer = "Volleyball Legends",
    Icon = 76037421850699,
    NotifySide = "Right",
})

local Tabs = {
    Main = Window:AddTab("Main", "user"),
    Character = Window:AddTab("Character", "user"),
    Visuals = Window:AddTab("Visuals", "eye"),
    Misc = Window:AddTab("Misc", "settings"),
    GameJoin = Window:AddTab("Game Join", "gamepad-2"),
    ["UI Settings"] = Window:AddTab("UI Settings", "settings"),
}

local UI = {}

UI.LeftGroupBox = Tabs.Main:AddLeftGroupbox("Spike Settings", "crosshair")

UI.LeftGroupBox:AddToggle("redirectspike", {
    Text = "Redirect Spike",
    Tooltip = "Redirect spike to camera direction",
    Default = false,
    Callback = function(Value)
        if Value then
            enableRedirectSpike()
        else
            disableRedirectSpike()
        end
    end,
})

UI.LeftGroupBox:AddToggle("autocorner", {
    Text = "Auto Corner",
    Tooltip = "Aims to the corner sides of the enemy's goal",
    Default = false,
    Callback = function(Value)
        AutoCorner.enabled = Value
        if Value then
            AutoCorner.installAim()
        end
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerside", {
    Values = {"Auto", "Left", "Right"},
    Default = "Auto",
    Text = "Corner Side",
    Callback = function(Value)
        AutoCorner.side = Value
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerreach", {
    Values = {"All", "Back", "Nearest"},
    Default = "All",
    Text = "Corner Depth",
    Callback = function(Value)
        AutoCorner.reach = Value
    end,
})

UI.LeftGroupBox:AddLabel("Auto Corner bind"):AddKeyPicker("autocornerbind", {
    Default = "C",
    Mode = "Press",
    Text = "Auto Corner",
    Callback = function()
        local toggle = Toggles.autocorner
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.LeftGroupBox:AddToggle("newspike", {
    Text = "Silent Spike",
    Tooltip = "Spike with no animation or sound",
    Default = false,
    Callback = function(Value)
        newSilentSpikeEnabled = Value
        if newSpikeButton then
            newSpikeButton.Visible = Value
        end
    end,
})

UI.LeftGroupBox:AddLabel("Silent Spike bind"):AddKeyPicker("newspikebind", {
    Default = "R",
    Mode = "Press",
    Text = "Silent Spike",
    Callback = function()
        fireNewSpike()
    end,
})

UI.LeftGroupBox:AddToggle("sanju", {
    Text = "Sanju Tilt",
    Tooltip = "Sanju tilt effect",
    Default = false,
    Callback = function(Value)
        if Value then
            enableSanjuTilt()
        else
            disableSanjuTilt()
        end
    end,
})

UI.LeftGroupBox:AddToggle("maxcharge", {
    Text = "Max Charge Special",
    Tooltip = "Max charge your special",
    Default = false,
    Callback = function(Value)
        if Value then
            enableMaxCharge()
        else
            disableMaxCharge()
        end
    end,
})

UI.LeftGroupBox:AddToggle("fakespike", {
    Text = "Fake Spike",
    Tooltip = "Auto fake spike when jumping",
    Default = false,
    Callback = function(Value)
        fakeSpikeEnabled = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounter", {
    Text = "Auto Counter",
    Tooltip = "Counters an enemy spike when both of you are at the net",
    Default = false,
    Callback = function(Value)
        AutoCounter.state.enabled = Value
    end,
})

UI.LeftGroupBox:AddDropdown("autocountermove", {
    Values = {"Auto", "Block", "Spike"},
    Default = "Auto",
    Text = "Counter Move",
    Tooltip = "Auto: block while the ball is still on their half, spike once it crosses",
    Callback = function(Value)
        AutoCounter.state.move = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounternetrange", {
    Text = "Counter Net Range",
    Default = 9,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.netRange = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounterlateral", {
    Text = "Counter Width",
    Default = 14,
    Min = 4,
    Max = 30,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.lateral = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounterdelay", {
    Text = "Counter Delay",
    Default = 0.05,
    Min = 0,
    Max = 0.5,
    Rounding = 2,
    Callback = function(Value)
        AutoCounter.state.delay = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounterjump", {
    Text = "Counter Auto Jump",
    Tooltip = "Jump before the counter, the block hitbox dies the moment you land",
    Default = true,
    Callback = function(Value)
        AutoCounter.state.autoJump = Value
    end,
})

UI.LeftGroupBox:AddLabel("Auto Counter bind"):AddKeyPicker("autocounterbind", {
    Default = "N",
    Mode = "Press",
    Text = "Auto Counter",
    Callback = function()
        local toggle = Toggles.autocounter
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.HitboxGroup = Tabs.Main:AddRightGroupbox("Hitbox Settings", "box")

UI.HitboxGroup:AddToggle("hitboxenable", {
    Text = "Enable Hitbox",
    Tooltip = "Turn Hitbox ON/OFF",
    Default = false,
    Callback = function(Value)
        hitboxEnabled = Value
        if Value then
            updateHitboxes(hitboxScale)
        else
            removeHitboxes()
        end
    end,
})

UI.HitboxGroup:AddSlider("hitboxsize", {
    Text = "Hitbox Size",
    Tooltip = "Reach in studs, the server refuses anything past 20",
    Default = 5,
    Min = 0,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        hitboxScale = Value
        if hitboxEnabled then
            updateHitboxes(Value)
        end
    end,
})

UI.HitboxGroup:AddDropdown("hitboxcolor", {
    Values = {"Invisible", "White", "Green", "Blue", "Red", "Yellow", "Purple", "Orange", "Pink"},
    Default = "Blue",
    Text = "Hitbox Color",
    Callback = function(Value)
        local colors = {
            Invisible = Color3.fromRGB(255, 255, 255),
            White = Color3.fromRGB(255, 255, 255),
            Green = Color3.fromRGB(0, 255, 0),
            Blue = Color3.fromRGB(0, 0, 255),
            Red = Color3.fromRGB(255, 0, 0),
            Yellow = Color3.fromRGB(255, 255, 0),
            Purple = Color3.fromRGB(128, 0, 128),
            Orange = Color3.fromRGB(255, 165, 0),
            Pink = Color3.fromRGB(255, 105, 180)
        }
        local transparencies = {
            Invisible = 1,
            White = 0.3,
            Green = 0.3,
            Blue = 0.3,
            Red = 0.3,
            Yellow = 0.3,
            Purple = 0.3,
            Orange = 0.3,
            Pink = 0.3
        }
        hitboxColor = colors[Value] or Color3.fromRGB(0, 0, 255)
        hitboxTransparency = transparencies[Value] or 0.3
        if hitboxEnabled then
            updateHitboxes(hitboxScale)
        end
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Remove Hitboxes",
    Func = function()
        removeHitboxes()
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Stop Ball",
    Func = function()
        stopBallVisible = not stopBallVisible
        if stopBallButton then
            stopBallButton.Visible = stopBallVisible
        else
            stopBallButton = createStopBallButton()
        end
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Aim",
    Func = function()
        aimVisible = not aimVisible
        if aimButton then
            aimButton.Visible = aimVisible
        else
            aimButton = createAimButton()
        end
    end,
})

UI.PerfGroup = Tabs.Main:AddLeftGroupbox("Performance", "gauge")

UI.PerfGroup:AddToggle("antilag", {
    Text = "Anti-Lag",
    Tooltip = "Reduce graphics for better performance",
    Default = false,
    Callback = function(Value)
        if Value then
            enableAntiLag()
        else
            disableAntiLag()
        end
    end,
})

UI.MoveGroup = Tabs.Main:AddRightGroupbox("Movement", "move")

UI.MoveGroup:AddToggle("desync", {
    Text = "Desync",
    Tooltip = "Desync movement",
    Default = false,
    Callback = function(Value)
        if Value then
            enableDesync()
        else
            disableDesync()
        end
    end,
})

UI.MoveGroup:AddToggle("autoreceive", {
    Text = "Auto Receive",
    Tooltip = "Auto receive the ball",
    Default = false,
    Callback = function(Value)
        autoReceiveEnabled = Value
    end,
})

UI.MoveGroup:AddSlider("autoreceiverange", {
    Text = "Receive Range",
    Default = 10,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        Receive.range = Value
    end,
})

UI.MoveGroup:AddSlider("autoreceivelead", {
    Text = "Receive Lead",
    Default = 0.35,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Receive.lead = Value
    end,
})

UI.MoveGroup:AddLabel("Auto Receive bind"):AddKeyPicker("autoreceivebind", {
    Default = "X",
    Mode = "Press",
    Text = "Auto Receive",
    Callback = function()
        local toggle = Toggles.autoreceive
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.MoveGroup:AddToggle("kisukidive", {
    Text = "Kisuki Dive",
    Tooltip = "Kisuki super dive",
    Default = false,
    Callback = function(Value)
        Kisuki.enabled = Value
        if Value then
            Kisuki.install()
        end
    end,
})

UI.MoveGroup:AddSlider("kisukicharge", {
    Text = "Dive Charge",
    Tooltip = "Lerps Kimiro's real 19.5-45 power range, past 0.5 the FX go strong",
    Default = 1,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Kisuki.charge = Value
    end,
})

UI.MoveGroup:AddToggle("akaridash", {
    Text = "Akari Dash",
    Tooltip = "Dash into the ball",
    Default = false,
    Callback = function(Value)
        akariDashEnabled = Value
        if dashButton then
            dashButton.Visible = Value
        end
    end,
})

UI.MoveGroup:AddLabel("Akari Dash bind"):AddKeyPicker("akaridashbind", {
    Default = "F",
    Mode = "Press",
    Text = "Akari Dash",
    Callback = function()
        akariDash()
    end,
})

UI.MoveGroup:AddToggle("leadfeet", {
    Text = "Lead Feet",
    Tooltip = "Slams you down at the ability's own -10000 acceleration",
    Default = false,
    Callback = function(Value)
        leadFeetEnabled = Value
        if leadFeetButton then
            leadFeetButton.Visible = Value
        end
    end,
})

UI.MoveGroup:AddLabel("Lead Feet bind"):AddKeyPicker("leadfeetbind", {
    Default = "G",
    Mode = "Press",
    Text = "Lead Feet",
    Callback = function()
        leadFeetSlam()
    end,
})

UI.MaxServeGroup = Tabs.Main:AddLeftGroupbox("Max Serve", "server")

UI.MaxServeGroup:AddToggle("maxserve", {
    Text = "Max Serve",
    Tooltip = "Max serve power",
    Default = false,
    Callback = function(Value)
        if Value then
            enableMaxServe()
        else
            disableMaxServe()
        end
    end,
})

UI.MaxServeGroup:AddToggle("esp", {
    Text = "Jump ESP",
    Tooltip = "Highlight enemies while they are jumping",
    Default = false,
    Callback = function(Value)
        espJumpEnabled = Value
        if not Value then
            for player in pairs(espHighlights) do
                removeESP(player)
            end
        end
    end,
})

UI.DataGroup = Tabs.Main:AddRightGroupbox("Data", "database")

UI.DataGroup:AddButton({
    Text = "Data Rollback",
    Func = function()
        local Remote = game:GetService("ReplicatedStorage")
            :WaitForChild("Packages")
            :WaitForChild("_Index")
            :WaitForChild("sleitnick_knit@1.7.0")
            :WaitForChild("knit")
            :WaitForChild("Services")
            :WaitForChild("SettingsService")
            :WaitForChild("RF")
            :WaitForChild("UpdateKeybind")
        Remote:InvokeServer("MouseButton1", true, "Spike\xE2\x80\x8B\x8F")
        game:GetService("TeleportService"):Teleport(game.PlaceId)
    end,
})

UI.CharAttrGroup = Tabs.Character:AddLeftGroupbox("Attributes", "sliders-horizontal")

UI.CharAttrGroup:AddInput("divespeed", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Dive Speed",
    Placeholder = "0.95",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_DiveSpeed", num)
        end
    end,
})

UI.CharAttrGroup:AddInput("jumppower", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Jump Power",
    Placeholder = "1.1",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_JumpPower", num)
        end
    end,
})

UI.CharAttrGroup:AddInput("speed", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Speed",
    Placeholder = "0.85",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_Speed", num)
        end
    end,
})

UI.CharMoveGroup = Tabs.Character:AddRightGroupbox("Movement", "move")

UI.CharMoveGroup:AddToggle("airmove", {
    Text = "Air Movement",
    Tooltip = "Move in the air",
    Default = false,
    Callback = function(Value)
        airMovement = Value
        if not Value and bodyVelocity then
            bodyVelocity:Destroy()
            bodyVelocity = nil
        end
    end,
})

UI.CharMoveGroup:AddSlider("airspeed", {
    Text = "Air Movement Speed",
    Default = 16,
    Min = 0,
    Max = 100,
    Rounding = 0,
    Callback = function(Value)
        airMovementSpeed = Value
    end,
})

UI.CharMoveGroup:AddToggle("autoshiftlock", {
    Text = "Auto Shift Lock",
    Tooltip = "Auto rotate to camera when jumping",
    Default = false,
    Callback = function(Value)
        toggleShiftLock(Value)
    end,
})

UI.CharMoveGroup:AddToggle("characterlines", {
    Text = "Character Enemy/Team Line",
    Tooltip = "Show colored beams to enemies",
    Default = false,
    Callback = function(Value)
        linesEnabled = Value
        if not Value then
            for player in pairs(lines) do
                removeLine(player)
            end
        end
    end,
})

UI.CharMoveGroup:AddSlider("linedistance", {
    Text = "Line Distance",
    Default = 50,
    Min = 10,
    Max = 200,
    Rounding = 1,
    Callback = function(Value)
        lineDistance = Value
    end,
})

Tabs.Visuals:AddRightGroupbox("Ball Prediction", "target"):AddToggle("ballmarker", {
    Text = "Landing Marker",
    Tooltip = "Predict where the ball land and say if it's out or not",
    Default = false,
    Callback = function(Value)
        Landing.enabled = Value
        if not Value then
            Landing.clear()
        end
    end,
})

-- VISUAL APPLY (dropdown selects, button applies on demand)
local VisualApply = {}

function VisualApply.pick(list, wanted)
    if table.find(list, wanted) then
        return wanted
    end
    return list[1]
end

selectedEffect = VisualApply.pick(effectList, selectedEffect)
selectedCard = VisualApply.pick(cardList, selectedCard)
selectedBallSkin = VisualApply.pick(ballSkinList, selectedBallSkin)

function VisualApply.score()
    hitEffectEnabled = true
    pcall(enableHitEffect)
    Vault.mark("ScoreEffect", true)
    Vault.setSlot("ScoreEffect", selectedEffect)
    Library:Notify("Score effect applied: " .. selectedEffect)
end

function VisualApply.card()
    playerCardEnabled = true
    pcall(enablePlayerCard)
    Vault.mark("PlayerCard", true)
    Vault.setSlot("PlayerCard", selectedCard)
    task.spawn(function()
        pcall(fireCardRemote)
    end)
    Library:Notify("Player card applied: " .. selectedCard)
end

function VisualApply.ball()
    autoApplyBallSkin = true
    Vault.mark("Ball", true)
    Vault.setSlot("Ball", selectedBallSkin)
    task.spawn(function()
        pcall(sweep)
    end)
    Library:Notify("Ball applied: " .. selectedBallSkin)
end

function VisualApply.jersey()
    pickedTeam = nil
    task.spawn(function()
        pcall(applyJersey, selectedJersey)
    end)
    Library:Notify("Jersey applied: " .. selectedJersey)
end

UI.VisualScoreGroup = Tabs.Visuals:AddLeftGroupbox("Score Effect", "sparkles")

UI.VisualScoreGroup:AddDropdown("effectselect", {
    Values = effectList,
    Default = selectedEffect,
    Text = "Select Score Effect",
    Callback = function(Value)
        selectedEffect = Value
    end,
})

UI.VisualScoreGroup:AddButton({
    Text = "Apply Score Effect",
    Func = VisualApply.score,
})

UI.VisualProtectGroup = Tabs.Visuals:AddRightGroupbox("Protection", "shield")

UI.VisualProtectGroup:AddToggle("protect", {
    Text = "Protect",
    Tooltip = "Enable/Disable all protection features",
    Default = false,
    Callback = function(Value)
        toggleProtection(Value)
    end,
})

UI.VisualProtectGroup:AddToggle("tshanimation", {
    Text = "TSH Animation",
    Tooltip = "PowerSpike + SpecialChargeSpikeVFX on spike",
    Default = false,
    Callback = function(Value)
        tshAnimationEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("hidarianimation", {
    Text = "Hidari Animation",
    Tooltip = "PowerSpike + HidariSpikeVFX on spike",
    Default = false,
    Callback = function(Value)
        hidariAnimationEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("kazanabluejump", {
    Text = "Kazana Blue Jump",
    Tooltip = "Fires KazanaBlue on jump",
    Default = false,
    Callback = function(Value)
        kazanaBlueEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("kazanawhitejump", {
    Text = "Kazana White Jump",
    Tooltip = "Fires KazanaWhite on jump",
    Default = false,
    Callback = function(Value)
        kazanaWhiteEnabled = Value
    end,
})

UI.PlayerCardGroup = Tabs.Visuals:AddLeftGroupbox("Player Card", "id-card")

UI.PlayerCardGroup:AddDropdown("cardselect", {
    Values = cardList,
    Default = selectedCard,
    Text = "Select Player Card",
    Callback = function(Value)
        selectedCard = Value
    end,
})

UI.PlayerCardGroup:AddButton({
    Text = "Apply Player Card",
    Func = VisualApply.card,
})

Tabs.Visuals:AddRightGroupbox("Title Changer", "tag"):AddToggle("titleunlock", {
    Text = "Title Changer",
    Tooltip = "Change title",
    Default = false,
    Callback = function(Value)
        Vault.mark("Title", Value)
    end,
})

-- BALL SKIN UI
UI.BallSkinGroup = Tabs.Visuals:AddLeftGroupbox("Ball Changer", "circle")

UI.BallSkinGroup:AddDropdown("ballselect", {
    Values = ballSkinList,
    Default = selectedBallSkin,
    Text = "Select Ball",
    Callback = function(Value)
        selectedBallSkin = Value
    end,
})

UI.BallSkinGroup:AddButton({
    Text = "Apply Ball",
    Func = VisualApply.ball,
})

-- JERSEY UI (FIXED - AUTO APPLY ENABLED BY DEFAULT)
UI.JerseyGroup = Tabs.Visuals:AddRightGroupbox("Jersey Changer", "shirt")

UI.JerseyGroup:AddToggle("autoapplyjersey", {
    Text = "Auto Apply Jersey",
    Tooltip = "Automatically apply selected jersey",
    Default = false,
    Callback = function(Value)
        autoApplyJersey = Value
        applyJersey(selectedJersey)
    end,
})

UI.JerseyGroup:AddDropdown("jerseyselect", {
    Values = #jerseyList > 0 and jerseyList or {"No Jerseys Found"},
    Default = #jerseyList > 0 and jerseyList[1] or "No Jerseys Found",
    Text = "Select Jersey",
    Callback = function(Value)
        selectedJersey = Value
        pickedTeam = nil
        if autoApplyJersey then
            applyJersey(selectedJersey)
        end
    end,
})

UI.JerseyGroup:AddButton({
    Text = "Apply Jersey",
    Func = VisualApply.jersey,
})

UI.MiscStyleGroup = Tabs.Misc:AddLeftGroupbox("Auto Style Spin", "refresh-cw")

UI.MiscStyleGroup:AddToggle("autostyle", {
    Text = "Auto Style Spin",
    Tooltip = "Auto spin until target style obtained",
    Default = false,
    Callback = function(Value)
        autoSpin = Value
        if Value then
            startAutoSpin()
        end
    end,
})

UI.MiscStyleGroup:AddDropdown("spintype", {
    Values = {"Normal", "Lucky"},
    Default = "Normal",
    Text = "Spin Type",
    Callback = function(Value)
        spinType = Value
    end,
})

UI.MiscStyleGroup:AddInput("targetstyle", {
    Default = "",
    Text = "Target Style (Type manually)",
    Placeholder = "Sanju",
    Callback = function(Value)
        desiredStyles = {Value}
    end,
})

UI.MiscStyleGroup:AddDropdown("stylelist", {
    Values = {
        "Ronin", "Hidari", "Jinko", "Timeskip Hinto", "Timeskip Kyamo",
        "Akuto", "Taichou", "Sanju", "Mikage", "Kazana", "Timeskip Okazu",
        "Kisuki", "Bakuri", "Kyamo", "Okazu", "Hirakumi",
        "Kozai", "Azmei", "Uchikai", "Yokai", "Yogan",
        "Sazuroku", "Kyoshin", "Yomosuke", "Oyatsu", "Tsuchiro",
        "Imaezi", "Tonkura", "Ninyoku", "Hinto", "Hakochi", "Yakisukai", "Sagumi", "Koshoti"
    },
    Default = "Ronin",
    Text = "Style List (Select to auto-fill)",
    Callback = function(Value)
        Options.targetstyle:SetValue(Value)
        desiredStyles = {Value}
    end,
})

UI.MiscAbilityGroup = Tabs.Misc:AddRightGroupbox("Auto Ability Spin", "zap")

UI.MiscAbilityGroup:AddToggle("autoabilityspin", {
    Text = "Auto Ability Spin",
    Tooltip = "Auto spin until target ability obtained",
    Default = false,
    Callback = function(Value)
        autoAbilitySpin = Value
        if Value then
            startAutoAbilitySpin()
        end
    end,
})

UI.MiscAbilityGroup:AddDropdown("abilityspintype", {
    Values = {"Normal", "Lucky"},
    Default = "Normal",
    Text = "Ability Spin Type",
    Callback = function(Value)
        abilitySpinType = Value
    end,
})

UI.MiscAbilityGroup:AddInput("targetability", {
    Default = "",
    Text = "Target Ability (Type manually)",
    Placeholder = "Shield Breaker",
    Callback = function(Value)
        desiredAbilities = {Value}
    end,
})

UI.MiscAbilityGroup:AddDropdown("abilitylist", {
    Values = {
        "Shield Breaker", "Magnetic Pull", "Lead Feet", "Extra Touch", "Godly",
        "Redirection Jump", "Curve Spike", "Divine Strength", "Legendary",
        "Steel Block", "Zero Gravity Set", "Rare", "Boom Jump", "Moonball",
        "Common", "Super Sprint", "Team Spirit", "Rolling Thunder"
    },
    Default = "Shield Breaker",
    Text = "Ability List (Select to auto-fill)",
    Callback = function(Value)
        Options.targetability:SetValue(Value)
        desiredAbilities = {Value}
    end,
})

UI.MiscShopGroup = Tabs.Misc:AddLeftGroupbox("Shop", "shopping-bag")

UI.MiscShopGroup:AddButton({
    Text = "Buy Emote",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("Emote1")
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Effect",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("ScoreEffect1")
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Extreme Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("Extreme")
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Medium Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("Medium")
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Basic Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("Basic")
            end
        end
    end,
})

UI.MiscClaimGroup = Tabs.Misc:AddRightGroupbox("Claim Rewards", "gift")

UI.MiscClaimGroup:AddButton({
    Text = "Claim Level Rewards",
    Func = function()
        local LevelService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.LevelService
        if LevelService then
            local RF = LevelService:FindFirstChild("RF")
            if RF then
                local ClaimLevelRewards = RF:FindFirstChild("ClaimLevelRewards")
                if ClaimLevelRewards then
                    ClaimLevelRewards:InvokeServer()
                end
            end
        end
    end,
})

UI.MiscClaimGroup:AddButton({
    Text = "Claim Quest Rewards",
    Func = function()
        local QuestService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.QuestService
        if QuestService then
            local RF = QuestService:FindFirstChild("RF")
            if RF then
                local ClaimAll = RF:FindFirstChild("ClaimAll")
                if ClaimAll then
                    ClaimAll:InvokeServer(true)
                end
            end
        end
    end,
})

UI.MiscClaimGroup:AddButton({
    Text = "Redeem All Codes",
    Func = function()
        local function fetchNewCodes()
            local success, data = pcall(function()
                return httpGet("https://beebom.com/haikyuu-legends-codes/")
            end)
            if not success or not data then
                return {}
            end
            local newCodes = {}
            local processed = {}
            for line in string.gmatch(data, "[^\n]+") do
                if string.find(line, "(NEW)") then
                    local code = string.match(line, "(%u+[%u%d_]+)")
                    if code and not processed[code] then
                        processed[code] = true
                        table.insert(newCodes, code)
                    end
                end
                if #newCodes >= 3 then
                    break
                end
            end
            return newCodes
        end
        local newCodes = fetchNewCodes()
        if #newCodes > 0 then
            for i, code in pairs(newCodes) do
                local CodeService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.CodeService
                if CodeService then
                    local RF = CodeService:FindFirstChild("RF")
                    if RF then
                        local Redeem = RF:FindFirstChild("Redeem")
                        if Redeem then
                            Redeem:InvokeServer(code)
                        end
                    end
                end
                task.wait(0.01)
            end
        end
    end,
})

UI.GameJoinGroup = Tabs.GameJoin:AddLeftGroupbox("Game Modes", "gamepad-2")

UI.GameJoinGroup:AddButton({
    Text = "Chaos Mode",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("ChaosMode")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "1v1 Mini Map",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("OnesMini")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "2v2 Ranked",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Twos")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "3v3 Ranked",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Threes")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "4v4 Ranked",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Fours")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "6v6 Ranked",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Sixes")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "Training",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Training")
            end
        end
    end,
})

local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")

MenuGroup:AddToggle("KeybindMenuOpen", {
    Default = Library.KeybindFrame.Visible,
    Text = "Open Keybind Menu",
    Callback = function(value)
        Library.KeybindFrame.Visible = value
    end,
})

MenuGroup:AddDropdown("NotificationSide", {
    Values = { "Left", "Right" },
    Default = "Right",
    Text = "Notification Side",
    Callback = function(Value)
        Library:SetNotifySide(Value)
    end,
})

MenuGroup:AddDropdown("DPIDropdown", {
    Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
    Default = "100%",
    Text = "DPI Scale",
    Callback = function(Value)
        Value = Value:gsub("%%", "")
        local DPI = tonumber(Value)
        Library:SetDPIScale(DPI)
    end,
})

MenuGroup:AddSlider("UICornerSlider", {
    Text = "Corner Radius",
    Default = Library.CornerRadius,
    Min = 0,
    Max = 20,
    Rounding = 0,
    Callback = function(value)
        Window:SetCornerRadius(value)
    end
})

MenuGroup:AddDivider()
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })

MenuGroup:AddButton("Unload", function()
    Library:Unload()
end)

Library.ToggleKeybind = Options.MenuKeybind

Library:SetConfigFolder("TWINHUB")
Library:BuildConfigSection(Tabs["UI Settings"])
Library:LoadAutoloadConfig()
-- Botão Flutuante TWINHUB
task.spawn(function()
    local WinShell = Library.Window.Instance
    local WinRoot = Library.Root

    for _, desc in ipairs(WinShell:GetDescendants()) do
        if desc:IsA("TextButton") and desc.Text == "-" then
            desc.Visible = false
        end
    end

    local FloatBtn = Instance.new("TextButton")
    FloatBtn.Name = "TWINHUB_FloatBtn"
    FloatBtn.Size = UDim2.fromOffset(56, 56)
    FloatBtn.Position = UDim2.new(0, 20, 0.5, -28)
    
    FloatBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    FloatBtn.Text = "T"
    FloatBtn.TextColor3 = Color3.fromRGB(219, 219, 219)
    FloatBtn.Font = Enum.Font.GothamBold
    FloatBtn.TextSize = 24
    FloatBtn.AutoButtonColor = false
    FloatBtn.BorderSizePixel = 0
    FloatBtn.Visible = false
    FloatBtn.ZIndex = 999
    FloatBtn.Parent = WinRoot

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = FloatBtn

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(219, 219, 219)
    stroke.Thickness = 1
    stroke.Parent = FloatBtn

    -- Logo da bola flutuante (PNG embutido em base64, gravado no disco e carregado via getcustomasset)
    do
        local LOGO_B64 = [[
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
yXWoReudXbOstcqciURGSQZdjdb74fKdGlUlEsIUqSxpWSslQVZ/4ut37lzSUD4uOldCzkbB4h3XPrWtdM187EPjdCNEfOd0QFEb038GAdx4xUUITfIlPPp1
//otZ7bncO/z5qrf/4PhmckXvv4yxGzHPvM5whGBa9/4vW86snfKLQNT9OjXvfufWQri0b5ebTPRK7o5EeHRLemLisXmSO6tDtYbAhY9OpiujnD5BlIhDWlp
DUo7FLeECzR40DTi11WYnlayoOz+zgYWAsSAobYc5FTxWw+W3hnU0fedNWGEwqW97jwS1op/6lNMENfW9FSK/dv+3aZ+3z++8anF2mrX5mD31L+khlL7e448
VWNabfp76A04/tq3vuGZuXeyVhBZZFgu/j//LClQu1W1hGZfIAqVRmNERUmUK0rc+sTe3KXeo0X6pmQiqUgJiCwydCZCWSwLkohSQMmc7tGRxiS9aBin97/n
wqm6TrCB8M66Y72nmMjnvmg1bUpPqP0+KNBFMW95TjKV0Y7+0ewB4Jijh8HbhZf88kOvvX1z2s0xr9S1+7dPeECm9G+5yOzy4198X8Tx173l9c/q61OuMinZ
MWccufAvfouWgOxo2i6Imj2jLCCWlfrUF1G2jpYLz8hHD9pm02MOpa8YHSDDoksxYnCQSdDCmebIAnlUhjlSSc+0UiwxBVykt6xmLUTrVKJ69t5jbXjjlafD
OmxT7vsCUqCrrIlvOnq2JuB+/oMjOrRdPtgymRnmb99Zn7MtRafE++/4Jx/2cS3ly152sKCA3Q9c8x1veMX1OjhJX2ai927o/YrpD/7lI6YEqCsWOVnflK0y
T1ArGT2tlpwrazngtSdXfTP3nkiUMGuSxiIAMkUxKQkRYoJpQpKpofC0cSDICEMURXHbObKNka6TkQCNmKZ+SbLXr7J7wf7qhg80D8Bt0dLxqlnZDf3IZx4Y
sQCPdbee1q3V9WaubKGqg52PLX713ePZLcM74sLNl1h59r/9O1f3g3NZJqhZcjZf993FXb/+fngAhHZ2Y5qIjIYl+j7TvTkso5bF9ka7O4+2lnSESo/GeZi4
TUKkwYsOxfyiLIVQEQWGA1PPhMmgnhNqyVbEY3/4ujvulNCJLvOuAIzqzBuff6EWtZjqmd+FAJ/MZ8TWHd1pjGx/gJHU+uBebbZoJi+9OyzEtt766sUL/8qe
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
]]

        local function decodeBase64(data)
            data = data:gsub("[^%w%+/=]", "")
            local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            local map = {}
            for i = 1, 64 do
                map[alphabet:byte(i)] = i - 1
            end
            local parts, count = {}, 0
            for i = 1, #data, 4 do
                local a, b, c, d = data:byte(i, i + 3)
                local v = (map[a] or 0) * 262144 + (map[b] or 0) * 4096
                    + ((c and c ~= 61) and map[c] or 0) * 64
                    + ((d and d ~= 61) and map[d] or 0)
                local chunk = string.char(math.floor(v / 65536) % 256)
                if c and c ~= 61 then
                    chunk = chunk .. string.char(math.floor(v / 256) % 256)
                end
                if d and d ~= 61 then
                    chunk = chunk .. string.char(v % 256)
                end
                count = count + 1
                parts[count] = chunk
            end
            return table.concat(parts)
        end

        pcall(function()
            local write = rawget(_G, "writefile") or writefile
            local asset = rawget(_G, "getcustomasset") or getcustomasset or rawget(_G, "getsynasset") or getsynasset
            local isFolder = rawget(_G, "isfolder") or isfolder
            local makeFolder = rawget(_G, "makefolder") or makefolder
            if type(write) ~= "function" or type(asset) ~= "function" then
                return
            end
            if type(isFolder) == "function" and type(makeFolder) == "function" and not isFolder("TWINHUB") then
                pcall(makeFolder, "TWINHUB")
            end
            local path = "TWINHUB/logo.png"
            write(path, decodeBase64(LOGO_B64))
            local content = asset(path)
            if type(content) ~= "string" or content == "" then
                return
            end
            local logo = Instance.new("ImageLabel")
            logo.Name = "Logo"
            logo.BackgroundTransparency = 1
            logo.BorderSizePixel = 0
            logo.Size = UDim2.fromScale(1, 1)
            logo.Image = content
            logo.ScaleType = Enum.ScaleType.Crop
            logo.ZIndex = 1000
            logo.Parent = FloatBtn
            local logoCorner = Instance.new("UICorner")
            logoCorner.CornerRadius = UDim.new(1, 0)
            logoCorner.Parent = logo
            -- Mesmo logo no cabecalho da janela (ao lado do titulo)
            pcall(function()
                for _, desc in ipairs(WinShell:GetDescendants()) do
                    if desc:IsA("ImageLabel") and desc.Size == UDim2.fromOffset(26, 26) and desc.Position == UDim2.fromOffset(18, 15) then
                        desc.Image = content
                        desc.ScaleType = Enum.ScaleType.Crop
                        break
                    end
                end
            end)
            FloatBtn.Text = ""
        end)
    end

    WinShell:GetPropertyChangedSignal("Visible"):Connect(function()
        FloatBtn.Visible = not WinShell.Visible
    end)

    local dragging, dragStart, startPos = false, nil, nil
    FloatBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = FloatBtn.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    
    FloatBtn.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            FloatBtn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    
    FloatBtn.MouseButton1Click:Connect(function()
        WinShell.Visible = true
        WinShell.Position = UDim2.fromScale(0.5, 0.5)
        WinShell.Size = UDim2.fromOffset(680, 520)
        if Library.Window.SetMinimized then
            Library.Window:SetMinimized(false)
        end
    end)
end)
