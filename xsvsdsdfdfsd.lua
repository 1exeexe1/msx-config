--[[
╔══════════════════════════════════════════════════════════════════╗
║   PROMETHEUS DEOBFUSCATOR TERMINAL  v1.0                        ║
║   Roblox Executor GUI — Runtime String Resolver                 ║
║                                                                  ║
║   Usage:  Paste obfuscated Lua into the input box, press RUN.   ║
║   The terminal captures ALL runtime-resolved strings:           ║
║     • print / warn / error output      (green / yellow / red)   ║
║     • game:GetService(?) calls         (cyan)                   ║
║     • __index property accesses        (blue)                   ║
║     • rawget / rawset calls            (magenta)                ║
║     • tostring / string.* calls        (white)                  ║
║                                                                  ║
║   HOW IT DEFEATS THE CIPHER:                                    ║
║   WeAreDevs v1.0.0 uses an address-seeded XOR cipher to hide   ║
║   property names. Those addresses only exist at runtime inside  ║
║   Roblox's Lua VM. This terminal runs the script and logs       ║
║   everything the cipher resolves — cracking it empirically.     ║
╚══════════════════════════════════════════════════════════════════╝
--]]

-- ─────────────────────────────────────────────────────────────────
-- SECTION 1: SAFE GUI CONTAINER
-- Try executor-specific protected GUI first, fall back to CoreGui
-- ─────────────────────────────────────────────────────────────────

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

local function makeGui()
    -- Try gethui() (modern executors), then syn.get_hidden_gui(), then PlayerGui
    local container
    if gethui then
        container = gethui()
    elseif syn and syn.protect_gui then
        local g = Instance.new("ScreenGui")
        syn.protect_gui(g)
        g.Parent = game.CoreGui
        return g
    else
        container = PlayerGui
    end
    local g = Instance.new("ScreenGui")
    g.Name               = "PrometheusTerminal"
    g.ResetOnSpawn        = false
    g.ZIndexBehavior      = Enum.ZIndexBehavior.Sibling
    g.IgnoreGuiInset      = true
    g.Parent              = container
    return g
end

local ScreenGui = makeGui()

-- ─────────────────────────────────────────────────────────────────
-- SECTION 2: COLOUR PALETTE  (CRT green terminal aesthetic)
-- ─────────────────────────────────────────────────────────────────

local C = {
    BG          = Color3.fromRGB(10,  12,  10 ),   -- near-black with green tint
    BG2         = Color3.fromRGB(18,  22,  18 ),   -- slightly lighter panel
    BG3         = Color3.fromRGB(26,  32,  26 ),   -- input / header bg
    BORDER      = Color3.fromRGB(0,   90,  20 ),   -- dim green border
    CURSOR      = Color3.fromRGB(0,   255, 60 ),   -- bright cursor green
    HEADER_TXT  = Color3.fromRGB(0,   230, 60 ),   -- header text
    PROMPT      = Color3.fromRGB(0,   200, 50 ),   -- prompt symbol
    -- output colour channels
    OUT_PRINT   = Color3.fromRGB(0,   255, 70 ),   -- print()
    OUT_WARN    = Color3.fromRGB(255, 200, 0  ),   -- warn()
    OUT_ERROR   = Color3.fromRGB(255, 60,  60 ),   -- error / pcall fail
    OUT_SERVICE = Color3.fromRGB(0,   220, 255),   -- GetService resolved
    OUT_INDEX   = Color3.fromRGB(80,  160, 255),   -- __index property
    OUT_RAW     = Color3.fromRGB(200, 80,  255),   -- rawget/rawset
    OUT_STRING  = Color3.fromRGB(220, 220, 220),   -- tostring / misc
    OUT_SYSTEM  = Color3.fromRGB(0,   160, 40 ),   -- system / separator
    OUT_DIM     = Color3.fromRGB(0,   100, 25 ),   -- dim secondary text
    BTN_RUN     = Color3.fromRGB(0,   140, 30 ),
    BTN_RUN_H   = Color3.fromRGB(0,   200, 50 ),
    BTN_CLEAR   = Color3.fromRGB(40,  40,  40 ),
    BTN_CLEAR_H = Color3.fromRGB(80,  80,  80 ),
    BTN_COPY    = Color3.fromRGB(20,  60,  80 ),
    BTN_COPY_H  = Color3.fromRGB(30,  100, 130),
    SCROLLBAR   = Color3.fromRGB(0,   80,  20 ),
}

