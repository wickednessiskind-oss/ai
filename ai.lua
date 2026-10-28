--!nocheck
--[[
    AI SCRIPT HELPER  —  single-file Roblox executor script (Luau / mobile)
    ==================================================================
    Providers, automatic fallback chain:
        1. TokenHarbor   (OpenAI-compatible /chat/completions)
        2. Google Gemini (generateContent — supports old "AIza…" *and* new "AQ.…" keys)
        3. OpenRouter    (free models)
    ------------------------------------------------------------------
    CHANGELOG
    v3  (mobile / Delta fixes)
      * HTTP resolver rewritten. v2 looked the function up in `_G`, but Delta
        injects `request` / `http_request` into the *script environment*, not
        into `_G` — so it always reported "no HTTP function". Now reads the
        globals directly, then getgenv(), then syn/http/fluxus/krnl tables.
      * Gemini: new Google keys start with "AQ." and MUST be sent in the
        x-goog-api-key header; with ?key= they return 404. Both auth styles are
        tried, and a dead model id falls through to the next model.
      * GUI rebuilt: compact (≈300×420), fits any screen, real drag with
        clamping, layout calculated from the panel size so nothing overlaps.
    v2
      * REMOVED goto/label (::done::) — Luau has no goto, so v1 never compiled.
      * Fence parser, bounded game scan, request timeouts, CoreGui fallback,
        generated code on its own thread, settings panel for API keys.
    ------------------------------------------------------------------
    Everything lives inside a do-block so re-executing is always safe.
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

do
    local t0 = os.clock()
    while not game:IsLoaded() and (os.clock() - t0) < 25 do
        task.wait(0.2)
    end
end

local function Notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = tostring(title), Text = tostring(text), Duration = duration or 5,
        })
    end)
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 1.  CONFIG  (keys can also be typed in the ⚙ panel in-game)
-- ══════════════════════════════════════════════════════════════════════════════
local CONFIG = {
    -- Leave these empty in the file (a live key must never be committed to a
    -- public repo — GitHub push protection blocks it anyway). Paste your keys
    -- in the ⚙ panel; they are saved to ai_helper_keys.json when the executor
    -- supports writefile, otherwise they last for the session.
    tokenharbor = {
        key   = "",
        model = "deepseek/deepseek-v4.1-flash:free",
        url   = "https://api.tokenharbor.ai/v1/chat/completions",
    },
    gemini = {
        -- AQ.… = current Google key format, AIza… = legacy format. Both work below.
        key  = "",
        base = "https://generativelanguage.googleapis.com/v1beta/models/",
        models = {
            { label = "gemini-2.5-flash",      id = "gemini-2.5-flash" },
            { label = "gemini-2.5-flash-lite", id = "gemini-2.5-flash-lite" },
            { label = "gemini-2.0-flash",      id = "gemini-2.0-flash" },
            { label = "gemini-2.0-flash-lite", id = "gemini-2.0-flash-lite" },
        },
    },
    openrouter = {
        key  = "",
        url  = "https://openrouter.ai/api/v1/chat/completions",
        models = {
            "deepseek/deepseek-r1:free",
            "deepseek/deepseek-chat-v3-0324:free",
            "meta-llama/llama-3.3-70b-instruct:free",
        },
    },
}

local MAX_CTX      = 8
local HTTP_TIMEOUT = 60
local MAX_TOKENS   = 4096

local selectedGeminiIdx = 1

local KEYS = {
    tokenharbor = CONFIG.tokenharbor.key,
    gemini      = CONFIG.gemini.key,
    openrouter  = CONFIG.openrouter.key,
}

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
-- 2.  HTTP RESOLVER
--     (this is what v2 got wrong: executors inject `request` into the script
--      environment, NOT into `_G`, so `_G["request"]` was always nil)
-- ══════════════════════════════════════════════════════════════════════════════
local RawRequest, HTTP_SOURCE = nil, nil

do
    local candidates = {}
    local function add(name, fn)
        if type(fn) == "function" then
            candidates[#candidates + 1] = { name = name, fn = fn }
        end
    end

    -- 1) direct globals — reading an undefined global is nil, never an error
    add("request",      request)
    add("http_request", http_request)

    -- 2) the executor's shared environment
    local okGenv, genv = pcall(function() return getgenv and getgenv() or nil end)
    if okGenv and type(genv) == "table" then
        add("getgenv().request",      genv.request)
        add("getgenv().http_request", genv.http_request)
        if type(genv.syn) == "table"  then add("getgenv().syn.request",  genv.syn.request)  end
        if type(genv.http) == "table" then add("getgenv().http.request", genv.http.request) end
    end

    -- 3) executor namespaces
    if type(syn) == "table"    then add("syn.request",    syn.request)    end
    if type(http) == "table"   then add("http.request",   http.request)   end
    if type(fluxus) == "table" then add("fluxus.request", fluxus.request) end
    if type(krnl) == "table"   then add("krnl.request",   krnl.request)   end
    if type(delta) == "table"  then add("delta.request",  delta.request)  end
    if type(secure_call) == "function" and type(syn) == "table" and type(syn.request) == "function" then
        add("secure_call(syn.request)", function(o) return secure_call(syn.request, o) end)
    end

    if #candidates > 0 then
        RawRequest  = candidates[1].fn
        HTTP_SOURCE = candidates[1].name
    end
end

-- Unifies the different executor response shapes -> statusCode, bodyString
local function runRequest(opts)
    if opts.Timeout == nil then opts.Timeout = HTTP_TIMEOUT end
    local ok, res = pcall(RawRequest, opts)
    if not ok then return 0, "request error: " .. tostring(res) end
    if type(res) ~= "table" then return 0, "request returned " .. type(res) end

    local code = res.StatusCode or res.Status or res.status or res.statusCode or 0
    local body = res.Body or res.body or res.Data or res.data or ""
    if type(body) ~= "string" then body = tostring(body) end
    return tonumber(code) or 0, body
end

