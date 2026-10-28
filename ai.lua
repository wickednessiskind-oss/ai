--!nocheck
--[[
    ██████╗  AI HELPER  —  single-file Roblox executor script (Luau)
    ==================================================================
    A small, friendly AI panel for Roblox executors (Delta / mobile ready).

                     providers, in order:
        1. TokenHarbor   (OpenAI-compatible)
        2. Google Gemini (key from aistudio.google.com/apikey)
        3. OpenRouter    (live list of the models that are free *right now*)

    ------------------------------------------------------------------
    v4
      * LIVE MODEL LISTS. OpenRouter's free tier changes weekly, so the
        hardcoded ":free" slugs kept 404-ing. The script now fetches
        https://openrouter.ai/api/v1/models and keeps only entries whose
        prompt+completion price is 0. Gemini does the same with
        /v1beta/models, filtered to models that support generateContent.
      * MODEL PICKER for both providers — tap a model row, pick from the
        live list, choice is remembered.
      * AUTO-FALLBACK across the fetched list, so a retired model can no
        longer take the whole thing down; ends with openrouter/free.
      * ONE-LINE failure summary per provider at the end of an attempt.
      * GUI redesigned: gradient panels, coloured accents, rounded chips,
        hover/press states, comfortable tap targets, real type hierarchy.
    v3
      * Delta's `request` is injected into the script environment, not
        into _G — the old _G lookup was why it said "no HTTP function".
      * Gemini "AQ.…" keys must go in the x-goog-api-key header (?key=
        404s), so both auth styles are attempted.
    v2
      * Removed goto/::done:: (Luau has no goto, v1 never compiled).
      * Fence parser, bounded game scan, timeouts, CoreGui fallback,
        generated code on its own thread, safe re-execution.
    ------------------------------------------------------------------
    Keys are never stored in this file. Paste them in ⚙ once.
    Everything is inside a do-block, so re-running is always safe.
]]

do --════════════════════════════════════ SCOPE ════════════════════════════════════

--══════════════════════════════════════════════════════════════════════════════
-- 1.  SERVICES + SAFE BOOT
--══════════════════════════════════════════════════════════════════════════════
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")
local TweenService      = game:GetService("TweenService")

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

--══════════════════════════════════════════════════════════════════════════════
-- 2.  CONFIG  (keys stay empty here — paste them in the ⚙ panel)
--══════════════════════════════════════════════════════════════════════════════
local CONFIG = {
    tokenharbor = {
        key   = "",
        model = "deepseek/deepseek-v4.1-flash:free",
        url   = "https://api.tokenharbor.ai/v1/chat/completions",
    },
    gemini = {
        key  = "",
        base = "https://generativelanguage.googleapis.com/v1beta/models/",
        list = "https://generativelanguage.googleapis.com/v1beta/models",
        -- used only when the live list can't be fetched (offline / bad key)
        fallback = { "gemini-2.5-flash", "gemini-2.0-flash", "gemini-1.5-flash",
                     "gemini-2.5-flash-lite" },
    },
    openrouter = {
        key   = "",
        url   = "https://openrouter.ai/api/v1/chat/completions",
        list  = "https://openrouter.ai/api/v1/models",
        -- used only when the live list can't be fetched
        fallback = { "openrouter/free", "meta-llama/llama-3.3-70b-instruct:free",
                     "qwen/qwen3-coder:free" },
    },
}

local MAX_CTX      = 8
local HTTP_TIMEOUT = 45
local MAX_TOKENS   = 4096
local PREF_FILE    = "ai_helper_keys.json"

local KEYS = {
    tokenharbor = CONFIG.tokenharbor.key,
    gemini      = CONFIG.gemini.key,
    openrouter  = CONFIG.openrouter.key,
}

--══════════════════════════════════════════════════════════════════════════════
-- 3.  PERSISTENCE  (keys + chosen models, when the executor has writefile)
--══════════════════════════════════════════════════════════════════════════════
local Prefs = { keys = KEYS, models = {} }

local function readPrefs()
    local ok, raw = pcall(function()
        if type(isfile) == "function" and type(readfile) == "function" then
            if isfile(PREF_FILE) then return readfile(PREF_FILE) end
        end
        return nil
    end)
    if not ok or type(raw) ~= "string" or raw == "" then return nil end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok2 and type(data) == "table" then return data end
    return nil
end

local function savePrefs()
    pcall(function()
        if type(writefile) == "function" then
            writefile(PREF_FILE, HttpService:JSONEncode(Prefs))
        end
    end)
end

do
    local stored = readPrefs()
    if stored then
        -- new layout: { keys = {...}, models = {...} }
        if type(stored.keys) == "table" then
            for k in pairs(KEYS) do
                if type(stored.keys[k]) == "string" then KEYS[k] = stored.keys[k] end
            end
        end
        if type(stored.models) == "table" then
            for k, v in pairs(stored.models) do
                if type(v) == "string" and v ~= "" then Prefs.models[k] = v end
            end
        end
        -- old layout: { gemini = "...", openrouter = "..." }
        for k in pairs(KEYS) do
            if type(stored[k]) == "string" and stored[k] ~= "" then KEYS[k] = stored[k] end
        end
    end
end

--══════════════════════════════════════════════════════════════════════════════
-- 4.  HTTP RESOLVER
--     Executors inject `request` into the script environment, not into _G,
--     so read the globals first and only then the shared env / namespaces.
--══════════════════════════════════════════════════════════════════════════════
local RawRequest, HTTP_SOURCE = nil, nil

