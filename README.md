<img src="assets/icon.svg" width="64" height="64" alt="">

# AI.luau

A single-file, strictly typed LLM client for **Roblox** and **Lune**.

- **Anthropic** Messages API, with SSE streaming, tool use and extended thinking
- **OpenAI** and any **OpenAI-compatible** server that implements the **Responses API**
- Streaming over the Responses API **WebSocket mode** (default) or SSE
- Persistent WebSocket sessions with `PreviousResponseId` chaining and concurrent `StreamId` lanes
- **OpenAI moderation**, policy-based **content checks**, and an automatic moderation guard for any provider
- **Roblox secret store** integration (`HttpService:GetSecret`); environment variables on Lune
- A tool-use loop (`Provider:Run`), retries with backoff, and typed `AIError` values

Drop `AI.luau` into your project. It has no dependencies.

## Quick start

```lua
local AI = require(path.to.AI)

local claude = AI.Provider.new({
	Format = AI.Format.Anthropic.V2023_06_01,
	Secret = "anthropic", -- Roblox secret store key, or an environment variable on Lune
	DefaultModel = "claude-sonnet-5-5",
})

local response = claude:Create({ Prompt = "Write a haiku about Luau." })
print(response.Text)
```

## Formats

`Format` picks the wire protocol and API version:

| Format | Protocol |
| --- | --- |
| `AI.Format.Anthropic.V2023_06_01` | Anthropic Messages API, `anthropic-version: 2023-06-01` |
| `AI.Format.Anthropic["2023-06-01"]` | The same value as `V2023_06_01` |
| `AI.Format.Anthropic.Latest` | The newest Anthropic format, currently `V2023_06_01` |
| `AI.Format.OpenAI.Responses` | OpenAI Responses API, for OpenAI and compatible servers |
| `AI.Format.OpenAI.Latest` | Currently `Responses` |

Pin a dated format for stable behavior, or use `Latest` to follow upgrades. `provider.Format` and
`response.Format` report which format was used.

```lua
-- Any OpenAI-compatible server with the Responses API, here a local one without a key.
local ollama = AI.Provider.new({
	Format = AI.Format.OpenAI.Responses,
	BaseUrl = "http://localhost:11434/v1",
	Transport = "sse",
})
```

## Streaming

```lua
local openai = AI.Provider.new({ Format = AI.Format.OpenAI.Responses, Secret = "openai", DefaultModel = "gpt-5.2" })

local stream = openai:Stream({ Prompt = "Count to five." })
for event in stream:Iter() do
	if event.Type == "text" then
		print(event.Delta)
	end
end
local final = stream:Await()
```

Every stream ends with exactly one `done` or `error` event. You can also pass a callback,
`provider:Stream(request, function(event) ... end)`, and then call `stream:Await()`.

OpenAI formats stream over WebSocket mode by default. Set `Transport = "sse"` for OpenAI-compatible
servers that don't support it. Anthropic always streams over SSE.

### WebSocket sessions

```lua
local session = openai:Connect()
local first = session:Create({ Prompt = "Pick a number.", Store = false })
local second = session:Create({ Prompt = "Double it.", PreviousResponseId = first.Id, Store = false })

-- Requests on different lanes run concurrently over one connection.
local a = session:Stream({ Prompt = "Summarize A", StreamId = "a" })
local b = session:Stream({ Prompt = "Summarize B", StreamId = "b" })
print(a:Await().Text, b:Await().Text)
session:Close()
```

## Tools

```lua
local result = claude:Run({
	Prompt = "What's the weather in Paris?",
	Tools = {
		{
			Name = "get_weather",
			Description = "Current weather for a city",
			Parameters = { type = "object", properties = { city = { type = "string" } }, required = { "city" } },
		},
	},
}, {
	get_weather = function(args)
		return { city = args.city, celsius = 14 }
	end,
})
print(result.Response.Text)
```

Tool `Parameters` are plain JSON Schema, so their keys keep JSON Schema's own casing. The same goes for
`Request.Extra`, which is merged into the request body as is.

To drive the loop yourself, read `response.ToolCalls`, append `AI.Assistant(response)`, then append
`AI.User({ AI.ToolResult(call.Id, "...") })`. Thinking blocks and reasoning items in `response.Content`
are sent back automatically, as tool use requires.

## Moderation and content checks

```lua
local moderation = openai:Moderate({ "first text", "second text" })

local check = openai:Check(text, {
	Thresholds = { harassment = 0.4 }, -- per-category score thresholds
	DefaultThreshold = 0.7, -- for the other categories (omit to use the API's `Flagged` verdict)
	Allow = { "violence" }, -- never block these
})
if not check.Allowed then
	print(check.Violations[1].Category, check.Violations[1].Score)
end
```

Category names are the API's own, such as `"self-harm/intent"`.

Guard every request and response of any provider, including Anthropic ones:

```lua
local guarded = AI.Provider.new({
	Format = AI.Format.Anthropic.Latest,
	Secret = "anthropic",
	Moderation = { Provider = openai, Policy = { DefaultThreshold = 0.5 } },
})
-- Raises an AIError with Kind "moderation" (and the failing `Check`) on a violation.
```

On Roblox, text shown to players must still go through `TextService` filtering. Moderation adds to
Roblox's filter; it doesn't replace it.

## Errors

Everything raises `AIError` tables:

```lua
local ok, err = pcall(claude.Create, claude, { Prompt = "hi" })
if not ok and AI.IsError(err) then
	print(err.Kind, err.Status, err.Code, err.Message, err.Retryable)
end
```

Kinds: `config`, `network`, `http`, `api`, `parse`, `moderation`, `closed`, `cancelled`, `unsupported`.
Rate limits, overloads, 5xx responses and network errors are retried (`MaxRetries`, default 2) and honor `retry-after`.

## Roblox notes

- Enable **Allow HTTP Requests**, and use AI.luau from server scripts only.
- Store keys in the experience's secret store and pass the key name as `Secret`. You can also pass a `Secret`
  object directly as `ApiKey`. Plugins can't access local secrets.
- `HttpService:CreateWebStreamClient`, which streaming and WebSockets use, currently works **in Studio only**
  and allows four clients at once. Elsewhere, `Provider:Stream` makes one regular request and replays it as
  stream events. Set `StreamFallback = false` to get an `unsupported` error instead. `Provider:Connect` always
  needs WebSocket support.

## Lune notes

Tested with Lune 0.11. Streaming and WebSockets use `net.tcp` with TLS, because Lune's built-in WebSocket
client can't send an `Authorization` header. Keys come from `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`,
or from the variable named in `Secret`.

## Development

Tools are pinned with [Rokit](https://github.com/rojo-rbx/rokit): `rokit install`.

```sh
lune run tests/run       # offline test suite against a local mock server
./scripts/analyze.sh     # luau-lsp strict type check, Moonwave doc check and StyLua check
stylua .                 # format
```

API docs are written as [Moonwave](https://eryn.io/moonwave/) comments in `AI.luau`.
