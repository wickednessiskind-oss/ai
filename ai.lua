--!nocheck
--[[
    AI SCRIPT HELPER  —  single-file Roblox executor script (Luau / Mobile)
    ------------------------------------------------------------------
    Providers (automatic fallback chain):
        1. TokenHarbor   (OpenAI-compatible /chat/completions)
        2. Google Gemini (generateContent, model picker)
        3. OpenRouter    (free models)
    ------------------------------------------------------------------
    v2 FIXES vs v1:
      * REMOVED goto/label (::done::) — Luau has no goto, so v1 failed to
        COMPILE and nothing ran at all. This is the main "it does nothing" bug.
      * Works with Delta's `request`, plus http_request / syn.request / http.request.
      * Strips assistant markdown fences properly (no more broken scripts).
      * Handles a text box that never fires FocusLost (mobile keyboards).
      * scan no longer freezes the game (bounded, non-recursive walk).
      * Rotation of providers + key/settings UI, keys saved across resets.
      * Every http call has a timeout so it can never hang on "thinking…".
    ------------------------------------------------------------------
    All the logic is inside a do-block so re-executing never collides with
    leftover globals from a previous run.
]]

do -- ══════════════════════════════════ SCOPE ══════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════════════
-- 0.  SERVICES + SAFE BOOT
-- ══════════════════════════════════════════════════════════════════════════════
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")

-- wait for the place to stream in, but never hang forever
do
    local t0 = os.clock()
    while not game:IsLoaded() and (os.clock() - t0) < 25 do
        task.wait(0.2)
    end
end

local function Notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = tostring(title),
            Text  = tostring(text),
            Duration = duration or 5,
        })
    end)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 1.  CONFIG  (edit keys here, or type them in the ⚙ panel in-game)
-- ══════════════════════════════════════════════════════════════════════════════
local CONFIG = {
    tokenharbor = {
        key   = "thk_live_hWc5ISofXgwrBrZDl0_MOllhwXvOauZMz0kS3bGtKvVRhchtpis2zh0JKibAi2oY",
        model = "deepseek/deepseek-v4.1-flash:free",
        url   = "https://api.tokenharbor.ai/v1/chat/completions",
    },
    gemini = {
        key  = "AQ.Ab8RN6ID2jm4agl6Q0SgUFK-4AT7pKN1ZqhWJlbdIpGcjG-nbw",
        base = "https://generativelanguage.googleapis.com/v1beta/models/",
        models = {
            { label = "gemini-2.0-flash (fast)",  id = "gemini-2.0-flash" },
            { label = "gemini-2.0-flash-lite",    id = "gemini-2.0-flash-lite" },
            { label = "gemini-1.5-flash",         id = "gemini-1.5-flash" },
            { label = "gemini-1.5-flash-8b",      id = "gemini-1.5-flash-8b" },
        },
    },
    openrouter = {
        key  = "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",
        url  = "https://openrouter.ai/api/v1/chat/completions",
        -- tried in order; if a free model id disappears the next one is used
        models = {
            "deepseek/deepseek-r1:free",
            "deepseek/deepseek-chat-v3-0324:free",
            "meta-llama/llama-3.3-70b-instruct:free",
        },
    },
}

local MAX_CTX      = 8      -- messages of history kept
local HTTP_TIMEOUT = 60     -- seconds per request (stop hanging forever)
local MAX_TOKENS   = 4096

local selectedGeminiIdx = 1

-- keys live in their own table so the ⚙ panel can rewrite them
local KEYS = {
    tokenharbor = CONFIG.tokenharbor.key,
    gemini      = CONFIG.gemini.key,
    openrouter  = CONFIG.openrouter.key,
}

-- ── persisted overrides (optional: only if your executor has file API) ──────
local KEYS_FILE = "ai_helper_keys.json"

local function readKeysFile()
    local ok, raw = pcall(function()
        if type(isfile) == "function" and type(readfile) == "function" then
            if isfile(KEYS_FILE) then return readfile(KEYS_FILE) end
        end
        return nil
    end)
    if not ok or type(raw) ~= "string" or raw == "" then return nil end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok2 and type(data) == "table" then return data end
    return nil
end

local function saveKeysFile()
    pcall(function()
        if type(writefile) == "function" then
            writefile(KEYS_FILE, HttpService:JSONEncode(KEYS))
        end
    end)
end

do
    local stored = readKeysFile()
    if stored then
        for k in pairs(KEYS) do
            if type(stored[k]) == "string" and stored[k] ~= "" then
                KEYS[k] = stored[k]
            end
        end
    end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 2.  HTTP RESOLVER  (works on Delta / Wave / Synapse / Codex style executors)
-- ══════════════════════════════════════════════════════════════════════════════
local function resolveHttp()
    -- 1) plain globals
    local candidates = { "request", "http_request" }
    for _, name in ipairs(candidates) do
        local ok, fn = pcall(function() return _G[name] end)
        if ok and type(fn) == "function" then return fn end
    end
    -- 2) syn.request
    local okSyn, syn = pcall(function() return _G.syn end)
    if okSyn and type(syn) == "table" and type(syn.request) == "function" then
        return syn.request
    end
    -- 3) http.request
    local okHttp, http = pcall(function() return _G.http end)
    if okHttp and type(http) == "table" and type(http.request) == "function" then
        return http.request
    end
    -- 4) last resort: Roblox HttpService (only works on servers, but harmless)
    return nil
end

local RawRequest = resolveHttp()

-- Unified request: returns statusCode, bodyString  (never throws)
local function HttpCall(opts)
    if opts.Timeout == nil then opts.Timeout = HTTP_TIMEOUT end
    if not RawRequest then
        return 0, "no http_request function available in this executor"
    end
    local ok, res = pcall(RawRequest, opts)
    if not ok then
        return 0, "request error: " .. tostring(res)
    end
    if type(res) ~= "table" then
        return 0, "request returned " .. type(res)
    end
    return tonumber(res.StatusCode or res.Status) or 0, tostring(res.Body or "")
end

local function JsonDecode(str)
    local ok, data = pcall(function() return HttpService:JSONDecode(str) end)
    if ok and type(data) == "table" then return data end
    return nil
end

local function JsonEncode(tbl)
    local ok, data = pcall(function() return HttpService:JSONEncode(tbl) end)
    if ok then return data end
    return nil
end