local FONT_MONO = Enum.Font.Code
local FONT_UI   = Enum.Font.Code

-- ─────────────────────────────────────────────────────────────────
-- SECTION 3: UI CONSTRUCTION
-- ─────────────────────────────────────────────────────────────────

-- ── Main window frame ──────────────────────────────────────────

local Main = Instance.new("Frame")
Main.Name            = "Main"
Main.Size            = UDim2.new(0, 660, 0, 540)
Main.Position        = UDim2.new(0.5, -330, 0.5, -270)
Main.BackgroundColor3 = C.BG
Main.BorderSizePixel = 0
Main.ClipsDescendants = true
Main.Parent          = ScreenGui

-- Outer glow border
local OuterBorder = Instance.new("UIStroke")
OuterBorder.Color     = C.BORDER
OuterBorder.Thickness = 1.5
OuterBorder.Parent    = Main

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 6)
MainCorner.Parent       = Main

-- Scanline texture overlay (purely decorative Frame with gradient)
local Scanlines = Instance.new("Frame")
Scanlines.Size             = UDim2.new(1,0,1,0)
Scanlines.BackgroundColor3 = Color3.fromRGB(0,0,0)
Scanlines.BackgroundTransparency = 0.97
Scanlines.BorderSizePixel  = 0
Scanlines.ZIndex           = 10
Scanlines.Parent           = Main

-- ── Title bar ─────────────────────────────────────────────────

local TitleBar = Instance.new("Frame")
TitleBar.Name              = "TitleBar"
TitleBar.Size              = UDim2.new(1,0,0,36)
TitleBar.BackgroundColor3  = C.BG3
TitleBar.BorderSizePixel   = 0
TitleBar.Parent            = Main

local TitleBarCorner = Instance.new("UICorner")
TitleBarCorner.CornerRadius = UDim.new(0, 6)
TitleBarCorner.Parent       = TitleBar

-- Square off bottom corners of title bar
local TitleBarFix = Instance.new("Frame")
TitleBarFix.Size = UDim2.new(1,0,0.5,0)
TitleBarFix.Position = UDim2.new(0,0,0.5,0)
TitleBarFix.BackgroundColor3 = C.BG3
TitleBarFix.BorderSizePixel = 0
TitleBarFix.Parent = TitleBar

