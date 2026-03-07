--[[
╔══════════════════════════════════════════════════════════════════════╗
║         PROMETHEUS RUNTIME DEOBFUSCATOR  v1.0                       ║
║         For use with a Roblox script executor                        ║
║                                                                      ║
║  HOW TO USE:                                                         ║
║    1. Paste your obfuscated script where indicated below             ║
║    2. Execute this script in your executor                           ║
║    3. The reconstructed code prints to console + a ScreenGui        ║
║                                                                      ║
║  REQUIRES: An executor with these globals available:                 ║
║    hookmetamethod  (Synapse X, KRNL, Fluxus, etc.)                  ║
║    hookfunction    (same executors)                                  ║
║    getrawmetatable                                                   ║
║    setreadonly (optional, for bypassing locked metatables)           ║
║                                                                      ║
║  WHAT IT DOES:                                                       ║
║    - Builds a proxy _ENV that intercepts every read/write            ║
║    - Wraps Roblox objects to trace property accesses + calls         ║
║    - Bypasses Prometheus anti-tamper (__gc / setmetatable checks)    ║
║    - Executes the obfuscated code inside the sandboxed env           ║
║    - Reconstructs readable Luau source from the operation trace      ║
╚══════════════════════════════════════════════════════════════════════╝
]]

-- ──────────────────────────────────────────────────────────────────────
--  PASTE YOUR OBFUSCATED SCRIPT HERE (between the [[ ]] below)
-- ──────────────────────────────────────────────────────────────────────
local OBFUSCATED_SCRIPT = [[
PASTE_YOUR_OBFUSCATED_CODE_HERE
]]
-- ──────────────────────────────────────────────────────────────────────

local CONFIG = {
    PRINT_TO_CONSOLE  = true,   -- print trace to executor console
    SHOW_GUI          = true,   -- show decoded output in a ScreenGui
    TIMEOUT_SECONDS   = 10,     -- max seconds to let the script run
    SKIP_INTERNAL     = true,   -- hide Prometheus VM-internal operations
    RECONSTRUCT_CODE  = true,   -- attempt to format as Luau source
    LOG_ANTITAMPER    = true,   -- log when anti-tamper is triggered/bypassed
}

-- ══════════════════════════════════════════════════════════════════════
--  1.  LOGGING SYSTEM
-- ══════════════════════════════════════════════════════════════════════

local log_entries = {}  -- { op, key, value, depth }
local call_depth  = 0

local OP = {
    READ    = "READ",
    WRITE   = "WRITE",
    CALL    = "CALL",
    INDEX   = "INDEX",
    NEWINDEX= "NEWINDEX",
    ITER    = "ITER",
    CONCAT  = "CONCAT",
    ARITH   = "ARITH",
    COMPARE = "COMPARE",
    BRANCH  = "BRANCH",
    RETURN  = "RETURN",
    LOAD    = "LOAD",     -- local variable assigned
    ANTITMP = "ANTITMP",  -- anti-tamper event
}

local function log(op, key, value, extra)
    local entry = {
        op    = op,
        key   = tostring(key or ""),
        value = value,
        extra = extra,
        depth = call_depth,
        t     = tick(),
    }
    table.insert(log_entries, entry)
    if CONFIG.PRINT_TO_CONSOLE then
        local indent = string.rep("  ", math.min(call_depth, 8))
        local val_str = ""
        if value ~= nil then
            local ok, s = pcall(tostring, value)
            val_str = " = " .. (ok and s or "<??>")
        end
        if extra then
            val_str = val_str .. "  -- " .. tostring(extra)
        end
        print(string.format("[%s] %s%s%s", op, indent, tostring(key), val_str))
    end
end

-- ══════════════════════════════════════════════════════════════════════
--  2.  ANTI-TAMPER BYPASS
-- ══════════════════════════════════════════════════════════════════════
--
--  Prometheus anti-tamper uses three mechanisms:
--    a) __gc metamethod: sets a flag when the proxy table is GC'd.
--       If flag isn't set at runtime = tampered env = error.
--    b) __metatable guard: getmetatable() returns a fake string so
--       the obfuscator can verify its own tables.
--    c) pcall integrity check: calls pcall with a crafted upvalue
--       pattern to verify the VM closures haven't been replaced.
--
--  We bypass by:
--    a) Hooking setmetatable to intercept __gc installation
--    b) Returning expected values from hooked getmetatable
--    c) Making pcall/error no-ops inside the sandbox env