local function UrlEncode(str)
    return (tostring(str):gsub("\n", ""):gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 3.  GAME SCANNER  (bounded + non-blocking)
-- ══════════════════════════════════════════════════════════════════════════════
-- Breadth-first walk with hard caps: `workspace:GetDescendants()` on a big map
-- can lock the client for seconds and looks like a crash.
local function collectBounded(root, maxDepth, maxNodes)
    local out   = {}
    local queue = { { inst = root, depth = 0 } }
    local head  = 1
    local visited = 0
    while head <= #queue and visited < maxNodes do
        local node = queue[head]
        head = head + 1
        if node.depth < maxDepth then
            local ok, kids = pcall(function() return node.inst:GetChildren() end)
            if ok and kids then
                for _, kid in ipairs(kids) do
                    visited = visited + 1
                    out[#out + 1] = kid
                    queue[#queue + 1] = { inst = kid, depth = node.depth + 1 }
                    if visited >= maxNodes then break end
                end
            end
        end
    end
    return out
end

local function ScanGame()
    local LP   = Players.LocalPlayer
    local char = LP and LP.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local pos  = root and root.Position or Vector3.new(0, 0, 0)

    -- NPCs / humanoids
    local npcs = {}
    for _, obj in ipairs(collectBounded(workspace, 3, 4000)) do
        if obj ~= char and obj:IsA("Model") then
            local h = obj:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then
                npcs[#npcs + 1] = {
                    Name  = obj.Name,
                    HP    = math.floor(h.Health),
                    MaxHP = math.floor(h.MaxHealth),
                }
                if #npcs >= 25 then break end
            end
        end
    end

    -- remotes
    local remotes = {}
    for _, obj in ipairs(collectBounded(ReplicatedStorage, 3, 3000)) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
            remotes[#remotes + 1] = obj.ClassName .. ": " .. obj:GetFullName()
            if #remotes >= 40 then break end
        end
    end

    -- tools
    local tools = {}
    local backpack = LP and LP:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, t in ipairs(backpack:GetChildren()) do
            if t:IsA("Tool") then tools[#tools + 1] = t.Name end
        end
    end
    if char then
        for _, t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") then tools[#tools + 1] = t.Name .. " [equipped]" end
        end
    end

    -- top-level workspace folders / models
    local wsObjs = {}
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Folder") or obj:IsA("Model") then
            wsObjs[#wsObjs + 1] = obj.ClassName .. ": " .. obj.Name
            if #wsObjs >= 30 then break end
        end
    end

    local gameName = "Unknown"
    pcall(function()
        gameName = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
    end)

    return HttpService:JSONEncode({
        PlaceID        = game.PlaceId,
        GameName       = gameName,
        PlayerCount    = #Players:GetPlayers(),
        PlayerName     = LP and LP.Name or "?",
        Position       = string.format("%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z),
        Tools          = tools,
        NPCs           = npcs,
        RemoteEvents   = remotes,
        WorkspaceObjects = wsObjs,
    })
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 4.  PROVIDER LAYER
-- ══════════════════════════════════════════════════════════════════════════════
local function extractOpenAI(resBody)
    local d = JsonDecode(resBody)
    local choice = d and d.choices and d.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) == "string" and content ~= "" then return content end
    -- some free endpoints stream proxies that answer with a string body
    if d and type(d.content) == "string" and d.content ~= "" then return d.content end
    return nil
end

-- TokenHarbor ─────────────────────────────────────────────────────────────────
local function CallTokenharbor(messages)
    if KEYS.tokenharbor == "" then return nil, "no api key" end
    local body = JsonEncode({
        model      = CONFIG.tokenharbor.model,
        max_tokens = MAX_TOKENS,
        messages   = messages,
    })
    local status, resBody = HttpCall({
        Url     = CONFIG.tokenharbor.url,
        Method  = "POST",
        Headers = {
            ["Content-Type"]  = "application/json",
            ["Authorization"] = "Bearer " .. KEYS.tokenharbor,
        },
        Body = body,
    })
    if status ~= 200 then
        return nil, string.format("HTTP %d: %s", status, tostring(resBody):sub(1, 180))
    end
    local reply = extractOpenAI(resBody)
    if not reply then return nil, "empty response: " .. tostring(resBody):sub(1, 150) end
    return reply, nil
end

-- Gemini ──────────────────────────────────────────────────────────────────────
local function messagesToGemini(messages)
    local contents, sysParts = {}, {}
    local function push(role, text)
        local last = contents[#contents]
        if last and last.role == role then
            -- Gemini rejects consecutive same-role turns: merge them
            last.parts[1].text = last.parts[1].text .. "\n\n" .. text
        else
            contents[#contents + 1] = { role = role, parts = { { text = text } } }
        end
    end
    for _, m in ipairs(messages) do
        if m.role == "system" then
            sysParts[#sysParts + 1] = { text = tostring(m.content) }
        elseif m.role == "user" then
            push("user", tostring(m.content))
        elseif m.role == "assistant" then
            push("model", tostring(m.content))
        end
    end
    -- the conversation must open with a user turn
    while contents[1] and contents[1].role ~= "user" do
        table.remove(contents, 1)
    end
    return contents, sysParts
end

local function getGeminiKey()
    local key = KEYS.gemini
    -- Google AI Studio browser keys look like "AQ.Ab8..." and are NOT valid
    -- for generateContent; those need an "AIza..." API key.
    if key == "" then return nil, "no api key" end
    if key:sub(1, 3) ~= "AIz" and key:sub(1, 2) ~= "AI" then
        return nil, "key does not look like a Google AI Studio API key (must start with AIza). " ..
                    "Create one free at https://aistudio.google.com/apikey"
    end
    return key, nil
end

local function CallGemini(messages)
    local key, keyErr = getGeminiKey()
    if not key then return nil, keyErr end

    local contents, sysParts = messagesToGemini(messages)
    if #contents == 0 then return nil, "nothing to send" end

    local payload = {
        contents = contents,
        generationConfig = { maxOutputTokens = MAX_TOKENS, temperature = 0.7 },
    }
    if #sysParts > 0 then
        payload.systemInstruction = { parts = sysParts }
    end

    local model = CONFIG.gemini.models[selectedGeminiIdx] or CONFIG.gemini.models[1]
    local url = CONFIG.gemini.base .. model.id .. ":generateContent?key=" .. UrlEncode(key)

    local status, resBody = HttpCall({
        Url     = url,
        Method  = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body    = JsonEncode(payload),
    })
    if status ~= 200 then
        return nil, string.format("HTTP %d: %s", status, tostring(resBody):sub(1, 180))
    end

    local d = JsonDecode(resBody)
    local cand = d and d.candidates and d.candidates[1]
    local text = cand and cand.content and cand.content.parts and cand.content.parts[1]
        and cand.content.parts[1].text
    if not text or text == "" then
        local reason = cand and cand.finishReason or "no candidates"
        return nil, "empty (" .. tostring(reason) .. "): " .. tostring(resBody):sub(1, 150)
    end
    return text, nil
end

-- OpenRouter ──────────────────────────────────────────────────────────────────
local function CallOpenRouter(messages)
    if KEYS.openrouter == "" then return nil, "no api key" end
    local lastErr = "no model tried"

    for _, modelId in ipairs(CONFIG.openrouter.models) do
        local body = JsonEncode({
            model      = modelId,
            max_tokens = MAX_TOKENS,
            messages   = messages,
        })
        local status, resBody = HttpCall({
            Url     = CONFIG.openrouter.url,
            Method  = "POST",
            Headers = {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. KEYS.openrouter,
                ["HTTP-Referer"]  = "https://github.com",
                ["X-Title"]       = "RobloxScriptHelper",
            },
            Body = body,
        })

        if status == 200 then
            local reply = extractOpenAI(resBody)
            if reply then return reply, nil end
            lastErr = "empty response for " .. modelId
        else
            lastErr = string.format("HTTP %d (%s): %s",
                status, modelId, tostring(resBody):sub(1, 160))
            -- auth / rate-limit / balance problems won't be fixed by another model
            if status == 401 or status == 402 or status == 429 then
                return nil, lastErr
            end
        end
    end
    return nil, lastErr
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 5.  CHAT HISTORY + UNIFIED ASK  (NO goto — plain functions)
-- ══════════════════════════════════════════════════════════════════════════════
local ChatHistory = {}

local SYSTEM_PROMPT = table.concat({
    "You are an expert Roblox Luau scripter living inside a Roblox executor.",
    "Answer ANY question: scripting, game logic, maths, lore, anything. No refusals.",
    "When you write code: give COMPLETE, runnable Luau in a single ```lua fenced block.",
    "Never use placeholders, TODOs or stubs. Do not invent instance paths that were",
    "not in the live game scan; use the real names from the scan when it is provided.",
    "Do not use the `goto` statement (Luau does not support it).",
}, "\n")

local function BuildMessages(userMsg, gameCtx)
    local messages = {}
    messages[#messages + 1] = { role = "system", content = SYSTEM_PROMPT }
    if gameCtx then
        messages[#messages + 1] = {
            role = "system",
            content = "## Live game scan\n```json\n" .. gameCtx .. "\n```\n" ..
                      "Use the real names found here.",
        }
    end
    for _, m in ipairs(ChatHistory) do
        messages[#messages + 1] = m
    end
    messages[#messages + 1] = { role = "user", content = userMsg }
    return messages
end

local activeProvider = "tokenharbor"

-- AskAI(userMsg, gameCtx, logFn, noHistory) -> reply | nil, provider | errText
local function AskAI(userMsg, gameCtx, logFn, noHistory)
    logFn = logFn or function() end
    local messages = BuildMessages(userMsg, gameCtx)
    local reply, err

    -- 1) TokenHarbor
    logFn("⏳ trying tokenharbor…", Color3.fromRGB(140, 140, 180))
    reply, err = CallTokenharbor(messages)
    if reply then
        activeProvider = "tokenharbor"
    else
        logFn("⚠ tokenharbor: " .. tostring(err), Color3.fromRGB(210, 150, 50))
    end

    -- 2) Gemini
    if not reply then
        local label = (CONFIG.gemini.models[selectedGeminiIdx] or CONFIG.gemini.models[1]).label
        logFn("⏳ falling back → gemini (" .. label .. ")…", Color3.fromRGB(140, 200, 140))
        reply, err = CallGemini(messages)
        if reply then
            activeProvider = "gemini"
        else
            logFn("⚠ gemini: " .. tostring(err), Color3.fromRGB(210, 150, 50))
        end
    end

    -- 3) OpenRouter
    if not reply then
        logFn("⏳ falling back → openrouter…", Color3.fromRGB(140, 180, 220))
        reply, err = CallOpenRouter(messages)
        if reply then
            activeProvider = "openrouter"
        else
            logFn("❌ openrouter: " .. tostring(err), Color3.fromRGB(220, 70, 70))
        end
    end

    if not reply then
        return nil, nil, tostring(err or "unknown error")
    end

    if not noHistory then
        ChatHistory[#ChatHistory + 1] = { role = "user", content = userMsg }
        ChatHistory[#ChatHistory + 1] = { role = "assistant", content = reply }
        while #ChatHistory > MAX_CTX * 2 do
            table.remove(ChatHistory, 1)
        end
    end
    return reply, activeProvider, nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 6.  CODE EXTRACTION + EXECUTION
-- ══════════════════════════════════════════════════════════════════════════════
local function trimBlanks(s)
    s = tostring(s or "")
    s = s:gsub("^%s*\n", "")
    s = s:gsub("%s+$", "")
    return s
end

local function looksLikeLua(s)
    local hits = 0
    local patterns = {
        "local%s+[%w_]+%s*=",
        "game:GetService",
        "Instance%.new",
        "function%s*%(",
        "task%.wait",
        "for%s+[%w_%s_,]+in%s+pairs",
        "workspace[%.:]",
    }
    for _, p in ipairs(patterns) do
        if s:find(p) then hits = hits + 1 end
    end
    return hits >= 2
end

-- Works with or without a language tag, with CRLF, with fences that have no
-- newline after ```, and with the closing fence on the last line (v1 missed all
-- of those because it required "\n```" strictly).
local function ExtractCode(text)
    if type(text) ~= "string" or text == "" then return nil end
    local t = text:gsub("\r\n", "\n"):gsub("\r", "\n")

    local blocks = {}
    for header, body in t:gmatch("```([^\n]*)\n(.-)```") do
        blocks[#blocks + 1] = { lang = header:lower(), body = body }
    end
    if #blocks == 0 then
        for body in t:gmatch("```(.-)```") do
            blocks[#blocks + 1] = { lang = "", body = body }
        end
    end

    local best, bestLen = nil, -1
    for _, b in ipairs(blocks) do
        local code = trimBlanks(b.body)
        if code ~= "" then
            local isLua = b.lang:find("lua") ~= nil
                or b.lang:find("luau") ~= nil
                or looksLikeLua(code)
            local score = #code + (isLua and 100000 or 0)
            if score > bestLen then
                best, bestLen = code, score
            end
        end
    end
    if best then return best end

    -- unterminated fence (a cut-off / truncated answer): keep what follows it
    local tail = t:match("```[^\n]*\n(.*)$")
    if tail then
        local code = trimBlanks(tail)
        if code ~= "" then return code end
    end

    -- no fences at all but the answer is clearly a script
    local plain = t:gsub("```[^\n]*", ""):gsub("```", "")
    if looksLikeLua(plain) then
        local code = trimBlanks(plain)
        if code ~= "" then return code end
    end
    return nil
end

local function getLoader()
    local ok, ls = pcall(function() return loadstring end)
    if ok and type(ls) == "function" then return ls end
    local ok2, l = pcall(function() return load end)
    if ok2 and type(l) == "function" then return l end
    return nil
end

local LOADER = getLoader()

-- ExecScript(code, onError) -> ok, err
-- Compiles first (so syntax errors surface immediately as compile errors), then
-- runs the chunk on its own thread: generated code may yield forever without
-- freezing the panel, and any runtime error is handed to onError instead of
-- disappearing into the console.
local function ExecScript(code, onError)
    if not code or code == "" then return false, "no code to run" end
    if not LOADER then return false, "loadstring is not available in this executor" end

    local fn, compileErr = LOADER(code)
    if not fn then
        return false, "compile error: " .. tostring(compileErr)
    end

    task.spawn(function()
        local ok, runtimeErr = pcall(fn)
        if not ok and onError then
            onError(runtimeErr)
        end
    end)
    return true, nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 7.  GUI
-- ══════════════════════════════════════════════════════════════════════════════
-- CoreGui is the nice place to live, but some executors lock it down; fall back
-- to PlayerGui so the UI always shows up instead of erroring out.
local function guiParentCandidates()
    local list = {}
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then list[#list + 1] = core end
    local lp = Players.LocalPlayer
    local ok2, pg = pcall(function() return lp and lp:FindFirstChildOfClass("PlayerGui") end)
    if ok2 and pg then list[#list + 1] = pg end
    return list
end

local SG = Instance.new("ScreenGui")
SG.Name = "DSHelper"
SG.ResetOnSpawn = false
SG.IgnoreGuiInset = true
SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SG.DisplayOrder = 999

local parented = false
for _, parent in ipairs(guiParentCandidates()) do
    local ok = pcall(function()
        local old = parent:FindFirstChild("DSHelper")
        if old then old:Destroy() end
        SG.Parent = parent
    end)
    if ok and SG.Parent ~= nil then
        parented = true
        break
    end
end
if not parented then
    Notify("AI Helper", "Could not create the GUI — CoreGui/PlayerGui blocked.", 8)
    return
end

local function corner(obj, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = obj
    return c
end

local function stroke(obj, thickness, color)
    local s = Instance.new("UIStroke")
    s.Thickness = thickness or 1
    s.Color = color or Color3.fromRGB(50, 50, 80)
    s.Parent = obj
    return s
end

-- Touch-friendly dragging (mouse + finger), works on mobile Delta
local function MakeDraggable(frame, handle)
    handle = handle or frame
    local dragging, dragStart, startPos = false, nil, nil

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

-- ── floating toggle bubble ───────────────────────────────────────────────────
local Bubble = Instance.new("TextButton")
Bubble.Size = UDim2.new(0, 46, 0, 46)
Bubble.Position = UDim2.new(0, 8, 0.45, -23)
Bubble.BackgroundColor3 = Color3.fromRGB(14, 14, 24)
Bubble.Text = "🤖"
Bubble.TextSize = 22
Bubble.Font = Enum.Font.GothamBold
Bubble.TextColor3 = Color3.fromRGB(255, 255, 255)
Bubble.AutoButtonColor = true
Bubble.ZIndex = 10
Bubble.Parent = SG
corner(Bubble, 23)
stroke(Bubble, 1.5, Color3.fromRGB(80, 80, 160))
MakeDraggable(Bubble)

-- ── main panel ───────────────────────────────────────────────────────────────
local Panel = Instance.new("Frame")
Panel.Size = UDim2.new(0, 330, 0, 530)
Panel.Position = UDim2.new(0.5, -165, 0.5, -265)
Panel.BackgroundColor3 = Color3.fromRGB(10, 10, 18)
Panel.Visible = false
Panel.ZIndex = 5
Panel.Parent = SG
corner(Panel, 12)
stroke(Panel, 1, Color3.fromRGB(40, 40, 70))

Bubble.MouseButton1Click:Connect(function()
    Panel.Visible = not Panel.Visible
end)

-- ── title bar ────────────────────────────────────────────────────────────────
local TBar = Instance.new("Frame")
TBar.Size = UDim2.new(1, 0, 0, 38)
TBar.BackgroundColor3 = Color3.fromRGB(14, 14, 26)
TBar.ZIndex = 6
TBar.Parent = Panel
corner(TBar, 12)

local TLbl = Instance.new("TextLabel")
TLbl.Text = "🤖  AI Script Helper"
TLbl.Size = UDim2.new(0, 200, 1, 0)
TLbl.Position = UDim2.new(0, 10, 0, 0)
TLbl.BackgroundTransparency = 1
TLbl.TextColor3 = Color3.fromRGB(110, 160, 255)
TLbl.Font = Enum.Font.GothamBold
TLbl.TextSize = 13
TLbl.TextXAlignment = Enum.TextXAlignment.Left
TLbl.ZIndex = 7
TLbl.Parent = TBar
MakeDraggable(Panel, TBar)

local function titleButton(text, xOffset, bg)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 26, 0, 26)
    b.Position = UDim2.new(1, xOffset, 0.5, -13)
    b.BackgroundColor3 = bg
    b.Text = text
    b.Font = Enum.Font.GothamBold
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 12
    b.ZIndex = 7
    b.Parent = TBar
    corner(b, 5)
    return b
end

local SettingsBtn = titleButton("⚙", -64, Color3.fromRGB(45, 45, 75))
local XBtn        = titleButton("✕", -32, Color3.fromRGB(180, 40, 40))
XBtn.MouseButton1Click:Connect(function() Panel.Visible = false end)

-- ── provider badge ───────────────────────────────────────────────────────────
local ProvBadge = Instance.new("TextLabel")
ProvBadge.Size = UDim2.new(1, -16, 0, 18)
ProvBadge.Position = UDim2.new(0, 8, 0, 40)
ProvBadge.BackgroundColor3 = Color3.fromRGB(20, 20, 35)
ProvBadge.TextColor3 = Color3.fromRGB(120, 120, 180)
ProvBadge.Font = Enum.Font.Code
ProvBadge.TextSize = 9
ProvBadge.TextXAlignment = Enum.TextXAlignment.Left
ProvBadge.Text = "  provider: not connected"
ProvBadge.ZIndex = 6
ProvBadge.Parent = Panel
corner(ProvBadge, 5)

local function SetProvBadge(name)
    local colors = {
        tokenharbor = Color3.fromRGB(60, 200, 120),
        gemini      = Color3.fromRGB(80, 180, 255),
        openrouter  = Color3.fromRGB(200, 140, 60),
    }
    ProvBadge.TextColor3 = colors[name] or Color3.fromRGB(180, 180, 180)
    ProvBadge.Text = "  ✦ " .. tostring(name)
end

-- ── gemini model picker ──────────────────────────────────────────────────────
local PickerFrame = Instance.new("Frame")
PickerFrame.Size = UDim2.new(1, -16, 0, 22)
PickerFrame.Position = UDim2.new(0, 8, 0, 61)
PickerFrame.BackgroundColor3 = Color3.fromRGB(16, 16, 30)
PickerFrame.ZIndex = 6
PickerFrame.Parent = Panel
corner(PickerFrame, 5)
stroke(PickerFrame, 1, Color3.fromRGB(40, 60, 100))

local PickerLbl = Instance.new("TextLabel")
PickerLbl.Size = UDim2.new(0, 55, 1, 0)
PickerLbl.Position = UDim2.new(0, 5, 0, 0)
PickerLbl.BackgroundTransparency = 1
PickerLbl.Text = "gemini:"
PickerLbl.TextColor3 = Color3.fromRGB(80, 120, 180)
PickerLbl.Font = Enum.Font.Code
PickerLbl.TextSize = 9
PickerLbl.TextXAlignment = Enum.TextXAlignment.Left
PickerLbl.ZIndex = 7
PickerLbl.Parent = PickerFrame

local PickerBtn = Instance.new("TextButton")
PickerBtn.Size = UDim2.new(1, -60, 1, 0)
PickerBtn.Position = UDim2.new(0, 55, 0, 0)
PickerBtn.BackgroundColor3 = Color3.fromRGB(22, 22, 40)
PickerBtn.Text = (CONFIG.gemini.models[selectedGeminiIdx]).label
PickerBtn.TextColor3 = Color3.fromRGB(160, 210, 255)
PickerBtn.Font = Enum.Font.Code
PickerBtn.TextSize = 9
PickerBtn.TextTruncate = Enum.TextTruncate.AtEnd
PickerBtn.ZIndex = 7
PickerBtn.Parent = PickerFrame
corner(PickerBtn, 4)

local Dropdown = Instance.new("Frame")
Dropdown.Size = UDim2.new(0, 200, 0, #CONFIG.gemini.models * 24 + 6)
Dropdown.Position = UDim2.new(0, 66, 0, 84)
Dropdown.BackgroundColor3 = Color3.fromRGB(18, 18, 32)
Dropdown.Visible = false
Dropdown.ZIndex = 20
Dropdown.Parent = Panel
corner(Dropdown, 6)
stroke(Dropdown, 1, Color3.fromRGB(60, 80, 140))

local DDLayout = Instance.new("UIListLayout")
DDLayout.SortOrder = Enum.SortOrder.LayoutOrder
DDLayout.Padding = UDim.new(0, 2)
DDLayout.Parent = Dropdown

local DDPad = Instance.new("UIPadding")
DDPad.PaddingLeft = UDim.new(0, 4)
DDPad.PaddingRight = UDim.new(0, 4)
DDPad.PaddingTop = UDim.new(0, 3)
DDPad.PaddingBottom = UDim.new(0, 3)
DDPad.Parent = Dropdown

for i, m in ipairs(CONFIG.gemini.models) do
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, 20)
    row.LayoutOrder = i
    row.BackgroundColor3 = Color3.fromRGB(26, 26, 44)
    row.Text = m.label
    row.Font = Enum.Font.Code
    row.TextSize = 9
    row.TextColor3 = Color3.fromRGB(180, 220, 255)
    row.TextXAlignment = Enum.TextXAlignment.Left
    row.ZIndex = 21
    row.Parent = Dropdown
    corner(row, 4)

    local rp = Instance.new("UIPadding")
    rp.PaddingLeft = UDim.new(0, 5)
    rp.Parent = row

    row.MouseButton1Click:Connect(function()
        selectedGeminiIdx = i
        PickerBtn.Text = m.label
        Dropdown.Visible = false
    end)
end

PickerBtn.MouseButton1Click:Connect(function()
    Dropdown.Visible = not Dropdown.Visible
end)

-- ── status pill ──────────────────────────────────────────────────────────────
local StatusBar = Instance.new("Frame")
StatusBar.Size = UDim2.new(1, -16, 0, 20)
StatusBar.Position = UDim2.new(0, 8, 0, 86)
StatusBar.BackgroundColor3 = Color3.fromRGB(16, 16, 28)
StatusBar.ZIndex = 6
StatusBar.Parent = Panel
corner(StatusBar, 5)

local StatusLbl = Instance.new("TextLabel")
StatusLbl.Text = "⏳ starting…"
StatusLbl.Size = UDim2.new(1, -8, 1, 0)
StatusLbl.Position = UDim2.new(0, 6, 0, 0)
StatusLbl.BackgroundTransparency = 1
StatusLbl.TextColor3 = Color3.fromRGB(140, 140, 180)
StatusLbl.Font = Enum.Font.Code
StatusLbl.TextSize = 10
StatusLbl.TextXAlignment = Enum.TextXAlignment.Left
StatusLbl.TextTruncate = Enum.TextTruncate.AtEnd
StatusLbl.ZIndex = 7
StatusLbl.Parent = StatusBar

-- ── output log ───────────────────────────────────────────────────────────────
local OutScroll = Instance.new("ScrollingFrame")
OutScroll.Size = UDim2.new(1, -16, 0, 226)
OutScroll.Position = UDim2.new(0, 8, 0, 110)
OutScroll.BackgroundColor3 = Color3.fromRGB(7, 7, 13)
OutScroll.BorderSizePixel = 0
OutScroll.ScrollBarThickness = 4
OutScroll.ScrollBarImageColor3 = Color3.fromRGB(60, 60, 110)
OutScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
OutScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
OutScroll.ZIndex = 6
OutScroll.Parent = Panel
corner(OutScroll, 8)
stroke(OutScroll, 1, Color3.fromRGB(25, 25, 45))

local OP = Instance.new("UIPadding")
OP.PaddingLeft = UDim.new(0, 5)
OP.PaddingRight = UDim.new(0, 5)
OP.PaddingTop = UDim.new(0, 4)
OP.PaddingBottom = UDim.new(0, 4)
OP.Parent = OutScroll

local OL = Instance.new("UIListLayout")
OL.SortOrder = Enum.SortOrder.LayoutOrder
OL.Padding = UDim.new(0, 2)
OL.Parent = OutScroll

local lineCount = 0
local MAX_LINES = 300 -- stop the log from eating memory in long sessions

local function Log(text, col)
    col = col or Color3.fromRGB(200, 200, 210)
    lineCount = lineCount + 1
    local lbl = Instance.new("TextLabel")
    lbl.Text = tostring(text)
    lbl.Size = UDim2.new(1, 0, 0, 0)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = col
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 10
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.LayoutOrder = lineCount
    lbl.ZIndex = 7
    lbl.Parent = OutScroll
    task.defer(function()
        if OutScroll then
            OutScroll.CanvasPosition = Vector2.new(0, 1e6)
        end
    end)
    -- trim oldest lines
    local labels = {}
    for _, c in ipairs(OutScroll:GetChildren()) do
        if c:IsA("TextLabel") then labels[#labels + 1] = c end
    end
    if #labels > MAX_LINES then
        table.sort(labels, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
        for i = 1, #labels - MAX_LINES do labels[i]:Destroy() end
    end
end

-- ── action row ───────────────────────────────────────────────────────────────
local ActRow = Instance.new("Frame")
ActRow.Size = UDim2.new(1, -16, 0, 28)
ActRow.Position = UDim2.new(0, 8, 0, 342)
ActRow.BackgroundTransparency = 1
ActRow.ZIndex = 6
ActRow.Parent = Panel

local AL = Instance.new("UIListLayout")
AL.FillDirection = Enum.FillDirection.Horizontal
AL.SortOrder = Enum.SortOrder.LayoutOrder
AL.Padding = UDim.new(0, 5)
AL.Parent = ActRow

local function ActBtn(txt, bg, order, vis)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 93, 1, 0)
    b.BackgroundColor3 = bg
    b.Text = txt
    b.Font = Enum.Font.GothamBold
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 10
    b.Visible = (vis ~= false)
    b.LayoutOrder = order
    b.ZIndex = 6
    b.Parent = ActRow
    corner(b, 6)
    return b
end

local ExecBtn  = ActBtn("▶ Run",   Color3.fromRGB(40, 140, 200), 1, false)
local ScanBtn  = ActBtn("🔍 Scan", Color3.fromRGB(110, 45, 155), 2, true)
local ClearBtn = ActBtn("🗑 Clear", Color3.fromRGB(45, 45, 60),   3, true)

local ScanLbl = Instance.new("TextLabel")
ScanLbl.Text = "scan: pending"
ScanLbl.Size = UDim2.new(1, -16, 0, 12)
ScanLbl.Position = UDim2.new(0, 8, 0, 373)
ScanLbl.BackgroundTransparency = 1
ScanLbl.TextColor3 = Color3.fromRGB(70, 70, 110)
ScanLbl.Font = Enum.Font.Code
ScanLbl.TextSize = 9
ScanLbl.TextXAlignment = Enum.TextXAlignment.Left
ScanLbl.ZIndex = 6
ScanLbl.Parent = Panel

-- ── input area ───────────────────────────────────────────────────────────────
local InputWrap = Instance.new("ScrollingFrame")
InputWrap.Size = UDim2.new(1, -16, 0, 88)
InputWrap.Position = UDim2.new(0, 8, 0, 388)
InputWrap.BackgroundColor3 = Color3.fromRGB(12, 12, 24)
InputWrap.BorderSizePixel = 0
InputWrap.ScrollBarThickness = 3
InputWrap.ScrollBarImageColor3 = Color3.fromRGB(60, 60, 110)
InputWrap.AutomaticCanvasSize = Enum.AutomaticSize.Y
InputWrap.CanvasSize = UDim2.new(0, 0, 0, 0)
InputWrap.ZIndex = 6
InputWrap.Parent = Panel
corner(InputWrap, 8)
stroke(InputWrap, 1, Color3.fromRGB(45, 45, 78))

local InputBox = Instance.new("TextBox")
InputBox.Size = UDim2.new(1, 0, 0, 0)
InputBox.AutomaticSize = Enum.AutomaticSize.Y
InputBox.BackgroundTransparency = 1
InputBox.PlaceholderText = "ask anything — scripting, ideas, game logic…"
InputBox.PlaceholderColor3 = Color3.fromRGB(55, 55, 85)
InputBox.Text = ""
InputBox.TextColor3 = Color3.fromRGB(225, 225, 255)
InputBox.Font = Enum.Font.Code
InputBox.TextSize = 10
InputBox.MultiLine = true
InputBox.TextWrapped = true
InputBox.ClearTextOnFocus = false
InputBox.TextXAlignment = Enum.TextXAlignment.Left
InputBox.TextYAlignment = Enum.TextYAlignment.Top
InputBox.ZIndex = 7
InputBox.Parent = InputWrap

local IP = Instance.new("UIPadding")
IP.PaddingLeft = UDim.new(0, 5)
IP.PaddingRight = UDim.new(0, 5)
IP.PaddingTop = UDim.new(0, 5)
IP.PaddingBottom = UDim.new(0, 5)
IP.Parent = InputBox

-- ── ASK button ───────────────────────────────────────────────────────────────
local AskBtn = Instance.new("TextButton")
AskBtn.Size = UDim2.new(1, -16, 0, 30)
AskBtn.Position = UDim2.new(0, 8, 0, 481)
AskBtn.BackgroundColor3 = Color3.fromRGB(195, 45, 45)
AskBtn.Text = "⚡  ASK"
AskBtn.Font = Enum.Font.GothamBold
AskBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AskBtn.TextSize = 14
AskBtn.ZIndex = 6
AskBtn.Parent = Panel
corner(AskBtn, 8)
stroke(AskBtn, 1, Color3.fromRGB(255, 70, 70))

-- ══════════════════════════════════════════════════════════════════════════════
-- 8.  SETTINGS OVERLAY (API keys)
-- ══════════════════════════════════════════════════════════════════════════════
local Settings = Instance.new("Frame")
Settings.Size = UDim2.new(1, 0, 1, 0)
Settings.BackgroundColor3 = Color3.fromRGB(12, 12, 22)
Settings.BorderSizePixel = 0
Settings.Visible = false
Settings.ZIndex = 40
Settings.Parent = Panel
corner(Settings, 12)

local SHeader = Instance.new("TextLabel")
SHeader.Text = "⚙  API KEYS"
SHeader.Size = UDim2.new(1, -60, 0, 24)
SHeader.Position = UDim2.new(0, 12, 0, 8)
SHeader.BackgroundTransparency = 1
SHeader.TextColor3 = Color3.fromRGB(120, 170, 255)
SHeader.Font = Enum.Font.GothamBold
SHeader.TextSize = 12
SHeader.TextXAlignment = Enum.TextXAlignment.Left
SHeader.ZIndex = 41
SHeader.Parent = Settings

local SClose = Instance.new("TextButton")
SClose.Size = UDim2.new(0, 24, 0, 24)
SClose.Position = UDim2.new(1, -32, 0, 8)
SClose.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
SClose.Text = "✕"
SClose.Font = Enum.Font.GothamBold
SClose.TextColor3 = Color3.fromRGB(255, 255, 255)
SClose.TextSize = 11
SClose.ZIndex = 42
SClose.Parent = Settings
corner(SClose, 5)
SClose.MouseButton1Click:Connect(function() Settings.Visible = false end)

local settingsBoxes = {}

local function settingsRow(labelText, keyName, yPos, placeholder)
    local l = Instance.new("TextLabel")
    l.Text = labelText
    l.Size = UDim2.new(1, -24, 0, 12)
    l.Position = UDim2.new(0, 12, 0, yPos)
    l.BackgroundTransparency = 1
    l.TextColor3 = Color3.fromRGB(90, 110, 160)
    l.Font = Enum.Font.Code
    l.TextSize = 9
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.ZIndex = 41
    l.Parent = Settings

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -24, 0, 28)
    box.Position = UDim2.new(0, 12, 0, yPos + 13)
    box.BackgroundColor3 = Color3.fromRGB(20, 20, 36)
    box.Text = KEYS[keyName] or ""
    box.PlaceholderText = placeholder or ""
    box.PlaceholderColor3 = Color3.fromRGB(60, 60, 90)
    box.TextColor3 = Color3.fromRGB(215, 225, 255)
    box.Font = Enum.Font.Code
    box.TextSize = 9
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.ClearTextOnFocus = false
    box.ZIndex = 41
    box.Parent = Settings
    corner(box, 5)
    stroke(box, 1, Color3.fromRGB(40, 45, 80))

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 5)
    pad.PaddingRight = UDim.new(0, 5)
    pad.Parent = box

    settingsBoxes[#settingsBoxes + 1] = { box = box, key = keyName }
    return box
end

settingsRow("GEMINI API KEY (starts with AIza…)", "gemini", 34, "AIza…")
settingsRow("OPENROUTER API KEY",                 "openrouter", 82, "sk-or-v1-…")
settingsRow("TOKENHARBOR API KEY",                "tokenharbor", 130, "thk_live_…")

local SHint = Instance.new("TextLabel")
SHint.Text = "Free Gemini key → aistudio.google.com/apikey\nFree OpenRouter key → openrouter.ai/keys\n" ..
             "Leave blank to skip that provider. Keys are only stored in this game session" ..
             (type(writefile) == "function" and " (and in " .. KEYS_FILE .. ")." or ".")
SHint.Size = UDim2.new(1, -24, 0, 58)
SHint.Position = UDim2.new(0, 12, 0, 180)
SHint.BackgroundTransparency = 1
SHint.TextColor3 = Color3.fromRGB(80, 90, 130)
SHint.Font = Enum.Font.Code
SHint.TextSize = 8
SHint.TextWrapped = true
SHint.TextXAlignment = Enum.TextXAlignment.Left
SHint.TextYAlignment = Enum.TextYAlignment.Top
SHint.ZIndex = 41
SHint.Parent = Settings

local SaveKeysBtn = Instance.new("TextButton")
SaveKeysBtn.Size = UDim2.new(1, -24, 0, 32)
SaveKeysBtn.Position = UDim2.new(0, 12, 0, 248)
SaveKeysBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 90)
SaveKeysBtn.Text = "💾  Save & reconnect"
SaveKeysBtn.Font = Enum.Font.GothamBold
SaveKeysBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SaveKeysBtn.TextSize = 11
SaveKeysBtn.ZIndex = 41
SaveKeysBtn.Parent = Settings
corner(SaveKeysBtn, 6)

local ReconnectBtn = Instance.new("TextButton")
ReconnectBtn.Size = UDim2.new(1, -24, 0, 30)
ReconnectBtn.Position = UDim2.new(0, 12, 0, 288)
ReconnectBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 70)
ReconnectBtn.Text = "🔄  Retry all providers"
ReconnectBtn.Font = Enum.Font.GothamBold
ReconnectBtn.TextColor3 = Color3.fromRGB(220, 220, 240)
ReconnectBtn.TextSize = 11
ReconnectBtn.ZIndex = 41
ReconnectBtn.Parent = Settings
corner(ReconnectBtn, 6)

SettingsBtn.MouseButton1Click:Connect(function()
    Settings.Visible = not Settings.Visible
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 9.  STATE + ACTIONS
-- ══════════════════════════════════════════════════════════════════════════════
local Connected = false
local Busy      = false
local LastCode  = nil
local LastGameCtx = nil

local function setBusy(on)
    Busy = on
    if on then
        AskBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
        AskBtn.Text = "…"
    else
        AskBtn.BackgroundColor3 = Color3.fromRGB(195, 45, 45)
        AskBtn.Text = "⚡  ASK"
    end
end

-- ── scan ─────────────────────────────────────────────────────────────────────
local function DoScan()
    ScanLbl.Text = "scanning…"
    local ok, res = pcall(ScanGame)
    if ok then
        LastGameCtx = res
        ScanLbl.Text = "✅ scanned — PlaceID " .. tostring(game.PlaceId)
        Log("🔍 scan done — PlaceID " .. tostring(game.PlaceId), Color3.fromRGB(130, 55, 175))
    else
        ScanLbl.Text = "❌ scan error"
        Log("❌ scan: " .. tostring(res):sub(1, 90), Color3.fromRGB(215, 55, 55))
    end
end

ScanBtn.MouseButton1Click:Connect(function()
    task.spawn(DoScan) -- never block the UI thread
end)

-- ── clear ────────────────────────────────────────────────────────────────────
ClearBtn.MouseButton1Click:Connect(function()
    ChatHistory = {}
    for _, c in ipairs(OutScroll:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    lineCount = 0
    LastCode = nil
    ExecBtn.Visible = false
    Log("🗑 cleared.", Color3.fromRGB(70, 70, 100))
end)

-- ── run generated code ───────────────────────────────────────────────────────
local function RunLastCode()
    if not LastCode then
        Log("⚠ nothing to run yet.", Color3.fromRGB(255, 180, 40))
        return
    end
    Log("▶ executing generated script…", Color3.fromRGB(52, 150, 215))
    local ok, err = ExecScript(LastCode, function(runtimeErr)
        Log("❌ runtime error: " .. tostring(runtimeErr):sub(1, 300), Color3.fromRGB(215, 55, 55))
        StatusLbl.Text = "❌ runtime error"
        StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
    end)
    if ok then
        Log("✅ script launched OK.", Color3.fromRGB(46, 200, 110))
        StatusLbl.Text = "✅ executed"
        StatusLbl.TextColor3 = Color3.fromRGB(46, 200, 110)
    else
        Log("❌ " .. tostring(err), Color3.fromRGB(215, 55, 55))
        StatusLbl.Text = "❌ execution failed"
        StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
    end
end

ExecBtn.MouseButton1Click:Connect(RunLastCode)

-- ── submit ───────────────────────────────────────────────────────────────────
local Submit -- forward declaration (Submit <-> Connect use each other)

Submit = function()
    if Busy then return end
    local msg = InputBox.Text:match("^%s*(.-)%s*$")
    if msg == "" then return end
    if not Connected then
        Log("⚠ not connected yet — open ⚙, check your API keys, then retry.", Color3.fromRGB(255, 180, 40))
        Settings.Visible = true
        return
    end

    setBusy(true)
    InputBox.Text = ""
    StatusLbl.Text = "⏳ thinking…"
    StatusLbl.TextColor3 = Color3.fromRGB(255, 200, 80)
    Log("───────────────────────", Color3.fromRGB(25, 25, 45))
    Log("you: " .. msg:sub(1, 300) .. (#msg > 300 and "…" or ""), Color3.fromRGB(120, 165, 255))

    task.spawn(function()
        local ok, reply, prov, err = pcall(AskAI, msg, LastGameCtx, Log)
        if not ok then
            -- AskAI itself blew up: surface the real error instead of dying silently
            Log("❌ internal error: " .. tostring(reply), Color3.fromRGB(215, 55, 55))
            StatusLbl.Text = "❌ internal error"
            StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
            setBusy(false)
            return
        end

        if not reply then
            Log("❌ all providers failed.", Color3.fromRGB(215, 55, 55))
            Log("   last error: " .. tostring(err), Color3.fromRGB(180, 60, 60))
            Log("   → tap ⚙ to check your API keys.", Color3.fromRGB(180, 140, 60))
            StatusLbl.Text = "❌ all providers failed"
            StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
        else
            SetProvBadge(prov)
            for line in (reply .. "\n"):gmatch("(.-)\n") do
                Log(line)
            end

            local code = ExtractCode(reply)
            if code then
                LastCode = code
                ExecBtn.Visible = true
                StatusLbl.Text = "✅ script ready — tap Run"
                StatusLbl.TextColor3 = Color3.fromRGB(46, 200, 110)
                Log("▶ tap [Run] to execute.", Color3.fromRGB(46, 200, 110))

                local lower = msg:lower()
                if lower:find("run it", 1, true) or lower:find("auto run", 1, true)
                    or lower:find("execute it", 1, true) or lower:find("run now", 1, true) then
                    Log("⚡ auto-exec requested…", Color3.fromRGB(255, 180, 40))
                    task.wait(0.3)
                    RunLastCode()
                end
            else
                StatusLbl.Text = "✅ reply received"
                StatusLbl.TextColor3 = Color3.fromRGB(46, 200, 110)
            end
        end
        setBusy(false)
    end)
end

AskBtn.MouseButton1Click:Connect(Submit)

-- v1 relied on TextBox.FocusLost to send, which mobile keyboards frequently
-- never fire — so on a phone the prompt silently did nothing. The ASK button is
-- now the single, explicit send path (works with touch).

-- Mobile: keep the ASK button on-screen when the viewport is shorter than the
-- panel (small phones / landscape).
task.spawn(function()
    pcall(function()
        local vp = workspace.CurrentCamera.ViewportSize
        if vp.Y < 560 and Panel.AbsoluteSize.Y > vp.Y then
            Panel.Size = UDim2.new(0, 330, 0, vp.Y - 20)
            AskBtn.Position = UDim2.new(0, 8, 1, -34)
        end
    end)
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 10. CONNECT / BOOT
-- ══════════════════════════════════════════════════════════════════════════════
local function Connect(silent)
    if Busy then return end
    if not RawRequest then
        StatusLbl.Text = "❌ no HTTP function"
        StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
        Log("❌ No http_request / request / syn.request found.", Color3.fromRGB(215, 55, 55))
        Log("   Re-inject your executor (Delta) and run the script again.", Color3.fromRGB(180, 140, 60))
        Notify("AI Helper", "No HTTP function in this executor.", 6)
        return
    end

    setBusy(true)
    StatusLbl.Text = "⏳ connecting…"
    StatusLbl.TextColor3 = Color3.fromRGB(255, 200, 80)
    if not silent then
        Log("🤖 connecting to providers…", Color3.fromRGB(110, 155, 255))
    end

    task.spawn(function()
        local ok, reply, prov, err = pcall(AskAI, "Reply with exactly: CONNECTED", nil, function() end, true)
        if ok and reply then
            Connected = true
            SetProvBadge(prov)
            StatusLbl.Text = "✅ online via " .. tostring(prov)
            StatusLbl.TextColor3 = Color3.fromRGB(46, 200, 110)
            Log("✅ live on " .. tostring(prov), Color3.fromRGB(46, 200, 110))
            Log("type a question, or say 'run it' to auto-execute.", Color3.fromRGB(130, 130, 155))
            task.spawn(DoScan)
        else
            Connected = false
            StatusLbl.Text = "❌ all providers down"
            StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
            Log("❌ could not reach any provider.", Color3.fromRGB(215, 55, 55))
            local detail = ok and tostring(err) or tostring(reply)
            Log("   " .. tostring(detail):sub(1, 220), Color3.fromRGB(180, 70, 70))
            Log("   → tap ⚙ to paste a working API key.", Color3.fromRGB(180, 140, 60))
            ProvBadge.Text = "  ✦ offline"
            ProvBadge.TextColor3 = Color3.fromRGB(200, 80, 80)
        end
        setBusy(false)
    end)
end

SaveKeysBtn.MouseButton1Click:Connect(function()
    for _, item in ipairs(settingsBoxes) do
        KEYS[item.key] = (item.box.Text:gsub("%s+", ""))
    end
    saveKeysFile()
    Settings.Visible = false
    Log("💾 keys saved — reconnecting…", Color3.fromRGB(60, 200, 140))
    Connect(true)
end)

ReconnectBtn.MouseButton1Click:Connect(function()
    Connect(true)
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 11. GO
-- ══════════════════════════════════════════════════════════════════════════════
Log("🤖 AI Script Helper loaded.", Color3.fromRGB(110, 155, 255))
Log("tap the 🤖 bubble to open • tap ⚙ for API keys", Color3.fromRGB(120, 120, 155))
Notify("AI Helper", "Loaded — tap the 🤖 bubble to open.", 4)

if not RawRequest then
    Log("❌ no HTTP function (request / http_request / syn.request).", Color3.fromRGB(215, 55, 55))
    StatusLbl.Text = "❌ no HTTP function"
    StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
    Notify("AI Helper", "No HTTP function — re-inject Delta.", 8)
else
    Connect(true)
end

end -- ════════════════════════════════ END SCOPE ════════════════════════════════