local TitleBarBorder = Instance.new("Frame")
TitleBarBorder.Size = UDim2.new(1,0,0,1)
TitleBarBorder.Position = UDim2.new(0,0,1,-1)
TitleBarBorder.BackgroundColor3 = C.BORDER
TitleBarBorder.BorderSizePixel = 0
TitleBarBorder.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size                = UDim2.new(1,-90,1,0)
TitleLabel.Position            = UDim2.new(0,14,0,0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Font                = FONT_MONO
TitleLabel.Text                = "PROMETHEUS TERMINAL  v1.0  ▐  Runtime Cipher Resolver"
TitleLabel.TextColor3          = C.HEADER_TXT
TitleLabel.TextSize            = 13
TitleLabel.TextXAlignment      = Enum.TextXAlignment.Left
TitleLabel.ZIndex              = 2
TitleLabel.Parent              = TitleBar

-- Traffic-light style close button
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size               = UDim2.new(0,20,0,20)
CloseBtn.Position           = UDim2.new(1,-28,0.5,-10)
CloseBtn.BackgroundColor3   = Color3.fromRGB(180, 40, 40)
CloseBtn.Text               = ""
CloseBtn.Font               = FONT_MONO
CloseBtn.ZIndex             = 5
CloseBtn.Parent             = TitleBar
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(1,0)

local CloseX = Instance.new("TextLabel")
CloseX.Size = UDim2.new(1,0,1,0)
CloseX.BackgroundTransparency = 1
CloseX.Text = "×"
CloseX.TextColor3 = Color3.fromRGB(255,255,255)
CloseX.TextSize = 14
CloseX.Font = FONT_MONO
CloseX.ZIndex = 6
CloseX.Parent = CloseBtn

-- ── Output area ────────────────────────────────────────────────

local OutputArea = Instance.new("ScrollingFrame")
OutputArea.Name                = "OutputArea"
OutputArea.Size                = UDim2.new(1,-4,0,354)
OutputArea.Position            = UDim2.new(0,2,0,38)
OutputArea.BackgroundColor3    = C.BG
OutputArea.BorderSizePixel     = 0
OutputArea.ScrollBarThickness  = 4
OutputArea.ScrollBarImageColor3 = C.SCROLLBAR
OutputArea.CanvasSize          = UDim2.new(0,0,0,0)
OutputArea.AutomaticCanvasSize = Enum.AutomaticSize.Y
OutputArea.ScrollingDirection  = Enum.ScrollingDirection.Y
OutputArea.Parent              = Main

local OutputList = Instance.new("UIListLayout")
OutputList.SortOrder     = Enum.SortOrder.LayoutOrder
OutputList.Padding       = UDim.new(0,1)
OutputList.Parent        = OutputArea

local OutputPadding = Instance.new("UIPadding")
OutputPadding.PaddingLeft   = UDim.new(0,8)
OutputPadding.PaddingRight  = UDim.new(0,8)
OutputPadding.PaddingTop    = UDim.new(0,4)
OutputPadding.PaddingBottom = UDim.new(0,4)
OutputPadding.Parent        = OutputArea

-- ── Divider ────────────────────────────────────────────────────

local Divider = Instance.new("Frame")
Divider.Size              = UDim2.new(1,-20,0,1)
Divider.Position          = UDim2.new(0,10,0,394)
Divider.BackgroundColor3  = C.BORDER
Divider.BorderSizePixel   = 0
Divider.Parent            = Main

-- ── Code input area ────────────────────────────────────────────

local InputLabel = Instance.new("TextLabel")
InputLabel.Size               = UDim2.new(1,0,0,16)
InputLabel.Position           = UDim2.new(0,10,0,398)
InputLabel.BackgroundTransparency = 1
InputLabel.Text               = "── PASTE OBFUSCATED CODE BELOW ─────────────────────────────────────"
InputLabel.TextColor3         = C.OUT_DIM
InputLabel.TextSize           = 10
InputLabel.Font               = FONT_MONO
InputLabel.TextXAlignment     = Enum.TextXAlignment.Left
InputLabel.Parent             = Main

local InputBox = Instance.new("TextBox")
InputBox.Name                = "InputBox"
InputBox.Size                = UDim2.new(1,-20,0,68)
InputBox.Position            = UDim2.new(0,10,0,416)
InputBox.BackgroundColor3    = C.BG3
InputBox.Text                = ""
InputBox.PlaceholderText     = "-- Paste obfuscated Lua here (Ctrl+A to select all, Ctrl+V to paste)"
InputBox.TextColor3          = Color3.fromRGB(180,240,180)
InputBox.PlaceholderColor3   = C.OUT_DIM
InputBox.TextSize            = 11
InputBox.Font                = FONT_MONO
InputBox.TextXAlignment      = Enum.TextXAlignment.Left
InputBox.TextYAlignment      = Enum.TextYAlignment.Top
InputBox.MultiLine           = true
InputBox.ClearTextOnFocus    = false
InputBox.BorderSizePixel     = 0
InputBox.ZIndex              = 2
InputBox.Parent              = Main

local InputCorner = Instance.new("UICorner")
InputCorner.CornerRadius = UDim.new(0,4)
InputCorner.Parent       = InputBox

local InputPad = Instance.new("UIPadding")
InputPad.PaddingLeft   = UDim.new(0,6)
InputPad.PaddingRight  = UDim.new(0,6)
InputPad.PaddingTop    = UDim.new(0,4)
InputPad.PaddingBottom = UDim.new(0,4)
InputPad.Parent        = InputBox

local InputBorder = Instance.new("UIStroke")
InputBorder.Color     = C.BORDER
InputBorder.Thickness = 1
InputBorder.Parent    = InputBox

-- ── Button row ─────────────────────────────────────────────────

local function makeButton(text, posX, width, bgColor, hoverColor)
    local btn = Instance.new("TextButton")
    btn.Size              = UDim2.new(0,width,0,26)
    btn.Position          = UDim2.new(0,posX,0,492)
    btn.BackgroundColor3  = bgColor
    btn.Text              = text
    btn.TextColor3        = Color3.fromRGB(220,255,220)
    btn.TextSize          = 12
    btn.Font              = FONT_MONO
    btn.BorderSizePixel   = 0
    btn.ZIndex            = 3
    btn.Parent            = Main
    Instance.new("UICorner",btn).CornerRadius = UDim.new(0,4)

    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12), {BackgroundColor3=hoverColor}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12), {BackgroundColor3=bgColor}):Play()
    end)
    return btn