local function HttpCall(opts)
    if not RawRequest then
        return 0, "no http function available in this executor"
    end
    return runRequest(opts)
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
local function collectBounded(root, maxDepth, maxNodes)
    local out     = {}
    local queue   = { { inst = root, depth = 0 } }
    local head    = 1
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

    local npcs = {}
    for _, obj in ipairs(collectBounded(workspace, 3, 4000)) do
        if obj ~= char and obj:IsA("Model") then
            local h = obj:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then
                npcs[#npcs + 1] = {
                    Name = obj.Name, HP = math.floor(h.Health),
                    MaxHP = math.floor(h.MaxHealth),
                }
                if #npcs >= 25 then break end
            end
        end
    end

    local remotes = {}
    for _, obj in ipairs(collectBounded(ReplicatedStorage, 3, 3000)) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
            remotes[#remotes + 1] = obj.ClassName .. ": " .. obj:GetFullName()
            if #remotes >= 40 then break end
        end
    end

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
        PlaceID = game.PlaceId, GameName = gameName,
        PlayerCount = #Players:GetPlayers(),
        PlayerName = LP and LP.Name or "?",
        Position = string.format("%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z),
        Tools = tools, NPCs = npcs, RemoteEvents = remotes, WorkspaceObjects = wsObjs,
    })
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 4.  PROVIDERS
-- ══════════════════════════════════════════════════════════════════════════════
local function extractOpenAI(resBody)
    local d = JsonDecode(resBody)
    local choice = d and d.choices and d.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) == "string" and content ~= "" then return content end
    if d and type(d.content) == "string" and d.content ~= "" then return d.content end
    if d and d.error then
        local e = d.error
        if type(e) == "table" then return nil, tostring(e.message or e.code or "error") end
        return nil, tostring(e)
    end
    return nil, nil
end

-- TokenHarbor ─────────────────────────────────────────────────────────────────
local function CallTokenharbor(messages)
    if KEYS.tokenharbor == "" then return nil, "no api key" end
    local status, resBody = HttpCall({
        Url     = CONFIG.tokenharbor.url,
        Method  = "POST",
        Headers = {
            ["Content-Type"]  = "application/json",
            ["Authorization"] = "Bearer " .. KEYS.tokenharbor,
        },
        Body = JsonEncode({
            model = CONFIG.tokenharbor.model, max_tokens = MAX_TOKENS, messages = messages,
        }),
    })
    if status ~= 200 then
        return nil, string.format("HTTP %d: %s", status, tostring(resBody):sub(1, 160))
    end
    local reply, apiErr = extractOpenAI(resBody)
    if not reply then return nil, apiErr or ("empty: " .. tostring(resBody):sub(1, 120)) end
    return reply, nil
end