do
    local found = {}
    local function add(name, fn)
        if type(fn) == "function" then found[#found + 1] = { name = name, fn = fn } end
    end

    add("request",      request)
    add("http_request", http_request)

    local okGenv, genv = pcall(function() return getgenv and getgenv() or nil end)
    if okGenv and type(genv) == "table" then
        add("getgenv().request",      genv.request)
        add("getgenv().http_request", genv.http_request)
        if type(genv.syn)  == "table" then add("getgenv().syn.request",  genv.syn.request)  end
        if type(genv.http) == "table" then add("getgenv().http.request", genv.http.request) end
    end

    if type(syn)    == "table"  then add("syn.request",    syn.request)    end
    if type(http)   == "table"  then add("http.request",   http.request)   end
    if type(fluxus) == "table"  then add("fluxus.request", fluxus.request) end
    if type(krnl)   == "table"  then add("krnl.request",   krnl.request)   end
    if type(delta)  == "table"  then add("delta.request",  delta.request)  end
    if type(secure_call) == "function" and type(syn) == "table" and type(syn.request) == "function" then
        add("secure_call(syn.request)", function(o) return secure_call(syn.request, o) end)
    end

    if #found > 0 then
        RawRequest  = found[1].fn
        HTTP_SOURCE = found[1].name
    end
end

local function HttpCall(opts)
    if not RawRequest then return 0, "no http function available in this executor" end
    if opts.Timeout == nil then opts.Timeout = HTTP_TIMEOUT end
    local ok, res = pcall(RawRequest, opts)
    if not ok then return 0, "request error: " .. tostring(res) end
    if type(res) ~= "table" then return 0, "request returned " .. type(res) end
    local code = res.StatusCode or res.Status or res.status or res.statusCode or 0
    local body = res.Body or res.body or res.Data or res.data or ""
    if type(body) ~= "string" then body = tostring(body) end
    return tonumber(code) or 0, body
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

local function shortErr(body, limit)
    local d = JsonDecode(body)
    if d and d.error then
        local e = d.error
        if type(e) == "table" then return tostring(e.message or e.status or e.code or "error") end
        if type(e) == "string" then return e end
    end
    if d and d.message then return tostring(d.message) end
    return tostring(body or ""):sub(1, limit or 120)
end

--══════════════════════════════════════════════════════════════════════════════
-- 5.  GAME SCANNER  (bounded, never freezes the client)
--══════════════════════════════════════════════════════════════════════════════
local function collectBounded(root, maxDepth, maxNodes)
    local out, queue = {}, { { inst = root, depth = 0 } }
    local head, visited = 1, 0
    while head <= #queue and visited < maxNodes do
        local node = queue[head]; head = head + 1
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
                    Name = obj.Name, HP = math.floor(h.Health), MaxHP = math.floor(h.MaxHealth),
                }
                if #npcs >= 20 then break end
            end
        end
    end

    local remotes = {}
    for _, obj in ipairs(collectBounded(ReplicatedStorage, 3, 3000)) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
            remotes[#remotes + 1] = obj.ClassName .. ": " .. obj:GetFullName()
            if #remotes >= 30 then break end
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
            if #wsObjs >= 25 then break end
        end
    end

    local gameName = "Unknown"
    pcall(function()
        gameName = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
    end)

    return HttpService:JSONEncode({
        PlaceID = game.PlaceId, GameName = gameName,
        PlayerCount = #Players:GetPlayers(), PlayerName = LP and LP.Name or "?",
        Position = string.format("%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z),
        Tools = tools, NPCs = npcs, RemoteEvents = remotes, WorkspaceObjects = wsObjs,
    })
end

--══════════════════════════════════════════════════════════════════════════════
-- 6.  MODEL CATALOGS  (live, so dead model ids can't break the script)
--══════════════════════════════════════════════════════════════════════════════
local Catalog = {
    gemini = {
        state = "idle",     -- idle | loading | ready | error
        error = nil,
        list  = {},         -- { { id = "...", label = "...", note = "..." }, ... }
        selected = Prefs.models.gemini,
    },
    openrouter = {
        state = "idle",
        error = nil,
        list  = {},
        selected = Prefs.models.openrouter,
    },
}

local OnCatalogChanged = function() end  -- wired to the GUI later

local function setCatalog(provider, state, err)
    local cat = Catalog[provider]
    cat.state = state
    cat.error = err
    -- if the live list can't be fetched, fall back to the built-in ids so the
    -- picker is never an empty screen
    if state == "error" and #cat.list == 0 then
        local list = {}
        for _, id in ipairs(CONFIG[provider].fallback or {}) do
            list[#list + 1] = { id = id, label = id, note = "built-in" }
        end
        cat.list = list
    end
    OnCatalogChanged(provider)
end

-- OpenRouter: GET /api/v1/models -> keep zero-priced, text-output models
local function FetchOpenRouterModels(verbose)
    setCatalog("openrouter", "loading")
    local status, body = HttpCall({
        Url = CONFIG.openrouter.list,
        Method = "GET",
        Headers = {
            ["Accept"] = "application/json",
            ["HTTP-Referer"] = "https://github.com",
            ["X-Title"] = "RobloxAIHelper",
        },
    })
    if status ~= 200 then
        setCatalog("openrouter", "error", string.format("HTTP %d: %s", status, shortErr(body)))
        return false
    end
    local d = JsonDecode(body)
    local data = d and (d.data or d.models)
    if type(data) ~= "table" then
        setCatalog("openrouter", "error", "unexpected response")
        return false
    end

    local list = {}
    for _, m in ipairs(data) do
        local id = m.id
        if type(id) == "string" then
            local pricing = m.pricing or {}
            local pin  = tonumber(pricing.prompt or pricing.input or -1)
            local pout = tonumber(pricing.completion or pricing.output or -1)
            local free = (pin == 0 and pout == 0)

            local outputs = m.architecture and m.architecture.output_modalities
            local textOK = true
            if type(outputs) == "table" then
                textOK = false
                for _, mod in ipairs(outputs) do
                    if tostring(mod):lower() == "text" then textOK = true break end
                end
            end

            if free and textOK then
                local ctx = tonumber(m.context_length or (m.top_provider and m.top_provider.context_length) or 0)
                list[#list + 1] = {
                    id    = id,
                    label = (m.name and tostring(m.name):gsub("%s*%(free%)%s*$", "")) or id,
                    note  = (ctx > 0) and string.format("%dk ctx", math.floor(ctx / 1000)) or "",
                }
            end
        end
    end

    table.sort(list, function(a, b) return a.id < b.id end)
    -- keep the UI snappy and the request short
    while #list > 80 do table.remove(list) end

    Catalog.openrouter.list = list
    if #list == 0 then
        setCatalog("openrouter", "error", "no free models listed right now")
        return false
    end
    setCatalog("openrouter", "ready")

    -- make sure the saved pick still exists
    local sel = Catalog.openrouter.selected
    if sel then
        local keep = false
        for _, m in ipairs(list) do
            if m.id == sel then keep = true break end
        end
        if not keep then Catalog.openrouter.selected = nil end
    end
    if verbose then
        setCatalog("openrouter", "ready")
    end
    return true
end

-- Gemini: GET /v1beta/models -> keep models that support generateContent
local function FetchGeminiModels(verbose)
    setCatalog("gemini", "loading")
    local key = KEYS.gemini
    if key == "" then
        setCatalog("gemini", "error", "no api key")
        return false
    end

    local status, body = HttpCall({
        Url = CONFIG.gemini.list .. "?pageSize=200",
        Method = "GET",
        Headers = { ["Accept"] = "application/json", ["x-goog-api-key"] = key },
    })
    if status ~= 200 then
        -- retry once with the legacy query style
        status, body = HttpCall({
            Url = CONFIG.gemini.list .. "?pageSize=200&key=" .. UrlEncode(key),
            Method = "GET",
            Headers = { ["Accept"] = "application/json" },
        })
    end
    if status ~= 200 then
        setCatalog("gemini", "error", string.format("HTTP %d: %s", status, shortErr(body)))
        return false
    end

    local d = JsonDecode(body)
    local models = d and d.models
    if type(models) ~= "table" then
        setCatalog("gemini", "error", "unexpected response")
        return false
    end

    local list = {}
    for _, m in ipairs(models) do
        local raw = tostring(m.name or "")
        local id  = raw:gsub("^models/", "")
        local methods = m.supportedGenerationMethods or {}
        local canGenerate = false
        for _, meth in ipairs(methods) do
            if meth == "generateContent" then canGenerate = true break end
        end
        -- embeddings / vision-only generators are noise here
        local junk = id:find("embedding", 1, true) or id:find("aqa", 1, true)
            or id:find("imagen", 1, true) or id:find("veo", 1, true)
            or id:find("tts", 1, true)
        if canGenerate and not junk then
            list[#list + 1] = {
                id = id,
                label = (m.displayName and tostring(m.displayName)) or id,
                note = id,
            }
        end
    end

    table.sort(list, function(a, b) return a.id < b.id end)
    Catalog.gemini.list = list
    if #list == 0 then
        setCatalog("gemini", "error", "this key can't call any model")
        return false
    end

    local sel = Catalog.gemini.selected
    if sel then
        local keep = false
        for _, m in ipairs(list) do if m.id == sel then keep = true break end end
        if not keep then Catalog.gemini.selected = nil end
    end
    setCatalog("gemini", "ready")
    return true
end

local function FetchAllModels(verbose)
    task.spawn(function() pcall(FetchOpenRouterModels, verbose) end)
    task.spawn(function() pcall(FetchGeminiModels, verbose) end)
end

-- model id ordering for one attempt: picked first, then the rest of the list
local function ModelOrder(provider, limit)
    local order, seen = {}, {}
    local cat = Catalog[provider]
    local function push(id)
        if type(id) == "string" and id ~= "" and not seen[id] then
            seen[id] = true
            order[#order + 1] = id
        end
    end

    push(cat.selected)
    for _, m in ipairs(cat.list) do push(m.id) end
    for _, id in ipairs(CONFIG[provider].fallback or {}) do push(id) end
    if provider == "openrouter" then push("openrouter/free") end

    local capped = {}
    for i = 1, math.min(#order, limit or 4) do capped[i] = order[i] end
    return capped
end

--══════════════════════════════════════════════════════════════════════════════
-- 7.  PROVIDERS
--══════════════════════════════════════════════════════════════════════════════
local function extractOpenAI(body)
    local d = JsonDecode(body)
    local choice = d and d.choices and d.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) == "string" and content ~= "" then return content end
    if d and type(d.content) == "string" and d.content ~= "" then return d.content end
    return nil
end

-- TokenHarbor ────────────────────────────────────────────────────────────────
local function CallTokenharbor(messages)
    if KEYS.tokenharbor == "" then return nil, "no api key" end
    local status, body = HttpCall({
        Url = CONFIG.tokenharbor.url, Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. KEYS.tokenharbor,
        },
        Body = JsonEncode({
            model = CONFIG.tokenharbor.model, max_tokens = MAX_TOKENS, messages = messages,
        }),
    })
    if status ~= 200 then
        return nil, string.format("HTTP %d: %s", status, shortErr(body))
    end
    local reply = extractOpenAI(body)
    if not reply then return nil, "empty response" end
    return reply, nil
end

-- Gemini ─────────────────────────────────────────────────────────────────────
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
    while contents[1] and contents[1].role ~= "user" do table.remove(contents, 1) end
    return contents, sysParts
end

-- returns reply, err, and whether trying another model could help
local function CallGeminiModel(payload, modelId)
    local key = KEYS.gemini
    local base = CONFIG.gemini.base .. modelId .. ":generateContent"
    local body = JsonEncode(payload)

    local attempts = {
        { url = base, headers = { ["Content-Type"] = "application/json", ["x-goog-api-key"] = key } },
        { url = base .. "?key=" .. UrlEncode(key), headers = { ["Content-Type"] = "application/json" } },
    }

    local lastErr, retryOtherModel = "unknown", false
    for _, at in ipairs(attempts) do
        local status, resBody = HttpCall({
            Url = at.url, Method = "POST", Headers = at.headers, Body = body,
        })

        if status == 200 then
            local d = JsonDecode(resBody)
            local cand = d and d.candidates and d.candidates[1]
            local text = cand and cand.content and cand.content.parts and cand.content.parts[1]
                and cand.content.parts[1].text
            if type(text) == "string" and text ~= "" then return text, nil, false end
            local reason = (cand and cand.finishReason)
                or (d and d.promptFeedback and d.promptFeedback.blockReason) or "no candidates"
            return nil, "empty (" .. tostring(reason) .. ")", false
        end

        lastErr = string.format("HTTP %d: %s", status, shortErr(resBody))
        if status == 404 then
            retryOtherModel = true            -- model gone: try the next one
        elseif status == 429 then
            return nil, lastErr, false        -- quota: stop hammering
        elseif status == 400 or status == 401 or status == 403 then
            local low = lastErr:lower()
            if low:find("not found", 1, true) or low:find("not supported", 1, true)
                or low:find("does not exist", 1, true) then
                retryOtherModel = true
            else
                retryOtherModel = false       -- bad key / bad request
            end
        end
    end
    return nil, lastErr, retryOtherModel
end

local function CallGemini(messages)
    if KEYS.gemini == "" then return nil, "no api key" end
    local contents, sysParts = messagesToGemini(messages)
    if #contents == 0 then return nil, "nothing to send" end

    local payload = {
        contents = contents,
        generationConfig = { maxOutputTokens = MAX_TOKENS, temperature = 0.7 },
    }
    if #sysParts > 0 then payload.systemInstruction = { parts = sysParts } end

    local errs = {}
    for _, id in ipairs(ModelOrder("gemini", 4)) do
        local text, err, tryMore = CallGeminiModel(payload, id)
        if text then
            if not Catalog.gemini.selected then Catalog.gemini.selected = id end
            return text, nil
        end
        errs[#errs + 1] = id .. " → " .. tostring(err)
        if not tryMore then break end
    end
    return nil, table.concat(errs, " · ")
end

-- OpenRouter ─────────────────────────────────────────────────────────────────
local function CallOpenRouterModel(messages, modelId)
    local status, body = HttpCall({
        Url = CONFIG.openrouter.url, Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. KEYS.openrouter,
            ["HTTP-Referer"] = "https://github.com",
            ["X-Title"] = "RobloxAIHelper",
        },
        Body = JsonEncode({ model = modelId, max_tokens = MAX_TOKENS, messages = messages }),
    })
    if status == 200 then
        local reply = extractOpenAI(body)
        if reply then return reply, nil, false end
        return nil, "empty response", true
    end
    local err = string.format("HTTP %d: %s", status, shortErr(body))
    if status == 401 or status == 402 or status == 429 then
        return nil, err, false      -- auth / credits / rate limit: stop
    end
    return nil, err, true           -- 404 model retired: try the next one
end

local function CallOpenRouter(messages)
    if KEYS.openrouter == "" then return nil, "no api key" end
    local errs = {}
    local tried = 0
    for _, id in ipairs(ModelOrder("openrouter", 4)) do
        tried = tried + 1
        local reply, err, tryMore = CallOpenRouterModel(messages, id)
        if reply then
            if not Catalog.openrouter.selected then Catalog.openrouter.selected = id end
            return reply, nil
        end
        errs[#errs + 1] = id .. " → " .. tostring(err)
        if not tryMore then break end
    end
    if tried == 1 and #errs == 1 then return nil, errs[1] end
    return nil, table.concat(errs, " · ")
end

--══════════════════════════════════════════════════════════════════════════════
-- 8.  CHAT + UNIFIED ASK
--══════════════════════════════════════════════════════════════════════════════
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

local activeProvider = nil

-- returns reply, provider, summaryTable
local function AskAI(userMsg, gameCtx, logFn, noHistory)
    logFn = logFn or function() end
    local messages = BuildMessages(userMsg, gameCtx)
    local failures = {}
    local reply, err

    local steps = {
        {
            name = "tokenharbor",
            run  = CallTokenharbor,
            color = Color3.fromRGB(94, 234, 168),
        },
        {
            name = "gemini",
            run  = CallGemini,
            color = Color3.fromRGB(120, 190, 255),
        },
        {
            name = "openrouter",
            run  = CallOpenRouter,
            color = Color3.fromRGB(255, 176, 112),
        },
    }

    for _, step in ipairs(steps) do
        local keyMissing =
            (step.name == "tokenharbor" and KEYS.tokenharbor == "") or
            (step.name == "gemini"     and KEYS.gemini == "")     or
            (step.name == "openrouter" and KEYS.openrouter == "")

        if keyMissing then
            failures[#failures + 1] = { name = step.name, err = "no api key" }
        else
            logFn("· " .. step.name .. "…", step.color)
            local ok, r, e = pcall(step.run, messages)
            if ok and r then
                reply, err = r, nil
                activeProvider = step.name
                -- if this provider used a different model than the pick, remember it
                break
            end
            err = ok and e or ("error: " .. tostring(r))
            failures[#failures + 1] = { name = step.name, err = tostring(err) }
        end
    end

    if not reply then return nil, nil, failures end

    if not noHistory then
        ChatHistory[#ChatHistory + 1] = { role = "user", content = userMsg }
        ChatHistory[#ChatHistory + 1] = { role = "assistant", content = reply }
        while #ChatHistory > MAX_CTX * 2 do table.remove(ChatHistory, 1) end
    end
    return reply, activeProvider, failures
end

--══════════════════════════════════════════════════════════════════════════════
-- 9.  CODE EXTRACTION + EXECUTION
--══════════════════════════════════════════════════════════════════════════════
local function trimBlanks(s)
    s = tostring(s or "")
    s = s:gsub("^%s*\n", ""):gsub("%s+$", "")
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

local function ExecScript(code, onError)
    if not code or code == "" then return false, "no code to run" end
    if not LOADER then return false, "loadstring isn't available in this executor" end
    local fn, compileErr = LOADER(code)
    if not fn then return false, "compile error: " .. tostring(compileErr) end
    task.spawn(function()
        local ok, runtimeErr = pcall(fn)
        if not ok and onError then onError(runtimeErr) end
    end)
    return true, nil
end

--══════════════════════════════════════════════════════════════════════════════
-- 10.  THEME
--══════════════════════════════════════════════════════════════════════════════
local THEME = {
    -- surfaces
    bgTop      = Color3.fromRGB(27, 25, 48),
    bgBottom   = Color3.fromRGB(16, 16, 30),
    card       = Color3.fromRGB(33, 32, 57),
    cardAlt    = Color3.fromRGB(40, 39, 70),
    well       = Color3.fromRGB(15, 15, 27),
    stroke     = Color3.fromRGB(64, 62, 108),
    strokeSoft = Color3.fromRGB(48, 46, 82),

    -- accents
    violet     = Color3.fromRGB(150, 122, 255),
    violetDeep = Color3.fromRGB(112, 84, 226),
    cyan       = Color3.fromRGB(96, 214, 255),
    pink       = Color3.fromRGB(255, 128, 190),
    mint       = Color3.fromRGB(94, 234, 168),
    amber      = Color3.fromRGB(255, 196, 92),
    coral      = Color3.fromRGB(255, 118, 118),

    -- text
    text       = Color3.fromRGB(238, 240, 252),
    textDim    = Color3.fromRGB(166, 170, 204),
    textFaint  = Color3.fromRGB(112, 116, 152),
}

local FONT       = Enum.Font.Gotham
local FONT_MED   = Enum.Font.GothamMedium
local FONT_BOLD  = Enum.Font.GothamBold
local FONT_MONO  = Enum.Font.Code

--══════════════════════════════════════════════════════════════════════════════
-- 11.  GUI HELPERS
--══════════════════════════════════════════════════════════════════════════════
local function corner(obj, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = obj
    return c
end

local function stroke(obj, thickness, color, transparency)
    local s = Instance.new("UIStroke")
    s.Thickness = thickness or 1
    s.Color = color or THEME.strokeSoft
    s.Transparency = transparency or 0
    s.Parent = obj
    return s
end

local function gradient(obj, from, to, rotation)
    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new(from, to)
    g.Rotation = rotation or 90
    g.Parent = obj
    return g
end

local function pad(obj, l, r, t, b)
    local p = Instance.new("UIPadding")
    p.PaddingLeft = UDim.new(0, l or 0)
    p.PaddingRight = UDim.new(0, r or l or 0)
    p.PaddingTop = UDim.new(0, t or 0)
    p.PaddingBottom = UDim.new(0, b or t or 0)
    p.Parent = obj
    return p
end

local function label(parent, text, size, color, font, textSize, xAlign)
    local l = Instance.new("TextLabel")
    l.Text = text
    l.Size = size
    l.BackgroundTransparency = 1
    l.TextColor3 = color or THEME.text
    l.Font = font or FONT
    l.TextSize = textSize or 11
    l.TextXAlignment = xAlign or Enum.TextXAlignment.Left
    l.RichText = false
    l.Parent = parent
    return l
end

-- hover / press feedback for buttons
local function addButtonFeel(btn, baseColor, hoverColor, pressColor)
    btn.BackgroundColor3 = baseColor
    btn.AutoButtonColor = false
    btn.MouseEnter:Connect(function()
        if btn:GetAttribute("lock") ~= true then
            TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = hoverColor }):Play()
        end
    end)
    btn.MouseLeave:Connect(function()
        if btn:GetAttribute("lock") ~= true then
            TweenService:Create(btn, TweenInfo.new(0.16), { BackgroundColor3 = baseColor }):Play()
        end
    end)
    btn.MouseButton1Down:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.05), { BackgroundColor3 = pressColor }):Play()
    end)
    btn.MouseButton1Up:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = hoverColor }):Play()
    end)
    btn:SetAttribute("baseColor", baseColor)
end

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

local function clampTo(x, y, w, h)
    local vp = screenSize()
    return math.clamp(x, 0, math.max(0, vp.X - w)), math.clamp(y, 0, math.max(0, vp.Y - h))
end

local function makeDraggable(frame, handle)
    local dragging, dragStart, startPos = false, nil, nil
    local moved, movedAt = false, 0

    handle.InputBegan:Connect(function(input)
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
            dragging, moved = true, false
            dragStart, startPos = input.Position, frame.Position
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
            local w, h = sizePx(frame)
            local nx, ny = clampTo(startPos.X.Offset + delta.X, startPos.Y.Offset + delta.Y, w, h)
            frame.Position = UDim2.new(0, nx, 0, ny)
        end
    end)

    return function()
        return moved and (os.clock() - movedAt) < 0.3
    end
end

--══════════════════════════════════════════════════════════════════════════════
-- 12.  ROOT GUI
--══════════════════════════════════════════════════════════════════════════════
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
    Notify("AI Helper", "Couldn't create the panel — CoreGui/PlayerGui blocked.", 8)
    return
end

--────────────────────────────────────────────── floating bubble
local Bubble = Instance.new("TextButton")
Bubble.Size = UDim2.new(0, 44, 0, 44)
Bubble.BackgroundColor3 = THEME.card
Bubble.Text = ""
Bubble.ZIndex = 20
Bubble.Parent = SG
corner(Bubble, 22)
stroke(Bubble, 1.5, THEME.violet, 0.25)
gradient(Bubble, THEME.violetDeep, THEME.bgBottom, 115)
do
    local vp = screenSize()
    local _, y = clampTo(0, math.floor(vp.Y * 0.40), 44, 44)
    Bubble.Position = UDim2.new(0, 10, 0, y)
end

local BubbleIcon = label(Bubble, "✦", UDim2.new(1, 0, 1, -2), THEME.text, FONT_BOLD, 20,
    Enum.TextXAlignment.Center)
BubbleIcon.TextYAlignment = Enum.TextYAlignment.Center
BubbleIcon.ZIndex = 21

local bubbleDragEnded = makeDraggable(Bubble, Bubble)

--────────────────────────────────────────────── panel shell
local panelW, panelH = 312, 452

local Panel = Instance.new("Frame")
Panel.BackgroundColor3 = THEME.bgTop
Panel.Visible = false
Panel.ZIndex = 5
Panel.Parent = SG
corner(Panel, 14)
stroke(Panel, 1, THEME.stroke, 0.35)
gradient(Panel, THEME.bgTop, THEME.bgBottom, 90)

Bubble.MouseButton1Click:Connect(function()
    if bubbleDragEnded() then return end
    Panel.Visible = not Panel.Visible
    if Panel.Visible then
        local vp = screenSize()
        local w, h = sizePx(Panel)
        local x, y = clampTo(Panel.Position.X.Offset, Panel.Position.Y.Offset, w, h)
        Panel.Position = UDim2.new(0, x, 0, y)
    end
end)

--────────────────────────────────────────────── header
local Header = Instance.new("Frame")
Header.BackgroundTransparency = 1
Header.ZIndex = 6
Header.Parent = Panel

local HeaderAccent = Instance.new("Frame")
HeaderAccent.Size = UDim2.new(0, 3, 0, 20)
HeaderAccent.Position = UDim2.new(0, 14, 0, 14)
HeaderAccent.BackgroundColor3 = THEME.violet
HeaderAccent.BorderSizePixel = 0
HeaderAccent.ZIndex = 7
HeaderAccent.Parent = Header
corner(HeaderAccent, 2)
gradient(HeaderAccent, THEME.violet, THEME.cyan, 90)

local TitleLbl = label(Header, "AI Helper", UDim2.new(0, 150, 0, 16), THEME.text, FONT_BOLD, 14)
TitleLbl.Position = UDim2.new(0, 24, 0, 10)
TitleLbl.ZIndex = 7

local SubLbl = label(Header, "roblox copilot", UDim2.new(0, 150, 0, 12), THEME.textFaint, FONT_MED, 9)
SubLbl.Position = UDim2.new(0, 25, 0, 25)
SubLbl.ZIndex = 7

local function headerButton(icon, xOffset, tint)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 28, 0, 28)
    b.Position = UDim2.new(1, xOffset, 0, 9)
    b.BackgroundColor3 = THEME.card
    b.Text = icon
    b.Font = FONT_BOLD
    b.TextColor3 = tint or THEME.textDim
    b.TextSize = 12
    b.ZIndex = 7
    b.Parent = Header
    corner(b, 9)
    stroke(b, 1, THEME.strokeSoft, 0.2)
    addButtonFeel(b, THEME.card, THEME.cardAlt, THEME.strokeSoft)
    return b
end

local SettingsBtn = headerButton("⚙", -70, THEME.textDim)
local CloseBtn    = headerButton("✕", -36, THEME.coral)
CloseBtn.MouseButton1Click:Connect(function() Panel.Visible = false end)

--────────────────────────────────────────────── status strip
local StatusRow = Instance.new("Frame")
StatusRow.BackgroundColor3 = THEME.card
StatusRow.ZIndex = 6
StatusRow.Parent = Panel
corner(StatusRow, 8)
stroke(StatusRow, 1, THEME.strokeSoft, 0.55)

local StatusDot = Instance.new("Frame")
StatusDot.Size = UDim2.new(0, 6, 0, 6)
StatusDot.Position = UDim2.new(0, 9, 0.5, -3)
StatusDot.BackgroundColor3 = THEME.amber
StatusDot.BorderSizePixel = 0
StatusDot.ZIndex = 7
StatusDot.Parent = StatusRow
corner(StatusDot, 3)

local StatusLbl = label(StatusRow, "starting…", UDim2.new(1, -34, 1, 0), THEME.textDim, FONT_MED, 10)
StatusLbl.Position = UDim2.new(0, 21, 0, 0)
StatusLbl.TextTruncate = Enum.TextTruncate.AtEnd
StatusLbl.ZIndex = 7

local HttpLbl = label(StatusRow, "", UDim2.new(0, 0, 1, 0), THEME.textFaint, FONT_MONO, 8,
    Enum.TextXAlignment.Right)
HttpLbl.Position = UDim2.new(1, -96, 0, 0)
HttpLbl.Size = UDim2.new(0, 90, 1, 0)
HttpLbl.TextTruncate = Enum.TextTruncate.AtEnd
HttpLbl.ZIndex = 7
HttpLbl.Text = HTTP_SOURCE and ("via " .. HTTP_SOURCE) or "no http"

local function setStatus(text, color, dotColor)
    StatusLbl.Text = text
    StatusLbl.TextColor3 = color or THEME.textDim
    if dotColor then StatusDot.BackgroundColor3 = dotColor end
end

--────────────────────────────────────────────── model chips
local ChipsRow = Instance.new("Frame")
ChipsRow.BackgroundTransparency = 1
ChipsRow.ZIndex = 6
ChipsRow.Parent = Panel

local function makeChip(order, accent)
    local chip = Instance.new("TextButton")
    chip.BackgroundColor3 = THEME.card
    chip.Text = ""
    chip.LayoutOrder = order
    chip.ZIndex = 6
    chip.Parent = ChipsRow
    corner(chip, 8)
    stroke(chip, 1, THEME.strokeSoft, 0.4)

    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 5, 0, 5)
    dot.Position = UDim2.new(0, 8, 0.5, -2.5)
    dot.BackgroundColor3 = accent
    dot.BorderSizePixel = 0
    dot.ZIndex = 7
    dot.Parent = chip
    corner(dot, 3)

    local name = label(chip, "", UDim2.new(1, -20, 0, 10), THEME.textFaint, FONT_MED, 8)
    name.Position = UDim2.new(0, 17, 0, 5)
    name.ZIndex = 7

    local value = label(chip, "", UDim2.new(1, -20, 0, 12), THEME.text, FONT_MONO, 9)
    value.Position = UDim2.new(0, 17, 0, 16)
    value.TextTruncate = Enum.TextTruncate.AtEnd
    value.ZIndex = 7

    addButtonFeel(chip, THEME.card, THEME.cardAlt, THEME.strokeSoft)
    return chip, name, value
