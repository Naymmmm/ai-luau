<img src="assets/icon.svg" width="64" height="64" alt="">

# AI.luau

A single-file, strictly typed LLM client for **Roblox** and **Lune**.

- **Anthropic** Messages API, with SSE streaming, tool use and extended thinking
- **OpenAI** and any **OpenAI-compatible** server that implements the **Responses API**
- Streaming over the Responses API **WebSocket mode** (default) or SSE
- Persistent WebSocket sessions with `previousResponseId` chaining and concurrent `streamId` lanes
- **OpenAI moderation**, policy-based **content checks**, and an automatic moderation guard for any client
- **Roblox secret store** integration (`HttpService:GetSecret`); environment variables on Lune
- A tool-use loop (`client:run`), retries with backoff, and typed `AIError` values

Drop `AI.luau` into your project. It has no dependencies.

## Quick start

```lua
local AI = require(path.to.AI)

local claude = AI.new({
	provider = "anthropic",
	secret = "anthropic", -- Roblox secret store key, or an environment variable on Lune
	defaultModel = "claude-sonnet-5-5",
})

local response = claude:create({ prompt = "Write a haiku about Luau." })
print(response.text)
```

### Streaming

```lua
local openai = AI.new({ provider = "openai", secret = "openai", defaultModel = "gpt-5.2" })

local stream = openai:stream({ prompt = "Count to five." })
for event in stream:iter() do
	if event.type == "text" then
		print(event.delta)
	end
end
local final = stream:await()
```

Every stream ends with exactly one `done` or `error` event. You can also pass a callback,
`client:stream(request, function(event) ... end)`, and then call `stream:await()`.

OpenAI clients stream over WebSocket mode by default. Set `transport = "sse"` for
OpenAI-compatible servers that don't support it. Anthropic always streams over SSE.

### WebSocket sessions

```lua
local session = openai:connect()
local first = session:create({ prompt = "Pick a number.", store = false })
local second = session:create({ prompt = "Double it.", previousResponseId = first.id, store = false })

-- Requests on different lanes run concurrently over one connection.
local a = session:stream({ prompt = "Summarize A", streamId = "a" })
local b = session:stream({ prompt = "Summarize B", streamId = "b" })
print(a:await().text, b:await().text)
session:close()
```

### Tools

```lua
local result = claude:run({
	prompt = "What's the weather in Paris?",
	tools = {
		{
			name = "get_weather",
			description = "Current weather for a city",
			parameters = { type = "object", properties = { city = { type = "string" } }, required = { "city" } },
		},
	},
}, {
	get_weather = function(args)
		return { city = args.city, celsius = 14 }
	end,
})
print(result.response.text)
```

To drive the loop yourself, read `response.toolCalls`, append `AI.assistant(response)`, then append
`AI.user({ AI.toolResult(call.id, "...") })`. Thinking blocks and reasoning items in `response.content`
are sent back automatically, as tool use requires.

### Moderation and content checks

```lua
local moderation = openai:moderate({ "first text", "second text" })

local check = openai:check(text, {
	thresholds = { harassment = 0.4 }, -- per-category score thresholds
	defaultThreshold = 0.7, -- for the other categories (omit to use the API's `flagged` verdict)
	allow = { "violence" }, -- never block these
})
if not check.allowed then
	print(check.violations[1].category, check.violations[1].score)
end
```

Guard every request and response of any client, including Anthropic ones:

```lua
local guarded = AI.new({
	provider = "anthropic",
	secret = "anthropic",
	moderation = { client = openai, policy = { defaultThreshold = 0.5 } },
})
-- Raises an AIError with kind "moderation" (and the failing `check`) on a violation.
```

On Roblox, text shown to players must still go through `TextService` filtering. Moderation adds to
Roblox's filter; it doesn't replace it.

### Errors

Everything raises `AIError` tables:

```lua
local ok, err = pcall(claude.create, claude, { prompt = "hi" })
if not ok and AI.isError(err) then
	print(err.kind, err.status, err.code, err.message, err.retryable)
end
```

Kinds: `config`, `network`, `http`, `api`, `parse`, `moderation`, `closed`, `cancelled`, `unsupported`.
Rate limits, overloads, 5xx responses and network errors are retried (`maxRetries`, default 2) and honor `retry-after`.

## Roblox notes

- Enable **Allow HTTP Requests**, and use AI.luau from server scripts only.
- Store keys in the experience's secret store and pass the key name as `secret`. You can also pass a `Secret`
  directly as `apiKey`. Plugins can't access local secrets.
- `HttpService:CreateWebStreamClient`, which streaming and WebSockets use, currently works **in Studio only**
  and allows four clients at once. Elsewhere, `client:stream` makes one regular request and replays it as
  stream events. Set `streamFallback = false` to get an `unsupported` error instead. `client:connect` always
  needs WebSocket support.

## Lune notes

Tested with Lune 0.11. Streaming and WebSockets use `net.tcp` with TLS, because Lune's built-in WebSocket
client can't send an `Authorization` header. Keys come from `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`,
or from the variable named in `secret`.

## Development

Tools are pinned with [Rokit](https://github.com/rojo-rbx/rokit): `rokit install`.

```sh
lune run tests/run       # offline test suite against a local mock server
./scripts/analyze.sh     # luau-lsp strict type check (Roblox definitions) and StyLua check
stylua .                 # format
```

API docs are written as [Moonwave](https://eryn.io/moonwave/) comments in `AI.luau`.