-- Gemini ──────────────────────────────────────────────────────────────────────
local function messagesToGemini(messages)
    local contents, sysParts = {}, {}
    local function push(role, text)
        local last = contents[#contents]
        if last and last.role == role then
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
    while contents[1] and contents[1].role ~= "user" do
        table.remove(contents, 1)
    end
    return contents, sysParts
end

-- One request to one model. Two auth styles because Google now mints "AQ.…"
-- keys that only work in the header, while legacy "AIza…" keys work either way.
local function CallGeminiOnce(payload, modelId)
    local key = KEYS.gemini
    if key == "" then return nil, "no api key", false end

    local base = CONFIG.gemini.base .. modelId .. ":generateContent"
    local bodyJson = JsonEncode(payload)

    local attempts = {
        {
            name    = "header",
            url     = base,
            headers = { ["Content-Type"] = "application/json", ["x-goog-api-key"] = key },
        },
        {
            name    = "query",
            url     = base .. "?key=" .. UrlEncode(key),
            headers = { ["Content-Type"] = "application/json" },
        },
    }

    local lastErr = "unknown"
    local authFailed = false

    for _, at in ipairs(attempts) do
        local status, resBody = HttpCall({
            Url = at.url, Method = "POST", Headers = at.headers, Body = bodyJson,
        })

        if status == 200 then
            local d = JsonDecode(resBody)
            local cand = d and d.candidates and d.candidates[1]
            local text = cand and cand.content and cand.content.parts and cand.content.parts[1]
                and cand.content.parts[1].text
            if type(text) == "string" and text ~= "" then
                return text, nil, false
            end
            local reason = (cand and cand.finishReason)
                or (d and d.promptFeedback and d.promptFeedback.blockReason)
                or "no candidates"
            lastErr = "empty (" .. tostring(reason) .. ")"
            -- model refused / was blocked: another auth style won't change that
            if reason ~= "no candidates" then return nil, lastErr, true end
        else
            local d = JsonDecode(resBody)
            local msg = d and d.error and (d.error.message or d.error.status)
            lastErr = string.format("HTTP %d: %s", status,
                tostring(msg or tostring(resBody):sub(1, 140)))

            -- quota exceeded: try the other style once, then give up entirely
            if status == 429 then return nil, lastErr, true end
            if status == 400 or status == 401 or status == 403 or status == 404 then
                authFailed = true
            end
            -- anything else (5xx / network) is worth one more attempt too
        end
    end

    -- both auth styles failed with an auth error -> this key/model is unusable,
    -- don't burn four more requests on the rest of the model list
    return nil, lastErr, authFailed
end

local function CallGemini(messages)
    local contents, sysParts = messagesToGemini(messages)
    if #contents == 0 then return nil, "nothing to send" end

    local payload = {
        contents = contents,
        generationConfig = { maxOutputTokens = MAX_TOKENS, temperature = 0.7 },
    }
    if #sysParts > 0 then payload.systemInstruction = { parts = sysParts } end

    -- start with the picked model, then fall through the rest (a retired model
    -- id returns 404 and shouldn't kill the whole provider)
    local order = {}
    local n = #CONFIG.gemini.models
    for i = 0, n - 1 do
        order[#order + 1] = CONFIG.gemini.models[((selectedGeminiIdx - 1 + i) % n) + 1]
    end

    local lastErr = "no model tried"
    for _, model in ipairs(order) do
        local text, err, fatal = CallGeminiOnce(payload, model.id)
        if text then return text, nil end
        lastErr = model.id .. " → " .. tostring(err)
        if fatal then break end
    end
    return nil, lastErr
end

-- OpenRouter ──────────────────────────────────────────────────────────────────
local function CallOpenRouter(messages)
    if KEYS.openrouter == "" then return nil, "no api key" end
    local lastErr = "no model tried"
    for _, modelId in ipairs(CONFIG.openrouter.models) do
        local status, resBody = HttpCall({
            Url     = CONFIG.openrouter.url,
            Method  = "POST",
            Headers = {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. KEYS.openrouter,
                ["HTTP-Referer"]  = "https://github.com",
                ["X-Title"]       = "RobloxScriptHelper",
            },
            Body = JsonEncode({
                model = modelId, max_tokens = MAX_TOKENS, messages = messages,
            }),
        })
        if status == 200 then
            local reply = extractOpenAI(resBody)
            if reply then return reply, nil end
            lastErr = "empty response for " .. modelId
        else
            lastErr = string.format("HTTP %d (%s): %s",
                status, modelId, tostring(resBody):sub(1, 140))
            if status == 401 or status == 402 or status == 429 then break end
        end
    end
    return nil, lastErr
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 5.  CHAT HISTORY + UNIFIED ASK
-- ══════════════════════════════════════════════════════════════════════════════
local ChatHistory = {}

local SYSTEM_PROMPT = table.concat({
    "You are an expert Roblox Luau scripter living inside a Roblox executor.",
    "Answer ANY question: scripting, game logic, maths, lore, anything. No refusals.",
    "When writing code give COMPLETE runnable Luau in a single ```lua fenced block.",
    "Never use placeholders, TODOs or stubs.",
    "Use the real instance names from the live game scan when one is provided.",
    "Do not use the `goto` statement (Luau does not support it).",
}, "\n")

local function BuildMessages(userMsg, gameCtx)
    local messages = {}
    messages[#messages + 1] = { role = "system", content = SYSTEM_PROMPT }
    if gameCtx then
        messages[#messages + 1] = {
            role = "system",
            content = "## Live game scan\n```json\n" .. gameCtx .. "\n```\nUse the real names found here.",
        }
    end
    for _, m in ipairs(ChatHistory) do messages[#messages + 1] = m end
    messages[#messages + 1] = { role = "user", content = userMsg }
    return messages
end

local activeProvider = "tokenharbor"

local function AskAI(userMsg, gameCtx, logFn, noHistory)
    logFn = logFn or function() end
    local messages = BuildMessages(userMsg, gameCtx)
    local reply, err

    logFn("⏳ tokenharbor…", Color3.fromRGB(140, 140, 180))
    reply, err = CallTokenharbor(messages)
    if reply then
        activeProvider = "tokenharbor"
    else
        logFn("⚠ tokenharbor: " .. tostring(err), Color3.fromRGB(210, 150, 50))
        local label = (CONFIG.gemini.models[selectedGeminiIdx] or CONFIG.gemini.models[1]).label
        logFn("⏳ gemini (" .. label .. ")…", Color3.fromRGB(140, 200, 140))
        reply, err = CallGemini(messages)
        if reply then
            activeProvider = "gemini"
        else
            logFn("⚠ gemini: " .. tostring(err), Color3.fromRGB(210, 150, 50))
            logFn("⏳ openrouter…", Color3.fromRGB(140, 180, 220))
            reply, err = CallOpenRouter(messages)
            if reply then
                activeProvider = "openrouter"
            else
                logFn("❌ openrouter: " .. tostring(err), Color3.fromRGB(220, 70, 70))
            end
        end
    end

    if not reply then return nil, nil, tostring(err or "unknown error") end

    if not noHistory then
        ChatHistory[#ChatHistory + 1] = { role = "user", content = userMsg }
        ChatHistory[#ChatHistory + 1] = { role = "assistant", content = reply }
        while #ChatHistory > MAX_CTX * 2 do table.remove(ChatHistory, 1) end
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
    for _, p in ipairs({
        "local%s+[%w_]+%s*=", "game:GetService", "Instance%.new",
        "function%s*%(", "task%.wait", "for%s+[%w_%s_,]+in%s+pairs", "workspace[%.:]",
    }) do
        if s:find(p) then hits = hits + 1 end
    end
    return hits >= 2
end

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

    local best, bestScore = nil, -1
    for _, b in ipairs(blocks) do
        local code = trimBlanks(b.body)
        if code ~= "" then
            local isLua = b.lang:find("lua", 1, true) ~= nil or looksLikeLua(code)
            local score = #code + (isLua and 100000 or 0)
            if score > bestScore then best, bestScore = code, score end
        end
    end
    if best then return best end

    local tail = t:match("```[^\n]*\n(.*)$")
    if tail then
        local code = trimBlanks(tail)
        if code ~= "" then return code end
    end

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
    local ok3, genv = pcall(function() return getgenv and getgenv() or nil end)
    if ok3 and type(genv) == "table" and type(genv.loadstring) == "function" then
        return genv.loadstring
    end
    return nil
end

local LOADER = getLoader()

-- Compile first (syntax errors surface immediately), then run on its own
-- thread so generated code can yield / loop without freezing the panel.
local function ExecScript(code, onError)
    if not code or code == "" then return false, "no code to run" end
    if not LOADER then return false, "loadstring is not available in this executor" end

    local fn, compileErr = LOADER(code)
    if not fn then return false, "compile error: " .. tostring(compileErr) end

    task.spawn(function()
        local ok, runtimeErr = pcall(fn)
        if not ok and onError then onError(runtimeErr) end
    end)
    return true, nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- 7.  GUI  (compact, responsive, draggable — built for phones)
-- ══════════════════════════════════════════════════════════════════════════════
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
    if ok and SG.Parent ~= nil then parented = true break end
end
if not parented then
    Notify("AI Helper", "Could not create the GUI — CoreGui/PlayerGui blocked.", 8)
    return
end

local function corner(obj, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
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

-- ── screen metrics ───────────────────────────────────────────────────────────
local function screenSize()
    local cam = workspace.CurrentCamera
    local ok, vp = pcall(function() return cam.ViewportSize end)
    if ok and vp and vp.X > 0 and vp.Y > 0 then return vp end
    return Vector2.new(800, 600)
end

local function sizePx(frame)
    local a = frame.AbsoluteSize
    local w = (a and a.X > 0) and a.X or frame.Size.X.Offset
    local h = (a and a.Y > 0) and a.Y or frame.Size.Y.Offset
    return w, h
end

-- keep the whole window on screen
local function clampTo(x, y, w, h)
    local vp = screenSize()
    local maxX = math.max(0, vp.X - w)
    local maxY = math.max(0, vp.Y - h)
    return math.clamp(x, 0, maxX), math.clamp(y, 0, maxY)
end

-- touch + mouse drag, clamped, no global state shared between windows
-- touch + mouse drag, clamped so nothing can be lost off-screen.
-- Returns a predicate telling you whether a drag just ended, so a drag on the
-- bubble isn't also treated as a tap (which would toggle the panel by accident).
local function makeDraggable(frame, handle)
    local dragging, dragStart, startPos = false, nil, nil
    local moved, movedAt = false, 0

    handle.InputBegan:Connect(function(input)
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
            dragging  = true
            moved     = false
            dragStart = input.Position
            startPos  = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if moved then movedAt = os.clock() end
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            if math.abs(delta.X) + math.abs(delta.Y) > 6 then moved = true end
            local w, h  = sizePx(frame)
            local nx, ny = clampTo(startPos.X.Offset + delta.X, startPos.Y.Offset + delta.Y, w, h)
            frame.Position = UDim2.new(0, nx, 0, ny)
        end
    end)

    return function()
        return moved and (os.clock() - movedAt) < 0.3
    end
end

-- ── toggle bubble ────────────────────────────────────────────────────────────
local Bubble = Instance.new("TextButton")
Bubble.Size = UDim2.new(0, 40, 0, 40)
Bubble.BackgroundColor3 = Color3.fromRGB(14, 14, 24)
Bubble.Text = "🤖"
Bubble.TextSize = 19
Bubble.Font = Enum.Font.GothamBold
Bubble.TextColor3 = Color3.fromRGB(255, 255, 255)
Bubble.ZIndex = 10
Bubble.Parent = SG
corner(Bubble, 20)
stroke(Bubble, 1.5, Color3.fromRGB(80, 80, 160))
do
    local vp = screenSize()
    local _, y = clampTo(0, math.floor(vp.Y * 0.42), 40, 40)
    Bubble.Position = UDim2.new(0, 8, 0, y)
end
local bubbleDragEnded = makeDraggable(Bubble, Bubble)

-- ── panel ────────────────────────────────────────────────────────────────────
local panelW, panelH = 300, 420

local Panel = Instance.new("Frame")
Panel.BackgroundColor3 = Color3.fromRGB(10, 10, 18)
Panel.Visible = false
Panel.ZIndex = 5
Panel.Parent = SG
corner(Panel, 10)
stroke(Panel, 1, Color3.fromRGB(40, 40, 70))

Bubble.MouseButton1Click:Connect(function()
    if bubbleDragEnded() then return end -- that was a drag, not a tap
    Panel.Visible = not Panel.Visible
end)

-- ── title bar ────────────────────────────────────────────────────────────────
local TBar = Instance.new("Frame")
TBar.Size = UDim2.new(1, 0, 0, 30)
TBar.BackgroundColor3 = Color3.fromRGB(14, 14, 26)
TBar.ZIndex = 6
TBar.Parent = Panel
corner(TBar, 10)
makeDraggable(Panel, TBar)

local TLbl = Instance.new("TextLabel")
TLbl.Text = "🤖  AI Helper"
TLbl.Size = UDim2.new(1, -66, 1, 0)
TLbl.Position = UDim2.new(0, 8, 0, 0)
TLbl.BackgroundTransparency = 1
TLbl.TextColor3 = Color3.fromRGB(110, 160, 255)
TLbl.Font = Enum.Font.GothamBold
TLbl.TextSize = 11
TLbl.TextXAlignment = Enum.TextXAlignment.Left
TLbl.ZIndex = 7
TLbl.Parent = TBar

local function titleButton(text, xOffset, bg, size)
    local b = Instance.new("TextButton")
    size = size or 22
    b.Size = UDim2.new(0, size, 0, size)
    b.Position = UDim2.new(1, xOffset, 0.5, -size / 2)
    b.BackgroundColor3 = bg
    b.Text = text
    b.Font = Enum.Font.GothamBold
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 10
    b.ZIndex = 7
    b.Parent = TBar
    corner(b, 4)
    return b
end

local SettingsBtn = titleButton("⚙", -54, Color3.fromRGB(45, 45, 75))
local XBtn        = titleButton("✕", -28, Color3.fromRGB(180, 40, 40))
XBtn.MouseButton1Click:Connect(function() Panel.Visible = false end)

-- ── provider badge ───────────────────────────────────────────────────────────
local ProvBadge = Instance.new("TextLabel")
ProvBadge.BackgroundColor3 = Color3.fromRGB(20, 20, 35)
ProvBadge.TextColor3 = Color3.fromRGB(120, 120, 180)
ProvBadge.Font = Enum.Font.Code
ProvBadge.TextSize = 8
ProvBadge.TextXAlignment = Enum.TextXAlignment.Left
ProvBadge.Text = "  provider: not connected"
ProvBadge.ZIndex = 6
ProvBadge.Parent = Panel
corner(ProvBadge, 4)

local function SetProvBadge(name)
    local colors = {
        tokenharbor = Color3.fromRGB(60, 200, 120),
        gemini      = Color3.fromRGB(80, 180, 255),
        openrouter  = Color3.fromRGB(200, 140, 60),
    }
    ProvBadge.TextColor3 = colors[name] or Color3.fromRGB(180, 180, 180)
    ProvBadge.Text = "  ✦ " .. tostring(name) ..
        (HTTP_SOURCE and ("   ·   http: " .. HTTP_SOURCE) or "   ·   http: missing")
end

-- ── gemini model picker ──────────────────────────────────────────────────────
local PickerFrame = Instance.new("Frame")
PickerFrame.BackgroundColor3 = Color3.fromRGB(16, 16, 30)
PickerFrame.ZIndex = 6
PickerFrame.Parent = Panel
corner(PickerFrame, 4)
stroke(PickerFrame, 1, Color3.fromRGB(40, 60, 100))

local PickerLbl = Instance.new("TextLabel")
PickerLbl.Size = UDim2.new(0, 42, 1, 0)
PickerLbl.Position = UDim2.new(0, 4, 0, 0)
PickerLbl.BackgroundTransparency = 1
PickerLbl.Text = "gemini"
PickerLbl.TextColor3 = Color3.fromRGB(80, 120, 180)
PickerLbl.Font = Enum.Font.Code
PickerLbl.TextSize = 8
PickerLbl.TextXAlignment = Enum.TextXAlignment.Left
PickerLbl.ZIndex = 7
PickerLbl.Parent = PickerFrame

local PickerBtn = Instance.new("TextButton")
PickerBtn.Size = UDim2.new(1, -48, 1, 0)
PickerBtn.Position = UDim2.new(0, 44, 0, 0)
PickerBtn.BackgroundColor3 = Color3.fromRGB(22, 22, 40)
PickerBtn.Text = (CONFIG.gemini.models[selectedGeminiIdx]).label
PickerBtn.TextColor3 = Color3.fromRGB(160, 210, 255)
PickerBtn.Font = Enum.Font.Code
PickerBtn.TextSize = 8
PickerBtn.TextTruncate = Enum.TextTruncate.AtEnd
PickerBtn.ZIndex = 7
PickerBtn.Parent = PickerFrame
corner(PickerBtn, 3)

local Dropdown = Instance.new("Frame")
Dropdown.Size = UDim2.new(0, 170, 0, #CONFIG.gemini.models * 20 + 6)
Dropdown.BackgroundColor3 = Color3.fromRGB(18, 18, 32)
Dropdown.Visible = false
Dropdown.ZIndex = 30
Dropdown.Parent = Panel
corner(Dropdown, 5)
stroke(Dropdown, 1, Color3.fromRGB(60, 80, 140))

local DDLayout = Instance.new("UIListLayout")
DDLayout.SortOrder = Enum.SortOrder.LayoutOrder
DDLayout.Padding = UDim.new(0, 1)
DDLayout.Parent = Dropdown

local DDPad = Instance.new("UIPadding")
DDPad.PaddingLeft = UDim.new(0, 3)
DDPad.PaddingRight = UDim.new(0, 3)
DDPad.PaddingTop = UDim.new(0, 3)
DDPad.PaddingBottom = UDim.new(0, 3)
DDPad.Parent = Dropdown

for i, m in ipairs(CONFIG.gemini.models) do
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, 18)
    row.LayoutOrder = i
    row.BackgroundColor3 = Color3.fromRGB(26, 26, 44)
    row.Text = m.label
    row.Font = Enum.Font.Code
    row.TextSize = 8
    row.TextColor3 = Color3.fromRGB(180, 220, 255)
    row.TextXAlignment = Enum.TextXAlignment.Left
    row.ZIndex = 31
    row.Parent = Dropdown
    corner(row, 3)
    local rp = Instance.new("UIPadding")
    rp.PaddingLeft = UDim.new(0, 4)
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
StatusBar.BackgroundColor3 = Color3.fromRGB(16, 16, 28)
StatusBar.ZIndex = 6
StatusBar.Parent = Panel
corner(StatusBar, 4)

local StatusLbl = Instance.new("TextLabel")
StatusLbl.Text = "⏳ starting…"
StatusLbl.Size = UDim2.new(1, -8, 1, 0)
StatusLbl.Position = UDim2.new(0, 5, 0, 0)
StatusLbl.BackgroundTransparency = 1
StatusLbl.TextColor3 = Color3.fromRGB(140, 140, 180)
StatusLbl.Font = Enum.Font.Code
StatusLbl.TextSize = 8
StatusLbl.TextXAlignment = Enum.TextXAlignment.Left
StatusLbl.TextTruncate = Enum.TextTruncate.AtEnd
StatusLbl.ZIndex = 7
StatusLbl.Parent = StatusBar

-- ── log ──────────────────────────────────────────────────────────────────────
local OutScroll = Instance.new("ScrollingFrame")
OutScroll.BackgroundColor3 = Color3.fromRGB(7, 7, 13)
OutScroll.BorderSizePixel = 0
OutScroll.ScrollBarThickness = 3
OutScroll.ScrollBarImageColor3 = Color3.fromRGB(60, 60, 110)
OutScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
OutScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
OutScroll.ZIndex = 6
OutScroll.Parent = Panel
corner(OutScroll, 6)
stroke(OutScroll, 1, Color3.fromRGB(25, 25, 45))

local OP = Instance.new("UIPadding")
OP.PaddingLeft = UDim.new(0, 4)
OP.PaddingRight = UDim.new(0, 4)
OP.PaddingTop = UDim.new(0, 3)
OP.PaddingBottom = UDim.new(0, 3)
OP.Parent = OutScroll

local OL = Instance.new("UIListLayout")
OL.SortOrder = Enum.SortOrder.LayoutOrder
OL.Padding = UDim.new(0, 1)
OL.Parent = OutScroll

local lineCount, MAX_LINES = 0, 250

local function Log(text, col)
    col = col or Color3.fromRGB(200, 200, 210)
    local str = tostring(text)
    if #str > 1200 then str = str:sub(1, 1200) .. " …" end
    lineCount = lineCount + 1
    local lbl = Instance.new("TextLabel")
    lbl.Text = str
    lbl.Size = UDim2.new(1, 0, 0, 0)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = col
    lbl.Font = Enum.Font.Code
    lbl.TextSize = 9
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.LayoutOrder = lineCount
    lbl.ZIndex = 7
    lbl.Parent = OutScroll
    task.defer(function()
        if OutScroll then OutScroll.CanvasPosition = Vector2.new(0, 1e6) end
    end)
    if lineCount % 25 == 0 then
        local labels = {}
        for _, c in ipairs(OutScroll:GetChildren()) do
            if c:IsA("TextLabel") then labels[#labels + 1] = c end
        end
        if #labels > MAX_LINES then
            table.sort(labels, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
            for i = 1, #labels - MAX_LINES do labels[i]:Destroy() end
        end
    end
end

-- ── action row ───────────────────────────────────────────────────────────────
local ActRow = Instance.new("Frame")
ActRow.BackgroundTransparency = 1
ActRow.ZIndex = 6
ActRow.Parent = Panel

local AL = Instance.new("UIListLayout")
AL.FillDirection = Enum.FillDirection.Horizontal
AL.SortOrder = Enum.SortOrder.LayoutOrder
AL.Padding = UDim.new(0, 4)
AL.Parent = ActRow

local function ActBtn(txt, bg, order, vis)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 80, 1, 0)
    b.BackgroundColor3 = bg
    b.Text = txt
    b.Font = Enum.Font.GothamBold
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 9
    b.Visible = (vis ~= false)
    b.LayoutOrder = order
    b.ZIndex = 6
    b.Parent = ActRow
    corner(b, 5)
    return b
end

local ExecBtn  = ActBtn("▶ Run",   Color3.fromRGB(40, 140, 200), 1, false)
local ScanBtn  = ActBtn("🔍 Scan", Color3.fromRGB(110, 45, 155), 2, true)
local ClearBtn = ActBtn("🗑 Clear", Color3.fromRGB(45, 45, 60),   3, true)

-- ── input ────────────────────────────────────────────────────────────────────
local InputWrap = Instance.new("ScrollingFrame")
InputWrap.BackgroundColor3 = Color3.fromRGB(12, 12, 24)
InputWrap.BorderSizePixel = 0
InputWrap.ScrollBarThickness = 2
InputWrap.ScrollBarImageColor3 = Color3.fromRGB(60, 60, 110)
InputWrap.AutomaticCanvasSize = Enum.AutomaticSize.Y
InputWrap.CanvasSize = UDim2.new(0, 0, 0, 0)
InputWrap.ZIndex = 6
InputWrap.Parent = Panel
corner(InputWrap, 6)
stroke(InputWrap, 1, Color3.fromRGB(45, 45, 78))

local InputBox = Instance.new("TextBox")
InputBox.Size = UDim2.new(1, 0, 0, 0)
InputBox.AutomaticSize = Enum.AutomaticSize.Y
InputBox.BackgroundTransparency = 1
InputBox.PlaceholderText = "ask anything…"
InputBox.PlaceholderColor3 = Color3.fromRGB(55, 55, 85)
InputBox.Text = ""
InputBox.TextColor3 = Color3.fromRGB(225, 225, 255)
InputBox.Font = Enum.Font.Code
InputBox.TextSize = 9
InputBox.MultiLine = true
InputBox.TextWrapped = true
InputBox.ClearTextOnFocus = false
InputBox.TextXAlignment = Enum.TextXAlignment.Left
InputBox.TextYAlignment = Enum.TextYAlignment.Top
InputBox.ZIndex = 7
InputBox.Parent = InputWrap

local IP = Instance.new("UIPadding")
IP.PaddingLeft = UDim.new(0, 4)
IP.PaddingRight = UDim.new(0, 4)
IP.PaddingTop = UDim.new(0, 4)
IP.PaddingBottom = UDim.new(0, 4)
IP.Parent = InputBox

-- ── ASK ──────────────────────────────────────────────────────────────────────
local AskBtn = Instance.new("TextButton")
AskBtn.BackgroundColor3 = Color3.fromRGB(195, 45, 45)
AskBtn.Text = "⚡  ASK"
AskBtn.Font = Enum.Font.GothamBold
AskBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AskBtn.TextSize = 12
AskBtn.ZIndex = 6
AskBtn.Parent = Panel
corner(AskBtn, 6)
stroke(AskBtn, 1, Color3.fromRGB(255, 70, 70))

-- ── layout maths: everything below is positioned from the panel size, so the
--    window can be any size and nothing ever overlaps (v2 used fixed offsets
--    and drew the ASK button on top of the input box on phones) ─────────────
local LAYOUT = {
    pad = 6, gap = 3,
    tbar = 30, prov = 14, picker = 17, status = 14,
    actions = 22, input = 52, ask = 28, bottom = 6,
}

local function ApplyLayout()
    local pad, gap = LAYOUT.pad, LAYOUT.gap
    local inner = panelW - pad * 2
    local y = LAYOUT.tbar + gap

    local function place(obj, h)
        obj.Position = UDim2.new(0, pad, 0, y)
        obj.Size = UDim2.new(0, inner, 0, h)
        y = y + h + gap
    end

    TBar.Size = UDim2.new(1, 0, 0, LAYOUT.tbar)
    place(ProvBadge,   LAYOUT.prov)
    place(PickerFrame, LAYOUT.picker)
    place(StatusBar,   LAYOUT.status)

    local bottomH = LAYOUT.actions + gap + LAYOUT.input + gap + LAYOUT.ask + LAYOUT.bottom
    local logH = math.max(50, panelH - y - bottomH)

    OutScroll.Position = UDim2.new(0, pad, 0, y)
    OutScroll.Size = UDim2.new(0, inner, 0, logH)
    y = y + logH + gap

    place(ActRow, LAYOUT.actions)
    place(InputWrap, LAYOUT.input)
    place(AskBtn, LAYOUT.ask)

    -- 3 action buttons share the row width
    local bw = math.floor((inner - gap * 2) / 3)
    ExecBtn.Size  = UDim2.new(0, bw, 1, 0)
    ScanBtn.Size  = UDim2.new(0, bw, 1, 0)
    ClearBtn.Size = UDim2.new(0, bw, 1, 0)

    -- dropdown hangs under the picker row, kept inside the panel
    Dropdown.Position = UDim2.new(0, pad + 44, 0, LAYOUT.tbar + gap * 3 + LAYOUT.prov + LAYOUT.picker - 2)
    Dropdown.Size = UDim2.new(0, math.min(170, inner - 44), 0, #CONFIG.gemini.models * 20 + 6)
end

local function layoutPanel(recenter)
    local vp = screenSize()
    panelW = math.clamp(math.floor(vp.X * 0.86), 258, 330)
    panelH = math.clamp(math.floor(vp.Y * 0.68), 320, 460)
    Panel.Size = UDim2.new(0, panelW, 0, panelH)

    local w, h = sizePx(Panel)
    if w <= 0 then w, h = panelW, panelH end
    local x, y
    if recenter then
        x = math.floor(math.max(0, (vp.X - panelW) / 2))
        y = math.floor(math.max(0, (vp.Y - panelH) / 2))
    else
        x, y = Panel.Position.X.Offset, Panel.Position.Y.Offset
    end
    x, y = clampTo(x, y, w, h)
    Panel.Position = UDim2.new(0, x, 0, y)

    ApplyLayout()
end

layoutPanel(true)

-- react to rotation / window resizes
pcall(function()
    local cam = workspace.CurrentCamera
    cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        layoutPanel(false)
    end)
end)

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
corner(Settings, 10)

local SScroll = Instance.new("ScrollingFrame")
SScroll.Size = UDim2.new(1, -12, 1, -12)
SScroll.Position = UDim2.new(0, 6, 0, 6)
SScroll.BackgroundTransparency = 1
SScroll.BorderSizePixel = 0
SScroll.ScrollBarThickness = 3
SScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
SScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
SScroll.ZIndex = 41
SScroll.Parent = Settings

local SL = Instance.new("UIListLayout")
SL.SortOrder = Enum.SortOrder.LayoutOrder
SL.Padding = UDim.new(0, 4)
SL.Parent = SScroll

local SPad = Instance.new("UIPadding")
SPad.PaddingLeft = UDim.new(0, 4)
SPad.PaddingRight = UDim.new(0, 4)
SPad.PaddingTop = UDim.new(0, 2)
SPad.PaddingBottom = UDim.new(0, 4)
SPad.Parent = SScroll

local order = 0
local function sNext() order = order + 1 return order end

local SHeaderRow = Instance.new("Frame")
SHeaderRow.Size = UDim2.new(1, 0, 0, 22)
SHeaderRow.BackgroundTransparency = 1
SHeaderRow.LayoutOrder = sNext()
SHeaderRow.ZIndex = 41
SHeaderRow.Parent = SScroll

local SHeader = Instance.new("TextLabel")
SHeader.Text = "⚙  API KEYS"
SHeader.Size = UDim2.new(1, -26, 1, 0)
SHeader.BackgroundTransparency = 1
SHeader.TextColor3 = Color3.fromRGB(120, 170, 255)
SHeader.Font = Enum.Font.GothamBold
SHeader.TextSize = 11
SHeader.TextXAlignment = Enum.TextXAlignment.Left
SHeader.ZIndex = 42
SHeader.Parent = SHeaderRow

local SClose = Instance.new("TextButton")
SClose.Size = UDim2.new(0, 22, 0, 22)
SClose.Position = UDim2.new(1, -22, 0, 0)
SClose.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
SClose.Text = "✕"
SClose.Font = Enum.Font.GothamBold
SClose.TextColor3 = Color3.fromRGB(255, 255, 255)
SClose.TextSize = 10
SClose.ZIndex = 42
SClose.Parent = SHeaderRow
corner(SClose, 4)
SClose.MouseButton1Click:Connect(function() Settings.Visible = false end)

local settingsBoxes = {}

local function keyRow(labelText, keyName, placeholder)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 36)
    row.BackgroundTransparency = 1
    row.LayoutOrder = sNext()
    row.ZIndex = 41
    row.Parent = SScroll

    local l = Instance.new("TextLabel")
    l.Text = labelText
    l.Size = UDim2.new(1, 0, 0, 11)
    l.BackgroundTransparency = 1
    l.TextColor3 = Color3.fromRGB(90, 110, 160)
    l.Font = Enum.Font.Code
    l.TextSize = 8
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.ZIndex = 42
    l.Parent = row

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, 0, 0, 22)
    box.Position = UDim2.new(0, 0, 0, 13)
    box.BackgroundColor3 = Color3.fromRGB(20, 20, 36)
    box.Text = KEYS[keyName] or ""
    box.PlaceholderText = placeholder or ""
    box.PlaceholderColor3 = Color3.fromRGB(60, 60, 90)
    box.TextColor3 = Color3.fromRGB(215, 225, 255)
    box.Font = Enum.Font.Code
    box.TextSize = 8
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.ClearTextOnFocus = false
    box.ZIndex = 42
    box.Parent = row
    corner(box, 4)
    stroke(box, 1, Color3.fromRGB(40, 45, 80))

    local bp = Instance.new("UIPadding")
    bp.PaddingLeft = UDim.new(0, 4)
    bp.PaddingRight = UDim.new(0, 4)
    bp.Parent = box

    settingsBoxes[#settingsBoxes + 1] = { box = box, key = keyName }
    return box
end

keyRow("GEMINI KEY (AQ.… or AIza…)", "gemini", "AQ.…")
keyRow("OPENROUTER KEY",             "openrouter", "sk-or-v1-…")
keyRow("TOKENHARBOR KEY",            "tokenharbor", "thk_live_…")

local SHint = Instance.new("TextLabel")
SHint.Text = "Free Gemini key → aistudio.google.com/apikey\n" ..
             "Free OpenRouter key → openrouter.ai/keys\n" ..
             "Leave blank to skip a provider."
SHint.Size = UDim2.new(1, 0, 0, 44)
SHint.BackgroundTransparency = 1
SHint.TextColor3 = Color3.fromRGB(80, 90, 130)
SHint.Font = Enum.Font.Code
SHint.TextSize = 8
SHint.TextWrapped = true
SHint.TextXAlignment = Enum.TextXAlignment.Left
SHint.TextYAlignment = Enum.TextYAlignment.Top
SHint.LayoutOrder = sNext()
SHint.ZIndex = 41
SHint.Parent = SScroll

local SaveKeysBtn = Instance.new("TextButton")
SaveKeysBtn.Size = UDim2.new(1, 0, 0, 28)
SaveKeysBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 90)
SaveKeysBtn.Text = "💾  Save & reconnect"
SaveKeysBtn.Font = Enum.Font.GothamBold
SaveKeysBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SaveKeysBtn.TextSize = 10
SaveKeysBtn.LayoutOrder = sNext()
SaveKeysBtn.ZIndex = 41
SaveKeysBtn.Parent = SScroll
corner(SaveKeysBtn, 5)

local ReconnectBtn = Instance.new("TextButton")
ReconnectBtn.Size = UDim2.new(1, 0, 0, 26)
ReconnectBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 70)
ReconnectBtn.Text = "🔄  Retry all providers"
ReconnectBtn.Font = Enum.Font.GothamBold
ReconnectBtn.TextColor3 = Color3.fromRGB(220, 220, 240)
ReconnectBtn.TextSize = 10
ReconnectBtn.LayoutOrder = sNext()
ReconnectBtn.ZIndex = 41
ReconnectBtn.Parent = SScroll
corner(ReconnectBtn, 5)

local SHttpsrc = Instance.new("TextLabel")
SHttpsrc.Text = "http: " .. tostring(HTTP_SOURCE or "not found")
SHttpsrc.Size = UDim2.new(1, 0, 0, 12)
SHttpsrc.BackgroundTransparency = 1
SHttpsrc.TextColor3 = HTTP_SOURCE and Color3.fromRGB(70, 160, 110) or Color3.fromRGB(200, 80, 80)
SHttpsrc.Font = Enum.Font.Code
SHttpsrc.TextSize = 8
SHttpsrc.LayoutOrder = sNext()
SHttpsrc.ZIndex = 41
SHttpsrc.Parent = SScroll

SettingsBtn.MouseButton1Click:Connect(function()
    Settings.Visible = not Settings.Visible
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 9.  STATE + ACTIONS
-- ══════════════════════════════════════════════════════════════════════════════
local Connected   = false
local Busy        = false
local LastCode    = nil
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

local function DoScan()
    local ok, res = pcall(ScanGame)
    if ok then
        LastGameCtx = res
        Log("🔍 scanned — PlaceID " .. tostring(game.PlaceId), Color3.fromRGB(150, 80, 200))
    else
        Log("❌ scan: " .. tostring(res):sub(1, 90), Color3.fromRGB(215, 55, 55))
    end
end

ScanBtn.MouseButton1Click:Connect(function()
    task.spawn(DoScan)
end)

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

local function RunLastCode()
    if not LastCode then
        Log("⚠ nothing to run yet.", Color3.fromRGB(255, 180, 40))
        return
    end
    Log("▶ executing…", Color3.fromRGB(52, 150, 215))
    local ok, err = ExecScript(LastCode, function(runtimeErr)
        Log("❌ runtime: " .. tostring(runtimeErr):sub(1, 240), Color3.fromRGB(215, 55, 55))
        StatusLbl.Text = "❌ runtime error"
        StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
    end)
    if ok then
        Log("✅ script launched.", Color3.fromRGB(46, 200, 110))
        StatusLbl.Text = "✅ executed"
        StatusLbl.TextColor3 = Color3.fromRGB(46, 200, 110)
    else
        Log("❌ " .. tostring(err), Color3.fromRGB(215, 55, 55))
        StatusLbl.Text = "❌ execution failed"
        StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
    end
end

ExecBtn.MouseButton1Click:Connect(RunLastCode)

local Submit

Submit = function()
    if Busy then return end
    local msg = (InputBox.Text or ""):match("^%s*(.-)%s*$")
    if msg == "" then return end
    if not Connected then
        Log("⚠ not connected — open ⚙ and check your keys.", Color3.fromRGB(255, 180, 40))
        Settings.Visible = true
        return
    end

    setBusy(true)
    InputBox.Text = ""
    StatusLbl.Text = "⏳ thinking…"
    StatusLbl.TextColor3 = Color3.fromRGB(255, 200, 80)
    Log("──────────", Color3.fromRGB(25, 25, 45))
    Log("you: " .. msg:sub(1, 260) .. (#msg > 260 and "…" or ""), Color3.fromRGB(120, 165, 255))

    task.spawn(function()
        local ok, reply, prov, err = pcall(AskAI, msg, LastGameCtx, Log)
        if not ok then
            Log("❌ internal error: " .. tostring(reply), Color3.fromRGB(215, 55, 55))
            StatusLbl.Text = "❌ internal error"
            StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
            setBusy(false)
            return
        end

        if not reply then
            Log("❌ all providers failed.", Color3.fromRGB(215, 55, 55))
            Log("   " .. tostring(err):sub(1, 220), Color3.fromRGB(180, 70, 70))
            Log("   → tap ⚙ to check your API keys.", Color3.fromRGB(180, 140, 60))
            StatusLbl.Text = "❌ all providers failed"
            StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
        else
            SetProvBadge(prov)
            for line in (reply .. "\n"):gmatch("(.-)\n") do Log(line) end

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
                    Log("⚡ auto-exec…", Color3.fromRGB(255, 180, 40))
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

-- ══════════════════════════════════════════════════════════════════════════════
-- 10. CONNECT / BOOT
-- ══════════════════════════════════════════════════════════════════════════════
local function Connect(silent)
    if Busy then return end
    if not RawRequest then
        StatusLbl.Text = "❌ no HTTP function"
        StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
        Log("❌ no HTTP function found.", Color3.fromRGB(215, 55, 55))
        Log("   looked for: request, http_request, getgenv().request, syn.request, http.request", 
            Color3.fromRGB(180, 140, 60))
        Log("   → update/re-inject Delta, then run the script again.", Color3.fromRGB(180, 140, 60))
        Notify("AI Helper", "No HTTP function — re-inject Delta.", 8)
        return
    end

    if not (KEYS.gemini ~= "" or KEYS.openrouter ~= "" or KEYS.tokenharbor ~= "") then
        StatusLbl.Text = "🔑 add an API key"
        StatusLbl.TextColor3 = Color3.fromRGB(255, 190, 60)
        Log("🔑 no API key yet.", Color3.fromRGB(255, 190, 60))
        Log("   paste one in ⚙ → Save & reconnect.", Color3.fromRGB(180, 140, 60))
        Log("   gemini: aistudio.google.com/apikey  (AQ.… or AIza…)", Color3.fromRGB(120, 160, 220))
        Log("   openrouter: openrouter.ai/keys", Color3.fromRGB(120, 160, 220))
        Settings.Visible = true
        Notify("AI Helper", "Paste an API key in the ⚙ panel.", 6)
        return
    end

    setBusy(true)
    StatusLbl.Text = "⏳ connecting…"
    StatusLbl.TextColor3 = Color3.fromRGB(255, 200, 80)
    if not silent then
        Log("🤖 connecting (http: " .. tostring(HTTP_SOURCE) .. ")…", Color3.fromRGB(110, 155, 255))
    end

    task.spawn(function()
        local ok, reply, prov, err = pcall(AskAI, "Reply with exactly: CONNECTED", nil, function() end, true)
        if ok and reply then
            Connected = true
            SetProvBadge(prov)
            StatusLbl.Text = "✅ online via " .. tostring(prov)
            StatusLbl.TextColor3 = Color3.fromRGB(46, 200, 110)
            Log("✅ live on " .. tostring(prov), Color3.fromRGB(46, 200, 110))
            Log("say 'run it' to auto-execute.", Color3.fromRGB(130, 130, 155))
            task.spawn(DoScan)
        else
            Connected = false
            StatusLbl.Text = "❌ all providers down"
            StatusLbl.TextColor3 = Color3.fromRGB(215, 55, 55)
            Log("❌ no provider answered.", Color3.fromRGB(215, 55, 55))
            Log("   " .. tostring(ok and err or reply):sub(1, 200), Color3.fromRGB(180, 70, 70))
            Log("   → tap ⚙ to paste a working key.", Color3.fromRGB(180, 140, 60))
            ProvBadge.Text = "  ✦ offline   ·   http: " .. tostring(HTTP_SOURCE)
            ProvBadge.TextColor3 = Color3.fromRGB(200, 80, 80)
        end
        setBusy(false)
    end)
end

SaveKeysBtn.MouseButton1Click:Connect(function()
    for _, item in ipairs(settingsBoxes) do
        KEYS[item.key] = (item.box.Text or ""):gsub("%s+", "")
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
Log("🤖 AI Helper loaded (http: " .. tostring(HTTP_SOURCE or "none") .. ")",
    Color3.fromRGB(110, 155, 255))
Log("🤖 bubble = open  •  ⚙ = keys  •  drag the title bar to move",
    Color3.fromRGB(120, 120, 155))
Notify("AI Helper", "Loaded — tap the 🤖 bubble.", 3)

Connect(true) -- handles both diagnostics: no http function, or no API key

end -- ════════════════════════════════ END SCOPE ════════════════════════════════