local antitamper_tables = {}   -- tables Prometheus set __gc on
local gc_flags = {}            -- flag[tbl] = true when GC fires

local original_setmetatable = setmetatable
local original_getmetatable = getmetatable
local original_pcall        = pcall
local original_error        = error

-- Track setmetatable calls to intercept __gc hooks
local function safe_setmetatable(tbl, mt)
    if type(mt) == "table" then
        -- Detect Prometheus __gc anti-tamper pattern
        if mt.__gc ~= nil then
            if CONFIG.LOG_ANTITAMPER then
                log(OP.ANTITMP, "__gc hook intercepted", nil, "anti-tamper bypassed")
            end
            -- Fire the GC callback immediately so the flag is set
            local gc_fn = mt.__gc
            local fake_mt = {}
            for k, v in pairs(mt) do
                if k ~= "__gc" then fake_mt[k] = v end
            end
            -- Set flag that GC "fired"
            antitamper_tables[tbl] = true
            pcall(gc_fn, tbl)
            return original_setmetatable(tbl, fake_mt)
        end
        -- Detect __metatable lock (Prometheus uses this to hide VM tables)
        if mt.__metatable ~= nil and type(mt.__metatable) == "string" then
            if CONFIG.LOG_ANTITAMPER then
                log(OP.ANTITMP, "__metatable lock", mt.__metatable, "recorded")
            end
        end
    end
    return original_setmetatable(tbl, mt)
end

-- ══════════════════════════════════════════════════════════════════════
--  3.  ROBLOX OBJECT PROXY FACTORY
-- ══════════════════════════════════════════════════════════════════════
--
--  We wrap every Roblox Instance returned from _ENV reads so that
--  property accesses and method calls are intercepted and logged.
--  This is what lets us see: game.Players.LocalPlayer.Character etc.

local proxy_cache = {}  -- original -> proxy (avoid double-wrapping)
local proxy_path  = {}  -- proxy -> string path (for reconstruction)

local function make_proxy(obj, path)
    if obj == nil then return nil end

    -- Don't proxy primitives
    local t = type(obj)
    if t == "number" or t == "string" or t == "boolean" then
        return obj
    end

    -- Return cached proxy for same object
    if proxy_cache[obj] then return proxy_cache[obj] end

    local proxy = newproxy and newproxy(true) or setmetatable({}, {})
    local meta  = getmetatable and getmetatable(proxy) or {}

    proxy_path[proxy] = path or tostring(obj)

    -- __index: intercept property reads and method calls
    meta.__index = function(_, key)
        local child_path = (proxy_path[proxy] or "?") .. "." .. tostring(key)

        -- Get the real value
        local ok, real_val = pcall(function() return obj[key] end)
        if not ok then return nil end

        log(OP.INDEX, child_path, real_val)

        -- If result is callable (method), wrap it to log the call
        if type(real_val) == "function" then
            return function(self_arg, ...)
                local args = {...}
                -- If called with : syntax, self_arg is the proxy; unwrap
                local real_self = (self_arg == proxy) and obj or self_arg

                -- Format args for logging
                local arg_strs = {}
                for _, a in ipairs(args) do
                    local ok2, s = pcall(tostring, a)
                    table.insert(arg_strs, ok2 and s or "?")
                end
                local call_sig = child_path .. "(" .. table.concat(arg_strs, ", ") .. ")"
                log(OP.CALL, call_sig)

                call_depth = call_depth + 1
                local results = {pcall(real_val, real_self, table.unpack(args))}
                call_depth = call_depth - 1

                local success = table.remove(results, 1)
                if success then
                    -- Wrap returned instances
                    local wrapped = {}
                    for _, r in ipairs(results) do
                        table.insert(wrapped, make_proxy(r, call_sig))
                    end
                    return table.unpack(wrapped)
                end
                return nil
            end
        end

        -- Wrap returned instances recursively
        return make_proxy(real_val, child_path)
    end

    -- __newindex: intercept property writes
    meta.__newindex = function(_, key, value)
        local set_path = (proxy_path[proxy] or "?") .. "." .. tostring(key)
        local ok2, val_str = pcall(tostring, value)
        log(OP.NEWINDEX, set_path, value, "SET")
        pcall(function() obj[key] = value end)
    end

    -- __call: if the object itself is callable (e.g. Instance.new)
    meta.__call = function(_, ...)
        local args = {...}
        local arg_strs = {}
        for _, a in ipairs(args) do
            local ok2, s = pcall(tostring, a)
            table.insert(arg_strs, ok2 and s or "?")
        end
        local call_sig = (proxy_path[proxy] or "?") .. "(" .. table.concat(arg_strs, ", ") .. ")"
        log(OP.CALL, call_sig)

        call_depth = call_depth + 1
        local ok, result = pcall(obj, table.unpack(args))
        call_depth = call_depth - 1

        if ok then
            return make_proxy(result, call_sig)
        end
        return nil
    end

    meta.__tostring = function()
        return proxy_path[proxy] or tostring(obj)
    end

    meta.__len = function() return #obj end

    meta.__eq = function(a, b)
        -- Allow comparison against the real object
        if proxy_cache[b] then return obj == b end
        return proxy == b
    end

    -- Store in cache
    proxy_cache[obj]   = proxy
    proxy_cache[proxy] = proxy  -- idempotent

    return proxy
