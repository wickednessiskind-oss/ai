-- Lua | Single-file script | Delta Executor (Mobile Roblox)
-- Providers: tokenharbor → gemini → openrouter (free fallback chain)
-- Runtime: Roblox executor Lua 5.1

local HttpService       = game:GetService("HttpService")
local UserInputService  = game:GetService("UserInputService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

repeat task.wait() until game:IsLoaded()

-- ─────────────────────────────────────────────
-- KEYS + CONFIG  (Sam-held values)
-- ─────────────────────────────────────────────
local TOKENHARBOR_KEY  = "thk_live_hWc5ISofXgwrBrZDl0_MOllhwXvOauZMz0kS3bGtKvVRhchtpis2zh0JKibAi2oY"
local TOKENHARBOR_MODEL= "deepseek/deepseek-v4.1-flash:free"
local TOKENHARBOR_URL  = "https://api.tokenharbor.ai/v1/chat/completions"

local GEMINI_KEY       = "AQ.Ab8RN6ID2jm4agl6Q0SgUFK-4AT7pKN1ZqhWJlbdIpGcjG-nbw"
local GEMINI_URL_BASE  = "https://generativelanguage.googleapis.com/v1beta/models/"

local OPENROUTER_KEY   = "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"
local OPENROUTER_URL   = "https://openrouter.ai/api/v1/chat/completions"
local OPENROUTER_MODEL = "deepseek/deepseek-r1:free"  -- good free default

-- free gemini models the picker will show
local GEMINI_MODELS = {
    { label="gemini-2.0-flash (fast)",    id="gemini-2.0-flash"              },
    { label="gemini-2.0-flash-lite",      id="gemini-2.0-flash-lite"         },
    { label="gemini-1.5-flash",           id="gemini-1.5-flash"              },
    { label="gemini-1.5-flash-8b",        id="gemini-1.5-flash-8b"           },
    { label="gemini-2.5-flash-preview",   id="gemini-2.5-flash-preview-04-17"},
}
local selectedGeminiIdx = 1  -- default: gemini-2.0-flash

local MAX_CTX = 8

-- ─────────────────────────────────────────────
-- HTTP RESOLVER
-- ─────────────────────────────────────────────
local HttpRequest =
    (typeof(request)      == "function" and request)      or
    (typeof(http_request) == "function" and http_request) or
    (syn  and typeof(syn.request)  == "function" and syn.request)  or
    (http and typeof(http.request) == "function" and http.request) or
    nil

if not HttpRequest then
    game:GetService("StarterGui"):SetCore("SendNotification",{
        Title="DS Helper", Text="http_request not found — re-inject Delta.", Duration=8
    })
    return
end

-- ─────────────────────────────────────────────
-- GAME SCANNER
-- ─────────────────────────────────────────────
local function ScanGame()
    local LP   = Players.LocalPlayer
    local char = LP.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local pos  = root and root.Position or Vector3.new(0,0,0)

    local npcs = {}
    for _,obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj ~= char then
            local h = obj:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then
                npcs[#npcs+1] = {Name=obj.Name,HP=math.floor(h.Health),MaxHP=math.floor(h.MaxHealth)}
                if #npcs >= 25 then break end
            end
        end
    end

    local remotes = {}
    for _,obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
            remotes[#remotes+1] = obj.ClassName..": "..obj:GetFullName()
            if #remotes >= 40 then break end
        end
    end

    local tools = {}
    for _,t in ipairs(LP.Backpack:GetChildren()) do
        if t:IsA("Tool") then tools[#tools+1] = t.Name end
    end
    if char then
        for _,t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") then tools[#tools+1] = t.Name.." [equipped]" end
        end
    end

    local wsObjs = {}
    for _,obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Folder") or obj:IsA("Model") then
            wsObjs[#wsObjs+1] = obj.ClassName..": "..obj.Name
            if #wsObjs >= 30 then break end
        end
    end

    local gameName = "Unknown"
    pcall(function()
        gameName = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
    end)

    return HttpService:JSONEncode({
        PlaceID=game.PlaceId, GameName=gameName,
        PlayerCount=#Players:GetPlayers(), PlayerName=LP.Name,
        Position=string.format("%.1f,%.1f,%.1f",pos.X,pos.Y,pos.Z),
        Tools=tools, NPCs=npcs, RemoteEvents=remotes, WorkspaceObjects=wsObjs
    })
end

-- ─────────────────────────────────────────────
-- PROVIDER LAYER
-- ─────────────────────────────────────────────
-- returns reply string or nil + errstring
-- provider: "tokenharbor" | "gemini" | "openrouter"

local activeProvider = "tokenharbor"

local function CallTokenharbor(messages)
    local body = HttpService:JSONEncode({
        model=TOKENHARBOR_MODEL, max_tokens=4096, messages=messages
    })
    local ok, res = pcall(HttpRequest,{
        Url=TOKENHARBOR_URL, Method="POST",
        Headers={["Content-Type"]="application/json",["Authorization"]="Bearer "..TOKENHARBOR_KEY},
        Body=body
    })
    if not ok then return nil,"th-request: "..tostring(res) end
    if res.StatusCode ~= 200 then
        return nil,"th-"..res.StatusCode..": "..tostring(res.Body):sub(1,200)
    end
    local _,d = pcall(HttpService.JSONDecode,HttpService,res.Body)
    local r = d.choices and d.choices[1] and d.choices[1].message and d.choices[1].message.content
    if not r or r=="" then return nil,"th-empty: "..tostring(res.Body):sub(1,150) end
    return r, nil
end

local function CallGemini(messages)
    -- convert OpenAI-style messages → Gemini contents
    local contents = {}
    local sysParts = {}
    for _,m in ipairs(messages) do
        if m.role == "system" then
            sysParts[#sysParts+1] = {text=m.content}
        elseif m.role == "user" then
            contents[#contents+1] = {role="user",  parts={{text=m.content}}}
        elseif m.role == "assistant" then
            contents[#contents+1] = {role="model", parts={{text=m.content}}}
        end
    end

    local payload = {
        contents = contents,
        generationConfig = {maxOutputTokens=4096, temperature=0.7}
    }
    if #sysParts > 0 then
        payload.systemInstruction = {parts=sysParts}
    end

    local modelId = GEMINI_MODELS[selectedGeminiIdx].id
    local url = GEMINI_URL_BASE..modelId..":generateContent?key="..GEMINI_KEY

    local body = HttpService:JSONEncode(payload)
    local ok, res = pcall(HttpRequest,{
        Url=url, Method="POST",
        Headers={["Content-Type"]="application/json"},
        Body=body
    })
    if not ok then return nil,"gem-request: "..tostring(res) end
    if res.StatusCode ~= 200 then
        return nil,"gem-"..res.StatusCode..": "..tostring(res.Body):sub(1,200)
    end
    local _,d = pcall(HttpService.JSONDecode,HttpService,res.Body)
    local r = d.candidates
        and d.candidates[1]
        and d.candidates[1].content
        and d.candidates[1].content.parts
        and d.candidates[1].content.parts[1]
        and d.candidates[1].content.parts[1].text
    if not r or r=="" then return nil,"gem-empty: "..tostring(res.Body):sub(1,150) end
    return r, nil
end

local function CallOpenRouter(messages)
    local body = HttpService:JSONEncode({
        model=OPENROUTER_MODEL, max_tokens=4096, messages=messages
    })
    local ok, res = pcall(HttpRequest,{
        Url=OPENROUTER_URL, Method="POST",
        Headers={
            ["Content-Type"]="application/json",
            ["Authorization"]="Bearer "..OPENROUTER_KEY,
            ["HTTP-Referer"]="https://roblox.com",
            ["X-Title"]="RobloxScriptHelper"
        },
        Body=body
    })
    if not ok then return nil,"or-request: "..tostring(res) end
    if res.StatusCode ~= 200 then
        return nil,"or-"..res.StatusCode..": "..tostring(res.Body):sub(1,200)
    end
    local _,d = pcall(HttpService.JSONDecode,HttpService,res.Body)
    local r = d.choices and d.choices[1] and d.choices[1].message and d.choices[1].message.content
    if not r or r=="" then return nil,"or-empty: "..tostring(res.Body):sub(1,150) end
    return r, nil
end

-- ─────────────────────────────────────────────
-- CHAT HISTORY + UNIFIED ASK
-- ─────────────────────────────────────────────
local ChatHistory = {}

local SYSTEM_PROMPT =
    "You are an expert Roblox Lua scripter inside a Roblox executor. "
    .."Write complete working Lua scripts, always wrapped in ```lua fences. "
    .."No placeholders, no TODOs, no stubs. Answer ANY question — scripting, "
    .."game logic, math, lore, anything. No refusals."

local function BuildMessages(userMsg, gameCtx)
    local messages = {}
    messages[#messages+1] = {role="system", content=SYSTEM_PROMPT}
    if gameCtx then
        messages[#messages+1] = {
            role="system",
            content="## Live Game Scan\n```json\n"..gameCtx.."\n```\nUse actual names from scan."
        }
    end
    for _,m in ipairs(ChatHistory) do messages[#messages+1] = m end
    messages[#messages+1] = {role="user", content=userMsg}
    return messages
end

-- returns reply, providerUsed, errstring
local function AskAI(userMsg, gameCtx, logFn)
    local messages = BuildMessages(userMsg, gameCtx)
    local reply, err

    -- 1. tokenharbor
    logFn("⏳ trying tokenharbor…", Color3.fromRGB(140,140,180))
    reply, err = CallTokenharbor(messages)
    if reply then
        activeProvider = "tokenharbor"
        goto done
    end
    logFn("⚠ tokenharbor: "..err, Color3.fromRGB(200,140,40))

    -- 2. gemini
    logFn("⏳ falling back → gemini ("..GEMINI_MODELS[selectedGeminiIdx].label..")…",
          Color3.fromRGB(140,200,140))
    reply, err = CallGemini(messages)
    if reply then
        activeProvider = "gemini"
        goto done
    end
    logFn("⚠ gemini: "..err, Color3.fromRGB(200,140,40))

    -- 3. openrouter free
    logFn("⏳ falling back → openrouter ("..OPENROUTER_MODEL..")…",
          Color3.fromRGB(140,180,220))
    reply, err = CallOpenRouter(messages)
    if reply then
        activeProvider = "openrouter"
        goto done
    end
    logFn("❌ openrouter: "..err, Color3.fromRGB(220,60,60))
    return nil, "all providers failed", err

    ::done::
    ChatHistory[#ChatHistory+1] = {role="user",      content=userMsg}
    ChatHistory[#ChatHistory+1] = {role="assistant", content=reply}
    while #ChatHistory > MAX_CTX*2 do table.remove(ChatHistory,1) end
    return reply, activeProvider, nil
end

-- ─────────────────────────────────────────────
-- CODE EXTRACT + EXEC
-- ─────────────────────────────────────────────
local function ExtractCode(text)
    return text:match("```lua%s*\n(.-)\n```")
        or text:match("```%s*\n(.-)\n```")
        or nil
end

local function ExecScript(code)
    local fn,e = loadstring(code)
    if not fn then return false,"Compile: "..tostring(e) end
    local ok,re = pcall(fn)
    if not ok then return false,"Runtime: "..tostring(re) end
    return true,nil
end

-- ─────────────────────────────────────────────
-- GUI
-- ─────────────────────────────────────────────
if game.CoreGui:FindFirstChild("DSHelper") then
    game.CoreGui.DSHelper:Destroy()
end

local SG = Instance.new("ScreenGui")
SG.Name="DSHelper"; SG.ResetOnSpawn=false; SG.IgnoreGuiInset=true
SG.Parent=game:GetService("CoreGui")

local function corner(o,r)
    local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,r or 8); c.Parent=o
end
local function stroke(o,t,col)
    local s=Instance.new("UIStroke")
    s.Thickness=t or 1; s.Color=col or Color3.fromRGB(50,50,80); s.Parent=o
end
local function MakeDraggable(frame)
    local drag,ds,sp
    frame.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1
        or i.UserInputType==Enum.UserInputType.Touch then
            drag=true; ds=i.Position; sp=frame.Position
            i.Changed:Connect(function()
                if i.UserInputState==Enum.UserInputState.End then drag=false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if drag and (i.UserInputType==Enum.UserInputType.MouseMovement
                  or i.UserInputType==Enum.UserInputType.Touch) then
            local d=i.Position-ds
            frame.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y)
        end
    end)
end

-- ── toggle bubble ──
local Bubble=Instance.new("TextButton")
Bubble.Size=UDim2.new(0,46,0,46); Bubble.Position=UDim2.new(0,8,0.45,-23)
Bubble.BackgroundColor3=Color3.fromRGB(14,14,24); Bubble.Text="🤖"
Bubble.TextSize=22; Bubble.Font=Enum.Font.GothamBold
Bubble.TextColor3=Color3.fromRGB(255,255,255); Bubble.ZIndex=10; Bubble.Parent=SG
corner(Bubble,23); stroke(Bubble,1.5,Color3.fromRGB(80,80,160))

-- ── panel 330 × 530 ──
local Panel=Instance.new("Frame")
Panel.Size=UDim2.new(0,330,0,530); Panel.Position=UDim2.new(0.5,-165,0.5,-265)
Panel.BackgroundColor3=Color3.fromRGB(10,10,18); Panel.Visible=false
Panel.ZIndex=5; Panel.Parent=SG
corner(Panel,12); stroke(Panel,1,Color3.fromRGB(40,40,70))
MakeDraggable(Panel)

Bubble.MouseButton1Click:Connect(function() Panel.Visible=not Panel.Visible end)

-- ── title bar ──
local TBar=Instance.new("Frame")
TBar.Size=UDim2.new(1,0,0,38); TBar.BackgroundColor3=Color3.fromRGB(14,14,26)
TBar.ZIndex=6; TBar.Parent=Panel; corner(TBar,12)

local TLbl=Instance.new("TextLabel")
TLbl.Text="🤖  AI Script Helper"; TLbl.Size=UDim2.new(0,210,1,0)
TLbl.Position=UDim2.new(0,10,0,0); TLbl.BackgroundTransparency=1
TLbl.TextColor3=Color3.fromRGB(110,160,255); TLbl.Font=Enum.Font.GothamBold
TLbl.TextSize=13; TLbl.TextXAlignment=Enum.TextXAlignment.Left; TLbl.ZIndex=7; TLbl.Parent=TBar

local XBtn=Instance.new("TextButton")
XBtn.Size=UDim2.new(0,26,0,26); XBtn.Position=UDim2.new(1,-32,0.5,-13)
XBtn.BackgroundColor3=Color3.fromRGB(180,40,40); XBtn.Text="✕"
XBtn.Font=Enum.Font.GothamBold; XBtn.TextColor3=Color3.fromRGB(255,255,255)
XBtn.TextSize=11; XBtn.ZIndex=7; XBtn.Parent=TBar; corner(XBtn,5)
XBtn.MouseButton1Click:Connect(function() Panel.Visible=false end)

-- ── provider badge ──
local ProvBadge=Instance.new("TextLabel")
ProvBadge.Size=UDim2.new(1,-16,0,18); ProvBadge.Position=UDim2.new(0,8,0,40)
ProvBadge.BackgroundColor3=Color3.fromRGB(20,20,35); ProvBadge.ZIndex=6; ProvBadge.Parent=Panel
ProvBadge.TextColor3=Color3.fromRGB(120,120,180); ProvBadge.Font=Enum.Font.Code
ProvBadge.TextSize=9; ProvBadge.TextXAlignment=Enum.TextXAlignment.Left
ProvBadge.Text="  provider: initialising…"
corner(ProvBadge,5)

local function SetProvBadge(name)
    local colors={
        tokenharbor=Color3.fromRGB(60,200,120),
        gemini=Color3.fromRGB(80,180,255),
        openrouter=Color3.fromRGB(200,140,60),
    }
    ProvBadge.TextColor3 = colors[name] or Color3.fromRGB(180,180,180)
    ProvBadge.Text = "  ✦ "..name
end

-- ── gemini model picker ──
local PickerFrame=Instance.new("Frame")
PickerFrame.Size=UDim2.new(1,-16,0,22); PickerFrame.Position=UDim2.new(0,8,0,61)
PickerFrame.BackgroundColor3=Color3.fromRGB(16,16,30); PickerFrame.ZIndex=6; PickerFrame.Parent=Panel
corner(PickerFrame,5); stroke(PickerFrame,1,Color3.fromRGB(40,60,100))

local PickerLbl=Instance.new("TextLabel")
PickerLbl.Size=UDim2.new(0,65,1,0); PickerLbl.Position=UDim2.new(0,5,0,0)
PickerLbl.BackgroundTransparency=1; PickerLbl.Text="gemini:"
PickerLbl.TextColor3=Color3.fromRGB(80,120,180); PickerLbl.Font=Enum.Font.Code
PickerLbl.TextSize=9; PickerLbl.TextXAlignment=Enum.TextXAlignment.Left
PickerLbl.ZIndex=7; PickerLbl.Parent=PickerFrame

local PickerBtn=Instance.new("TextButton")
PickerBtn.Size=UDim2.new(1,-70,1,0); PickerBtn.Position=UDim2.new(0,65,0,0)
PickerBtn.BackgroundColor3=Color3.fromRGB(22,22,40)
PickerBtn.Text=GEMINI_MODELS[selectedGeminiIdx].label
PickerBtn.TextColor3=Color3.fromRGB(160,210,255); PickerBtn.Font=Enum.Font.Code
PickerBtn.TextSize=9; PickerBtn.TextTruncate=Enum.TextTruncate.AtEnd
PickerBtn.ZIndex=7; PickerBtn.Parent=PickerFrame; corner(PickerBtn,4)

-- dropdown overlay (hidden by default)
local Dropdown=Instance.new("Frame")
Dropdown.Size=UDim2.new(0,200,0,#GEMINI_MODELS*24+4)
Dropdown.Position=UDim2.new(0,122,0,83)  -- below picker
Dropdown.BackgroundColor3=Color3.fromRGB(18,18,32)
Dropdown.Visible=false; Dropdown.ZIndex=20; Dropdown.Parent=Panel
corner(Dropdown,6); stroke(Dropdown,1,Color3.fromRGB(60,80,140))

local DDLayout=Instance.new("UIListLayout",Dropdown)
DDLayout.SortOrder=Enum.SortOrder.LayoutOrder; DDLayout.Padding=UDim.new(0,2)
local DDPad=Instance.new("UIPadding",Dropdown)
DDPad.PaddingLeft=UDim.new(0,4); DDPad.PaddingRight=UDim.new(0,4)
DDPad.PaddingTop=UDim.new(0,3); DDPad.PaddingBottom=UDim.new(0,3)

for i,m in ipairs(GEMINI_MODELS) do
    local row=Instance.new("TextButton",Dropdown)
    row.Size=UDim2.new(1,0,0,20); row.LayoutOrder=i
    row.BackgroundColor3=Color3.fromRGB(26,26,44)
    row.Text=m.label; row.Font=Enum.Font.Code; row.TextSize=9
    row.TextColor3=Color3.fromRGB(180,220,255)
    row.TextXAlignment=Enum.TextXAlignment.Left
    row.ZIndex=21; corner(row,4)
    local rp=Instance.new("UIPadding",row); rp.PaddingLeft=UDim.new(0,5)
    row.MouseButton1Click:Connect(function()
        selectedGeminiIdx=i
        PickerBtn.Text=m.label
        Dropdown.Visible=false
    end)
end

PickerBtn.MouseButton1Click:Connect(function()
    Dropdown.Visible=not Dropdown.Visible
end)

-- ── status pill ──
local StatusBar=Instance.new("Frame")
StatusBar.Size=UDim2.new(1,-16,0,20); StatusBar.Position=UDim2.new(0,8,0,86)
StatusBar.BackgroundColor3=Color3.fromRGB(16,16,28); StatusBar.ZIndex=6; StatusBar.Parent=Panel
corner(StatusBar,5)

local StatusLbl=Instance.new("TextLabel")
StatusLbl.Text="⏳ Connecting…"; StatusLbl.Size=UDim2.new(1,-8,1,0)
StatusLbl.Position=UDim2.new(0,6,0,0); StatusLbl.BackgroundTransparency=1
StatusLbl.TextColor3=Color3.fromRGB(140,140,180); StatusLbl.Font=Enum.Font.Code
StatusLbl.TextSize=10; StatusLbl.TextXAlignment=Enum.TextXAlignment.Left
StatusLbl.ZIndex=7; StatusLbl.Parent=StatusBar

-- ── output scroll ──
local OutScroll=Instance.new("ScrollingFrame")
OutScroll.Size=UDim2.new(1,-16,0,228); OutScroll.Position=UDim2.new(0,8,0,110)
OutScroll.BackgroundColor3=Color3.fromRGB(7,7,13)
OutScroll.ScrollBarThickness=4; OutScroll.ScrollBarImageColor3=Color3.fromRGB(60,60,110)
OutScroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
OutScroll.CanvasSize=UDim2.new(0,0,0,0); OutScroll.ZIndex=6; OutScroll.Parent=Panel
corner(OutScroll,8); stroke(OutScroll,1,Color3.fromRGB(25,25,45))

local OP=Instance.new("UIPadding",OutScroll)
OP.PaddingLeft=UDim.new(0,5); OP.PaddingRight=UDim.new(0,5)
OP.PaddingTop=UDim.new(0,4); OP.PaddingBottom=UDim.new(0,4)
local OL=Instance.new("UIListLayout",OutScroll)
OL.SortOrder=Enum.SortOrder.LayoutOrder; OL.Padding=UDim.new(0,2)

local lineCount=0
local function Log(text,col)
    col=col or Color3.fromRGB(200,200,210)
    lineCount=lineCount+1
    local lbl=Instance.new("TextLabel")
    lbl.Text=tostring(text); lbl.Size=UDim2.new(1,0,0,0)
    lbl.AutomaticSize=Enum.AutomaticSize.Y; lbl.BackgroundTransparency=1
    lbl.TextColor3=col; lbl.Font=Enum.Font.Code; lbl.TextSize=10
    lbl.TextWrapped=true; lbl.TextXAlignment=Enum.TextXAlignment.Left
    lbl.LayoutOrder=lineCount; lbl.ZIndex=7; lbl.Parent=OutScroll
    task.defer(function() OutScroll.CanvasPosition=Vector2.new(0,99999) end)
end

-- ── action row ──
local ActRow=Instance.new("Frame")
ActRow.Size=UDim2.new(1,-16,0,28); ActRow.Position=UDim2.new(0,8,0,342)
ActRow.BackgroundTransparency=1; ActRow.ZIndex=6; ActRow.Parent=Panel
local AL=Instance.new("UIListLayout",ActRow)
AL.FillDirection=Enum.FillDirection.Horizontal
AL.SortOrder=Enum.SortOrder.LayoutOrder; AL.Padding=UDim.new(0,5)

local function ActBtn(txt,bg,order,vis)
    local b=Instance.new("TextButton")
    b.Size=UDim2.new(0,93,1,0); b.BackgroundColor3=bg; b.Text=txt
    b.Font=Enum.Font.GothamBold; b.TextColor3=Color3.fromRGB(255,255,255)
    b.TextSize=10; b.Visible=(vis~=false); b.LayoutOrder=order; b.ZIndex=6; b.Parent=ActRow
    corner(b,6); return b
end

local ExecBtn  = ActBtn("▶ Run",   Color3.fromRGB(40,140,200), 1, false)
local ScanBtn  = ActBtn("🔍 Scan", Color3.fromRGB(110,45,155), 2, true)
local ClearBtn = ActBtn("🗑 Clear",Color3.fromRGB(45,45,60),   3, true)

local ScanLbl=Instance.new("TextLabel")
ScanLbl.Text="scan: pending"; ScanLbl.Size=UDim2.new(1,-16,0,12)
ScanLbl.Position=UDim2.new(0,8,0,373); ScanLbl.BackgroundTransparency=1
ScanLbl.TextColor3=Color3.fromRGB(70,70,110); ScanLbl.Font=Enum.Font.Code
ScanLbl.TextSize=9; ScanLbl.TextXAlignment=Enum.TextXAlignment.Left
ScanLbl.ZIndex=6; ScanLbl.Parent=Panel

-- ── input wrap (tall, scrollable) ──
local InputWrap=Instance.new("ScrollingFrame")
InputWrap.Size=UDim2.new(1,-16,0,88); InputWrap.Position=UDim2.new(0,8,0,388)
InputWrap.BackgroundColor3=Color3.fromRGB(12,12,24)
InputWrap.ScrollBarThickness=3; InputWrap.ScrollBarImageColor3=Color3.fromRGB(60,60,110)
InputWrap.AutomaticCanvasSize=Enum.AutomaticSize.Y
InputWrap.CanvasSize=UDim2.new(0,0,0,0); InputWrap.ZIndex=6; InputWrap.Parent=Panel
corner(InputWrap,8); stroke(InputWrap,1,Color3.fromRGB(45,45,78))

local InputBox=Instance.new("TextBox",InputWrap)
InputBox.Size=UDim2.new(1,0,0,0); InputBox.AutomaticSize=Enum.AutomaticSize.Y
InputBox.BackgroundTransparency=1
InputBox.PlaceholderText="ask anything — no limit on prompt length…"
InputBox.PlaceholderColor3=Color3.fromRGB(55,55,85)
InputBox.Text=""; InputBox.TextColor3=Color3.fromRGB(225,225,255)
InputBox.Font=Enum.Font.Code; InputBox.TextSize=10
InputBox.MultiLine=true; InputBox.TextWrapped=true
InputBox.ClearTextOnFocus=false
InputBox.TextXAlignment=Enum.TextXAlignment.Left
InputBox.TextYAlignment=Enum.TextYAlignment.Top; InputBox.ZIndex=7
local IP=Instance.new("UIPadding",InputBox)
IP.PaddingLeft=UDim.new(0,5); IP.PaddingRight=UDim.new(0,5)
IP.PaddingTop=UDim.new(0,5); IP.PaddingBottom=UDim.new(0,5)

-- ── ASK button ──
local AskBtn=Instance.new("TextButton")
AskBtn.Size=UDim2.new(1,-16,0,30); AskBtn.Position=UDim2.new(0,8,0,481)
AskBtn.BackgroundColor3=Color3.fromRGB(195,45,45); AskBtn.Text="⚡  ASK"
AskBtn.Font=Enum.Font.GothamBold; AskBtn.TextColor3=Color3.fromRGB(255,255,255)
AskBtn.TextSize=14; AskBtn.ZIndex=6; AskBtn.Parent=Panel
corner(AskBtn,8); stroke(AskBtn,1,Color3.fromRGB(255,70,70))

-- ─────────────────────────────────────────────
-- STATE
-- ─────────────────────────────────────────────
local Connected=false; local Busy=false
local LastCode=nil;    local LastGameCtx=nil

-- ─────────────────────────────────────────────
-- SCAN
-- ─────────────────────────────────────────────
local function DoScan()
    ScanLbl.Text="scanning…"
    local ok,res=pcall(ScanGame)
    if ok then
        LastGameCtx=res
        ScanLbl.Text="✅ PlaceID "..game.PlaceId
        Log("🔍 scan done — PlaceID "..game.PlaceId, Color3.fromRGB(130,55,175))
    else
        ScanLbl.Text="❌ scan error"
        Log("❌ scan: "..tostring(res):sub(1,80), Color3.fromRGB(215,55,55))
    end
end
ScanBtn.MouseButton1Click:Connect(DoScan)

-- ─────────────────────────────────────────────
-- CLEAR
-- ─────────────────────────────────────────────
ClearBtn.MouseButton1Click:Connect(function()
    ChatHistory={}
    for _,c in ipairs(OutScroll:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    lineCount=0; LastCode=nil; ExecBtn.Visible=false
    Log("🗑 cleared.", Color3.fromRGB(70,70,100))
end)

-- ─────────────────────────────────────────────
-- EXECUTE
-- ─────────────────────────────────────────────
ExecBtn.MouseButton1Click:Connect(function()
    if not LastCode then return end
    Log("▶ running…", Color3.fromRGB(52,150,215))
    local ok,err=ExecScript(LastCode)
    Log(ok and "✅ OK." or "❌ "..tostring(err),
        ok and Color3.fromRGB(46,200,110) or Color3.fromRGB(215,55,55))
end)

-- ─────────────────────────────────────────────
-- SUBMIT
-- ─────────────────────────────────────────────
local function Submit()
    if Busy then return end
    if not Connected then Log("⏳ still connecting…",Color3.fromRGB(255,180,40)); return end
    local msg=InputBox.Text:match("^%s*(.-)%s*$")
    if msg=="" then return end
    Busy=true; InputBox.Text=""
    AskBtn.BackgroundColor3=Color3.fromRGB(55,55,55); AskBtn.Text="…"
    StatusLbl.Text="⏳ thinking…"; StatusLbl.TextColor3=Color3.fromRGB(255,200,80)
    Log("───────────────────────", Color3.fromRGB(25,25,45))
    Log("you: "..msg:sub(1,120)..(#msg>120 and "…" or ""), Color3.fromRGB(120,165,255))

    task.spawn(function()
        local reply,prov,err=AskAI(msg,LastGameCtx,Log)

        if not reply then
            Log("❌ all providers failed.", Color3.fromRGB(215,55,55))
            StatusLbl.Text="❌ all providers failed"
            StatusLbl.TextColor3=Color3.fromRGB(215,55,55)
        else
            SetProvBadge(prov)
            for line in (reply.."\n"):gmatch("(.-)\n") do Log(line) end
            local code=ExtractCode(reply)
            if code then
                LastCode=code; ExecBtn.Visible=true
                StatusLbl.Text="✅ script ready — tap Run"
                StatusLbl.TextColor3=Color3.fromRGB(46,200,110)
                Log("▶ tap [Run] to execute.", Color3.fromRGB(46,200,110))
                local lower=msg:lower()
                if lower:find("run it") or lower:find("auto run")
                or lower:find("execute it") or lower:find("run now") then
                    Log("⚡ auto-exec…",Color3.fromRGB(255,180,40))
                    local ok2,e2=ExecScript(code)
                    Log(ok2 and "✅ done." or "❌ "..tostring(e2),
                        ok2 and Color3.fromRGB(46,200,110) or Color3.fromRGB(215,55,55))
                end
            else
                StatusLbl.Text="✅ reply received"
                StatusLbl.TextColor3=Color3.fromRGB(46,200,110)
            end
        end

        Busy=false; AskBtn.BackgroundColor3=Color3.fromRGB(195,45,45); AskBtn.Text="⚡  ASK"
    end)
end

AskBtn.MouseButton1Click:Connect(Submit)
InputBox.FocusLost:Connect(function(enter) if enter then Submit() end end)

-- ─────────────────────────────────────────────
-- BOOT CONNECT — tries all providers, marks live
-- ─────────────────────────────────────────────
Log("🤖 loading — trying providers…", Color3.fromRGB(110,155,255))

task.spawn(function()
    local ping="Reply with exactly: CONNECTED"
    local reply,prov,_=AskAI(ping,nil,Log)
    if reply then
        Connected=true
        SetProvBadge(prov)
        StatusLbl.Text="✅ online via "..prov
        StatusLbl.TextColor3=Color3.fromRGB(46,200,110)
        Log("✅ live on "..prov, Color3.fromRGB(46,200,110))
        Log("no prompt limit — say 'run it' to auto-exec.", Color3.fromRGB(130,130,155))
        DoScan()
    else
        StatusLbl.Text="❌ all providers down"
        StatusLbl.TextColor3=Color3.fromRGB(215,55,55)
        Log("❌ all three providers failed. check keys / internet.", Color3.fromRGB(215,55,55))
    end
end)