end

local BtnRun   = makeButton("▶  RUN",    10,  120, C.BTN_RUN,   C.BTN_RUN_H)
local BtnClear = makeButton("⬜  CLEAR", 138, 100, C.BTN_CLEAR, C.BTN_CLEAR_H)
local BtnCopy  = makeButton("⎘  COPY LOG", 246, 120, C.BTN_COPY, C.BTN_COPY_H)

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size               = UDim2.new(0,180,0,26)
StatusLabel.Position           = UDim2.new(1,-190,0,492)
StatusLabel.BackgroundTransparency = 1
StatusLabel.Text               = "ready."
StatusLabel.TextColor3         = C.OUT_DIM
StatusLabel.TextSize           = 11
StatusLabel.Font               = FONT_MONO
StatusLabel.TextXAlignment     = Enum.TextXAlignment.Right
StatusLabel.Parent             = Main

-- ─────────────────────────────────────────────────────────────────
-- SECTION 4: DRAGGING
-- ─────────────────────────────────────────────────────────────────

do
    local dragging, dragStart, startPos
    TitleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging  = true
            dragStart = input.Position
            startPos  = Main.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            Main.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────
-- SECTION 5: LOG ENGINE
-- ─────────────────────────────────────────────────────────────────

local logLines   = {}
local lineOrder  = 0

local CATEGORIES = {
    PRINT   = { prefix = "  OUT │ ", color = C.OUT_PRINT   },
    WARN    = { prefix = " WARN │ ", color = C.OUT_WARN    },
    ERROR   = { prefix = "  ERR │ ", color = C.OUT_ERROR   },
    SERVICE = { prefix = "  SVC │ ", color = C.OUT_SERVICE },
    INDEX   = { prefix = "  IDX │ ", color = C.OUT_INDEX   },
    RAW     = { prefix = "  RAW │ ", color = C.OUT_RAW     },
    STRING  = { prefix = "  STR │ ", color = C.OUT_STRING  },
    SYSTEM  = { prefix = "  SYS │ ", color = C.OUT_SYSTEM  },
    SEP     = { prefix = "",          color = C.OUT_DIM     },
}

local function addLine(category, text)
    local cat  = CATEGORIES[category] or CATEGORIES.SYSTEM
    lineOrder  = lineOrder + 1

    -- Truncate very long lines
    local display = tostring(text or "")
    if #display > 300 then
        display = display:sub(1,297) .. "…"
    end

    local row = Instance.new("TextLabel")
    row.Size               = UDim2.new(1,0,0,0)
    row.AutomaticSize      = Enum.AutomaticSize.Y
    row.BackgroundTransparency = 1
    row.Text               = cat.prefix .. display
    row.TextColor3         = cat.color
    row.TextSize           = 12
    row.Font               = FONT_MONO
    row.TextXAlignment     = Enum.TextXAlignment.Left
    row.TextWrapped        = true
    row.RichText           = false
    row.LayoutOrder        = lineOrder
    row.ZIndex             = 2
    row.Parent             = OutputArea

    table.insert(logLines, row)

    -- Auto-scroll to bottom
    task.defer(function()
        OutputArea.CanvasPosition = Vector2.new(
            0,
            math.max(0, OutputArea.AbsoluteCanvasSize.Y - OutputArea.AbsoluteSize.Y)
        )
    end)
