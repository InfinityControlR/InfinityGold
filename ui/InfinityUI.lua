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
    Version = "1.0.0",
    Brand = "INFINITYGOLD",
    Theme = {
        Background     = Color3.fromRGB(13, 13, 18),
        Surface        = Color3.fromRGB(20, 20, 27),
        SurfaceLight   = Color3.fromRGB(28, 28, 38),
        Border         = Color3.fromRGB(44, 42, 34),
        Gold           = Color3.fromRGB(245, 197, 66),
        GoldDeep       = Color3.fromRGB(212, 175, 55),
        GoldSoft       = Color3.fromRGB(120, 96, 34),
        Text           = Color3.fromRGB(235, 233, 228),
        TextDim        = Color3.fromRGB(154, 152, 146),
        Danger         = Color3.fromRGB(224, 82, 82),
        Success        = Color3.fromRGB(94, 198, 118),
    },
    _gui = nil,
    _windows = {},
    _tweens = {},
}

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
    local textLabel = Instance.new("TextLabel")
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
    screenGui.DisplayOrder = 999

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
    }

    local main = Instance.new("Frame")
    main.Name = "Window"
    main.AnchorPoint = Vector2.new(0.5, 0.5)
    main.BackgroundColor3 = Library.Theme.Background
    main.BorderSizePixel = 0
    main.Position = UDim2.new(0.5, 0, 0.5, 0)
    main.Size = UDim2.new(0, 580, 0, 420)
    main.ClipsDescendants = true
    main.Parent = screenGui
    corner(main, 12)
    stroke(main, Library.Theme.GoldSoft, 1)

    window.Frame = main

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.BackgroundColor3 = Library.Theme.Surface
    titleBar.BorderSizePixel = 0
    titleBar.Size = UDim2.new(1, 0, 0, 46)
    titleBar.Parent = main
    corner(titleBar, 12)

    local bottomPatch = Instance.new("Frame")
    bottomPatch.BackgroundColor3 = Library.Theme.Surface
    bottomPatch.BorderSizePixel = 0
    bottomPatch.Position = UDim2.new(0, 0, 1, -12)
    bottomPatch.Size = UDim2.new(1, 0, 0, 12)
    bottomPatch.Parent = titleBar

    local brandMark = Instance.new("Frame")
    brandMark.Name = "BrandMark"
    brandMark.AnchorPoint = Vector2.new(0, 0.5)
    brandMark.BackgroundColor3 = Library.Theme.Gold
    brandMark.BorderSizePixel = 0
    brandMark.Position = UDim2.new(0, 14, 0.5, 0)
    brandMark.Size = UDim2.new(0, 4, 0, 22)
    brandMark.Parent = titleBar
    corner(brandMark, 2)

    local brandGradient = Instance.new("UIGradient")
    brandGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Library.Theme.Gold),
        ColorSequenceKeypoint.new(1, Library.Theme.GoldDeep),
    })
    brandGradient.Rotation = 90
    brandGradient.Parent = brandMark

    local titleText = label(titleBar, {
        Text = options.Title or Library.Brand,
        Font = Enum.Font.GothamBold,
        TextSize = 16,
        TextColor3 = Library.Theme.Gold,
        Position = UDim2.new(0, 28, 0, 0),
        Size = UDim2.new(0, 220, 0.55, 0),
    })

    local subTitleText = label(titleBar, {
        Text = options.SubTitle or "",
        TextSize = 12,
        TextColor3 = Library.Theme.TextDim,
        Position = UDim2.new(0, 28, 0.55, 0),
        Size = UDim2.new(0, 320, 0.45, 0),
    })

    local minimizeButton = Instance.new("TextButton")
    minimizeButton.Name = "Minimize"
    minimizeButton.AnchorPoint = Vector2.new(1, 0.5)
    minimizeButton.BackgroundColor3 = Library.Theme.SurfaceLight
    minimizeButton.BackgroundTransparency = 0.4
    minimizeButton.Size = UDim2.new(0, 26, 0, 26)
    minimizeButton.Position = UDim2.new(1, -42, 0.5, 0)
    minimizeButton.Font = Enum.Font.GothamBold
    minimizeButton.Text = "-"
    minimizeButton.TextSize = 16
    minimizeButton.TextColor3 = Library.Theme.TextDim
    minimizeButton.Parent = titleBar
    corner(minimizeButton, 6)

    local closeButton = Instance.new("TextButton")
    closeButton.Name = "Close"
    closeButton.AnchorPoint = Vector2.new(1, 0.5)
    closeButton.BackgroundColor3 = Library.Theme.SurfaceLight
    closeButton.BackgroundTransparency = 0.4
    closeButton.Size = UDim2.new(0, 26, 0, 26)
    closeButton.Position = UDim2.new(1, -10, 0.5, 0)
    closeButton.Font = Enum.Font.GothamBold
    closeButton.Text = "x"
    closeButton.TextSize = 14
    closeButton.TextColor3 = Library.Theme.TextDim
    closeButton.Parent = titleBar
    corner(closeButton, 6)

    -- Body: navigation + content
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.BackgroundTransparency = 1
    body.Position = UDim2.new(0, 0, 0, 46)
    body.Size = UDim2.new(1, 0, 1, -46)
    body.Parent = main

    local nav = Instance.new("ScrollingFrame")
    nav.Name = "Navigation"
    nav.BackgroundColor3 = Library.Theme.Background
    nav.BorderSizePixel = 0
    nav.Position = UDim2.new(0, 0, 0, 0)
    nav.Size = UDim2.new(0, 152, 1, -28)
    nav.CanvasSize = UDim2.new(0, 0, 0, 0)
    nav.AutomaticCanvasSize = Enum.AutomaticSize.Y
    nav.ScrollBarThickness = 2
    nav.ScrollBarImageColor3 = Library.Theme.GoldSoft
    nav.Parent = body

    local navLayout = Instance.new("UIListLayout")
    navLayout.Padding = UDim.new(0, 4)
    navLayout.SortOrder = Enum.SortOrder.LayoutOrder
    navLayout.Parent = nav

    padding(nav, 8)

    local contentHolder = Instance.new("Frame")
    contentHolder.Name = "ContentHolder"
    contentHolder.BackgroundTransparency = 1
    contentHolder.Position = UDim2.new(0, 152, 0, 0)
    contentHolder.Size = UDim2.new(1, -152, 1, -28)
    contentHolder.ClipsDescendants = true
    contentHolder.Parent = body

    -- Footer status
    local footer = Instance.new("Frame")
    footer.Name = "Footer"
    footer.BackgroundColor3 = Library.Theme.Surface
    footer.BorderSizePixel = 0
    footer.AnchorPoint = Vector2.new(0, 1)
    footer.Position = UDim2.new(0, 0, 1, 0)
    footer.Size = UDim2.new(1, 0, 0, 28)
    footer.Parent = main
    corner(footer, 12)

    local footerPatch = Instance.new("Frame")
    footerPatch.BackgroundColor3 = Library.Theme.Surface
    footerPatch.BorderSizePixel = 0
    footerPatch.Position = UDim2.new(0, 0, 0, 0)
    footerPatch.Size = UDim2.new(1, 0, 0, 12)
    footerPatch.Parent = footer

    local statusDot = Instance.new("Frame")
    statusDot.AnchorPoint = Vector2.new(0, 0.5)
    statusDot.BackgroundColor3 = Library.Theme.Gold
    statusDot.BorderSizePixel = 0
    statusDot.Position = UDim2.new(0, 12, 0.5, 0)
    statusDot.Size = UDim2.new(0, 6, 0, 6)
    statusDot.Parent = footer
    corner(statusDot, 3)

    local statusText = label(footer, {
        Text = "",
        TextSize = 12,
        TextColor3 = Library.Theme.TextDim,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 26, 0, 0),
        Size = UDim2.new(1, -38, 1, 0),
    })

    window.StatusLabel = statusText

    function window:SetStatus(text)
        window.Status = tostring(text or "")
        statusText.Text = window.Status
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

        UserInputService.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType ~= Enum.UserInputType.MouseMovement
                and input.UserInputType ~= Enum.UserInputType.Touch
            then
                return
            end
            local delta = input.Position - dragStart
            tween(main, {
                Position = UDim2.new(
                    startPosition.X.Scale,
                    startPosition.X.Offset + delta.X,
                    startPosition.Y.Scale,
                    startPosition.Y.Offset + delta.Y
                ),
            }, 0.06)
        end)

        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch
            then
                dragging = false
            end
        end)
    end

    -- Visibility controls
    local visible = true
    local collapsed = false

    local function refreshCollapsed()
        local targetSize = collapsed
            and UDim2.new(0, 580, 0, 46)
            or UDim2.new(0, 580, 0, 420)
        tween(main, { Size = targetSize }, 0.3)
    end

    minimizeButton.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        minimizeButton.Text = collapsed and "+" or "-"
        refreshCollapsed()
    end)

    closeButton.MouseButton1Click:Connect(function()
        visible = false
        tween(main, { BackgroundTransparency = 1 }, 0.15)
        main.Visible = false
    end)

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
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

    function window:CreateTab(tabOptions)
        tabOptions = type(tabOptions) == "table" and tabOptions or {}
        tabCount = tabCount + 1

        local tab = { Sections = {} }

        local navButton = Instance.new("TextButton")
        navButton.Name = "Tab" .. tabCount
        navButton.BackgroundColor3 = Library.Theme.Background
        navButton.BackgroundTransparency = 1
        navButton.Size = UDim2.new(1, 0, 0, 30)
        navButton.Font = Enum.Font.Gotham
        navButton.Text = ""
        navButton.TextSize = 13
        navButton.AutoButtonColor = false
        navButton.Parent = nav
        corner(navButton, 6)

        local navHighlight = Instance.new("Frame")
        navHighlight.Name = "Highlight"
        navHighlight.AnchorPoint = Vector2.new(0, 0.5)
        navHighlight.BackgroundColor3 = Library.Theme.Gold
        navHighlight.BackgroundTransparency = 1
        navHighlight.Position = UDim2.new(0, 0, 0.5, 0)
        navHighlight.Size = UDim2.new(0, 3, 0, 16)
        navHighlight.Parent = navButton
        corner(navHighlight, 2)

        local iconText = label(navButton, {
            Text = tabOptions.Icon or ">",
            Font = Enum.Font.GothamBold,
            TextSize = 13,
            TextColor3 = Library.Theme.TextDim,
            TextXAlignment = Enum.TextXAlignment.Center,
            Position = UDim2.new(0, 6, 0, 0),
            Size = UDim2.new(0, 22, 1, 0),
        })

        local nameText = label(navButton, {
            Text = tabOptions.Name or ("Tab " .. tabCount),
            TextSize = 13,
            TextColor3 = Library.Theme.TextDim,
            Position = UDim2.new(0, 32, 0, 0),
            Size = UDim2.new(1, -38, 1, 0),
        })

        local page = Instance.new("ScrollingFrame")
        page.Name = "Page" .. tabCount
        page.BackgroundTransparency = 1
        page.Position = UDim2.new(0, 0, 0, 0)
        page.Size = UDim2.new(1, 0, 1, 0)
        page.CanvasSize = UDim2.new(0, 0, 0, 0)
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y
        page.ScrollBarThickness = 3
        page.ScrollBarImageColor3 = Library.Theme.GoldSoft
        page.Visible = false
        page.Parent = contentHolder
        padding(page, 12)

        local pageLayout = Instance.new("UIListLayout")
        pageLayout.Padding = UDim.new(0, 10)
        pageLayout.SortOrder = Enum.SortOrder.LayoutOrder
        pageLayout.Parent = page

        tab.Page = page
        tab.Button = navButton
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
                BackgroundTransparency = selected and 0.55 or 1,
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

    function window:CreateSection(name)
        error("CreateSection must be called on a tab, not the window")
    end

    -- Section factory attached to every tab
    local newSection

    newSection = function(tab, name)
        local sectionFrame = Instance.new("Frame")
        sectionFrame.Name = "Section"
        sectionFrame.BackgroundColor3 = Library.Theme.Surface
        sectionFrame.BorderSizePixel = 0
        sectionFrame.Size = UDim2.new(1, 0, 0, 0)
        sectionFrame.AutomaticSize = Enum.AutomaticSize.Y
        sectionFrame.Parent = tab.Page
        corner(sectionFrame, 8)
        stroke(sectionFrame, Library.Theme.Border, 1)

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 6)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = sectionFrame

        padding(sectionFrame, 10)

        if name and name ~= "" then
            local header = label(sectionFrame, {
                Text = string.upper(tostring(name)),
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = Library.Theme.Gold,
                Size = UDim2.new(1, 0, 0, 16),
            })
        end

        local section = { Frame = sectionFrame, Order = 0 }

        local function nextOrder()
            section.Order = section.Order + 10
            return section.Order
        end

        function section:AddLabel(text)
            local element = label(sectionFrame, {
                Text = tostring(text),
                TextSize = 13,
                TextColor3 = Library.Theme.TextDim,
                Size = UDim2.new(1, 0, 0, 18),
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
            holder.BackgroundTransparency = 1
            holder.Size = UDim2.new(1, 0, 0, 0)
            holder.AutomaticSize = Enum.AutomaticSize.Y
            holder.LayoutOrder = nextOrder()
            holder.Parent = sectionFrame

            if paragraphOptions.Title then
                label(holder, {
                    Text = tostring(paragraphOptions.Title),
                    Font = Enum.Font.GothamBold,
                    TextSize = 13,
                    TextColor3 = Library.Theme.Text,
                    Size = UDim2.new(1, 0, 0, 18),
                })
            end
            label(holder, {
                Text = tostring(paragraphOptions.Text or ""),
                TextSize = 12,
                TextColor3 = Library.Theme.TextDim,
                TextWrapped = true,
                TextYAlignment = Enum.TextYAlignment.Top,
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
            })
            return holder
        end

        function section:AddToggle(toggleOptions)
            toggleOptions = type(toggleOptions) == "table" and toggleOptions or {}
            local value = toggleOptions.Default == true

            local row = Instance.new("TextButton")
            row.Name = "Toggle"
            row.BackgroundTransparency = 1
            row.Size = UDim2.new(1, 0, 0, 30)
            row.Font = Enum.Font.Gotham
            row.Text = ""
            row.TextSize = 13
            row.AutoButtonColor = false
            row.LayoutOrder = nextOrder()
            row.Parent = sectionFrame

            label(row, {
                Text = toggleOptions.Text or "Toggle",
                TextSize = 13,
                TextColor3 = Library.Theme.Text,
                Position = UDim2.new(0, 0, 0, 0),
                Size = UDim2.new(1, -54, 1, 0),
            })

            local track = Instance.new("Frame")
            track.Name = "Track"
            track.AnchorPoint = Vector2.new(1, 0.5)
            track.BackgroundColor3 = Library.Theme.SurfaceLight
            track.BorderSizePixel = 0
            track.Position = UDim2.new(1, 0, 0.5, 0)
            track.Size = UDim2.new(0, 40, 0, 20)
            track.Parent = row
            corner(track, 10)
            stroke(track, Library.Theme.Border, 1)

            local knob = Instance.new("Frame")
            knob.Name = "Knob"
            knob.AnchorPoint = Vector2.new(0, 0.5)
            knob.BackgroundColor3 = Library.Theme.TextDim
            knob.BorderSizePixel = 0
            knob.Position = UDim2.new(0, 2, 0.5, 0)
            knob.Size = UDim2.new(0, 16, 0, 16)
            knob.Parent = track
            corner(knob, 8)

            local element = {
                Set = nil,
                Get = function() return value end,
            }

            local function render(instant)
                local targetColor = value and Library.Theme.Gold or Library.Theme.TextDim
                local targetX = value and 1 - 0.43 or 0
                local properties = {
                    BackgroundColor3 = targetColor,
                    Position = UDim2.new(targetX, value and -2 or 2, 0.5, 0),
                }
                if instant then
                    knob.BackgroundColor3 = targetColor
                    knob.Position = properties.Position
                else
                    tween(knob, properties, 0.18)
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
            holder.BackgroundTransparency = 1
            holder.Size = UDim2.new(1, 0, 0, 44)
            holder.LayoutOrder = nextOrder()
            holder.Parent = sectionFrame

            local header = label(holder, {
                Text = sliderOptions.Text or "Slider",
                TextSize = 13,
                TextColor3 = Library.Theme.Text,
                Position = UDim2.new(0, 0, 0, 0),
                Size = UDim2.new(1, -60, 0, 20),
            })

            local valueText = label(holder, {
                Text = "",
                Font = Enum.Font.GothamBold,
                TextSize = 13,
                TextColor3 = Library.Theme.Gold,
                TextXAlignment = Enum.TextXAlignment.Right,
                Position = UDim2.new(1, -60, 0, 0),
                Size = UDim2.new(0, 60, 0, 20),
            })

            local track = Instance.new("TextButton")
            track.Name = "Track"
            track.BackgroundColor3 = Library.Theme.SurfaceLight
            track.BorderSizePixel = 0
            track.Position = UDim2.new(0, 0, 0, 26)
            track.Size = UDim2.new(1, 0, 0, 8)
            track.Font = Enum.Font.Gotham
            track.Text = ""
            track.AutoButtonColor = false
            track.Parent = holder
            corner(track, 4)
            stroke(track, Library.Theme.Border, 1)

            local fill = Instance.new("Frame")
            fill.Name = "Fill"
            fill.AnchorPoint = Vector2.new(0, 0)
            fill.BackgroundColor3 = Library.Theme.Gold
            fill.BorderSizePixel = 0
            fill.Size = UDim2.new(0, 0, 1, 0)
            fill.Parent = track
            corner(fill, 4)

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
            knob.Size = UDim2.new(0, 12, 0, 12)
            knob.Parent = track
            corner(knob, 6)

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

            UserInputService.InputChanged:Connect(function(input)
                if not draggingSlider then return end
                if input.UserInputType ~= Enum.UserInputType.MouseMovement
                    and input.UserInputType ~= Enum.UserInputType.Touch
                then
                    return
                end
                fromInput(input)
            end)

            UserInputService.InputEnded:Connect(function(input)
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
            for _, entry in ipairs(dropdownOptions.Values or {}) do
                table.insert(values, tostring(entry))
            end

            local selected = {}
            if multi then
                if type(dropdownOptions.Default) == "table" then
                    for _, entry in ipairs(dropdownOptions.Default) do
                        selected[tostring(entry)] = true
                    end
                end
            else
                local default = dropdownOptions.Default
                if default ~= nil then
                    selected[tostring(default)] = true
                elseif values[1] then
                    selected[values[1]] = true
                end
            end

            local holder = Instance.new("Frame")
            holder.Name = "Dropdown"
            holder.BackgroundTransparency = 1
            holder.Size = UDim2.new(1, 0, 0, 30)
            holder.AutomaticSize = Enum.AutomaticSize.Y
            holder.LayoutOrder = nextOrder()
            holder.Parent = sectionFrame

            local button = Instance.new("TextButton")
            button.Name = "Button"
            button.BackgroundColor3 = Library.Theme.SurfaceLight
            button.BorderSizePixel = 0
            button.Size = UDim2.new(1, 0, 0, 30)
            button.Font = Enum.Font.Gotham
            button.Text = ""
            button.TextSize = 13
            button.AutoButtonColor = false
            button.Parent = holder
            corner(button, 6)
            stroke(button, Library.Theme.Border, 1)

            label(button, {
                Text = dropdownOptions.Text or "Dropdown",
                TextSize = 12,
                TextColor3 = Library.Theme.TextDim,
                Position = UDim2.new(0, 8, 0, 0),
                Size = UDim2.new(0, 110, 1, 0),
            })

            local valueText = label(button, {
                Text = "",
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Library.Theme.Gold,
                TextXAlignment = Enum.TextXAlignment.Right,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Position = UDim2.new(0, 120, 0, 0),
                Size = UDim2.new(1, -140, 1, 0),
            })

            local arrow = label(button, {
                Text = ">",
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = Library.Theme.TextDim,
                TextXAlignment = Enum.TextXAlignment.Center,
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, -8, 0, 0),
                Size = UDim2.new(0, 14, 1, 0),
            })

            local listFrame = Instance.new("Frame")
            listFrame.Name = "List"
            listFrame.BackgroundColor3 = Library.Theme.SurfaceLight
            listFrame.BorderSizePixel = 0
            listFrame.Position = UDim2.new(0, 0, 0, 34)
            listFrame.Size = UDim2.new(1, 0, 0, 0)
            listFrame.AutomaticSize = Enum.AutomaticSize.Y
            listFrame.Visible = false
            listFrame.Parent = holder
            corner(listFrame, 6)
            stroke(listFrame, Library.Theme.Border, 1)
            padding(listFrame, 4)

            local listLayout = Instance.new("UIListLayout")
            listLayout.Padding = UDim.new(0, 2)
            listLayout.SortOrder = Enum.SortOrder.LayoutOrder
            listLayout.Parent = listFrame

            local element = {
                Set = nil,
                Get = nil,
                SetValues = nil,
            }

            local function renderSelected()
                local parts = {}
                if multi then
                    for _, entry in ipairs(values) do
                        if selected[entry] then
                            table.insert(parts, entry)
                        end
                    end
                else
                    for entry, isActive in pairs(selected) do
                        if isActive then
                            table.insert(parts, entry)
                        end
                    end
                end
                valueText.Text = next(parts) ~= nil and table.concat(parts, ", ") or "..."
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

            local function rebuildList()
                for _, child in ipairs(listFrame:GetChildren()) do
                    if child:IsA("TextButton") then child:Destroy() end
                end
                for index, entry in ipairs(values) do
                    local optionButton = Instance.new("TextButton")
                    optionButton.Name = entry
                    optionButton.BackgroundColor3 = Library.Theme.Surface
                    optionButton.BackgroundTransparency = selected[entry] and 0 or 1
                    optionButton.BorderSizePixel = 0
                    optionButton.Size = UDim2.new(1, 0, 0, 24)
                    optionButton.Font = Enum.Font.Gotham
                    optionButton.Text = ""
                    optionButton.TextSize = 12
                    optionButton.AutoButtonColor = false
                    optionButton.LayoutOrder = index
                    optionButton.Parent = listFrame
                    corner(optionButton, 4)

                    label(optionButton, {
                        Text = (selected[entry] and "[x] " or "[ ] ") .. entry,
                        TextSize = 12,
                        TextColor3 = selected[entry] and Library.Theme.Gold or Library.Theme.TextDim,
                        Position = UDim2.new(0, 8, 0, 0),
                        Size = UDim2.new(1, -16, 1, 0),
                    })

                    optionButton.MouseButton1Click:Connect(function()
                        if multi then
                            selected[entry] = not selected[entry] or nil
                        else
                            selected = { [entry] = true }
                            listFrame.Visible = false
                            arrow.Text = ">"
                        end
                        emit()
                        rebuildList()
                    end)
                end
            end

            button.MouseButton1Click:Connect(function()
                listFrame.Visible = not listFrame.Visible
                arrow.Text = listFrame.Visible and "v" or ">"
                if listFrame.Visible then
                    rebuildList()
                end
            end)

            function element.Set(_, newValue)
                selected = {}
                if multi and type(newValue) == "table" then
                    for _, entry in ipairs(newValue) do
                        selected[tostring(entry)] = true
                    end
                elseif newValue ~= nil then
                    selected[tostring(newValue)] = true
                end
                emit()
                rebuildList()
            end

            function element.SetValues(_, newValues)
                values = {}
                for _, entry in ipairs(newValues or {}) do
                    table.insert(values, tostring(entry))
                end
                selected = {}
                emit()
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
            button.BackgroundColor3 = Library.Theme.SurfaceLight
            button.BorderSizePixel = 0
            button.Size = UDim2.new(1, 0, 0, 30)
            button.Font = Enum.Font.GothamMedium
            button.Text = tostring(buttonOptions.Text or "Button")
            button.TextSize = 13
            button.TextColor3 = Library.Theme.Text
            button.AutoButtonColor = false
            button.LayoutOrder = nextOrder()
            button.Parent = sectionFrame
            corner(button, 6)
            stroke(button, Library.Theme.GoldSoft, 1)

            button.MouseButton1Click:Connect(function()
                tween(button, { BackgroundColor3 = Library.Theme.GoldSoft }, 0.08)
                task.delay(0.1, function()
                    tween(button, { BackgroundColor3 = Library.Theme.SurfaceLight }, 0.15)
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
            textBox.BackgroundColor3 = Library.Theme.SurfaceLight
            textBox.BorderSizePixel = 0
            textBox.Size = UDim2.new(1, 0, 0, 30)
            textBox.Font = Enum.Font.Gotham
            textBox.Text = tostring(inputOptions.Default or "")
            textBox.PlaceholderText = tostring(inputOptions.Placeholder or "")
            textBox.TextSize = 13
            textBox.TextColor3 = Library.Theme.Text
            textBox.ClearTextOnFocus = false
            textBox.LayoutOrder = nextOrder()
            textBox.Parent = sectionFrame
            corner(textBox, 6)
            stroke(textBox, Library.Theme.Border, 1)
            padding(textBox, 8)

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
