-- InfinityUI — original interface library for the InfinityGold brand.
--
-- A self-contained dashboard toolkit: draggable window, icon tabs, toggles,
-- sliders, dropdowns (single and multi), buttons, text inputs, labels and
-- toast notifications. Deep-black surface with gold accents.
--
-- API summary:
--   local Library = loadstring(source)()
--   local window  = Library:CreateWindow({ Title, SubTitle, Keybind })
--   local tab     = window:CreateTab({ Name = "Farm", Icon = ">" })
--   local section = tab:CreateSection("Automation")
--   section:AddToggle / AddSlider / AddDropdown / AddButton / AddInput /
--   section:AddLabel / AddParagraph
--   window:SetStatus("..."), Library:Notify({...}), Library:Destroy()

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local Library = {
    Version = "1.2.0",
    Brand = "INFINITYGOLD",
    Theme = {
        Background     = Color3.fromRGB(10, 11, 16),
        Navigation     = Color3.fromRGB(12, 13, 19),
        Surface        = Color3.fromRGB(18, 19, 27),
        SurfaceRaised  = Color3.fromRGB(23, 24, 34),
        SurfaceLight   = Color3.fromRGB(30, 31, 43),
        Border         = Color3.fromRGB(53, 51, 43),
        BorderSoft     = Color3.fromRGB(39, 40, 50),
        Gold           = Color3.fromRGB(248, 198, 57),
        GoldBright     = Color3.fromRGB(255, 220, 113),
        GoldDeep       = Color3.fromRGB(213, 151, 25),
        GoldSoft       = Color3.fromRGB(105, 80, 24),
        Interactive    = Color3.fromRGB(39, 37, 30),
        InteractiveHover = Color3.fromRGB(64, 52, 25),
        InteractivePress = Color3.fromRGB(78, 60, 21),
        InteractiveBorder = Color3.fromRGB(142, 105, 31),
        Text           = Color3.fromRGB(242, 241, 237),
        TextDim        = Color3.fromRGB(163, 163, 171),
        TextMuted      = Color3.fromRGB(108, 109, 120),
        Danger         = Color3.fromRGB(224, 82, 82),
        Success        = Color3.fromRGB(94, 198, 118),
    },
    _gui = nil,
    _windows = {},
    _tweens = {},
    _connections = {},
}

local function connectGlobal(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(Library._connections, connection)
    return connection
end

local function tween(instance, properties, duration, style, direction)
    local info = TweenInfo.new(
        duration or 0.18,
        style or Enum.EasingStyle.Quint,
        direction or Enum.EasingDirection.Out
    )
    local played = TweenService:Create(instance, info, properties)
    played:Play()
    return played
end

local function corner(instance, radius)
    local uiCorner = Instance.new("UICorner")
    uiCorner.CornerRadius = UDim.new(0, radius or 8)
    uiCorner.Parent = instance
    return uiCorner
end

local function stroke(instance, color, thickness, transparency)
    local uiStroke = Instance.new("UIStroke")
    uiStroke.Color = color or Library.Theme.Border
    uiStroke.Thickness = thickness or 1
    uiStroke.Transparency = transparency or 0
    uiStroke.Parent = instance
    return uiStroke
end

local function padding(instance, size)
    local uiPadding = Instance.new("UIPadding")
    uiPadding.PaddingTop = UDim.new(0, size)
    uiPadding.PaddingBottom = UDim.new(0, size)
    uiPadding.PaddingLeft = UDim.new(0, size)
    uiPadding.PaddingRight = UDim.new(0, size)
    uiPadding.Parent = instance
    return uiPadding
end

local function label(instance, options)
    options = type(options) == "table" and options or {}
    local textLabel = Instance.new("TextLabel")
    textLabel.Name = options.Name or "Text"
    textLabel.BackgroundTransparency = 1
    textLabel.Position = options.Position or UDim2.new()
    textLabel.Size = options.Size or UDim2.new(1, 0, 1, 0)
    textLabel.Font = options.Font or Enum.Font.Gotham
    textLabel.Text = options.Text or ""
    textLabel.TextSize = options.TextSize or 14
    textLabel.TextColor3 = options.TextColor3 or Library.Theme.Text
    textLabel.TextXAlignment = options.TextXAlignment or Enum.TextXAlignment.Left
    textLabel.TextYAlignment = options.TextYAlignment or Enum.TextYAlignment.Center
    textLabel.RichText = options.RichText or false
    if options.AnchorPoint ~= nil then textLabel.AnchorPoint = options.AnchorPoint end
    if options.AutomaticSize ~= nil then textLabel.AutomaticSize = options.AutomaticSize end
    if options.LayoutOrder ~= nil then textLabel.LayoutOrder = options.LayoutOrder end
    if options.LineHeight ~= nil then textLabel.LineHeight = options.LineHeight end
    if options.TextTruncate ~= nil then textLabel.TextTruncate = options.TextTruncate end
    if options.TextWrapped ~= nil then textLabel.TextWrapped = options.TextWrapped end
    if options.TextTransparency ~= nil then textLabel.TextTransparency = options.TextTransparency end
    if options.ZIndex ~= nil then textLabel.ZIndex = options.ZIndex end
    textLabel.Parent = instance
    return textLabel
end

local function resolveParent()
    -- PlayerGui first: it renders reliably on every executor (including
    -- mobile builds whose gethui()/CoreGui container never draws). The gui
    -- keeps ResetOnSpawn = false so respawns do not clear it.
    local player = Players.LocalPlayer
    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if playerGui then
        return playerGui
    end

    local holder = nil
    local ok = pcall(function()
        if type(gethui) == "function" then
            holder = gethui()
        end
    end)
    if ok and holder then return holder end

    holder = nil
    ok = pcall(function()
        holder = game:GetService("CoreGui")
    end)
    if ok and holder then
        local probe = Instance.new("Folder")
        local attached = pcall(function()
            probe.Parent = holder
        end)
        if attached then
            probe:Destroy()
            return holder
        end
    end

    return game:GetService("CoreGui")
end

local function ensureGui()
    if Library._gui and Library._gui.Parent then
        return Library._gui
    end
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "InfinityGold_" .. tostring(math.random(10000, 99999))
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.DisplayOrder = 1000000
    screenGui.IgnoreGuiInset = true

    local parent = resolveParent()
    local placed = pcall(function()
        screenGui.Parent = parent
    end)
    if not placed then
        pcall(function()
            screenGui.Parent = Players.LocalPlayer
                and Players.LocalPlayer:WaitForChild("PlayerGui")
        end)
    end

    Library._gui = screenGui
    return screenGui
end

function Library:IsAttached()
    return Library._gui ~= nil and Library._gui.Parent ~= nil
end

-- Notifications ---------------------------------------------------------------

local notifications do
    notifications = { frame = nil, stack = {} }

    function notifications.ensure()
        if notifications.frame and notifications.frame.Parent then
            return notifications.frame
        end
        local screenGui = ensureGui()
        local holder = Instance.new("Frame")
        holder.Name = "Notifications"
        holder.AnchorPoint = Vector2.new(1, 0)
        holder.BackgroundTransparency = 1
        holder.Position = UDim2.new(1, -14, 0, 14)
        holder.Size = UDim2.new(0, 300, 1, -28)
        holder.Parent = screenGui

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 8)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
        layout.Parent = holder

        notifications.frame = holder
        return holder
    end

    function Library:Notify(options)
        options = type(options) == "table" and options or {}
        local holder = notifications.ensure()
        local duration = math.max(1, tonumber(options.Duration) or 4)

        local card = Instance.new("Frame")
        card.Name = "Toast"
        card.BackgroundColor3 = Library.Theme.Surface
        card.BorderSizePixel = 0
        card.Size = UDim2.new(1, 0, 0, 0)
        card.AutomaticSize = Enum.AutomaticSize.Y
        card.Parent = holder
        corner(card, 8)
        stroke(card, Library.Theme.GoldSoft, 1)

        local accent = Instance.new("Frame")
        accent.Name = "Accent"
        accent.AnchorPoint = Vector2.new(0, 0.5)
        accent.BackgroundColor3 = options.Success and Library.Theme.Success
            or Library.Theme.Gold
        accent.BorderSizePixel = 0
        accent.Position = UDim2.new(0, 0, 0.5, 0)
        accent.Size = UDim2.new(0, 3, 1, -10)
        accent.Parent = card
        corner(accent, 2)

        local body = Instance.new("Frame")
        body.Name = "Body"
        body.BackgroundTransparency = 1
        body.Position = UDim2.new(0, 12, 0, 0)
        body.Size = UDim2.new(1, -24, 1, 0)
        body.AutomaticSize = Enum.AutomaticSize.Y
        body.Parent = card

        local titleText = label(body, {
            Text = options.Title or Library.Brand,
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            TextColor3 = Library.Theme.Gold,
            Size = UDim2.new(1, 0, 0, 20),
        })

        local contentText = label(body, {
            Text = options.Content or "",
            TextSize = 13,
            TextColor3 = Library.Theme.Text,
            TextWrapped = true,
            TextYAlignment = Enum.TextYAlignment.Top,
            Size = UDim2.new(1, 0, 0, 0),
            Position = UDim2.new(0, 0, 0, 20),
        })
        contentText.AutomaticSize = Enum.AutomaticSize.Y

        local progress = Instance.new("Frame")
        progress.Name = "Progress"
        progress.AnchorPoint = Vector2.new(0, 1)
        progress.BackgroundColor3 = Library.Theme.GoldDeep
        progress.BorderSizePixel = 0
        progress.Position = UDim2.new(0, 0, 1, 0)
        progress.Size = UDim2.new(1, 0, 0, 2)
        progress.Parent = card

        local total = #notifications.stack
        card.LayoutOrder = -total
        table.insert(notifications.stack, card)

        card.Position = card.Position + UDim2.new(0.4, 0, 0, 0)
        card.BackgroundTransparency = 1
        tween(card, { BackgroundTransparency = 0, Position = card.Position - UDim2.new(0.4, 0, 0, 0) }, 0.25)

        task.spawn(function()
            local startedAt = os.clock()
            while os.clock() - startedAt < duration do
                local remaining = 1 - (os.clock() - startedAt) / duration
                progress.Size = UDim2.new(remaining, 0, 0, 2)
                task.wait(0.05)
            end
            tween(card, { BackgroundTransparency = 1, Position = card.Position + UDim2.new(0.3, 0, 0, 0) }, 0.2)
            task.wait(0.22)
            for index, entry in ipairs(notifications.stack) do
                if entry == card then
                    table.remove(notifications.stack, index)
                    break
                end
            end
            card:Destroy()
        end)
    end