end

local function sep()
    addLine("SEP", "──────────────────────────────────────────────────────────────")
end

local function setStatus(msg, color)
    StatusLabel.Text       = msg
    StatusLabel.TextColor3 = color or C.OUT_DIM
end

-- ─────────────────────────────────────────────────────────────────
-- SECTION 6: HOOK ENGINE
-- Replaces global print/warn/error and patches game's metatable
-- to intercept GetService and property access in the sandbox env.
-- ─────────────────────────────────────────────────────────────────

-- Saved originals
local _print   = print
local _warn    = warn
local _error   = error
local _tostring = tostring

-- Convert varargs to a single display string
local function argsToString(...)
    local parts = {}
    for i = 1, select("#",...) do
        parts[i] = _tostring(select(i,...))
    end
    return table.concat(parts, "\t")
end

-- Build a spy environment for loadstring
-- This wraps game with a proxy that logs all method calls and index accesses.
local function buildSandboxEnv()
    local resolvedServices  = {}
    local resolvedProps     = {}
    local stringCalls       = {}

    -- Spy wrapper for a Roblox instance
    -- We use a real __index proxy via newproxy if available,
    -- otherwise fall back to a plain table with known keys forwarded.
    local function makeInstanceSpy(instance, label)
        local proxy = newproxy and newproxy(true) or nil
        if proxy then
            local mt = getmetatable(proxy)
            mt.__index = function(_, key)
                local val = instance[key]
                if type(key) == "string" then
                    local sig = label .. "." .. key
                    if not resolvedProps[sig] then
                        resolvedProps[sig] = true
                        addLine("INDEX", sig .. "  →  " .. _tostring(type(val)))
                    end
                end
                -- If the value is callable or is itself an Instance, wrap it too
                if typeof and typeof(val) == "Instance" then
                    return makeInstanceSpy(val, label .. "." .. key)
                elseif type(val) == "function" then
                    return function(selfArg, ...)
                        -- detect method calls (colon syntax passes instance as first arg)
                        local args = {...}
                        local argStr = ""
                        for i,v in ipairs(args) do
                            argStr = argStr .. (i>1 and ", " or "") .. _tostring(v)
                        end
                        addLine("INDEX", label .. ":" .. key .. "(" .. argStr .. ")")
                        -- actually call it
                        return val(instance, ...)
                    end
                end
                return val
            end
            mt.__newindex = function(_, key, val)
                addLine("INDEX", label .. "." .. key .. "  =  " .. _tostring(val))
                instance[key] = val
            end
            mt.__tostring = function() return _tostring(instance) end
            mt.__metatable = "locked"
            return proxy
        else
            -- Fallback: can't proxy, just return the real instance
            return instance
        end
    end

    -- Spy wrapper for game object
    local gameSpy = newproxy and newproxy(true) or nil
    if gameSpy then
        local mt = getmetatable(gameSpy)
        mt.__index = function(_, key)
            if key == "GetService" then
                return function(_, serviceName)
                    addLine("SERVICE", 'game:GetService("' .. _tostring(serviceName) .. '")')
                    local svc = game:GetService(serviceName)
                    return makeInstanceSpy(svc, serviceName)
                end
            elseif key == "Players" then
                addLine("SERVICE", 'game.Players  (direct access)')
                return makeInstanceSpy(game:GetService("Players"), "Players")
            else
                local val = game[key]
                addLine("INDEX", 'game["' .. _tostring(key) .. '"]  →  ' .. _tostring(type(val)))
                if typeof and typeof(val) == "Instance" then
                    return makeInstanceSpy(val, "game." .. key)
                end
                return val
            end
        end
        mt.__metatable = "locked"
    else
        gameSpy = game  -- can't proxy, use real game
    end

    -- String library spy
    local stringSpy = setmetatable({}, {
        __index = function(_, key)
            local orig = string[key]
            if type(orig) == "function" then
                return function(...)
                    local result = orig(...)
                    local argStr = argsToString(...)
                    if #argStr > 80 then argStr = argStr:sub(1,77).."…" end
                    addLine("STRING", 'string.' .. key .. '(' .. argStr .. ')  →  "' .. _tostring(result):sub(1,60) .. '"')
                    return result
                end
            end
            return orig
        end
    })

    -- Build the environment table
    local env = setmetatable({}, { __index = getfenv and getfenv(0) or _ENV })
    env.game        = gameSpy
    env.workspace   = makeInstanceSpy(workspace, "workspace")
    env.print = function(...)
        local s = argsToString(...)
        addLine("PRINT", s)
        _print(s)  -- also emit to real output
    end
    env.warn = function(...)
        local s = argsToString(...)
        addLine("WARN", s)
        _warn(s)
    end
    env.error = function(msg, level)
        addLine("ERROR", _tostring(msg))
    end
    env.tostring = function(v)
        local r = _tostring(v)
        -- Only log non-trivial tostring calls (skip numbers/booleans)
        if type(v) ~= "number" and type(v) ~= "boolean" then
            addLine("STRING", 'tostring(...)  →  "' .. r:sub(1,80) .. '"')
        end
        return r
    end
    env.string   = stringSpy
    env.rawget   = function(t, k)
        local v = rawget(t, k)
        addLine("RAW", 'rawget(t, "' .. _tostring(k) .. '")  →  ' .. _tostring(v))
        return v
    end
    env.rawset   = function(t, k, v)
        addLine("RAW", 'rawset(t, "' .. _tostring(k) .. '", ' .. _tostring(v) .. ')')
        return rawset(t, k, v)
    end

    -- Pass through everything else unchanged
    env.task             = task
    env.wait             = wait
    env.pairs            = pairs
    env.ipairs           = ipairs
    env.next             = next
    env.select           = select
    env.unpack           = unpack or table.unpack
    env.table            = table
    env.math             = math
    env.type             = type
    env.typeof           = typeof
    env.setmetatable     = setmetatable
    env.getmetatable     = getmetatable
    env.newproxy         = newproxy
    env.pcall            = pcall
    env.xpcall           = xpcall
    env.loadstring       = loadstring
    env.Instance         = Instance

    return env
