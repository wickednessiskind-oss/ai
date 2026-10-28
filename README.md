# AI Script Helper — Roblox executor script

Single-file Luau script that puts a floating AI chat panel inside Roblox (Delta /
mobile-friendly). You type what you want, it asks an LLM, and it can run the
generated script for you.

```
ai.lua   ← the whole thing, one file, paste into your executor
```

---

## Why it "did nothing" when you executed it (v1 → v2)

The v1 script **never ran a single line**. Here is what was broken, in order of
severity:

| # | Bug | Effect |
|---|-----|--------|
| 1 | `goto done` / `::done::` in `AskAI` (lines 246–271) | **Luau has no `goto`.** The file failed to *compile*, so nothing appeared, no errors you could see, no panel — just silence. This alone explains "I execute it and it doesn't work". |
| 2 | `typeof(request)` / `http and http.request` | `http` and `syn` are not globals in Luau, so touching them raised *"attempt to index a nil value"*. Replaced with `pcall`-protected `_G` lookups. |
| 3 | `InputBox.MultiLine = true` + `FocusLost` to submit | On mobile keyboards `FocusLost` usually never fires, so pressing send did nothing. The **⚡ ASK** button is now the send path. |
| 4 | `ExtractCode` required `"\n```"` exactly | Any reply using CRLF, ` ```luau `, or a fence without a blank line produced `nil` → "no code found" → no Run button. |
| 5 | `workspace:GetDescendants()` over the whole map, synchronously | On real games this freezes the client for seconds (looks like a crash). Now a bounded breadth-first walk. |
| 6 | HTTP calls with no timeout | A bad key/URL left it stuck on "thinking…" forever. |
| 7 | `game.CoreGui` assumed writable | Crashes the script if the executor blocks CoreGui. Now falls back to `PlayerGui`. |
| 8 | Gemini key was an `AQ.Ab8…` browser token | Not accepted by `generateContent` — Gemini always 400'd. The script now says so clearly instead of a silent fallback. |
| 9 | Generated code ran on the main thread with `pcall(fn)` | A `while true do` in generated code froze the whole panel. Now spawned on its own thread; runtime errors are reported back into the log. |
| 10 | Everything was in the global scope | Re-running the script collided with leftovers. Now wrapped in a `do ... end` block. |

The complete v2 file passes a headless simulation of the Roblox API
(boot → provider fallback → scan → ask → code extraction → auto-exec) plus unit
tests for the fence parser.

---

## Install

1. Open your executor (Delta, Wave, Codex, …) in Roblox.
2. Paste the entire contents of `ai.lua` and execute it.
3. Tap the **🤖** bubble (left edge) to open the panel.

> Re-running the script is safe: it destroys the previous GUI first.

## Using it

| Element | What it does |
|---|---|
| ⚙ | Paste / replace API keys, then **Save & reconnect** |
| gemini: picker | Choose which Gemini model the fallback uses |
| 🔍 Scan | Reads the current place (place id, tools, NPCs, remotes) and attaches it to every prompt |
| ⚡ ASK | Sends your prompt (no length limit, multi-line works) |
| ▶ Run | Appears when the answer contains a script — executes it |
| 🗑 Clear | Clears the log and the conversation memory |

Say **"run it"**, **"run now"**, **"execute it"** in your prompt and it
auto-executes the generated script.

## Providers

Tried in order, automatic fallback:

1. **TokenHarbor** — `POST https://api.tokenharbor.ai/v1/chat/completions` (OpenAI-compatible)
2. **Google Gemini** — `generateContent`, model chosen in the picker
3. **OpenRouter** — free models, tried in sequence if a model id disappears

If one provider fails you'll see exactly why in the log, e.g.
`⚠ gemini: HTTP 400: API key not valid`, then it moves on.

### About the keys

The keys currently baked into `ai.lua` are the ones from the original file.
Two of them are not usable, so expect the panel to come up on **OpenRouter**
or not at all:

* `GEMINI_KEY` starts with `AQ.` — that is a Google *browser* token, not an API
  key. Grab a free `AIza…` key from <https://aistudio.google.com/apikey>.
* `TOKENHARBOR_KEY` is a bearer token in the original file; if the service
  rejects it, the chain simply skips it.

Get free keys here:

* Gemini — <https://aistudio.google.com/apikey>
* OpenRouter — <https://openrouter.ai/keys>

Paste them in the ⚙ panel (no need to edit the file) — they are kept for the
session and, if your executor exposes `writefile`, saved to
`ai_helper_keys.json` in the executor's workspace folder.

> The keys that were in the shared file are now public — rotate them.

## Notes and limits

* Needs an executor with an HTTP function (`request` / `http_request` /
  `syn.request`). Delta has `request`.
* `loadstring` must be available to run generated code (every mainstream
  executor has it).
* This is a client-side script: it can only do what the client can do.
  Server-side exploits are out of scope.
* Only run generated code if you understand it — it executes with your
  executor's privileges.