end

local GemChip, GemName, GemValue = makeChip(1, THEME.cyan)
GemName.Text = "gemini"
GemValue.Text = "pick a model"

local OrChip, OrName, OrValue = makeChip(2, THEME.amber)
OrName.Text = "openrouter"
OrValue.Text = "loading…"

local ChipsLayout = Instance.new("UIListLayout")
ChipsLayout.FillDirection = Enum.FillDirection.Horizontal
ChipsLayout.SortOrder = Enum.SortOrder.LayoutOrder
ChipsLayout.Padding = UDim.new(0, 6)
ChipsLayout.Parent = ChipsRow

--────────────────────────────────────────────── log
local LogScroll = Instance.new("ScrollingFrame")
LogScroll.BackgroundColor3 = THEME.well
LogScroll.BorderSizePixel = 0
LogScroll.ScrollBarThickness = 3
LogScroll.ScrollBarImageColor3 = THEME.stroke
LogScroll.ScrollBarImageTransparency = 0.35
LogScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
LogScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
LogScroll.ZIndex = 6
LogScroll.Parent = Panel
corner(LogScroll, 10)
stroke(LogScroll, 1, THEME.strokeSoft, 0.6)
pad(LogScroll, 8, 8, 8, 8)

local LogList = Instance.new("UIListLayout")
LogList.SortOrder = Enum.SortOrder.LayoutOrder
LogList.Padding = UDim.new(0, 4)
LogList.Parent = LogScroll