end

-- ─────────────────────────────────────────────────────────────────
-- SECTION 7: RUN LOGIC
-- ─────────────────────────────────────────────────────────────────

local isRunning = false

local function runCode(code)
    if isRunning then
        addLine("WARN", "Already running. Wait for current script to finish.")
        return
    end
    if not code or code:match("^%s*$") then
        addLine("WARN", "No code to execute.")
        return
    end

    isRunning = true
    setStatus("running…", C.OUT_WARN)
    sep()
    addLine("SYSTEM", "▶  Executing script  (" .. #code .. " bytes)")
    addLine("SYSTEM", "   Hooks active: print · warn · error · game · string · rawget/rawset")
    sep()

    local t0 = tick()

    -- Build sandboxed environment
    local env = buildSandboxEnv()

    -- Compile
    local chunk, compileErr = loadstring(code, "@obfuscated")
    if not chunk then
        addLine("ERROR", "Compile error: " .. _tostring(compileErr))
        sep()
        setStatus("compile error.", C.OUT_ERROR)
        isRunning = false
        return
    end

    -- Set environment (Lua 5.1 style used by Roblox)
    if setfenv then
        setfenv(chunk, env)
    end

    -- Execute with pcall so errors don't crash the terminal
    local ok, err = pcall(chunk)

    local elapsed = string.format("%.3f", tick() - t0)
    sep()
    if ok then
        addLine("SYSTEM", "✓  Script completed in " .. elapsed .. "s")
        setStatus("done  " .. elapsed .. "s", C.OUT_PRINT)
    else
        addLine("ERROR", "Runtime error: " .. _tostring(err))
        addLine("SYSTEM", "✗  Script failed after " .. elapsed .. "s")
        setStatus("error.", C.OUT_ERROR)
    end
    sep()

    isRunning = false
end

-- ─────────────────────────────────────────────────────────────────
-- SECTION 8: BUTTON WIRING
-- ─────────────────────────────────────────────────────────────────

BtnRun.MouseButton1Click:Connect(function()
    local code = InputBox.Text
    task.spawn(runCode, code)
end)

BtnClear.MouseButton1Click:Connect(function()
    for _, v in ipairs(logLines) do v:Destroy() end
    logLines = {}
    lineOrder = 0
    setStatus("cleared.", C.OUT_DIM)
end)

BtnCopy.MouseButton1Click:Connect(function()
    local lines = {}
    for _, v in ipairs(logLines) do
        table.insert(lines, v.Text)
    end
    local full = table.concat(lines, "\n")
    if setclipboard then
        setclipboard(full)
        setStatus("copied to clipboard!", C.OUT_SERVICE)
    else
        -- Fallback: put it in the input box
        InputBox.Text = full
        setStatus("log → input box (no clipboard)", C.OUT_WARN)
    end
end)

CloseBtn.MouseButton1Click:Connect(function()
    TweenService:Create(Main, TweenInfo.new(0.2), {
        Size     = UDim2.new(0, 660, 0, 0),
        Position = UDim2.new(Main.Position.X.Scale, Main.Position.X.Offset, Main.Position.Y.Scale, Main.Position.Y.Offset + 270)
    }):Play()
    task.delay(0.22, function() ScreenGui:Destroy() end)
end)

-- ─────────────────────────────────────────────────────────────────
-- SECTION 9: STARTUP MESSAGE
-- ─────────────────────────────────────────────────────────────────

sep()
addLine("SYSTEM", "PROMETHEUS TERMINAL  v1.0  —  Runtime Cipher Resolver")
addLine("SYSTEM", "Executor: " .. (identifyexecutor and identifyexecutor() or "unknown"))
addLine("SYSTEM", "Place:    " .. tostring(game.PlaceId))
addLine("SYSTEM", "")
addLine("SYSTEM", "HOW TO USE:")
addLine("SYSTEM", "  1. Paste WeAreDevs-obfuscated Lua into the input box below")
addLine("SYSTEM", "  2. Press RUN — the cipher executes inside the Roblox VM")
addLine("SYSTEM", "  3. Watch SVC/IDX/STR lines — those are the resolved runtime strings")
addLine("SYSTEM", "     that the Python deobfuscator CANNOT recover statically")
addLine("SYSTEM", "")
addLine("SYSTEM", "LINE PREFIXES:")
addLine("PRINT",  "  OUT  →  print() output from the script")
addLine("WARN",   "  WARN →  warn() / non-fatal issues")
addLine("ERROR",  "  ERR  →  runtime errors")
addLine("SERVICE","  SVC  →  game:GetService(\"?\") call — cipher-resolved service name")
addLine("INDEX",  "  IDX  →  obj.property access — cipher-resolved property name")
addLine("RAW",    "  RAW  →  rawget/rawset operations")
addLine("STRING", "  STR  →  string library calls (char, byte, gsub, etc.)")
sep()
setStatus("ready.", C.OUT_DIM)

-- ─────────────────────────────────────────────────────────────────
-- SECTION 10: ENTRY ANIMATION
-- ─────────────────────────────────────────────────────────────────

Main.Size     = UDim2.new(0, 660, 0, 0)
Main.Position = UDim2.new(0.5,-330,0.5,0)

TweenService:Create(Main, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
    Size     = UDim2.new(0, 660, 0, 540),
    Position = UDim2.new(0.5,-330,0.5,-270)
}):Play()