end

-- Window ----------------------------------------------------------------------

function Library:CreateWindow(options)
    options = type(options) == "table" and options or {}
    local screenGui = ensureGui()

    local window = {
        Keybind = options.Keybind or Enum.KeyCode.RightShift,
        Status = "",
        Gui = screenGui,
    }

    local main = Instance.new("Frame")
    main.Name = "Window"
    main.AnchorPoint = Vector2.new(0.5, 0.5)
    main.BackgroundColor3 = Library.Theme.Background
    main.BorderSizePixel = 0
    main.Position = UDim2.new(0.5, 0, 0.5, 0)

    -- Keep the dashboard compact enough to leave the 3D world visible while
    -- capturing Running points. Smaller screens still get a margin-aware size.
    local function fittedWindowSize(viewport)
        if viewport == nil then return 600, 430 end
        -- CurrentCamera can briefly report a zero-sized viewport while the
        -- client is still bootstrapping. Keep a usable default until Roblox
        -- publishes the real dimensions; the viewport listener below will
        -- then apply the responsive size.
        if viewport.X < 100 or viewport.Y < 100 then return 600, 430 end
        local width = math.min(600, math.max(300, viewport.X - 32))
        local height = math.min(430, math.max(280, viewport.Y - 32))
        -- The final cap is deliberately independent of the minimum so even
        -- an unusually tiny emulator viewport cannot be overflowed.
        width = math.min(width, math.max(1, viewport.X - 12))
        height = math.min(height, math.max(1, viewport.Y - 12))
        return width, height
    end

    local currentCamera = nil
    pcall(function() currentCamera = workspace.CurrentCamera end)
    local initialViewport = currentCamera and currentCamera.ViewportSize or nil
    local windowWidth, windowHeight = fittedWindowSize(initialViewport)
    local compactNavigation = windowWidth < 520
    local navigationWidth = compactNavigation and 64 or 142
    main.Size = UDim2.new(0, windowWidth, 0, windowHeight)
    main.ClipsDescendants = true
    main.Parent = screenGui
    corner(main, 14)
    stroke(main, Library.Theme.GoldSoft, 1.25, 0.15)

    local mainGradient = Instance.new("UIGradient")
    mainGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(13, 14, 21)),
        ColorSequenceKeypoint.new(1, Library.Theme.Background),
    })
    mainGradient.Rotation = 115
    mainGradient.Parent = main

    window.Frame = main

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.BackgroundColor3 = Library.Theme.Surface
    titleBar.BorderSizePixel = 0
    titleBar.Size = UDim2.new(1, 0, 0, 62)
    titleBar.Parent = main
    corner(titleBar, 14)

    local bottomPatch = Instance.new("Frame")
    bottomPatch.BackgroundColor3 = Library.Theme.Surface
    bottomPatch.BorderSizePixel = 0
    bottomPatch.Position = UDim2.new(0, 0, 1, -14)
    bottomPatch.Size = UDim2.new(1, 0, 0, 14)
    bottomPatch.Parent = titleBar

    local titleDivider = Instance.new("Frame")
    titleDivider.Name = "Divider"
    titleDivider.AnchorPoint = Vector2.new(0, 1)
    titleDivider.BackgroundColor3 = Library.Theme.BorderSoft
    titleDivider.BorderSizePixel = 0
    titleDivider.Position = UDim2.new(0, 18, 1, 0)
    titleDivider.Size = UDim2.new(1, -36, 0, 1)
    titleDivider.Parent = titleBar

    local brandMark = Instance.new("Frame")
    brandMark.Name = "BrandMark"
    brandMark.AnchorPoint = Vector2.new(0, 0.5)
    brandMark.BackgroundColor3 = Library.Theme.SurfaceRaised
    brandMark.BorderSizePixel = 0
    brandMark.Position = UDim2.new(0, 16, 0.5, 0)
    brandMark.Size = UDim2.new(0, 34, 0, 34)
    brandMark.Parent = titleBar
    corner(brandMark, 9)
    stroke(brandMark, Library.Theme.GoldDeep, 1.25, 0.05)

    local brandGradient = Instance.new("UIGradient")
    brandGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Library.Theme.SurfaceLight),
        ColorSequenceKeypoint.new(1, Library.Theme.Surface),
    })
    brandGradient.Rotation = 135
    brandGradient.Parent = brandMark

    label(brandMark, {
        Name = "Monogram",
        Text = "IG",
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Library.Theme.Gold,
        TextXAlignment = Enum.TextXAlignment.Center,
    })

    local titleText = label(titleBar, {
        Text = options.Title or Library.Brand,
        Font = Enum.Font.GothamBold,
        TextSize = 17,
        TextColor3 = Library.Theme.Gold,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 62, 0, 8),
        Size = UDim2.new(1, -174, 0, 24),
    })

    local subTitleText = label(titleBar, {
        Text = options.SubTitle or "",
        TextSize = 11,
        TextColor3 = Library.Theme.TextDim,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 62, 0, 31),
        Size = UDim2.new(1, -174, 0, 20),
    })

    local minimizeButton = Instance.new("TextButton")
    minimizeButton.Name = "Minimize"
    minimizeButton.AnchorPoint = Vector2.new(1, 0.5)
    minimizeButton.BackgroundColor3 = Library.Theme.SurfaceRaised
    minimizeButton.BackgroundTransparency = 0
    minimizeButton.Size = UDim2.new(0, 32, 0, 32)
    minimizeButton.Position = UDim2.new(1, -56, 0.5, 0)
    minimizeButton.Font = Enum.Font.GothamBold
    minimizeButton.Text = "-"
    minimizeButton.TextSize = 16
    minimizeButton.TextColor3 = Library.Theme.TextDim
    minimizeButton.Parent = titleBar
    corner(minimizeButton, 8)
    stroke(minimizeButton, Library.Theme.BorderSoft, 1)

    local closeButton = Instance.new("TextButton")
    closeButton.Name = "Close"
    closeButton.AnchorPoint = Vector2.new(1, 0.5)
    closeButton.BackgroundColor3 = Library.Theme.SurfaceRaised
    closeButton.BackgroundTransparency = 0
    closeButton.Size = UDim2.new(0, 32, 0, 32)
    closeButton.Position = UDim2.new(1, -16, 0.5, 0)
    closeButton.Font = Enum.Font.GothamBold
    closeButton.Text = "x"
    closeButton.TextSize = 14
    closeButton.TextColor3 = Library.Theme.Danger
    closeButton.Parent = titleBar
    corner(closeButton, 8)
    stroke(closeButton, Library.Theme.BorderSoft, 1)

    -- Body: navigation + content
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.BackgroundTransparency = 1
    body.Position = UDim2.new(0, 0, 0, 62)
    body.Size = UDim2.new(1, 0, 1, -62)
    body.Parent = main

    local nav = Instance.new("ScrollingFrame")
    nav.Name = "Navigation"
    nav.BackgroundColor3 = Library.Theme.Navigation
    nav.BorderSizePixel = 0
    nav.Position = UDim2.new(0, 0, 0, 0)
    nav.Size = UDim2.new(0, navigationWidth, 1, -34)
    nav.CanvasSize = UDim2.new(0, 0, 0, 0)
    nav.AutomaticCanvasSize = Enum.AutomaticSize.Y
    nav.ScrollBarThickness = 2
    nav.ScrollBarImageColor3 = Library.Theme.GoldSoft
    nav.ScrollBarImageTransparency = 0.25
    nav.ScrollingDirection = Enum.ScrollingDirection.Y
    nav.Parent = body

    local navLayout = Instance.new("UIListLayout")
    navLayout.Padding = UDim.new(0, 5)
    navLayout.SortOrder = Enum.SortOrder.LayoutOrder
    navLayout.Parent = nav

    local navPadding = padding(nav, 10)
    navPadding.PaddingTop = UDim.new(0, 12)
    navPadding.PaddingRight = UDim.new(0, 12)

    local navCaption = label(nav, {
        Name = "NavigationCaption",
        Text = compactNavigation and "IG" or "NAVIGATION",
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = Library.Theme.TextMuted,
        TextXAlignment = compactNavigation and Enum.TextXAlignment.Center
            or Enum.TextXAlignment.Left,
        Size = UDim2.new(1, 0, 0, 22),
        LayoutOrder = -1000,
    })

    local navDivider = Instance.new("Frame")
    navDivider.Name = "NavigationDivider"
    navDivider.AnchorPoint = Vector2.new(1, 0)
    navDivider.BackgroundColor3 = Library.Theme.BorderSoft
    navDivider.BorderSizePixel = 0
    navDivider.Position = UDim2.new(0, navigationWidth, 0, 0)
    navDivider.Size = UDim2.new(0, 1, 1, -34)
    navDivider.Parent = body

    local contentHolder = Instance.new("Frame")
    contentHolder.Name = "ContentHolder"
    contentHolder.BackgroundTransparency = 1
    contentHolder.Position = UDim2.new(0, navigationWidth + 1, 0, 0)
    contentHolder.Size = UDim2.new(1, -(navigationWidth + 1), 1, -34)
    contentHolder.ClipsDescendants = true
    contentHolder.Parent = body

    -- Footer status
    local footer = Instance.new("Frame")
    footer.Name = "Footer"
    footer.BackgroundColor3 = Library.Theme.Surface
    footer.BorderSizePixel = 0
    footer.AnchorPoint = Vector2.new(0, 1)
    footer.Position = UDim2.new(0, 0, 1, 0)
    footer.Size = UDim2.new(1, 0, 0, 34)
    footer.Parent = main
    corner(footer, 14)

    local footerPatch = Instance.new("Frame")
    footerPatch.BackgroundColor3 = Library.Theme.Surface
    footerPatch.BorderSizePixel = 0
    footerPatch.Position = UDim2.new(0, 0, 0, 0)
    footerPatch.Size = UDim2.new(1, 0, 0, 14)
    footerPatch.Parent = footer

    local footerDivider = Instance.new("Frame")
    footerDivider.BackgroundColor3 = Library.Theme.BorderSoft
    footerDivider.BorderSizePixel = 0
    footerDivider.Size = UDim2.new(1, 0, 0, 1)
    footerDivider.Parent = footer

    local statusDot = Instance.new("Frame")
    statusDot.AnchorPoint = Vector2.new(0, 0.5)
    statusDot.BackgroundColor3 = Library.Theme.Gold
    statusDot.BorderSizePixel = 0
    statusDot.Position = UDim2.new(0, 16, 0.5, 0)
    statusDot.Size = UDim2.new(0, 7, 0, 7)
    statusDot.Parent = footer
    corner(statusDot, 4)

    local statusText = label(footer, {
        Text = "",
        TextSize = 12,
        TextColor3 = Library.Theme.TextDim,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 31, 0, 0),
        Size = UDim2.new(1, -48, 1, 0),
    })

    window.StatusLabel = statusText

    function window:SetStatus(text)
        window.Status = tostring(text or "")
        statusText.Text = window.Status
    end

    local function clampWindowToViewport(position)
        local ok, camera = pcall(function()
            return workspace.CurrentCamera
        end)
        if not ok or camera == nil then return position end

        local viewport = camera.ViewportSize
        local size = main.AbsoluteSize
        local centerX = viewport.X * position.X.Scale + position.X.Offset
        local centerY = viewport.Y * position.Y.Scale + position.Y.Offset
        local margin = 8
        local minX, maxX = size.X * 0.5 + margin,
            viewport.X - size.X * 0.5 - margin
        local minY, maxY = size.Y * 0.5 + margin,
            viewport.Y - size.Y * 0.5 - margin

        centerX = minX <= maxX and math.clamp(centerX, minX, maxX)
            or viewport.X * 0.5
        centerY = minY <= maxY and math.clamp(centerY, minY, maxY)
            or viewport.Y * 0.5
        return UDim2.new(0, centerX, 0, centerY)
    end

    -- Dragging
    do
        local dragging = false
        local dragStart = nil
        local startPosition = nil

        titleBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch
            then
                dragging = true
                dragStart = input.Position
                startPosition = main.Position
            end
        end)

        connectGlobal(UserInputService.InputChanged, function(input)
            if not dragging then return end
            if input.UserInputType ~= Enum.UserInputType.MouseMovement
                and input.UserInputType ~= Enum.UserInputType.Touch
            then
                return
            end
            local delta = input.Position - dragStart
            local desired = UDim2.new(
                startPosition.X.Scale,
                startPosition.X.Offset + delta.X,
                startPosition.Y.Scale,
                startPosition.Y.Offset + delta.Y
            )
            tween(main, {
                Position = clampWindowToViewport(desired),
            }, 0.06)
        end)

        connectGlobal(UserInputService.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch
            then
                dragging = false
            end
        end)
    end

    -- Visibility controls
    local visible = true

    -- Minimizing hides the window completely (same as the floating toggle);
    -- it is restored with the floating IG button or the keybind.
    minimizeButton.MouseButton1Click:Connect(function()
        visible = false
        main.Visible = false
    end)

    closeButton.MouseButton1Click:Connect(function()
        if type(window.OnClose) == "function" then
            local ok = pcall(window.OnClose)
            if ok then return end
        end
        Library:Destroy()
    end)

    connectGlobal(UserInputService.InputBegan, function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == window.Keybind then
            visible = not visible
            if visible then
                main.Visible = true
                tween(main, { BackgroundTransparency = 0 }, 0.15)
            else
                tween(main, { BackgroundTransparency = 1 }, 0.15)
                task.delay(0.16, function()
                    if not visible then main.Visible = false end
                end)
            end
        end
    end)

    -- Tabs
    local tabs = {}
    local tabCount = 0
    local activeDropdownClose = nil

    function window:CreateTab(tabOptions)
        tabOptions = type(tabOptions) == "table" and tabOptions or {}
        tabCount = tabCount + 1

        local tab = { Sections = {}, SectionCount = 0 }

        local navButton = Instance.new("TextButton")
        navButton.Name = "Tab" .. tabCount
        navButton.BackgroundColor3 = Library.Theme.SurfaceRaised
        navButton.BackgroundTransparency = 1
        navButton.Size = UDim2.new(1, 0, 0, 38)
        navButton.Font = Enum.Font.Gotham
        navButton.Text = ""
        navButton.TextSize = 13
        navButton.AutoButtonColor = false
        navButton.Parent = nav
        navButton.LayoutOrder = tabCount
        corner(navButton, 8)

        local navHighlight = Instance.new("Frame")
        navHighlight.Name = "Highlight"
        navHighlight.AnchorPoint = Vector2.new(0, 0.5)
        navHighlight.BackgroundColor3 = Library.Theme.Gold
        navHighlight.BackgroundTransparency = 1
        navHighlight.Position = UDim2.new(0, 1, 0.5, 0)
        navHighlight.Size = UDim2.new(0, 3, 0, 20)
        navHighlight.Parent = navButton
        corner(navHighlight, 2)

        local iconText = label(navButton, {
            Name = "Icon",
            Text = tabOptions.Icon or ">",
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextColor3 = Library.Theme.TextDim,
            TextXAlignment = Enum.TextXAlignment.Center,
            Position = compactNavigation
                and UDim2.new(0.5, -12, 0, 0)
                or UDim2.new(0, 9, 0, 0),
            Size = UDim2.new(0, 24, 1, 0),
        })

        local nameText = label(navButton, {
            Name = "Name",
            Text = tabOptions.Name or ("Tab " .. tabCount),
            Font = Enum.Font.GothamMedium,
            TextSize = 13,
            TextColor3 = Library.Theme.TextDim,
            Position = UDim2.new(0, 40, 0, 0),
            Size = UDim2.new(1, -48, 1, 0),
        })
        nameText.Visible = not compactNavigation

        local page = Instance.new("ScrollingFrame")
        page.Name = "Page" .. tabCount
        page.BackgroundTransparency = 1
        page.Position = UDim2.new(0, 0, 0, 0)
        page.Size = UDim2.new(1, 0, 1, 0)
        page.CanvasSize = UDim2.new(0, 0, 0, 0)
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y
        page.ScrollBarThickness = 3
        page.ScrollBarImageColor3 = Library.Theme.GoldSoft
        page.ScrollBarImageTransparency = 0.1
        page.ScrollingDirection = Enum.ScrollingDirection.Y
        page.Visible = false
        page.Parent = contentHolder
        local pagePadding = padding(page, 14)
        pagePadding.PaddingRight = UDim.new(0, 18)
        pagePadding.PaddingBottom = UDim.new(0, 18)

        local pageLayout = Instance.new("UIListLayout")
        pageLayout.Padding = UDim.new(0, 12)
        pageLayout.SortOrder = Enum.SortOrder.LayoutOrder
        pageLayout.Parent = page

        tab.Page = page
        tab.Button = navButton
        tab.IconLabel = iconText
        tab.NameLabel = nameText
        tab.Order = tabCount

        navButton.MouseButton1Click:Connect(function()
            window:SelectTab(tab)
        end)

        table.insert(tabs, tab)
        if #tabs == 1 then
            window:SelectTab(tab)
        end
        return tab
    end

    function window:SelectTab(target)
        for _, entry in ipairs(tabs) do
            local selected = entry == target
            entry.Page.Visible = selected
            tween(entry.Button, {
                BackgroundTransparency = selected and 0.08 or 1,
            }, 0.15)
            local highlight = entry.Button:FindFirstChild("Highlight")
            if highlight then
                tween(highlight, { BackgroundTransparency = selected and 0 or 1 }, 0.15)
            end
            for _, child in ipairs(entry.Button:GetChildren()) do
                if child:IsA("TextLabel") then
                    tween(child, {
                        TextColor3 = selected and Library.Theme.Text or Library.Theme.TextDim,
                    }, 0.15)
                end
            end
        end
    end

    local function applyViewportLayout()
        local ok, camera = pcall(function()
            return workspace.CurrentCamera
        end)
        if not ok or camera == nil then return end

        currentCamera = camera
        windowWidth, windowHeight = fittedWindowSize(camera.ViewportSize)
        compactNavigation = windowWidth < 520
        navigationWidth = compactNavigation and 64 or 142

        main.Size = UDim2.new(0, windowWidth, 0, windowHeight)
        nav.Size = UDim2.new(0, navigationWidth, 1, -34)
        navDivider.Position = UDim2.new(0, navigationWidth, 0, 0)
        contentHolder.Position = UDim2.new(0, navigationWidth + 1, 0, 0)
        contentHolder.Size = UDim2.new(1, -(navigationWidth + 1), 1, -34)
        navCaption.Text = compactNavigation and "IG" or "NAVIGATION"
        navCaption.TextXAlignment = compactNavigation
            and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left

        for _, entry in ipairs(tabs) do
            entry.IconLabel.Position = compactNavigation
                and UDim2.new(0.5, -12, 0, 0)
                or UDim2.new(0, 9, 0, 0)
            entry.NameLabel.Visible = not compactNavigation
        end

        -- AbsoluteSize settles on the next scheduler step after Size changes.
        task.defer(function()
            if main.Parent ~= nil then
                main.Position = clampWindowToViewport(main.Position)
            end
        end)
    end

    local watchedCamera = nil
    local function watchViewport(camera)
        if camera == nil or camera == watchedCamera then return end
        watchedCamera = camera
        connectGlobal(camera:GetPropertyChangedSignal("ViewportSize"), applyViewportLayout)
    end

    watchViewport(currentCamera)
    connectGlobal(workspace:GetPropertyChangedSignal("CurrentCamera"), function()
        local ok, camera = pcall(function() return workspace.CurrentCamera end)
        if ok then watchViewport(camera) end
        applyViewportLayout()
    end)

    function window:CreateSection(name)
        error("CreateSection must be called on a tab, not the window")
    end

    -- Section factory attached to every tab
    local newSection

    newSection = function(tab, name)
        tab.SectionCount = (tonumber(tab.SectionCount) or 0) + 1
        local sectionFrame = Instance.new("Frame")
        sectionFrame.Name = "Section"
        sectionFrame.BackgroundColor3 = Library.Theme.Surface
        sectionFrame.BorderSizePixel = 0
        sectionFrame.Size = UDim2.new(1, 0, 0, 0)
        sectionFrame.AutomaticSize = Enum.AutomaticSize.Y
        sectionFrame.LayoutOrder = tab.SectionCount * 10
        sectionFrame.Parent = tab.Page
        corner(sectionFrame, 11)
        stroke(sectionFrame, Library.Theme.BorderSoft, 1)

        local sectionGradient = Instance.new("UIGradient")
        sectionGradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Library.Theme.SurfaceRaised),
            ColorSequenceKeypoint.new(1, Library.Theme.Surface),
        })
        sectionGradient.Rotation = 115
        sectionGradient.Parent = sectionFrame

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 9)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = sectionFrame

        padding(sectionFrame, 14)

        if name and name ~= "" then
            local headerRow = Instance.new("Frame")
            headerRow.Name = "SectionHeader"
            headerRow.BackgroundTransparency = 1
            headerRow.Size = UDim2.new(1, 0, 0, 24)
            headerRow.LayoutOrder = -1000
            headerRow.Parent = sectionFrame

            local headerAccent = Instance.new("Frame")
            headerAccent.AnchorPoint = Vector2.new(0, 0.5)
            headerAccent.BackgroundColor3 = Library.Theme.Gold
            headerAccent.BorderSizePixel = 0
            headerAccent.Position = UDim2.new(0, 0, 0.5, 0)
            headerAccent.Size = UDim2.new(0, 3, 0, 14)
            headerAccent.Parent = headerRow
            corner(headerAccent, 2)

            label(headerRow, {
                Name = "Title",
                Text = string.upper(tostring(name)),
                Font = Enum.Font.GothamBold,
                TextSize = 11,
                TextColor3 = Library.Theme.Gold,
                Position = UDim2.new(0, 12, 0, 0),
                Size = UDim2.new(1, -12, 1, 0),
            })
        end

        local section = { Frame = sectionFrame, Order = 0 }
        table.insert(tab.Sections, section)

        local function nextOrder()
            section.Order = section.Order + 10
            return section.Order
        end

        function section:AddLabel(text)
            local element = label(sectionFrame, {
                Name = "DynamicLabel",
                Text = tostring(text),
                TextSize = 13,
                TextColor3 = Library.Theme.TextDim,
                TextWrapped = true,
                TextYAlignment = Enum.TextYAlignment.Top,
                AutomaticSize = Enum.AutomaticSize.Y,
                LineHeight = 1.18,
                Size = UDim2.new(1, 0, 0, 0),
                LayoutOrder = nextOrder(),
            })
            return {
                Set = function(_, value) element.Text = tostring(value) end,
                Get = function(_) return element.Text end,
            }
        end

        function section:AddParagraph(paragraphOptions)
            paragraphOptions = type(paragraphOptions) == "table" and paragraphOptions or {}
            local holder = Instance.new("Frame")
            holder.Name = "Paragraph"
            holder.BackgroundColor3 = Library.Theme.SurfaceRaised
            holder.BorderSizePixel = 0
            holder.Size = UDim2.new(1, 0, 0, 0)
            holder.AutomaticSize = Enum.AutomaticSize.Y
            holder.LayoutOrder = nextOrder()
            holder.Parent = sectionFrame
            corner(holder, 8)
            stroke(holder, Library.Theme.BorderSoft, 1, 0.35)
            padding(holder, 11)

            local paragraphLayout = Instance.new("UIListLayout")
            paragraphLayout.Padding = UDim.new(0, 5)
            paragraphLayout.SortOrder = Enum.SortOrder.LayoutOrder
            paragraphLayout.Parent = holder

            if paragraphOptions.Title then
                label(holder, {
                    Name = "ParagraphTitle",
                    Text = tostring(paragraphOptions.Title),
                    Font = Enum.Font.GothamMedium,
                    TextSize = 13,
                    TextColor3 = Library.Theme.GoldBright,
                    TextWrapped = true,
                    AutomaticSize = Enum.AutomaticSize.Y,
                    Size = UDim2.new(1, 0, 0, 0),
                    LayoutOrder = 1,
                })
            end
            label(holder, {
                Name = "ParagraphBody",
                Text = tostring(paragraphOptions.Text or ""),
                TextSize = 12,
                TextColor3 = Library.Theme.TextDim,
                TextWrapped = true,
                TextYAlignment = Enum.TextYAlignment.Top,
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                LineHeight = 1.2,
                LayoutOrder = 2,
            })
            return holder
        end

        function section:AddToggle(toggleOptions)
            toggleOptions = type(toggleOptions) == "table" and toggleOptions or {}
            local value = toggleOptions.Default == true

            local row = Instance.new("TextButton")
            row.Name = "Toggle"
            row.BackgroundColor3 = Library.Theme.SurfaceRaised
            row.BackgroundTransparency = 0.15
            row.BorderSizePixel = 0
            row.Size = UDim2.new(1, 0, 0, 44)
            row.Font = Enum.Font.Gotham
            row.Text = ""
            row.TextSize = 13
            row.AutoButtonColor = false
            row.LayoutOrder = nextOrder()
            row.Parent = sectionFrame
            corner(row, 8)
            stroke(row, Library.Theme.BorderSoft, 1, 0.35)

            label(row, {
                Text = toggleOptions.Text or "Toggle",
                TextSize = 13,
                TextColor3 = Library.Theme.Text,
                TextWrapped = true,
                Position = UDim2.new(0, 12, 0, 0),
                Size = UDim2.new(1, -80, 1, 0),
            })

            local track = Instance.new("Frame")
            track.Name = "Track"
            track.AnchorPoint = Vector2.new(1, 0.5)
            track.BackgroundColor3 = Library.Theme.SurfaceLight
            track.BorderSizePixel = 0
            track.Position = UDim2.new(1, -12, 0.5, 0)
            track.Size = UDim2.new(0, 44, 0, 24)
            track.Parent = row
            corner(track, 12)
            stroke(track, Library.Theme.Border, 1)

            local knob = Instance.new("Frame")
            knob.Name = "Knob"
            knob.AnchorPoint = Vector2.new(0, 0.5)
            knob.BackgroundColor3 = Library.Theme.TextDim
            knob.BorderSizePixel = 0
            knob.Position = UDim2.new(0, 3, 0.5, 0)
            knob.Size = UDim2.new(0, 18, 0, 18)
            knob.Parent = track
            corner(knob, 9)

            local element = {
                Set = nil,
                Get = function() return value end,
            }

            local function render(instant)
                local trackColor = value and Library.Theme.InteractiveBorder
                    or Library.Theme.SurfaceLight
                local knobColor = value and Library.Theme.GoldBright or Library.Theme.TextDim
                local knobProperties = {
                    BackgroundColor3 = knobColor,
                    Position = value
                        and UDim2.new(1, -21, 0.5, 0)
                        or UDim2.new(0, 3, 0.5, 0),
                }
                if instant then
                    track.BackgroundColor3 = trackColor
                    knob.BackgroundColor3 = knobColor
                    knob.Position = knobProperties.Position
                else
                    tween(track, { BackgroundColor3 = trackColor }, 0.18)
                    tween(knob, knobProperties, 0.18)
                end
            end

            function element.Set(_, newValue)
                local parsed = newValue == true
                if parsed == value then return end
                value = parsed
                render()
                if type(toggleOptions.Callback) == "function" then
                    task.spawn(toggleOptions.Callback, value)
                end
            end

            row.MouseButton1Click:Connect(function()
                element:Set(not value)
            end)

            render(true)
            if value and type(toggleOptions.Callback) == "function" then
                task.spawn(toggleOptions.Callback, value)
            end

            return element
        end

        function section:AddSlider(sliderOptions)
            sliderOptions = type(sliderOptions) == "table" and sliderOptions or {}
            local minimum = tonumber(sliderOptions.Min) or 0
            local maximum = tonumber(sliderOptions.Max) or 100
            maximum = math.max(maximum, minimum)
            local rounding = math.clamp(tonumber(sliderOptions.Rounding) or 0, 0, 3)
            local step = tonumber(sliderOptions.Step)
            local value = math.clamp(tonumber(sliderOptions.Default) or minimum, minimum, maximum)

            local holder = Instance.new("Frame")
            holder.Name = "Slider"
            holder.BackgroundColor3 = Library.Theme.SurfaceRaised
            holder.BackgroundTransparency = 0.15
            holder.BorderSizePixel = 0
            holder.Size = UDim2.new(1, 0, 0, 78)
            holder.LayoutOrder = nextOrder()
            holder.Parent = sectionFrame
            corner(holder, 8)
            stroke(holder, Library.Theme.BorderSoft, 1, 0.35)

            local header = label(holder, {
                Text = sliderOptions.Text or "Slider",
                TextSize = 13,
                TextColor3 = Library.Theme.Text,
                TextWrapped = true,
                TextYAlignment = Enum.TextYAlignment.Top,
                Position = UDim2.new(0, 12, 0, 7),
                Size = UDim2.new(1, -24, 0, 30),
            })

            local valueText = label(holder, {
                Text = "",
                Font = Enum.Font.GothamBold,
                TextSize = 13,
                TextColor3 = Library.Theme.Gold,
                Position = UDim2.new(0, 12, 0, 39),
                Size = UDim2.new(0, 58, 0, 24),
            })

            local track = Instance.new("TextButton")
            track.Name = "Track"
            track.BackgroundColor3 = Library.Theme.SurfaceLight
            track.BorderSizePixel = 0
            track.Position = UDim2.new(0, 78, 0, 48)
            track.Size = UDim2.new(1, -90, 0, 6)
            track.Font = Enum.Font.Gotham
            track.Text = ""
            track.AutoButtonColor = false
            track.Parent = holder
            corner(track, 3)

            local fill = Instance.new("Frame")
            fill.Name = "Fill"
            fill.AnchorPoint = Vector2.new(0, 0)
            fill.BackgroundColor3 = Library.Theme.Gold
            fill.BorderSizePixel = 0
            fill.Size = UDim2.new(0, 0, 1, 0)
            fill.Parent = track
            corner(fill, 3)

            local fillGradient = Instance.new("UIGradient")
            fillGradient.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Library.Theme.Gold),
                ColorSequenceKeypoint.new(1, Library.Theme.GoldDeep),
            })
            fillGradient.Parent = fill

            local knob = Instance.new("Frame")
            knob.Name = "Knob"
            knob.AnchorPoint = Vector2.new(0.5, 0.5)
            knob.BackgroundColor3 = Library.Theme.Text
            knob.BorderSizePixel = 0
            knob.Position = UDim2.new(0, 0, 0.5, 0)
            knob.Size = UDim2.new(0, 16, 0, 16)
            knob.Parent = track
            corner(knob, 8)
            stroke(knob, Library.Theme.GoldSoft, 1)

            local element = {
                Set = nil,
                Get = function() return value end,
            }

            local function quantize(rawValue)
                local stepped = rawValue
                if step and step > 0 then
                    stepped = minimum + math.floor((rawValue - minimum) / step + 0.5) * step
                end
                local exponent = 10 ^ rounding
                return math.floor(stepped * exponent + 0.5) / exponent
            end

            local function render(instant)
                local alpha = maximum > minimum
                    and (value - minimum) / (maximum - minimum)
                    or 0
                local fillScale = math.clamp(alpha, 0, 1)
                valueText.Text = string.format(
                    "%." .. rounding .. "f%s",
                    value,
                    sliderOptions.Suffix or ""
                )
                if instant then
                    fill.Size = UDim2.new(fillScale, 0, 1, 0)
                    knob.Position = UDim2.new(fillScale, 0, 0.5, 0)
                else
                    tween(fill, { Size = UDim2.new(fillScale, 0, 1, 0) }, 0.1)
                    tween(knob, { Position = UDim2.new(fillScale, 0, 0.5, 0) }, 0.1)
                end
            end

            function element.Set(_, newValue)
                local parsed = tonumber(newValue)
                if parsed == nil then return end
                local clamped = math.clamp(quantize(parsed), minimum, maximum)
                if clamped == value then
                    render(true)
                    return
                end
                value = clamped
                render()
                if type(sliderOptions.Callback) == "function" then
                    task.spawn(sliderOptions.Callback, value)
                end
            end

            local draggingSlider = false

            local function fromInput(input)
                local relative = math.clamp(
                    input.Position.X - track.AbsolutePosition.X,
                    0,
                    track.AbsoluteSize.X
                )
                local alpha = track.AbsoluteSize.X > 0
                    and relative / track.AbsoluteSize.X
                    or 0
                element:Set(minimum + (maximum - minimum) * alpha)
            end

            track.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch
                then
                    draggingSlider = true
                    fromInput(input)
                end
            end)

            connectGlobal(UserInputService.InputChanged, function(input)
                if not draggingSlider then return end
                if input.UserInputType ~= Enum.UserInputType.MouseMovement
                    and input.UserInputType ~= Enum.UserInputType.Touch
                then
                    return
                end
                fromInput(input)
            end)

            connectGlobal(UserInputService.InputEnded, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch
                then
                    draggingSlider = false
                end
            end)

            render(true)
            return element
        end

        function section:AddDropdown(dropdownOptions)
            dropdownOptions = type(dropdownOptions) == "table" and dropdownOptions or {}
            local multi = dropdownOptions.Multi == true
            local values = {}
            local valueLabels = {}
            local labelValues = {}
            local ambiguousLabels = {}

            local function rebuildValues(newValues)
                values = {}
                valueLabels = {}
                labelValues = {}
                ambiguousLabels = {}
                for _, entry in ipairs(newValues or {}) do
                    local rawValue = entry
                    local rawLabel = entry
                    if type(entry) == "table" then
                        rawValue = entry.Value or entry.value
                        rawLabel = entry.Text or entry.text
                            or entry.Label or entry.label
                            or rawValue
                    end
                    if rawValue ~= nil then
                        local value = tostring(rawValue)
                        local display = tostring(rawLabel or rawValue)
                        table.insert(values, value)
                        valueLabels[value] = display
                        if labelValues[display] == nil and not ambiguousLabels[display] then
                            labelValues[display] = value
                        elseif labelValues[display] ~= value then
                            labelValues[display] = nil
                            ambiguousLabels[display] = true
                        end
                    end
                end
            end

            local function resolveValue(entry)
                if type(entry) == "table" then
                    entry = entry.Value or entry.value
                end
                if entry == nil then return nil end
                local candidate = tostring(entry)
                if valueLabels[candidate] ~= nil then return candidate end

                -- Old InfinityGold configs stored "#ID translated name".
                -- Resolve those labels to the new stable ID-only value.
                local legacyId = string.match(candidate, "^#?(%d+)%s+")
                if legacyId ~= nil and valueLabels[legacyId] ~= nil then
                    return legacyId
                end
                return labelValues[candidate] or candidate
            end

            rebuildValues(dropdownOptions.Values)

            local selected = {}
            if multi then
                if type(dropdownOptions.Default) == "table" then
                    for _, entry in ipairs(dropdownOptions.Default) do
                        local value = resolveValue(entry)
                        if value ~= nil then selected[value] = true end
                    end
                end
            else
                local default = dropdownOptions.Default
                if default ~= nil then
                    local value = resolveValue(default)
                    if value ~= nil then selected[value] = true end
                elseif values[1] then
                    selected[values[1]] = true
                end
            end

            local holder = Instance.new("Frame")
            holder.Name = "Dropdown"
            holder.BackgroundTransparency = 1
            holder.Size = UDim2.new(1, 0, 0, 48)
            holder.LayoutOrder = nextOrder()
            holder.Parent = sectionFrame

            local button = Instance.new("TextButton")
            button.Name = "Button"
            button.BackgroundColor3 = Library.Theme.Interactive
            button.BorderSizePixel = 0
            button.Size = UDim2.new(1, 0, 0, 48)
            button.Font = Enum.Font.Gotham
            button.Text = ""
            button.TextSize = 13
            button.AutoButtonColor = false
            button.ZIndex = 3
            button.Parent = holder
            corner(button, 9)
            local buttonStroke = stroke(button, Library.Theme.InteractiveBorder, 1, 0.08)

            label(button, {
                Name = "Caption",
                Text = dropdownOptions.Text or "Dropdown",
                Font = Enum.Font.GothamMedium,
                TextSize = 10,
                TextColor3 = Library.Theme.TextDim,
                Position = UDim2.new(0, 14, 0, 5),
                Size = UDim2.new(1, -62, 0, 15),
                ZIndex = 4,
            })

            local valueText = label(button, {
                Name = "Value",
                Text = "",
                Font = Enum.Font.GothamMedium,
                TextSize = 13,
                TextColor3 = Library.Theme.GoldBright,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Position = UDim2.new(0, 14, 0, 21),
                Size = UDim2.new(1, -62, 0, 21),
                ZIndex = 4,
            })

            local arrowBox = Instance.new("Frame")
            arrowBox.Name = "ChevronBox"
            arrowBox.AnchorPoint = Vector2.new(1, 0.5)
            arrowBox.BackgroundColor3 = Library.Theme.InteractiveHover
            arrowBox.BorderSizePixel = 0
            arrowBox.Position = UDim2.new(1, -10, 0.5, 0)
            arrowBox.Size = UDim2.new(0, 28, 0, 28)
            arrowBox.ZIndex = 4
            arrowBox.Parent = button
            corner(arrowBox, 7)

            local arrow = label(arrowBox, {
                Name = "Chevron",
                Text = "v",
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = Library.Theme.GoldBright,
                TextXAlignment = Enum.TextXAlignment.Center,
                ZIndex = 5,
            })

            local maxVisible = math.max(1, math.floor(tonumber(dropdownOptions.MaxVisible) or 5))
            local optionHeight = 32
            local optionGap = 4
            local listPadding = 6

            local listFrame = Instance.new("ScrollingFrame")
            listFrame.Name = "List"
            listFrame.BackgroundColor3 = Library.Theme.SurfaceRaised
            listFrame.BorderSizePixel = 0
            listFrame.Position = UDim2.new(0, 0, 0, 54)
            listFrame.Size = UDim2.new(1, 0, 0, 0)
            listFrame.Visible = false
            listFrame.ScrollingDirection = Enum.ScrollingDirection.Y
            listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
            listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
            listFrame.ScrollBarThickness = 3
            listFrame.ScrollBarImageColor3 = Library.Theme.Gold
            listFrame.ScrollBarImageTransparency = 0.1
            listFrame.ZIndex = 8
            listFrame.Parent = holder
            corner(listFrame, 9)
            stroke(listFrame, Library.Theme.Border, 1)
            padding(listFrame, listPadding)

            local listLayout = Instance.new("UIListLayout")
            listLayout.Padding = UDim.new(0, optionGap)
            listLayout.SortOrder = Enum.SortOrder.LayoutOrder
            listLayout.Parent = listFrame

            local element = {
                Set = nil,
                Get = nil,
                SetValues = nil,
            }

            local function renderSelected()
                local parts = {}
                for _, entry in ipairs(values) do
                    if selected[entry] then
                        table.insert(parts, valueLabels[entry] or entry)
                    end
                end
                if #parts == 0 then
                    valueText.Text = multi and "Choose one or more..." or "Choose an option..."
                elseif multi and #parts > 3 then
                    valueText.Text = parts[1] .. ", " .. parts[2]
                        .. "  +" .. tostring(#parts - 2)
                else
                    valueText.Text = table.concat(parts, ", ")
                end
            end

            local function emit()
                renderSelected()
                if type(dropdownOptions.Callback) == "function" then
                    if multi then
                        local chosen = {}
                        for _, entry in ipairs(values) do
                            if selected[entry] then
                                table.insert(chosen, entry)
                            end
                        end
                        task.spawn(dropdownOptions.Callback, chosen)
                    else
                        local chosen = nil
                        for entry, isActive in pairs(selected) do
                            if isActive then chosen = entry end
                        end
                        task.spawn(dropdownOptions.Callback, chosen)
                    end
                end
            end

            local rebuildList
            local closeSelf

            local function listHeight()
                local rows = math.min(#values, maxVisible)
                if rows == 0 then return 44 end
                return listPadding * 2
                    + rows * optionHeight
                    + math.max(0, rows - 1) * optionGap
            end

            local function setOpen(open)
                if open then
                    if activeDropdownClose ~= nil and activeDropdownClose ~= closeSelf then
                        activeDropdownClose()
                    end
                    activeDropdownClose = closeSelf
                    rebuildList()
                elseif activeDropdownClose == closeSelf then
                    activeDropdownClose = nil
                end
                listFrame.Visible = open
                arrow.Text = open and "^" or "v"
                holder.Size = UDim2.new(1, 0, 0, open and (54 + listHeight()) or 48)
                tween(arrowBox, {
                    BackgroundColor3 = open and Library.Theme.InteractivePress
                        or Library.Theme.InteractiveHover,
                }, 0.14)
                tween(buttonStroke, {
                    Color = Library.Theme.InteractiveBorder,
                }, 0.14)
            end

            closeSelf = function()
                setOpen(false)
            end

            rebuildList = function()
                for _, child in ipairs(listFrame:GetChildren()) do
                    if child.Name == "Option" or child.Name == "Empty" then
                        child:Destroy()
                    end
                end
                local height = listHeight()
                listFrame.Size = UDim2.new(1, 0, 0, height)
                if listFrame.Visible then
                    holder.Size = UDim2.new(1, 0, 0, 54 + height)
                end

                if #values == 0 then
                    label(listFrame, {
                        Name = "Empty",
                        Text = "No options available",
                        TextSize = 12,
                        TextColor3 = Library.Theme.TextMuted,
                        TextXAlignment = Enum.TextXAlignment.Center,
                        Size = UDim2.new(1, 0, 0, 32),
                        LayoutOrder = 1,
                        ZIndex = 9,
                    })
                    return
                end

                for index, entry in ipairs(values) do
                    local optionButton = Instance.new("TextButton")
                    optionButton.Name = "Option"
                    optionButton.BackgroundColor3 = selected[entry]
                        and Library.Theme.SurfaceLight or Library.Theme.Surface
                    optionButton.BackgroundTransparency = selected[entry] and 0 or 0.45
                    optionButton.BorderSizePixel = 0
                    optionButton.Size = UDim2.new(1, 0, 0, optionHeight)
                    optionButton.Font = Enum.Font.Gotham
                    optionButton.Text = ""
                    optionButton.TextSize = 12
                    optionButton.AutoButtonColor = false
                    optionButton.LayoutOrder = index
                    optionButton.ZIndex = 9
                    optionButton.Parent = listFrame
                    corner(optionButton, 7)

                    local selectionMark = Instance.new("Frame")
                    selectionMark.Name = "Selection"
                    selectionMark.AnchorPoint = Vector2.new(0, 0.5)
                    selectionMark.BackgroundColor3 = Library.Theme.Gold
                    selectionMark.BackgroundTransparency = selected[entry] and 0 or 1
                    selectionMark.BorderSizePixel = 0
                    selectionMark.Position = UDim2.new(0, 8, 0.5, 0)
                    selectionMark.Size = UDim2.new(0, 3, 0, 16)
                    selectionMark.ZIndex = 10
                    selectionMark.Parent = optionButton
                    corner(selectionMark, 2)

                    label(optionButton, {
                        Text = valueLabels[entry] or entry,
                        Font = selected[entry] and Enum.Font.GothamMedium or Enum.Font.Gotham,
                        TextSize = 12,
                        TextColor3 = selected[entry] and Library.Theme.GoldBright
                            or Library.Theme.TextDim,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Position = UDim2.new(0, 18, 0, 0),
                        Size = UDim2.new(1, -48, 1, 0),
                        ZIndex = 10,
                    })

                    label(optionButton, {
                        Text = selected[entry] and (multi and "x" or "o") or "",
                        Font = Enum.Font.GothamBold,
                        TextSize = 11,
                        TextColor3 = Library.Theme.Gold,
                        TextXAlignment = Enum.TextXAlignment.Center,
                        Position = UDim2.new(1, -28, 0, 0),
                        Size = UDim2.new(0, 20, 1, 0),
                        ZIndex = 10,
                    })

                    optionButton.MouseButton1Click:Connect(function()
                        if multi then
                            selected[entry] = not selected[entry] or nil
                        else
                            selected = { [entry] = true }
                        end
                        emit()
                        rebuildList()
                        if not multi then
                            setOpen(false)
                        end
                    end)
                end
            end

            -- The header click toggles; a tap anywhere outside the dropdown
            -- also closes it, so an accidental open never needs a selection.
            button.MouseButton1Click:Connect(function()
                setOpen(not listFrame.Visible)
            end)

            connectGlobal(UserInputService.InputBegan, function(input, gameProcessed)
                if not listFrame.Visible then return end
                if input.UserInputType ~= Enum.UserInputType.MouseButton1
                    and input.UserInputType ~= Enum.UserInputType.Touch
                then
                    return
                end
                local position = input.Position
                local topLeft = holder.AbsolutePosition
                local size = holder.AbsoluteSize
                if position.X < topLeft.X
                    or position.X > topLeft.X + size.X
                    or position.Y < topLeft.Y
                    or position.Y > topLeft.Y + size.Y
                then
                    setOpen(false)
                end
            end)

            function element.Set(_, newValue)
                selected = {}
                if multi and type(newValue) == "table" then
                    for _, entry in ipairs(newValue) do
                        local value = resolveValue(entry)
                        if value ~= nil then selected[value] = true end
                    end
                elseif newValue ~= nil then
                    local value = resolveValue(newValue)
                    if value ~= nil then selected[value] = true end
                end
                emit()
                rebuildList()
            end

            function element.SetValues(_, newValues)
                rebuildValues(newValues)
                selected = {}
                emit()
                rebuildList()
            end

            function element.Get()
                if multi then
                    local chosen = {}
                    for _, entry in ipairs(values) do
                        if selected[entry] then
                            table.insert(chosen, entry)
                        end
                    end
                    return chosen
                end
                for entry, isActive in pairs(selected) do
                    if isActive then return entry end
                end
                return nil
            end

            rebuildList()
            renderSelected()
            return element
        end

        function section:AddButton(buttonOptions)
            buttonOptions = type(buttonOptions) == "table" and buttonOptions or {}
            local button = Instance.new("TextButton")
            button.Name = "Button"
            button.BackgroundColor3 = Library.Theme.Interactive
            button.BorderSizePixel = 0
            button.Size = UDim2.new(1, 0, 0, 40)
            button.Font = Enum.Font.GothamMedium
            button.Text = tostring(buttonOptions.Text or "Button")
            button.TextSize = 13
            button.TextColor3 = Library.Theme.GoldBright
            button.TextWrapped = true
            button.AutoButtonColor = false
            button.LayoutOrder = nextOrder()
            button.Parent = sectionFrame
            corner(button, 8)
            stroke(button, Library.Theme.InteractiveBorder, 1, 0.02)

            local hovered = false
            local function restoreButtonSurface(duration)
                tween(button, {
                    BackgroundColor3 = hovered and Library.Theme.InteractiveHover
                        or Library.Theme.Interactive,
                }, duration or 0.12)
            end
            button.MouseEnter:Connect(function()
                hovered = true
                tween(button, { BackgroundColor3 = Library.Theme.InteractiveHover }, 0.12)
            end)
            button.MouseLeave:Connect(function()
                hovered = false
                restoreButtonSurface()
            end)
            button.MouseButton1Down:Connect(function()
                tween(button, { BackgroundColor3 = Library.Theme.InteractivePress }, 0.06)
            end)
            button.InputEnded:Connect(function()
                restoreButtonSurface(0.1)
            end)

            button.MouseButton1Click:Connect(function()
                tween(button, { BackgroundColor3 = Library.Theme.InteractivePress }, 0.06)
                task.delay(0.1, function()
                    restoreButtonSurface(0.15)
                end)
                if type(buttonOptions.Callback) == "function" then
                    task.spawn(buttonOptions.Callback)
                end
            end)
            return button
        end

        function section:AddInput(inputOptions)
            inputOptions = type(inputOptions) == "table" and inputOptions or {}
            local textBox = Instance.new("TextBox")
            textBox.Name = "Input"
            textBox.BackgroundColor3 = Library.Theme.SurfaceRaised
            textBox.BorderSizePixel = 0
            textBox.Size = UDim2.new(1, 0, 0, 40)
            textBox.Font = Enum.Font.Gotham
            textBox.Text = tostring(inputOptions.Default or "")
            textBox.PlaceholderText = tostring(inputOptions.Placeholder or "")
            textBox.TextSize = 13
            textBox.TextColor3 = Library.Theme.Text
            textBox.ClearTextOnFocus = false
            textBox.LayoutOrder = nextOrder()
            textBox.Parent = sectionFrame
            corner(textBox, 8)
            stroke(textBox, Library.Theme.BorderSoft, 1)
            padding(textBox, 12)

            textBox.FocusLost:Connect(function(enterPressed)
                if type(inputOptions.Callback) == "function" then
                    task.spawn(inputOptions.Callback, textBox.Text, enterPressed)
                end
            end)
            return {
                Set = function(_, value) textBox.Text = tostring(value) end,
                Get = function() return textBox.Text end,
            }
        end

        return section
    end

    -- Attach a per-tab section factory
    local originalCreateTab = window.CreateTab
    window.CreateTab = function(self, tabOptions)
        local tab = originalCreateTab(self, tabOptions)
        function tab:CreateSection(name)
            return newSection(tab, name)
        end
        return tab
    end

    table.insert(Library._windows, window)
    return window
end

function Library:Destroy()
    for _, connection in ipairs(Library._connections or {}) do
        pcall(function() connection:Disconnect() end)
    end
    Library._connections = {}
    for _, window in ipairs(Library._windows) do
        pcall(function() window.Frame:Destroy() end)
    end
    Library._windows = {}
    if Library._gui then
        pcall(function() Library._gui:Destroy() end)
        Library._gui = nil
    end
end

return Library