local logLines, MAX_LINES = 0, 220

local function Log(text, color)
    local str = tostring(text)
    if #str > 900 then str = str:sub(1, 900) .. " …" end
    logLines = logLines + 1
    local l = Instance.new("TextLabel")
    l.Text = str
    l.Size = UDim2.new(1, 0, 0, 0)
    l.AutomaticSize = Enum.AutomaticSize.Y
    l.BackgroundTransparency = 1
    l.TextColor3 = color or THEME.text
    l.Font = FONT_MONO
    l.TextSize = 10
    l.TextWrapped = true
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.LineHeight = 1.1
    l.LayoutOrder = logLines
    l.ZIndex = 7
    l.Parent = LogScroll
    task.defer(function()
        if LogScroll then LogScroll.CanvasPosition = Vector2.new(0, 1e6) end
    end)
    if logLines % 20 == 0 then
        local kids = {}
        for _, c in ipairs(LogScroll:GetChildren()) do
            if c:IsA("TextLabel") then kids[#kids + 1] = c end
        end
        if #kids > MAX_LINES then
            table.sort(kids, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
            for i = 1, #kids - MAX_LINES do kids[i]:Destroy() end
        end
    end
end

--────────────────────────────────────────────── action row
local ActionRow = Instance.new("Frame")
ActionRow.BackgroundTransparency = 1
ActionRow.ZIndex = 6
ActionRow.Parent = Panel

local ActionLayout = Instance.new("UIListLayout")
ActionLayout.FillDirection = Enum.FillDirection.Horizontal
ActionLayout.SortOrder = Enum.SortOrder.LayoutOrder
ActionLayout.Padding = UDim.new(0, 6)
ActionLayout.Parent = ActionRow

local function actionButton(text, tint, order)
    local b = Instance.new("TextButton")
    b.BackgroundColor3 = THEME.card
    b.Text = text
    b.Font = FONT_MED
    b.TextColor3 = tint or THEME.text
    b.TextSize = 10
    b.LayoutOrder = order
    b.ZIndex = 6
    b.Parent = ActionRow
    corner(b, 8)
    stroke(b, 1, THEME.strokeSoft, 0.35)
    addButtonFeel(b, THEME.card, THEME.cardAlt, THEME.strokeSoft)
    return b
end

local RunBtn   = actionButton("▶  Run", THEME.mint, 1)
local ScanBtn  = actionButton("◎  Scan", THEME.violet, 2)
local ClearBtn = actionButton("✕  Clear", THEME.textDim, 3)
RunBtn.Visible = false

--────────────────────────────────────────────── input
local InputWell = Instance.new("ScrollingFrame")
InputWell.BackgroundColor3 = THEME.well
InputWell.BorderSizePixel = 0
InputWell.ScrollBarThickness = 2
InputWell.ScrollBarImageColor3 = THEME.stroke
InputWell.AutomaticCanvasSize = Enum.AutomaticSize.Y
InputWell.CanvasSize = UDim2.new(0, 0, 0, 0)
InputWell.ZIndex = 6
InputWell.Parent = Panel
corner(InputWell, 10)
stroke(InputWell, 1, THEME.strokeSoft, 0.35)

local InputBox = Instance.new("TextBox")
InputBox.Size = UDim2.new(1, 0, 0, 0)
InputBox.AutomaticSize = Enum.AutomaticSize.Y
InputBox.BackgroundTransparency = 1
InputBox.PlaceholderText = "what do you want to build?"
InputBox.PlaceholderColor3 = THEME.textFaint
InputBox.Text = ""
InputBox.TextColor3 = THEME.text
InputBox.Font = FONT
InputBox.TextSize = 12
InputBox.MultiLine = true
InputBox.TextWrapped = true
InputBox.ClearTextOnFocus = false
InputBox.TextXAlignment = Enum.TextXAlignment.Left
InputBox.TextYAlignment = Enum.TextYAlignment.Top
InputBox.ZIndex = 7
InputBox.Parent = InputWell
pad(InputBox, 9, 9, 8, 8)

--────────────────────────────────────────────── ask
local AskBtn = Instance.new("TextButton")
AskBtn.BackgroundColor3 = THEME.violetDeep
AskBtn.Text = "Ask  ✦"
AskBtn.Font = FONT_BOLD
AskBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AskBtn.TextSize = 14
AskBtn.AutoButtonColor = false
AskBtn.ZIndex = 6
AskBtn.Parent = Panel
corner(AskBtn, 10)
stroke(AskBtn, 1, THEME.violet, 0.25)
local AskGradient = gradient(AskBtn, THEME.violet, THEME.pink, 15)
TweenService:Create(AskBtn, TweenInfo.new(0.15), {}):Play()

--────────────────────────────────────────────── layout
local METRICS = {
    padX = 12,
    header = 46,
    status = 24,
    chips = 36,
    actions = 30,
    input = 62,
    ask = 38,
    gap = 6,
    bottom = 12,
}

local function ApplyLayout()
    local p, inner = METRICS.padX, nil
    local vp = screenSize()

    -- keep a 8px margin so the panel can always be dragged and never clips
    local maxW = math.max(240, vp.X - 16)
    local maxH = math.max(280, vp.Y - 16)
    panelW = math.min(math.clamp(math.floor(vp.X * 0.90), 296, 356), maxW)
    panelH = math.min(math.clamp(math.floor(vp.Y * 0.74), 372, 520), maxH)
    Panel.Size = UDim2.new(0, panelW, 0, panelH)
    inner = panelW - p * 2

    Header.Size = UDim2.new(1, 0, 0, METRICS.header)
    StatusRow.Position = UDim2.new(0, p, 0, METRICS.header)
    StatusRow.Size = UDim2.new(0, inner, 0, METRICS.status)

    ChipsRow.Position = UDim2.new(0, p, 0, METRICS.header + METRICS.status + METRICS.gap)
    ChipsRow.Size = UDim2.new(0, inner, 0, METRICS.chips)
    local chipW = math.floor((inner - 6) / 2)
    GemChip.Size = UDim2.new(0, chipW, 1, 0)
    OrChip.Size  = UDim2.new(0, chipW, 1, 0)

    local below = METRICS.header + METRICS.status + METRICS.gap * 2 + METRICS.chips
    -- shrink the input/ask blocks a little on short screens
    local short = panelH < 400
    local actionsH = short and 26 or METRICS.actions
    local inputH   = short and 46 or METRICS.input
    local askH     = short and 32 or METRICS.ask

    local bottomBlock = actionsH + METRICS.gap + inputH + METRICS.gap
        + askH + METRICS.bottom
    local logH = math.max(56, panelH - below - bottomBlock)

    LogScroll.Position = UDim2.new(0, p, 0, below)
    LogScroll.Size = UDim2.new(0, inner, 0, logH)

    local y = below + logH + METRICS.gap
    ActionRow.Position = UDim2.new(0, p, 0, y)
    ActionRow.Size = UDim2.new(0, inner, 0, actionsH)
    local btnW = math.floor((inner - 12) / 3)
    RunBtn.Size   = UDim2.new(0, btnW, 1, 0)
    ScanBtn.Size  = UDim2.new(0, btnW, 1, 0)
    ClearBtn.Size = UDim2.new(0, btnW, 1, 0)

    y = y + actionsH + METRICS.gap
    InputWell.Position = UDim2.new(0, p, 0, y)
    InputWell.Size = UDim2.new(0, inner, 0, inputH)

    y = y + inputH + METRICS.gap
    AskBtn.Position = UDim2.new(0, p, 0, y)
    AskBtn.Size = UDim2.new(0, inner, 0, askH)
end

local function layoutPanel(recenter)
    local vp = screenSize()
    ApplyLayout()
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
end

layoutPanel(true)

pcall(function()
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        layoutPanel(false)
    end)
end)

--══════════════════════════════════════════════════════════════════════════════
-- 13.  SHEETS (settings + model picker share this)
--══════════════════════════════════════════════════════════════════════════════
local function makeSheet()
    local sheet = Instance.new("Frame")
    sheet.Size = UDim2.new(1, 0, 1, 0)
    sheet.BackgroundColor3 = THEME.bgTop
    sheet.BorderSizePixel = 0
    sheet.Visible = false
    sheet.ZIndex = 40
    sheet.Parent = Panel
    corner(sheet, 14)
    gradient(sheet, THEME.bgTop, THEME.bgBottom, 90)

    local head = Instance.new("Frame")
    head.Size = UDim2.new(1, -24, 0, 26)
    head.Position = UDim2.new(0, 12, 0, 10)
    head.BackgroundTransparency = 1
    head.ZIndex = 41
    head.Parent = sheet

    local title = label(head, "", UDim2.new(1, -40, 1, 0), THEME.text, FONT_BOLD, 12)
    title.ZIndex = 42

    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 26, 0, 26)
    close.Position = UDim2.new(1, -26, 0, 0)
    close.BackgroundColor3 = THEME.card
    close.Text = "✕"
    close.Font = FONT_BOLD
    close.TextColor3 = THEME.coral
    close.TextSize = 11
    close.ZIndex = 42
    close.Parent = head
    corner(close, 8)
    stroke(close, 1, THEME.strokeSoft, 0.3)
    addButtonFeel(close, THEME.card, THEME.cardAlt, THEME.strokeSoft)
    close.MouseButton1Click:Connect(function() sheet.Visible = false end)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -20, 1, -52)
    scroll.Position = UDim2.new(0, 10, 0, 44)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 3
    scroll.ScrollBarImageColor3 = THEME.stroke
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.ZIndex = 41
    scroll.Parent = sheet
    pad(scroll, 2, 2, 0, 8)

    local list = Instance.new("UIListLayout")
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 6)
    list.Parent = scroll

    return sheet, scroll, title