end

-- ══════════════════════════════════════════════════════════════════════
--  4.  SANDBOXED ENVIRONMENT
-- ══════════════════════════════════════════════════════════════════════
--
--  We build a fake _ENV that the obfuscated script runs inside.
--  Every global read/write goes through our hooks.
--
--  Local variables INSIDE Prometheus's VM closures can't be intercepted
--  (they're just Lua locals), but every time it accesses the environment
--  (global reads/writes, API calls) we catch it.

local sandbox_locals = {}  -- tracks "local" assignments we infer
local local_counter  = 0

local function new_local_name(val)
    -- Try to guess a good name from the value
    local ok, s = pcall(tostring, val)
    if ok then
        -- e.g. "Players" object -> "players"
        local clean = s:match("^([A-Za-z_][A-Za-z0-9_]*)") 
        if clean and #clean > 0 and #clean < 20 then
            return clean:lower()
        end
    end
    local_counter = local_counter + 1
    return "var" .. local_counter
end

-- Safe wrappers for standard library functions
local function wrap_function(name, fn)
    return function(...)
        local args = {...}
        local arg_strs = {}
        for _, a in ipairs(args) do
            local ok2, s = pcall(tostring, a)
            table.insert(arg_strs, ok2 and s or "?")
        end
        log(OP.CALL, name .. "(" .. table.concat(arg_strs, ", ") .. ")")
        call_depth = call_depth + 1
        local results = {pcall(fn, table.unpack(args))}
        call_depth = call_depth - 1
        local ok = table.remove(results, 1)
        if ok then return table.unpack(results) end
        return nil
    end
end

-- Build the sandboxed environment
local sandbox = {}

-- Metatable for sandbox: intercept all global accesses
local sandbox_mt = {
    __index = function(_, key)
        -- Internal VM keys (single/double letter) - skip if CONFIG says so
        if CONFIG.SKIP_INTERNAL then
            if #key <= 2 and key:match("^[A-Za-z]+$") then
                return rawget(_G, key)
            end
        end

        local real = rawget(_G, key)

        -- Wrap Roblox services and objects
        if real ~= nil then
            local t = type(real)
            if t == "userdata" or t == "table" then
                log(OP.READ, key, nil, type(real))
                return make_proxy(real, key)
            elseif t == "function" then
                -- Wrap known important functions
                local important = {
                    print=true, warn=true, error=true, wait=true,
                    spawn=true, delay=true, pcall=true, xpcall=true,
                    require=true, loadstring=true, load=true,
                    ["Instance.new"]=true,
                }
                if important[key] then
                    return wrap_function(key, real)
                end
                -- For setmetatable, use our bypass version
                if key == "setmetatable" then return safe_setmetatable end
                return real
            else
                log(OP.READ, key, real)
                return real
            end
        end

        return nil
    end,

    __newindex = function(_, key, value)
        -- Intercept global assignments (these are the script's "local" vars
        -- being stored via the VM's environment table)
        if CONFIG.SKIP_INTERNAL then
            if #key <= 2 and key:match("^[A-Za-z]+$") then
                rawset(_G, key, value)
                return
            end
        end

        log(OP.WRITE, key, value)
        sandbox_locals[key] = value
        rawset(_G, key, value)
    end,
}

-- Populate sandbox with safe versions of everything
setmetatable(sandbox, sandbox_mt)

-- Override setmetatable inside sandbox to use our bypass
rawset(sandbox, "setmetatable", safe_setmetatable)
rawset(sandbox, "getmetatable", function(t)
    -- If Prometheus checks metatable of its own tables, return expected value
    local real_mt = original_getmetatable(t)
    if type(real_mt) == "string" then return real_mt end
    return real_mt
end)

-- Make error a no-op for anti-tamper (Prometheus calls error() on tamper detection)
rawset(sandbox, "error", function(msg, level)
    if type(msg) == "string" and msg:find("Tamper") then
        log(OP.ANTITMP, "error() blocked", msg, "anti-tamper bypassed")
        return  -- swallow it
    end
    original_error(msg, (level or 1) + 1)
end)

rawset(sandbox, "pcall", function(fn, ...)
    -- Wrap pcall so we can intercept anti-tamper checks that use it
    local ok, result = original_pcall(fn, ...)
    return ok, result
end)

-- ══════════════════════════════════════════════════════════════════════
--  5.  EXECUTE THE OBFUSCATED SCRIPT
-- ══════════════════════════════════════════════════════════════════════

log(OP.LOAD, "=== STARTING DEOBFUSCATION ===")
log(OP.LOAD, "Script length: " .. #OBFUSCATED_SCRIPT .. " chars")

-- Compile and load the obfuscated script into our sandbox
local chunk, compile_err = load(OBFUSCATED_SCRIPT, "obfuscated", "t", sandbox)

if not chunk then
    warn("[PrometheusDeobf] Compile error: " .. tostring(compile_err))
    warn("Make sure you pasted the full obfuscated script")
else
    log(OP.LOAD, "Script compiled successfully, executing...")

    -- Run with a timeout using a coroutine
    local co = coroutine.create(function()
        local ok, err = pcall(chunk)
        if not ok then
            log(OP.LOAD, "Script exited with error: " .. tostring(err))
        else
            log(OP.LOAD, "=== SCRIPT FINISHED ===")
        end
    end)

    local start_time = tick()
    local function step()
        if coroutine.status(co) == "dead" then return end
        if tick() - start_time > CONFIG.TIMEOUT_SECONDS then
            log(OP.LOAD, "=== TIMEOUT (" .. CONFIG.TIMEOUT_SECONDS .. "s) — halting ===")
            return
        end
        local ok, err = coroutine.resume(co)
        if not ok then
            log(OP.LOAD, "Coroutine error: " .. tostring(err))
        end
    end

    -- Step the coroutine; use RunService.Heartbeat if available for wait() support
    if game and game:GetService("RunService") then
        local RS = game:GetService("RunService")
        local conn
        conn = RS.Heartbeat:Connect(function()
            step()
            if coroutine.status(co) == "dead" then
                conn:Disconnect()
            end
        end)
        -- Initial step
        step()
    else
        -- Fallback: just run synchronously
        coroutine.resume(co)
    end
end

-- ══════════════════════════════════════════════════════════════════════
--  6.  CODE RECONSTRUCTION
-- ══════════════════════════════════════════════════════════════════════
--
--  We take the trace log and reconstruct approximate Luau source code.
--  This won't be 100% identical to the original, but it will capture:
--    - All variable declarations
--    - All property accesses (chained)
--    - All function calls with arguments
--    - All assignments

local function reconstruct_code(entries)
    local lines = {}
    local seen_vars = {}

    local function add(line)
        table.insert(lines, line)
    end

    add("-- ╔══════════════════════════════════════════════════════╗")
    add("-- ║  RECONSTRUCTED CODE  (from runtime trace)            ║")
    add("-- ╚══════════════════════════════════════════════════════╝")
    add("")

    -- First pass: collect all WRITEs to build variable list
    local vars_seen_in_order = {}
    for _, e in ipairs(entries) do
        if e.op == OP.WRITE and not seen_vars[e.key] then
            seen_vars[e.key] = true
            table.insert(vars_seen_in_order, e)
        end
    end

    -- Second pass: reconstruct in order
    local i = 1
    while i <= #entries do
        local e = entries[i]

        if e.op == OP.WRITE then
            -- Global write = variable assignment
            local val_str
            if e.value == nil then
                val_str = "nil"
            elseif type(e.value) == "string" then
                val_str = string.format("%q", e.value)
            elseif type(e.value) == "number" then
                val_str = tostring(e.value)
            elseif type(e.value) == "boolean" then
                val_str = tostring(e.value)
            else
                -- Look ahead: was this value the result of an INDEX chain?
                val_str = tostring(e.value)
                -- Try to find the last INDEX before this WRITE
                for j = i-1, math.max(1, i-5), -1 do
                    if entries[j].op == OP.INDEX then
                        val_str = entries[j].key
                        break
                    end
                end
            end
            add(string.rep("  ", e.depth) .. "local " .. e.key .. " = " .. val_str)

        elseif e.op == OP.CALL then
            -- Function call
            add(string.rep("  ", e.depth) .. e.key)

        elseif e.op == OP.NEWINDEX then
            -- Property set: e.key = "player.Character.Humanoid.WalkSpeed"
            local val_str
            if type(e.value) == "string" then
                val_str = string.format("%q", e.value)
            elseif e.value == nil then
                val_str = "nil"
            else
                local ok2, s = pcall(tostring, e.value)
                val_str = ok2 and s or "?"
            end
            add(string.rep("  ", e.depth) .. e.key .. " = " .. val_str)

        elseif e.op == OP.ANTITMP then
            add("-- [ANTI-TAMPER] " .. e.key .. (e.extra and (" — " .. e.extra) or ""))

        elseif e.op == OP.LOAD then
            if e.key:find("===") then
                add("")
                add("-- " .. e.key)
                add("")
            end
        end

        i = i + 1
    end

    return table.concat(lines, "\n")
end

-- ══════════════════════════════════════════════════════════════════════
--  7.  OUTPUT — PRINT + GUI
-- ══════════════════════════════════════════════════════════════════════

-- Wait a moment for the script to finish executing, then output
task.delay(CONFIG.TIMEOUT_SECONDS + 0.5, function()
    local reconstructed = CONFIG.RECONSTRUCT_CODE
        and reconstruct_code(log_entries)
        or  "-- (reconstruction disabled in CONFIG)"

    -- Full trace dump
    local trace_lines = {}
    for _, e in ipairs(log_entries) do
        local indent = string.rep("  ", math.min(e.depth, 8))
        local val = ""
        if e.value ~= nil then
            local ok, s = pcall(tostring, e.value)
            val = " → " .. (ok and s or "?")
        end
        table.insert(trace_lines,
            string.format("[%-8s] %s%s%s%s",
                e.op, indent, e.key, val,
                e.extra and ("  (" .. e.extra .. ")") or ""))
    end
    local full_trace = table.concat(trace_lines, "\n")

    print("\n" .. string.rep("═", 60))
    print("PROMETHEUS DEOBFUSCATOR — RESULTS")
    print(string.rep("═", 60))
    print(reconstructed)
    print(string.rep("─", 60))
    print("FULL OPERATION TRACE (" .. #log_entries .. " entries):")
    print(full_trace)
    print(string.rep("═", 60))

    -- ── GUI output ──────────────────────────────────────────────────
    if not CONFIG.SHOW_GUI then return end

    local ok_gui, gui_err = pcall(function()
        local player = game:GetService("Players").LocalPlayer
        local gui = Instance.new("ScreenGui")
        gui.Name = "PrometheusDeobf"
        gui.ResetOnSpawn = false
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.Parent = player.PlayerGui

        -- Background frame
        local bg = Instance.new("Frame")
        bg.Size = UDim2.new(0, 700, 0, 520)
        bg.Position = UDim2.new(0.5, -350, 0.5, -260)
        bg.BackgroundColor3 = Color3.fromRGB(10, 10, 18)
        bg.BorderSizePixel = 0
        bg.Parent = gui

        -- Corner
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = bg

        -- Title bar
        local titlebar = Instance.new("Frame")
        titlebar.Size = UDim2.new(1, 0, 0, 36)
        titlebar.BackgroundColor3 = Color3.fromRGB(18, 12, 35)
        titlebar.BorderSizePixel = 0
        titlebar.Parent = bg

        local title_corner = Instance.new("UICorner")
        title_corner.CornerRadius = UDim.new(0, 8)
        title_corner.Parent = titlebar

        -- Fix bottom corners of titlebar (make it flat on bottom)
        local fix = Instance.new("Frame")
        fix.Size = UDim2.new(1, 0, 0.5, 0)
        fix.Position = UDim2.new(0, 0, 0.5, 0)
        fix.BackgroundColor3 = Color3.fromRGB(18, 12, 35)
        fix.BorderSizePixel = 0
        fix.Parent = titlebar

        local title_lbl = Instance.new("TextLabel")
        title_lbl.Size = UDim2.new(1, -44, 1, 0)
        title_lbl.Position = UDim2.new(0, 12, 0, 0)
        title_lbl.BackgroundTransparency = 1
        title_lbl.Text = "⚡ Prometheus Deobfuscator — " .. #log_entries .. " operations traced"
        title_lbl.TextColor3 = Color3.fromRGB(167, 139, 250)
        title_lbl.TextXAlignment = Enum.TextXAlignment.Left
        title_lbl.Font = Enum.Font.Code
        title_lbl.TextSize = 13
        title_lbl.Parent = titlebar

        -- Close button
        local close_btn = Instance.new("TextButton")
        close_btn.Size = UDim2.new(0, 28, 0, 28)
        close_btn.Position = UDim2.new(1, -34, 0, 4)
        close_btn.BackgroundColor3 = Color3.fromRGB(60, 20, 20)
        close_btn.Text = "✕"
        close_btn.TextColor3 = Color3.fromRGB(248, 113, 113)
        close_btn.Font = Enum.Font.Code
        close_btn.TextSize = 13
        close_btn.BorderSizePixel = 0
        close_btn.Parent = titlebar

        local close_corner = Instance.new("UICorner")
        close_corner.CornerRadius = UDim.new(0, 6)
        close_corner.Parent = close_btn

        close_btn.MouseButton1Click:Connect(function()
            gui:Destroy()
        end)

        -- Tab buttons
        local tab_frame = Instance.new("Frame")
        tab_frame.Size = UDim2.new(1, 0, 0, 28)
        tab_frame.Position = UDim2.new(0, 0, 0, 36)
        tab_frame.BackgroundColor3 = Color3.fromRGB(13, 13, 22)
        tab_frame.BorderSizePixel = 0
        tab_frame.Parent = bg

        local tab_layout = Instance.new("UIListLayout")
        tab_layout.FillDirection = Enum.FillDirection.Horizontal
        tab_layout.SortOrder = Enum.SortOrder.LayoutOrder
        tab_layout.Padding = UDim.new(0, 2)
        tab_layout.Parent = tab_frame

        -- Content area (ScrollingFrame)
        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1, -8, 1, -72)
        scroll.Position = UDim2.new(0, 4, 0, 68)
        scroll.BackgroundColor3 = Color3.fromRGB(7, 7, 12)
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 4
        scroll.ScrollBarImageColor3 = Color3.fromRGB(80, 50, 150)
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.Parent = bg

        local scroll_corner = Instance.new("UICorner")
        scroll_corner.CornerRadius = UDim.new(0, 6)
        scroll_corner.Parent = scroll

        local content_lbl = Instance.new("TextLabel")
        content_lbl.Size = UDim2.new(1, -8, 0, 0)
        content_lbl.Position = UDim2.new(0, 4, 0, 4)
        content_lbl.AutomaticSize = Enum.AutomaticSize.Y
        content_lbl.BackgroundTransparency = 1
        content_lbl.Text = reconstructed
        content_lbl.TextColor3 = Color3.fromRGB(160, 160, 210)
        content_lbl.TextXAlignment = Enum.TextXAlignment.Left
        content_lbl.TextYAlignment = Enum.TextYAlignment.Top
        content_lbl.Font = Enum.Font.Code
        content_lbl.TextSize = 11
        content_lbl.TextWrapped = true
        content_lbl.RichText = false
        content_lbl.Parent = scroll

        -- Tab switching
        local tabs = {
            { name = "Reconstructed", text = reconstructed, color = Color3.fromRGB(74, 222, 128) },
            { name = "Full Trace",    text = full_trace,    color = Color3.fromRGB(167, 139, 250) },
            { name = "Variables",     text = (function()
                local var_lines = {}
                for k, v in pairs(sandbox_locals) do
                    local ok2, s = pcall(tostring, v)
                    table.insert(var_lines, k .. " = " .. (ok2 and s or "?"))
                end
                table.sort(var_lines)
                return table.concat(var_lines, "\n")
            end)(), color = Color3.fromRGB(251, 191, 36) },
        }

        local active_tab = 1

        local function switch_tab(idx)
            active_tab = idx
            content_lbl.Text = tabs[idx].text
            content_lbl.TextColor3 = Color3.fromRGB(160, 160, 210)
            -- Update button colors
            for i, btn_info in ipairs(tabs) do
                if btn_info._btn then
                    btn_info._btn.BackgroundColor3 = i == idx
                        and Color3.fromRGB(30, 20, 50)
                        or  Color3.fromRGB(15, 15, 24)
                    btn_info._btn.TextColor3 = i == idx
                        and tabs[i].color
                        or  Color3.fromRGB(60, 60, 80)
                end
            end
        end

        for idx, tab_info in ipairs(tabs) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(0, 130, 1, 0)
            btn.BackgroundColor3 = idx == 1
                and Color3.fromRGB(30, 20, 50)
                or  Color3.fromRGB(15, 15, 24)
            btn.Text = tab_info.name
            btn.TextColor3 = idx == 1
                and tab_info.color
                or  Color3.fromRGB(60, 60, 80)
            btn.Font = Enum.Font.Code
            btn.TextSize = 11
            btn.BorderSizePixel = 0
            btn.LayoutOrder = idx
            btn.Parent = tab_frame
            tab_info._btn = btn

            local btn_corner = Instance.new("UICorner")
            btn_corner.CornerRadius = UDim.new(0, 4)
            btn_corner.Parent = btn

            btn.MouseButton1Click:Connect(function()
                switch_tab(idx)
            end)
        end

        -- Make the window draggable
        local dragging, drag_start, start_pos = false, nil, nil
        titlebar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                drag_start = input.Position
                start_pos = bg.Position
            end
        end)
        titlebar.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
            end
        end)
        game:GetService("UserInputService").InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local delta = input.Position - drag_start
                bg.Position = UDim2.new(
                    start_pos.X.Scale,
                    start_pos.X.Offset + delta.X,
                    start_pos.Y.Scale,
                    start_pos.Y.Offset + delta.Y
                )
            end
        end)
    end)

    if not ok_gui then
        warn("[PrometheusDeobf] GUI creation failed: " .. tostring(gui_err))
        warn("Output was printed to console above.")
    end
end)

print("[PrometheusDeobf] Deobfuscator running... waiting up to "
    .. CONFIG.TIMEOUT_SECONDS .. "s for script to execute.")
print("[PrometheusDeobf] Results will appear in console + GUI when done.")