end

--────────────────────────────────────────────── settings sheet
local SettingsSheet, SettingsScroll, SettingsTitle = makeSheet()
SettingsTitle.Text = "Settings"
SettingsBtn.MouseButton1Click:Connect(function()
    SettingsSheet.Visible = not SettingsSheet.Visible
end)

local settingsOrder = 0
local function sOrder() settingsOrder = settingsOrder + 1 return settingsOrder end
local settingsBoxes = {}

local function settingsKeyRow(keyName, titleText, placeholder)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 44)
    row.BackgroundColor3 = THEME.card
    row.LayoutOrder = sOrder()
    row.ZIndex = 41
    row.Parent = SettingsScroll
    corner(row, 10)
    stroke(row, 1, THEME.strokeSoft, 0.5)
    pad(row, 10, 10, 7, 8)

    local l = label(row, titleText, UDim2.new(1, 0, 0, 12), THEME.textDim, FONT_MED, 9)
    l.ZIndex = 42

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, 0, 0, 20)
    box.Position = UDim2.new(0, 0, 0, 15)
    box.BackgroundColor3 = THEME.well
    box.Text = KEYS[keyName] or ""
    box.PlaceholderText = placeholder or ""
    box.PlaceholderColor3 = THEME.textFaint
    box.TextColor3 = THEME.text
    box.Font = FONT_MONO
    box.TextSize = 9
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.ClearTextOnFocus = false
    box.ZIndex = 42
    box.Parent = row
    corner(box, 6)
    stroke(box, 1, THEME.strokeSoft, 0.4)
    pad(box, 6, 6, 0, 0)

    settingsBoxes[#settingsBoxes + 1] = { box = box, key = keyName }
end

settingsKeyRow("gemini", "Gemini key · aistudio.google.com/apikey", "AQ.… or AIza…")
settingsKeyRow("openrouter", "OpenRouter key · openrouter.ai/keys", "sk-or-v1-…")
settingsKeyRow("tokenharbor", "TokenHarbor key (optional)", "thk_live_…")

local hint = label(SettingsScroll,
    "Free tiers: Gemini free key, OpenRouter free models.\nKeys stay on this device.",
    UDim2.new(1, 0, 0, 30), THEME.textFaint, FONT, 8)
hint.TextWrapped = true
hint.TextYAlignment = Enum.TextYAlignment.Top
hint.LayoutOrder = sOrder()
hint.ZIndex = 41

local SaveBtn = Instance.new("TextButton")
SaveBtn.Size = UDim2.new(1, 0, 0, 32)
SaveBtn.BackgroundColor3 = THEME.violetDeep
SaveBtn.Text = "Save & connect"
SaveBtn.Font = FONT_BOLD
SaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SaveBtn.TextSize = 11
SaveBtn.AutoButtonColor = false
SaveBtn.LayoutOrder = sOrder()
SaveBtn.ZIndex = 41
SaveBtn.Parent = SettingsScroll
corner(SaveBtn, 10)
gradient(SaveBtn, THEME.violetDeep, THEME.violet, 15)

local RefreshBtn = Instance.new("TextButton")
RefreshBtn.Size = UDim2.new(1, 0, 0, 28)
RefreshBtn.BackgroundColor3 = THEME.card
RefreshBtn.Text = "Refresh model lists"
RefreshBtn.Font = FONT_MED
RefreshBtn.TextColor3 = THEME.textDim
RefreshBtn.TextSize = 10
RefreshBtn.LayoutOrder = sOrder()
RefreshBtn.ZIndex = 41
RefreshBtn.Parent = SettingsScroll
corner(RefreshBtn, 10)
stroke(RefreshBtn, 1, THEME.strokeSoft, 0.4)
addButtonFeel(RefreshBtn, THEME.card, THEME.cardAlt, THEME.strokeSoft)

--────────────────────────────────────────────── model picker sheet
local PickerSheet, PickerScroll, PickerTitle = makeSheet()
local pickerProvider = "openrouter"

local function pickerRows()
    for _, c in ipairs(PickerScroll:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
    end

    local cat = Catalog[pickerProvider]
    local accent = (pickerProvider == "gemini") and THEME.cyan or THEME.amber

    local statusRow = label(PickerScroll, "", UDim2.new(1, 0, 0, 16), THEME.textFaint, FONT_MONO, 8)
    statusRow.LayoutOrder = 1
    statusRow.ZIndex = 42

    if cat.state == "loading" then
        statusRow.Text = "fetching the live model list…"
        statusRow.TextColor3 = THEME.amber
    elseif cat.state == "error" then
        statusRow.Text = "couldn't load: " .. tostring(cat.error)
        statusRow.TextColor3 = THEME.coral
    elseif #cat.list == 0 then
        statusRow.Text = "no models — add a key or refresh"
        statusRow.TextColor3 = THEME.textFaint
    else
        statusRow.Text = string.format("%d models available · tap to pick", #cat.list)
        statusRow.TextColor3 = THEME.mint
    end

    if cat.state == "error" then
        local retry = Instance.new("TextButton")
        retry.Size = UDim2.new(1, 0, 0, 30)
        retry.BackgroundColor3 = THEME.card
        retry.Text = "↻  Try fetching again"
        retry.Font = FONT_MED
        retry.TextColor3 = THEME.amber
        retry.TextSize = 10
        retry.LayoutOrder = 2
        retry.ZIndex = 41
        retry.Parent = PickerScroll
        corner(retry, 9)
        stroke(retry, 1, THEME.amber, 0.6)
        addButtonFeel(retry, THEME.card, THEME.cardAlt, THEME.strokeSoft)
        retry.MouseButton1Click:Connect(function()
            if pickerProvider == "gemini" then
                task.spawn(function() pcall(FetchGeminiModels, true) end)
            else
                task.spawn(function() pcall(FetchOpenRouterModels, true) end)
            end
            task.defer(pickerRows)
        end)
    end

    for i, m in ipairs(cat.list) do
        local selected = (cat.selected == m.id)
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, 0, 0, 38)
        row.BackgroundColor3 = selected and THEME.cardAlt or THEME.card
        row.Text = ""
        row.LayoutOrder = i + 1
        row.ZIndex = 41
        row.Parent = PickerScroll
        corner(row, 10)
        stroke(row, 1, selected and accent or THEME.strokeSoft, selected and 0.2 or 0.6)

        local name = label(row, m.label or m.id, UDim2.new(1, -18, 0, 14), THEME.text, FONT_MED, 10)
        name.Position = UDim2.new(0, 10, 0, 5)
        name.TextTruncate = Enum.TextTruncate.AtEnd
        name.ZIndex = 42

        local sub = label(row, m.id, UDim2.new(1, -18, 0, 12), THEME.textFaint, FONT_MONO, 8)
        sub.Position = UDim2.new(0, 10, 0, 20)
        sub.TextTruncate = Enum.TextTruncate.AtEnd
        sub.ZIndex = 42

        local tick = label(row, selected and "✓" or "", UDim2.new(0, 14, 1, 0), accent, FONT_BOLD, 12,
            Enum.TextXAlignment.Right)
        tick.Position = UDim2.new(1, -22, 0, 0)
        tick.ZIndex = 42

        addButtonFeel(row, row.BackgroundColor3, THEME.cardAlt, THEME.strokeSoft)

        row.MouseButton1Click:Connect(function()
            Catalog[pickerProvider].selected = m.id
            Prefs.models[pickerProvider] = m.id
            savePrefs()
            if pickerProvider == "gemini" then
                GemValue.Text = m.id
                GemValue.TextColor3 = THEME.text
            else
                OrValue.Text = m.id
                OrValue.TextColor3 = THEME.text
            end
            PickerSheet.Visible = false
            Log("model set · " .. pickerProvider .. " → " .. m.id, THEME.textDim)
        end)
    end
end

local function openPicker(provider)
    pickerProvider = provider
    PickerTitle.Text = (provider == "gemini") and "Gemini models" or "OpenRouter free models"
    pickerRows()
    PickerSheet.Visible = true
    if Catalog[provider].state == "idle" or Catalog[provider].state == "error" then
        task.spawn(function()
            if provider == "gemini" then
                pcall(FetchGeminiModels, true)
            else
                pcall(FetchOpenRouterModels, true)
            end
        end)
    end
end

GemChip.MouseButton1Click:Connect(function() openPicker("gemini") end)
OrChip.MouseButton1Click:Connect(function() openPicker("openrouter") end)

-- keep the chips in sync with whatever the catalog does
OnCatalogChanged = function(provider)
    local cat = Catalog[provider]
    local valueLbl = (provider == "gemini") and GemValue or OrValue
    local scope = tostring(provider)

    if cat.state == "loading" then
        valueLbl.Text = "loading…"
        valueLbl.TextColor3 = THEME.amber
    elseif cat.state == "error" then
        valueLbl.Text = cat.selected or "tap to pick"
        valueLbl.TextColor3 = cat.selected and THEME.text or THEME.coral
    elseif cat.state == "ready" then
        local shown = cat.selected
        if not shown then
            shown = (cat.list[1] and cat.list[1].id) or "tap to pick"
        end
        valueLbl.Text = shown
        valueLbl.TextColor3 = THEME.text
    end
    local _ = scope

    if PickerSheet.Visible then
        task.defer(function()
            if PickerSheet.Visible and pickerProvider == provider then pickerRows() end
        end)
    end
end

--══════════════════════════════════════════════════════════════════════════════
-- 14.  STATE + ACTIONS
--══════════════════════════════════════════════════════════════════════════════
local Connected   = false
local Busy        = false
local LastCode    = nil
local LastGameCtx = nil

local function setBusy(on)
    Busy = on
    if on then
        AskBtn.Text = "thinking…"
        AskGradient.Color = ColorSequence.new(THEME.stroke, THEME.card)
        AskBtn.TextColor3 = THEME.textDim
    else
        AskBtn.Text = "Ask  ✦"
        AskGradient.Color = ColorSequence.new(THEME.violet, THEME.pink)
        AskBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    end
end

local function DoScan()
    local ok, res = pcall(ScanGame)
    if ok then
        LastGameCtx = res
        Log("game scanned · PlaceID " .. tostring(game.PlaceId), THEME.violet)
    else
        Log("scan failed: " .. tostring(res):sub(1, 80), THEME.coral)
    end
end

ScanBtn.MouseButton1Click:Connect(function()
    task.spawn(DoScan)
end)

ClearBtn.MouseButton1Click:Connect(function()
    ChatHistory = {}
    for _, c in ipairs(LogScroll:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    logLines = 0
    LastCode = nil
    RunBtn.Visible = false
    Log("cleared.", THEME.textFaint)
end)

local function RunLastCode()
    if not LastCode then
        Log("nothing to run yet.", THEME.amber)
        return
    end
    Log("running the generated script…", THEME.cyan)
    local ok, err = ExecScript(LastCode, function(runtimeErr)
        Log("runtime error: " .. tostring(runtimeErr):sub(1, 200), THEME.coral)
        setStatus("runtime error", THEME.coral, THEME.coral)
    end)
    if ok then
        Log("done — script is running.", THEME.mint)
        setStatus("executed", THEME.mint, THEME.mint)
    else
        Log(tostring(err), THEME.coral)
        setStatus("couldn't run it", THEME.coral, THEME.coral)
    end
end

RunBtn.MouseButton1Click:Connect(RunLastCode)

local function summarizeFailures(failures)
    local parts = {}
    for _, f in ipairs(failures or {}) do
        local msg = tostring(f.err or "failed"):gsub("%s+", " ")
        if #msg > 70 then msg = msg:sub(1, 70) .. "…" end
        parts[#parts + 1] = f.name .. ": " .. msg
    end
    return table.concat(parts, "  |  ")
end

local Submit
Submit = function()
    if Busy then return end
    local msg = (InputBox.Text or ""):match("^%s*(.-)%s*$")
    if msg == "" then return end
    if not RawRequest then
        Log("this executor has no http function — re-inject Delta.", THEME.coral)
        setStatus("no http function", THEME.coral, THEME.coral)
        return
    end

    setBusy(true)
    InputBox.Text = ""
    setStatus("thinking…", THEME.amber, THEME.amber)
    Log("you · " .. msg:sub(1, 220) .. (#msg > 220 and "…" or ""), THEME.cyan)

    task.spawn(function()
        local ok, reply, prov, failures = pcall(AskAI, msg, LastGameCtx, Log)
        if not ok then
            Log("internal error: " .. tostring(reply):sub(1, 200), THEME.coral)
            setStatus("internal error", THEME.coral, THEME.coral)
            setBusy(false)
            return
        end

        if not reply then
            Log(summarizeFailures(failures), THEME.coral)
            setStatus("no provider answered", THEME.coral, THEME.coral)
            Log("tip · open ⚙ to fix keys, or tap a model row to pick another one.", THEME.textFaint)
            setBusy(false)
            return
        end

        Connected = true
        local catName = prov == "gemini" and "gemini"
            or (prov == "openrouter" and "openrouter" or tostring(prov))
        setStatus("online · " .. catName, THEME.mint, THEME.mint)

        for line in (reply .. "\n"):gmatch("(.-)\n") do
            Log(line, THEME.text)
        end

        local code = ExtractCode(reply)
        if code then
            LastCode = code
            RunBtn.Visible = true
            Log("script ready · tap Run", THEME.mint)
            local lower = msg:lower()
            if lower:find("run it", 1, true) or lower:find("auto run", 1, true)
                or lower:find("execute it", 1, true) or lower:find("run now", 1, true) then
                task.wait(0.3)
                RunLastCode()
            end
        end
        setBusy(false)
    end)
end

AskBtn.MouseButton1Click:Connect(Submit)

--══════════════════════════════════════════════════════════════════════════════
-- 15.  CONNECT / BOOT
--══════════════════════════════════════════════════════════════════════════════
local function hasAnyKey()
    return KEYS.gemini ~= "" or KEYS.openrouter ~= "" or KEYS.tokenharbor ~= ""
end

local function Connect(silent)
    if Busy then return end

    if not RawRequest then
        setStatus("no http function", THEME.coral, THEME.coral)
        Log("no http function in this executor.", THEME.coral)
        Log("looked for request, http_request, getgenv().request, syn.request.", THEME.textFaint)
        Notify("AI Helper", "No HTTP function — re-inject Delta.", 8)
        return
    end

    if not hasAnyKey() then
        setStatus("add an api key", THEME.amber, THEME.amber)
        Log("no API key yet.", THEME.amber)
        Log("gemini · aistudio.google.com/apikey", THEME.cyan)
        Log("openrouter · openrouter.ai/keys", THEME.amber)
        Log("paste one in ⚙ then Save & connect.", THEME.textFaint)
        SettingsSheet.Visible = true
        return
    end

    setBusy(true)
    setStatus("connecting…", THEME.amber, THEME.amber)
    if not silent then Log("connecting…", THEME.textDim) end

    task.spawn(function()
        local ok, reply, prov, failures = pcall(AskAI, "Say exactly: CONNECTED", nil, function() end, true)
        if ok and reply then
            Connected = true
            setStatus("online · " .. tostring(prov), THEME.mint, THEME.mint)
            Log("connected via " .. tostring(prov), THEME.mint)
        else
            Connected = false
            setStatus("offline", THEME.coral, THEME.coral)
            Log(summarizeFailures(ok and failures or { { name = "error", err = tostring(reply) } }),
                THEME.coral)
            Log("tip · check your key in ⚙, or pick another model.", THEME.textFaint)
        end
        setBusy(false)
    end)
end

SaveBtn.MouseButton1Click:Connect(function()
    for _, item in ipairs(settingsBoxes) do
        KEYS[item.key] = (item.box.Text or ""):gsub("%s+", "")
    end
    Prefs.keys = KEYS
    savePrefs()
    SettingsSheet.Visible = false
    Log("keys saved · reconnecting", THEME.mint)
    task.spawn(function()
        pcall(FetchGeminiModels, true)
        pcall(FetchOpenRouterModels, true)
        Connect(true)
    end)
end)

RefreshBtn.MouseButton1Click:Connect(function()
    Log("refreshing model lists…", THEME.textDim)
    FetchAllModels(true)
end)

--══════════════════════════════════════════════════════════════════════════════
-- 16.  GO
--══════════════════════════════════════════════════════════════════════════════
Log("hi · I'm your roblox copilot.", THEME.text)
Log("ask for a script, or say 'run it' and I'll execute it.", THEME.textDim)
if not RawRequest then
    Log("warning · no http function, so I can't reach any provider.", THEME.coral)
elseif not hasAnyKey() then
    Log("add a key in ⚙ to get started.", THEME.amber)
end

Notify("AI Helper", "Loaded — tap ✦ to open.", 3)

FetchAllModels(false)
Connect(true)

end --════════════════════════════════ END SCOPE ════════════════════════════════════
