--!strict
--[=[
	@class AI

	A single-file, strictly typed client for large language model APIs that runs on both
	[Roblox](https://create.roblox.com) and [Lune](https://lune-org.github.io/docs).

	Providers are created with [Provider.new] and a [Format], which picks the wire protocol and API version:

	- `AI.Format.Anthropic.V2023_06_01` (also `AI.Format.Anthropic["2023-06-01"]`): the Anthropic Messages API,
	  streamed over server-sent events.
	- `AI.Format.OpenAI.Responses`: OpenAI and OpenAI-compatible endpoints through the Responses API, streamed over
	  [WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode) or server-sent events.
	  OpenAI providers also expose the moderation API and policy-based content checks.

	On Roblox, API keys can come straight from the experience's secret store through
	[HttpService:GetSecret](https://create.roblox.com/docs/reference/engine/classes/HttpService#GetSecret),
	so the key never touches your source code. On Lune, the same `Secret` option reads an environment variable.

	```lua
	local AI = require(path.to.AI)

	local claude = AI.Provider.new({
		Format = AI.Format.Anthropic.V2023_06_01,
		Secret = "anthropic",
		DefaultModel = "claude-sonnet-5-5",
	})

	local response = claude:Create({ Prompt = "Write a haiku about Luau." })
	print(response.Text)

	local stream = claude:Stream({ Prompt = "Count to five." })
	for event in stream:Iter() do
		if event.Type == "text" then
			print(event.Delta)
		end
	end
	```
]=]
local AI = {}

--------------------------------------------------------------------------------
-- Public types
--------------------------------------------------------------------------------

--[=[
	@type Protocol "anthropic" | "openai"
	@within AI
	The wire protocol behind a [Format].
]=]
export type Protocol = "anthropic" | "openai"

--[=[
	@interface Format
	@within AI
	.Name string -- Display name, such as `"Anthropic 2023-06-01"`.
	.Protocol Protocol
	.Version string? -- The API version sent to the provider, if it has one.

	A wire format and API version. Use the values in [AI.Format]; other tables are rejected.
]=]
export type Format = { Name: string, Protocol: Protocol, Version: string? }

--[=[
	@interface Formats
	@within AI
	.Anthropic { V2023_06_01: Format, ["2023-06-01"]: Format, Latest: Format }
	.OpenAI { Responses: Format, Latest: Format }
]=]
export type Formats = {
	Anthropic: { V2023_06_01: Format, ["2023-06-01"]: Format, Latest: Format },
	OpenAI: { Responses: Format, Latest: Format },
}

--[=[
	@type Transport "websocket" | "sse"
	@within AI
	How OpenAI providers stream. Anthropic always streams over server-sent events.
]=]
export type Transport = "websocket" | "sse"

--[=[
	@type ApiKey string | Secret
	@within AI
	An API key as a plain string, or a Roblox [Secret](https://create.roblox.com/docs/reference/engine/datatypes/Secret).
]=]
export type ApiKey = string | Secret

--[=[
	@type Role "system" | "user" | "assistant"
	@within AI
]=]
export type Role = "system" | "user" | "assistant"

--[=[
	@interface TextPart
	@within AI
	.Type "text"
	.Text string
]=]
export type TextPart = { Type: "text", Text: string }

--[=[
	@interface ImagePart
	@within AI
	.Type "image"
	.Url string? -- A publicly reachable image URL.
	.Data string? -- Base64 encoded image data, used when `Url` is absent.
	.MediaType string? -- The MIME type of `Data`. Defaults to `"image/png"`.
]=]
export type ImagePart = { Type: "image", Url: string?, Data: string?, MediaType: string? }

--[=[
	@interface ToolCallPart
	@within AI
	.Type "tool_call"
	.Id string -- Identifier to echo back in a matching [ToolResultPart].
	.Name string
	.Arguments { [string]: any } -- Decoded arguments. Empty if the model produced invalid JSON.
	.RawArguments string -- The arguments exactly as the model produced them.
	.ItemId string? -- OpenAI output item id, sent back so the call stays paired with its reasoning item.
]=]
export type ToolCallPart = {
	Type: "tool_call",
	Id: string,
	Name: string,
	Arguments: { [string]: any },
	RawArguments: string,
	ItemId: string?,
}

--[=[
	@interface ToolResultPart
	@within AI
	.Type "tool_result"
	.ToolCallId string
	.Content string
	.IsError boolean?
]=]
export type ToolResultPart = { Type: "tool_result", ToolCallId: string, Content: string, IsError: boolean? }

--[=[
	@interface ThinkingPart
	@within AI
	.Type "thinking"
	.Text string -- Thinking text (Anthropic) or reasoning summary (OpenAI).
	.Protocol Protocol -- The protocol that produced it. Only that protocol receives it back.
	.Raw any -- The original block, replayed verbatim on later turns.
]=]
export type ThinkingPart = { Type: "thinking", Text: string, Protocol: Protocol, Raw: any }

--[=[
	@interface RefusalPart
	@within AI
	.Type "refusal"
	.Text string
]=]
export type RefusalPart = { Type: "refusal", Text: string }

--[=[
	@interface RawPart
	@within AI
	.Type "raw"
	.Protocol Protocol
	.Raw any -- A provider block AI.luau does not model, such as server tool results.
]=]
export type RawPart = { Type: "raw", Protocol: Protocol, Raw: any }

--[=[
	@type ContentPart TextPart | ImagePart | ToolCallPart | ToolResultPart | ThinkingPart | RefusalPart | RawPart
	@within AI
]=]
export type ContentPart = TextPart | ImagePart | ToolCallPart | ToolResultPart | ThinkingPart | RefusalPart | RawPart

--[=[
	@interface Message
	@within AI
	.Role Role
	.Content string | { ContentPart }
]=]
export type Message = { Role: Role, Content: string | { ContentPart } }

--[=[
	@interface Tool
	@within AI
	.Name string
	.Description string?
	.Parameters { [string]: any }? -- A JSON Schema object. Defaults to an empty object schema.
	.Strict boolean? -- OpenAI strict schema adherence. Defaults to `false`.
]=]
export type Tool = { Name: string, Description: string?, Parameters: { [string]: any }?, Strict: boolean? }

--[=[
	@type ToolChoice "auto" | "none" | "required" | { Name: string }
	@within AI
]=]
export type ToolChoice = "auto" | "none" | "required" | { Name: string }

--[=[
	@interface Reasoning
	@within AI
	.Effort string? -- OpenAI reasoning effort, such as `"low"` or `"high"`.
	.Summary string? -- OpenAI reasoning summary mode, such as `"auto"`.
	.BudgetTokens number? -- Anthropic extended thinking budget.
]=]
export type Reasoning = { Effort: string?, Summary: string?, BudgetTokens: number? }

--[=[
	@interface Request
	@within AI
	.Model string? -- Falls back to the provider's `DefaultModel`.
	.Prompt string? -- Shorthand appended as a final user message.
	.Messages { Message }?
	.System string?
	.MaxTokens number?
	.Temperature number?
	.TopP number?
	.Stop { string }? -- Anthropic only. The Responses API has no stop sequences.
	.Tools { Tool }?
	.ToolChoice ToolChoice?
	.Reasoning Reasoning?
	.PreviousResponseId string? -- OpenAI only. Continues a stored or cached response.
	.Store boolean? -- OpenAI only.
	.StreamId string? -- OpenAI WebSocket mode lane. Requests on different lanes run concurrently.
	.Extra { [string]: any }? -- Raw fields merged into the request body last, in the provider's own casing.
]=]
export type Request = {
	Model: string?,
	Prompt: string?,
	Messages: { Message }?,
	System: string?,
	MaxTokens: number?,
	Temperature: number?,
	TopP: number?,
	Stop: { string }?,
	Tools: { Tool }?,
	ToolChoice: ToolChoice?,
	Reasoning: Reasoning?,
	PreviousResponseId: string?,
	Store: boolean?,
	StreamId: string?,
	Extra: { [string]: any }?,
}

--[=[
	@type StopReason "stop" | "length" | "tool_calls" | "content_filter" | "refusal" | "pause" | "error" | "unknown"
	@within AI
]=]
export type StopReason = "stop" | "length" | "tool_calls" | "content_filter" | "refusal" | "pause" | "error" | "unknown"

--[=[
	@interface Usage
	@within AI
	.InputTokens number
	.OutputTokens number
	.TotalTokens number
	.CacheReadTokens number?
	.CacheWriteTokens number?
]=]
export type Usage = {
	InputTokens: number,
	OutputTokens: number,
	TotalTokens: number,
	CacheReadTokens: number?,
	CacheWriteTokens: number?,
}

--[=[
	@interface Response
	@within AI
	.Id string
	.Model string
	.Format Format -- The format of the provider that produced it.
	.Content { ContentPart } -- Every output block, in order. Pass it back with [AI.Assistant].
	.Text string -- All text parts concatenated.
	.ToolCalls { ToolCallPart }
	.StopReason StopReason
	.Usage Usage
	.Raw any -- The decoded provider response.
]=]
export type Response = {
	Id: string,
	Model: string,
	Format: Format,
	Content: { ContentPart },
	Text: string,
	ToolCalls: { ToolCallPart },
	StopReason: StopReason,
	Usage: Usage,
	Raw: any,
}

--[=[
	@type StreamEvent { Type: "start", Id: string, Model: string } | { Type: "text", Delta: string, Index: number } | { Type: "thinking", Delta: string, Index: number } | { Type: "refusal", Delta: string, Index: number } | { Type: "tool_call_start", Index: number, Id: string, Name: string } | { Type: "tool_call_delta", Index: number, Delta: string } | { Type: "tool_call", Index: number, Call: ToolCallPart } | { Type: "done", Response: Response } | { Type: "error", Error: AIError }
	@within AI
	Normalized streaming events. `Index` is the 1-based position of the content block being written.
	Every stream ends with exactly one `done` or `error` event.
]=]
export type StreamEvent =
	{ Type: "start", Id: string, Model: string }
	| { Type: "text", Delta: string, Index: number }
	| { Type: "thinking", Delta: string, Index: number }
	| { Type: "refusal", Delta: string, Index: number }
	| { Type: "tool_call_start", Index: number, Id: string, Name: string }
	| { Type: "tool_call_delta", Index: number, Delta: string }
	| { Type: "tool_call", Index: number, Call: ToolCallPart }
	| { Type: "done", Response: Response }
	| { Type: "error", Error: AIError }

--[=[
	@type AIErrorKind "config" | "network" | "http" | "api" | "parse" | "moderation" | "closed" | "cancelled" | "unsupported"
	@within AI
]=]
export type AIErrorKind =
	"config"
	| "network"
	| "http"
	| "api"
	| "parse"
	| "moderation"
	| "closed"
	| "cancelled"
	| "unsupported"

--[=[
	@interface AIError
	@within AI
	.Kind AIErrorKind
	.Message string
	.Status number? -- HTTP status code, when there is one.
	.Code string? -- Provider error code, such as `"rate_limit_exceeded"`.
	.ErrorType string? -- Provider error type, such as `"overloaded_error"`.
	.Body string? -- The raw response body of a failed HTTP request.
	.Retryable boolean
	.Check ContentCheck? -- The failing check, for `"moderation"` errors.

	Every error AI.luau raises is an `AIError` table. Catch it with `pcall` and test it with [AI.IsError].
]=]
export type AIError = {
	Kind: AIErrorKind,
	Message: string,
	Status: number?,
	Code: string?,
	ErrorType: string?,
	Body: string?,
	Retryable: boolean,
	Check: ContentCheck?,
}

--[=[
	@type ModerationCategory "harassment" | "harassment/threatening" | "hate" | "hate/threatening" | "illicit" | "illicit/violent" | "self-harm" | "self-harm/intent" | "self-harm/instructions" | "sexual" | "sexual/minors" | "violence" | "violence/graphic"
	@within AI
	Categories reported by `omni-moderation-latest`. Maps are keyed by `string` so new categories still work.
]=]
export type ModerationCategory =
	"harassment"
	| "harassment/threatening"
	| "hate"
	| "hate/threatening"
	| "illicit"
	| "illicit/violent"
	| "self-harm"
	| "self-harm/intent"
	| "self-harm/instructions"
	| "sexual"
	| "sexual/minors"
	| "violence"
	| "violence/graphic"

--[=[
	@type ModerationInput string | { string } | { ContentPart }
	@within AI
	Text, a batch of texts, or content parts mixing text and images.
]=]
export type ModerationInput = string | { string } | { ContentPart }

--[=[
	@interface ModerationOptions
	@within AI
	.Model string? -- Defaults to `"omni-moderation-latest"`.
]=]
export type ModerationOptions = { Model: string? }

--[=[
	@interface ModerationResult
	@within AI
	.Flagged boolean
	.Categories { [string]: boolean }
	.Scores { [string]: number }
	.AppliedInputTypes { [string]: { string } }
]=]
export type ModerationResult = {
	Flagged: boolean,
	Categories: { [string]: boolean },
	Scores: { [string]: number },
	AppliedInputTypes: { [string]: { string } },
}

--[=[
	@interface ModerationResponse
	@within AI
	.Id string
	.Model string
	.Flagged boolean -- True if any result is flagged.
	.Results { ModerationResult }
	.Raw any
]=]
export type ModerationResponse = {
	Id: string,
	Model: string,
	Flagged: boolean,
	Results: { ModerationResult },
	Raw: any,
}

--[=[
	@interface ContentPolicy
	@within AI
	.Model string? -- Moderation model to use.
	.Thresholds { [string]: number }? -- Per-category score thresholds in `[0, 1]`.
	.DefaultThreshold number? -- Threshold for categories without one. Without it, the API's own `Flagged` verdict is used.
	.Block { string }? -- Only these categories can cause a violation.
	.Allow { string }? -- These categories never cause a violation.

	Decides which moderation results count as violations.
]=]
export type ContentPolicy = {
	Model: string?,
	Thresholds: { [string]: number }?,
	DefaultThreshold: number?,
	Block: { string }?,
	Allow: { string }?,
}

--[=[
	@interface ContentViolation
	@within AI
	.Category string
	.Score number
	.Threshold number? -- The threshold that was crossed, if the policy set one.
	.Result number -- Index of the moderation result, matching the input order.
]=]
export type ContentViolation = { Category: string, Score: number, Threshold: number?, Result: number }

--[=[
	@interface ContentCheck
	@within AI
	.Allowed boolean -- True when there are no violations.
	.Flagged boolean -- The API's own verdict, regardless of policy.
	.Violations { ContentViolation } -- Sorted by descending score.
	.Moderation ModerationResponse
]=]
export type ContentCheck = {
	Allowed: boolean,
	Flagged: boolean,
	Violations: { ContentViolation },
	Moderation: ModerationResponse,
}

--[=[
	@interface ModerationGuard
	@within AI
	.Provider Provider? -- OpenAI provider used for moderation. Defaults to the guarded provider itself.
	.Policy ContentPolicy?
	.Input boolean? -- Check the latest message before sending. Defaults to `true`.
	.Output boolean? -- Check the response text before returning it. Defaults to `true`.

	Automatically moderates a provider's traffic. Violations raise an [AIError] with kind `"moderation"`.
]=]
export type ModerationGuard = { Provider: Provider?, Policy: ContentPolicy?, Input: boolean?, Output: boolean? }

--[=[
	@interface ProviderConfig
	@within AI
	.Format Format -- One of the values in [AI.Format].
	.ApiKey ApiKey? -- A key or Roblox `Secret`. Takes priority over `Secret`.
	.Secret string? -- Roblox secret store key, or Lune environment variable name.
	.BaseUrl string? -- Defaults to the official endpoint, such as `https://api.openai.com/v1`.
	.Headers { [string]: string }? -- Extra headers sent with every request.
	.DefaultModel string?
	.MaxTokens number? -- Anthropic `max_tokens` default. Defaults to `4096`.
	.MaxRetries number? -- Retries for rate limits, overloads and network errors. Defaults to `2`.
	.Transport Transport? -- OpenAI streaming transport. Defaults to `"websocket"`.
	.StreamFallback boolean? -- Emulate streaming with a regular request where streaming is unavailable. Defaults to `true`.
	.ConnectTimeout number? -- Seconds to wait for a WebSocket to open. Defaults to `30`.
	.AnthropicBeta { string }? -- Values for the `anthropic-beta` header.
	.Organization string? -- OpenAI organization header.
	.Project string? -- OpenAI project header.
	.Moderation ModerationGuard?

	When neither `ApiKey` nor `Secret` is set, the provider looks for `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` in the
	secret store (Roblox) or environment (Lune). A missing key is only an error for the official endpoints.
]=]
export type ProviderConfig = {
	Format: Format,
	ApiKey: ApiKey?,
	Secret: string?,
	BaseUrl: string?,
	Headers: { [string]: string }?,
	DefaultModel: string?,
	MaxTokens: number?,
	MaxRetries: number?,
	Transport: Transport?,
	StreamFallback: boolean?,
	ConnectTimeout: number?,
	AnthropicBeta: { string }?,
	Organization: string?,
	Project: string?,
	Moderation: ModerationGuard?,
}

--[=[
	@type ToolHandler (arguments: { [string]: any }, call: ToolCallPart) -> any
	@within AI
	Returns a string, or any JSON-encodable value. Raising an error reports it to the model as a failed call.
]=]
export type ToolHandler = (arguments: { [string]: any }, call: ToolCallPart) -> any

--[=[
	@interface RunOptions
	@within AI
	.MaxSteps number? -- Maximum model calls. Defaults to `8`.
	.OnStep ((response: Response) -> ())? -- Called after every model call.
]=]
export type RunOptions = { MaxSteps: number?, OnStep: ((response: Response) -> ())? }

--[=[
	@interface RunResult
	@within AI
	.Response Response -- The final response.
	.Messages { Message } -- The full conversation, including tool calls and results.
	.Steps number
]=]
export type RunResult = { Response: Response, Messages: { Message }, Steps: number }

--[=[
	@class Stream

	A live response. Read it with [Stream:Iter], [Stream:Next] or [Stream:Await]. A stream has a single consumer.
]=]
export type Stream = {
	Text: string,
	Response: Response?,
	Next: (self: Stream) -> StreamEvent?,
	Iter: (self: Stream) -> () -> StreamEvent?,
	Await: (self: Stream) -> Response,
	Cancel: (self: Stream) -> (),
}

--[=[
	@class Session

	A persistent OpenAI Responses [WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode)
	connection, created with [Provider:Connect]. Reusing one connection keeps recent responses cached server-side,
	which makes `PreviousResponseId` continuations faster. Connections last up to 60 minutes.
]=]
export type Session = {
	Stream: (self: Session, request: Request, onEvent: ((event: StreamEvent) -> ())?) -> Stream,
	Create: (self: Session, request: Request) -> Response,
	Close: (self: Session) -> (),
	IsOpen: (self: Session) -> boolean,
}

--[=[
	@class Provider

	A configured connection to one API, created with [Provider.new].
]=]
export type Provider = {
	Format: Format,
	BaseUrl: string,
	Create: (self: Provider, request: Request) -> Response,
	Stream: (self: Provider, request: Request, onEvent: ((event: StreamEvent) -> ())?) -> Stream,
	Connect: (self: Provider) -> Session,
	Run: (self: Provider, request: Request, handlers: { [string]: ToolHandler }, options: RunOptions?) -> RunResult,
	Moderate: (self: Provider, input: ModerationInput, options: ModerationOptions?) -> ModerationResponse,
	Check: (self: Provider, input: ModerationInput, policy: ContentPolicy?) -> ContentCheck,
}

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

type ErrorDetails = {
	status: number?,
	code: string?,
	errorType: string?,
	body: string?,
	retryable: boolean?,
	check: ContentCheck?,
}

local ErrorMeta = {
	__tostring = function(err: AIError): string
		local label = if err.Status then `{err.Kind} {err.Status}` else err.Kind
		return `AI.luau [{label}]: {err.Message}`
	end,
}

local function newError(kind: AIErrorKind, message: string, details: ErrorDetails?): AIError
	local d: ErrorDetails = details or {}
	local err: AIError = {
		Kind = kind,
		Message = message,
		Status = d.status,
		Code = d.code,
		ErrorType = d.errorType,
		Body = d.body,
		Retryable = d.retryable == true,
		Check = d.check,
	}
	setmetatable(err :: any, ErrorMeta)
	return err
end

local function isError(value: unknown): boolean
	return type(value) == "table" and getmetatable(value :: any) == ErrorMeta
end

local function asError(value: unknown, kind: AIErrorKind): AIError
	if isError(value) then
		return value :: any
	end
	return newError(kind, tostring(value), { retryable = kind == "network" })
end

--------------------------------------------------------------------------------
-- JSON encoding
--------------------------------------------------------------------------------

local JSON_NULL = table.freeze({})
local objectTables: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local JSON_ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function escapeJsonCharacter(character: string): string
	return JSON_ESCAPES[character] or string.format("\\u%04x", string.byte(character))
end

local function encodeJsonValue(value: any, out: { string }, depth: number)
	if depth > 200 then
		error(newError("config", "cannot encode JSON nested deeper than 200 levels (is there a cycle?)"))
	end
	local kind = type(value)
	if value == nil or value == JSON_NULL then
		table.insert(out, "null")
	elseif kind == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error(newError("config", "cannot encode a non-finite number as JSON"))
		end
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			table.insert(out, string.format("%d", value))
		else
			table.insert(out, string.format("%.17g", value))
		end
	elseif kind == "string" then
		table.insert(out, '"' .. string.gsub(value, '[%c"\\]', escapeJsonCharacter) .. '"')
	elseif kind == "table" then
		local count = 0
		for _ in value do
			count += 1
		end
		local length = #value
		if count == 0 then
			table.insert(out, if objectTables[value] then "{}" else "[]")
		elseif length == count and not objectTables[value] then
			table.insert(out, "[")
			for index = 1, length do
				if index > 1 then
					table.insert(out, ",")
				end
				encodeJsonValue(value[index], out, depth + 1)
			end
			table.insert(out, "]")
		else
			local keys: { string } = {}
			local lookup: { [string]: any } = {}
			for key, item in value do
				local name = tostring(key)
				table.insert(keys, name)
				lookup[name] = item
			end
			table.sort(keys)
			table.insert(out, "{")
			for index, name in keys do
				if index > 1 then
					table.insert(out, ",")
				end
				table.insert(out, '"' .. string.gsub(name, '[%c"\\]', escapeJsonCharacter) .. '":')
				encodeJsonValue(lookup[name], out, depth + 1)
			end
			table.insert(out, "}")
		end
	else
		error(newError("config", `cannot encode a value of type '{kind}' as JSON`))
	end
end

local function encodeJson(value: any): string
	local out: { string } = {}
	encodeJsonValue(value, out, 0)
	return table.concat(out)
end

local function markObject<T>(value: T): T
	if type(value) == "table" then
		objectTables[value] = true
	end
	return value
end

-- Marks every `properties` table in a JSON Schema as an object, so `properties = {}` encodes as `{}`.
local function normalizeSchema(schema: { [string]: any }?): { [string]: any }
	if schema == nil then
		return markObject({ type = "object", properties = markObject({}) })
	end
	local function walk(node: any, depth: number)
		if type(node) ~= "table" or depth > 64 then
			return
		end
		markObject(node)
		for key, child in node do
			if type(child) == "table" then
				if key == "properties" or key == "$defs" or key == "definitions" or key == "patternProperties" then
					markObject(child)
					for _, property in child do
						walk(property, depth + 1)
					end
				elseif key == "items" or key == "additionalProperties" or key == "not" then
					walk(child, depth + 1)
				elseif key == "anyOf" or key == "oneOf" or key == "allOf" or key == "prefixItems" then
					for _, option in child do
						walk(option, depth + 1)
					end
				end
			end
		end
	end
	walk(schema, 0)
	return schema
end

--------------------------------------------------------------------------------
-- Runtime abstraction (Roblox and Lune)
--------------------------------------------------------------------------------

type Headers = { [string]: ApiKey }
type HttpMethod = "GET" | "POST"
type HttpRequest = { url: string, method: HttpMethod, headers: Headers, body: string? }
type HttpResponse = { status: number, statusMessage: string, headers: { [string]: string }, body: string }

type StreamSink = {
	onData: (chunk: string) -> (),
	onError: (status: number?, message: string) -> (),
	onClose: () -> (),
}

type SocketSink = {
	onMessage: (message: string) -> (),
	onClose: (code: number?, reason: string?) -> (),
}

type RawSocket = {
	send: (message: string) -> (),
	close: () -> (),
	isOpen: () -> boolean,
}

type Runtime = {
	name: "roblox" | "lune",
	request: (request: HttpRequest) -> HttpResponse,
	stream: (request: HttpRequest, sink: StreamSink) -> () -> (),
	socket: (url: string, headers: Headers, sink: SocketSink, timeout: number) -> RawSocket,
	decodeJson: (text: string) -> any,
	spawn: (callback: () -> ()) -> (),
	resume: (thread: thread) -> (),
	wait: (seconds: number) -> (),
	delay: (seconds: number, callback: () -> ()) -> (),
	secret: (name: string) -> ApiKey?,
}

local IS_ROBLOX = typeof(game) == "Instance"

local function createRobloxRuntime(): Runtime
	local HttpService = game:GetService("HttpService")

	local function lowerHeaders(headers: { [string]: string }?): { [string]: string }
		local out: { [string]: string } = {}
		if headers then
			for key, value in headers do
				out[string.lower(key)] = value
			end
		end
		return out
	end

	return {
		name = "roblox",
		request = function(request: HttpRequest): HttpResponse
			local ok, result = pcall(function()
				return HttpService:RequestAsync({
					Url = request.url,
					Method = request.method,
					Headers = request.headers,
					Body = request.body,
				})
			end)
			if not ok then
				error(newError("network", tostring(result), { retryable = true }))
			end
			return {
				status = result.StatusCode,
				statusMessage = result.StatusMessage,
				headers = lowerHeaders(result.Headers),
				body = result.Body or "",
			}
		end,
		stream = function(request: HttpRequest, sink: StreamSink): () -> ()
			local ok, client = pcall(function()
				return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.RawStream, {
					Url = request.url,
					Method = request.method,
					Headers = request.headers,
					Body = request.body,
				})
			end)
			if not ok then
				error(newError("unsupported", `streaming is unavailable here: {client}`))
			end
			local connections: { RBXScriptConnection } = {}
			local finished = false
			local errorStatus: number? = nil
			local errorBody: { string } = {}
			local function finish(): boolean
				if finished then
					return false
				end
				finished = true
				for _, connection in connections do
					connection:Disconnect()
				end
				return true
			end
			table.insert(
				connections,
				client.Opened:Connect(function(status: number)
					if status >= 400 then
						errorStatus = status
					end
				end)
			)
			table.insert(
				connections,
				client.MessageReceived:Connect(function(message: string)
					if errorStatus then
						table.insert(errorBody, message)
					else
						sink.onData(message)
					end
				end)
			)
			table.insert(
				connections,
				client.Error:Connect(function(status: number, message: string)
					if finish() then
						sink.onError(if status > 0 then status else nil, message)
					end
				end)
			)
			table.insert(
				connections,
				client.Closed:Connect(function()
					if finish() then
						local status = errorStatus
						if status then
							sink.onError(status, table.concat(errorBody))
						else
							sink.onClose()
						end
					end
				end)
			)
			return function()
				if finish() then
					pcall(function()
						client:Close()
					end)
				end
			end
		end,
		socket = function(url: string, headers: Headers, sink: SocketSink, timeout: number): RawSocket
			local ok, client = pcall(function()
				return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
					Url = url,
					Headers = headers,
				})
			end)
			if not ok then
				error(newError("unsupported", `WebSockets are unavailable here: {client}`))
			end
			local state: "connecting" | "open" | "closed" = "connecting"
			local failure: AIError? = nil
			local waiting: thread? = nil
			local connections: { RBXScriptConnection } = {}
			local function wake()
				local thread = waiting
				if thread then
					waiting = nil
					task.spawn(thread)
				end
			end
			local function shutdown(code: number?, reason: string?)
				local wasOpen = state == "open"
				state = "closed"
				for _, connection in connections do
					connection:Disconnect()
				end
				if wasOpen then
					sink.onClose(code, reason)
				end
			end
			table.insert(
				connections,
				client.Opened:Connect(function()
					if state == "connecting" then
						state = "open"
						wake()
					end
				end)
			)
			table.insert(
				connections,
				client.MessageReceived:Connect(function(message: string)
					if state == "open" then
						sink.onMessage(message)
					end
				end)
			)
			table.insert(
				connections,
				client.Error:Connect(function(status: number, message: string)
					if state == "connecting" then
						failure = newError("network", `WebSocket failed to open: {message}`, {
							status = if status > 0 then status else nil,
							retryable = true,
						})
						shutdown()
						wake()
					else
						shutdown(status, message)
					end
				end)
			)
			table.insert(
				connections,
				client.Closed:Connect(function()
					if state == "connecting" then
						failure = newError("network", "WebSocket closed before it opened", { retryable = true })
						shutdown()
						wake()
					else
						shutdown(1000, "closed")
					end
				end)
			)
			task.delay(timeout, function()
				if state == "connecting" then
					failure =
						newError("network", `WebSocket did not open within {timeout} seconds`, { retryable = true })
					shutdown()
					pcall(function()
						client:Close()
					end)
					wake()
				end
			end)
			if state == "connecting" then
				waiting = coroutine.running()
				coroutine.yield()
			end
			if failure then
				error(failure)
			end
			return {
				send = function(message: string)
					if state ~= "open" then
						error(newError("closed", "the WebSocket is closed"))
					end
					client:Send(message)
				end,
				close = function()
					if state ~= "closed" then
						shutdown(1000, "closed by client")
						pcall(function()
							client:Close()
						end)
					end
				end,
				isOpen = function(): boolean
					return state == "open"
				end,
			}
		end,
		decodeJson = function(text: string): any
			return HttpService:JSONDecode(text)
		end,
		spawn = function(callback: () -> ())
			task.spawn(callback)
		end,
		resume = function(thread: thread)
			task.spawn(thread)
		end,
		wait = function(seconds: number)
			task.wait(seconds)
		end,
		delay = function(seconds: number, callback: () -> ())
			task.delay(seconds, callback)
		end,
		secret = function(name: string): ApiKey?
			local ok, secret = pcall(function()
				return HttpService:GetSecret(name)
			end)
			return if ok then secret else nil
		end,
	}
end

type LuneTcpStream = {
	write: (self: LuneTcpStream, data: string | buffer) -> (),
	read: (self: LuneTcpStream, size: number?) -> string?,
	close: (self: LuneTcpStream) -> (),
}

type LuneNet = {
	request: (
		params: {
			url: string,
			method: HttpMethod,
			headers: { [string]: string },
			body: string?,
		}
	) -> { statusCode: number, statusMessage: string, headers: { [string]: any }, body: string },
	tcp: { connect: (host: string, port: number, config: { tls: boolean }) -> LuneTcpStream },
}

type LuneSerde = { decode: (format: "json", encoded: string) -> any }

type LuneTask = {
	spawn: (callback: thread | () -> ()) -> thread,
	wait: (seconds: number?) -> number,
	delay: (seconds: number, callback: () -> ()) -> thread,
}

type LuneProcess = { env: { [string]: string? } }

type ParsedUrl = { scheme: string, host: string, port: number, path: string, secure: boolean, hostHeader: string }

local function parseUrl(url: string): ParsedUrl
	local scheme, rest = string.match(url, "^(%a[%w+.-]*)://(.*)$")
	if scheme == nil or rest == nil then
		error(newError("config", `invalid URL '{url}'`))
	end
	local lowerScheme = string.lower(scheme)
	local authority: string = string.match(rest, "^([^/?#]*)") or ""
	local path: string = string.match(rest, "^[^/?#]*([^#]*)") or ""
	authority = string.gsub(authority, "^.*@", "")
	if path == "" then
		path = "/"
	elseif string.sub(path, 1, 1) == "?" then
		path = "/" .. path
	end
	local host, port = string.match(authority, "^%[(.+)%]:?(%d*)$")
	if host == nil then
		host, port = string.match(authority, "^([^:]+):?(%d*)$")
	end
	if host == nil then
		error(newError("config", `invalid URL host in '{url}'`))
	end
	local secure = lowerScheme == "https" or lowerScheme == "wss"
	local defaultPort = if secure then 443 else 80
	local portNumber = tonumber(port or "") or defaultPort
	local hostHeader = if portNumber == defaultPort then (string.gsub(authority, ":%d+$", "")) else authority
	return {
		scheme = lowerScheme,
		host = host,
		port = portNumber,
		path = path,
		secure = secure,
		hostHeader = hostHeader,
	}
end

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(input: string): string
	local out: { string } = {}
	for index = 1, #input, 3 do
		local a, b, c = string.byte(input, index, index + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local chars = {}
		for shift = 3, 0, -1 do
			local sextet = (n // (64 ^ shift)) % 64
			table.insert(chars, string.sub(BASE64_ALPHABET, sextet + 1, sextet + 1))
		end
		if c == nil then
			chars[4] = "="
		end
		if b == nil then
			chars[3] = "="
		end
		table.insert(out, table.concat(chars))
	end
	return table.concat(out)
end

local function randomBytes(count: number): string
	local bytes = table.create(count, 0)
	for index = 1, count do
		bytes[index] = math.random(0, 255)
	end
	return string.char(table.unpack(bytes))
end

local function applyMask(payload: string, key: string): string
	local data = buffer.fromstring(payload)
	local k1, k2, k3, k4 = string.byte(key, 1, 4)
	local keys = { k1, k2, k3, k4 }
	for index = 0, #payload - 1 do
		buffer.writeu8(data, index, bit32.bxor(buffer.readu8(data, index), keys[index % 4 + 1]))
	end
	return buffer.tostring(data)
end

-- Reads an HTTP/1.1 status line and headers, returning any bytes already read past them.
local function readHttpHead(connection: LuneTcpStream): (number, string, { [string]: string }, string)
	local data = ""
	while true do
		local headEnd = string.find(data, "\r\n\r\n", 1, true)
		if headEnd then
			local lines = string.split(string.sub(data, 1, headEnd - 1), "\r\n")
			local code, message = string.match(lines[1], "^HTTP/[%d%.]+ (%d%d%d) ?(.*)$")
			if code == nil then
				error(newError("network", `malformed HTTP status line '{lines[1]}'`))
			end
			local headers: { [string]: string } = {}
			for index = 2, #lines do
				local name, value = string.match(lines[index], "^([^:]+):%s*(.-)%s*$")
				if name and value then
					local key = string.lower(name)
					headers[key] = if headers[key] then headers[key] .. ", " .. value else value
				end
			end
			return tonumber(code) or 0, message or "", headers, string.sub(data, headEnd + 4)
		end
		local chunk = connection:read()
		if chunk == nil then
			error(newError("network", "connection closed before the response headers arrived", { retryable = true }))
		end
		data ..= chunk
	end
end

-- Incrementally decodes an HTTP/1.1 response body. `feed` returns true once the body is complete.
local function newBodyDecoder(headers: { [string]: string }, emit: (chunk: string) -> ()): (chunk: string) -> boolean
	local transferEncoding = string.lower(headers["transfer-encoding"] or "")
	if string.find(transferEncoding, "chunked", 1, true) then
		local pending = ""
		local state: "size" | "data" | "crlf" = "size"
		local remaining = 0
		return function(chunk: string): boolean
			pending ..= chunk
			while true do
				if state == "size" then
					local lineEnd = string.find(pending, "\r\n", 1, true)
					if lineEnd == nil then
						return false
					end
					local size = tonumber(string.match(string.sub(pending, 1, lineEnd - 1), "^%s*(%x+)") or "", 16)
					if size == nil then
						error(newError("parse", "malformed chunked transfer encoding"))
					end
					pending = string.sub(pending, lineEnd + 2)
					if size == 0 then
						return true
					end
					remaining = size
					state = "data"
				elseif state == "data" then
					if pending == "" then
						return false
					end
					local take = math.min(remaining, #pending)
					emit(string.sub(pending, 1, take))
					pending = string.sub(pending, take + 1)
					remaining -= take
					if remaining == 0 then
						state = "crlf"
					end
				else
					if #pending < 2 then
						return false
					end
					pending = string.sub(pending, 3)
					state = "size"
				end
			end
		end
	end
	local contentLength = tonumber(headers["content-length"] or "")
	if contentLength then
		local remaining = contentLength
		return function(chunk: string): boolean
			if remaining > 0 and chunk ~= "" then
				local take = string.sub(chunk, 1, remaining)
				remaining -= #take
				emit(take)
			end
			return remaining <= 0
		end
	end
	return function(chunk: string): boolean
		if chunk ~= "" then
			emit(chunk)
		end
		return false
	end
end

local function stringHeaders(headers: Headers): { [string]: string }
	local out: { [string]: string } = {}
	for key, value in headers do
		if typeof(value) == "string" then
			out[key] = value
		else
			error(newError("config", "Roblox Secrets can only be used on Roblox"))
		end
	end
	return out
end

local function createLuneRuntime(): Runtime
	local dynamicRequire: any = require
	local net: LuneNet = dynamicRequire("@lune/net")
	local serde: LuneSerde = dynamicRequire("@lune/serde")
	local luneTask: LuneTask = dynamicRequire("@lune/task")
	local process: LuneProcess = dynamicRequire("@lune/process")

	local function connect(url: ParsedUrl): LuneTcpStream
		local ok, connection = pcall(net.tcp.connect, url.host, url.port, { tls = url.secure })
		if not ok then
			error(newError("network", `could not connect to {url.host}:{url.port}: {connection}`, { retryable = true }))
		end
		return connection
	end

	local function writeHead(lines: { string }, headers: { [string]: string }): string
		for name, value in headers do
			if string.find(name, "[\r\n]") or string.find(value, "[\r\n]") then
				error(newError("config", `header '{name}' contains a line break`))
			end
			table.insert(lines, `{name}: {value}`)
		end
		table.insert(lines, "")
		table.insert(lines, "")
		return table.concat(lines, "\r\n")
	end

	return {
		name = "lune",
		request = function(request: HttpRequest): HttpResponse
			local ok, result = pcall(net.request, {
				url = request.url,
				method = request.method,
				headers = stringHeaders(request.headers),
				body = request.body,
			})
			if not ok then
				error(asError(result, "network"))
			end
			local headers: { [string]: string } = {}
			for key, value in result.headers do
				headers[string.lower(key)] = if type(value) == "table"
					then table.concat(value, ", ")
					else tostring(value)
			end
			return {
				status = result.statusCode,
				statusMessage = result.statusMessage,
				headers = headers,
				body = result.body,
			}
		end,
		stream = function(request: HttpRequest, sink: StreamSink): () -> ()
			local url = parseUrl(request.url)
			local headers = stringHeaders(request.headers)
			local cancelled = false
			local connection: LuneTcpStream? = nil
			luneTask.spawn(function()
				local ok, err = pcall(function(): unknown
					local stream = connect(url)
					connection = stream
					if cancelled then
						stream:close()
						return nil
					end
					local body = request.body or ""
					headers["Host"] = url.hostHeader
					headers["Connection"] = "close"
					headers["Accept-Encoding"] = "identity"
					headers["Content-Length"] = tostring(#body)
					stream:write(writeHead({ `{request.method} {url.path} HTTP/1.1` }, headers) .. body)
					local status, statusMessage, responseHeaders, rest = readHttpHead(stream)
					local failed = status >= 400
					local collected: { string } = {}
					local feed = newBodyDecoder(responseHeaders, function(chunk: string)
						if failed then
							table.insert(collected, chunk)
						elseif not cancelled then
							sink.onData(chunk)
						end
					end)
					local done = feed(rest)
					while not done and not cancelled do
						local chunk = stream:read()
						if chunk == nil then
							break
						end
						done = feed(chunk)
					end
					pcall(stream.close, stream)
					if cancelled then
						return nil
					end
					if failed then
						local text = table.concat(collected)
						sink.onError(status, if text == "" then statusMessage else text)
					else
						sink.onClose()
					end
					return nil
				end)
				if not ok and not cancelled then
					sink.onError(nil, if isError(err) then (err :: any).Message else tostring(err))
				end
			end)
			return function()
				cancelled = true
				local stream = connection
				if stream then
					pcall(stream.close, stream)
				end
			end
		end,
		socket = function(urlString: string, headers: Headers, sink: SocketSink, _timeout: number): RawSocket
			local url = parseUrl(urlString)
			local stream = connect(url)
			local handshake = stringHeaders(headers)
			handshake["Host"] = url.hostHeader
			handshake["Upgrade"] = "websocket"
			handshake["Connection"] = "Upgrade"
			handshake["Sec-WebSocket-Key"] = base64Encode(randomBytes(16))
			handshake["Sec-WebSocket-Version"] = "13"
			local okHandshake, status, statusMessage, _responseHeaders, rest = pcall(function()
				stream:write(writeHead({ `GET {url.path} HTTP/1.1` }, handshake))
				return readHttpHead(stream)
			end)
			if not okHandshake then
				pcall(stream.close, stream)
				error(asError(status, "network"))
			end
			if status ~= 101 then
				local text = rest
				if text == "" then
					local okRead, more = pcall(stream.read, stream)
					text = if okRead and more then more else ""
				end
				pcall(stream.close, stream)
				local message = `WebSocket upgrade failed: {status} {statusMessage}`
				local code: string? = nil
				local errorType: string? = nil
				local okDecode, decoded = pcall(function(): any
					return serde.decode("json", text)
				end)
				if okDecode and type(decoded) == "table" and type(decoded.error) == "table" then
					local inner = decoded.error
					if type(inner.message) == "string" then
						message = inner.message
					end
					code = if type(inner.code) == "string" then inner.code else nil
					errorType = if type(inner.type) == "string" then inner.type else nil
				end
				error(newError("http", message, {
					status = status,
					code = code,
					errorType = errorType,
					body = text,
					retryable = status == 429 or status >= 500,
				}))
			end

			local open = true
			local function sendFrame(opcode: number, payload: string)
				local length = #payload
				local header
				if length < 126 then
					header = string.char(0x80 + opcode, 0x80 + length)
				elseif length < 65536 then
					header = string.char(0x80 + opcode, 0x80 + 126, length // 256, length % 256)
				else
					header = string.char(0x80 + opcode, 0x80 + 127, 0, 0, 0, 0)
						.. string.char(
							length // 16777216 % 256,
							length // 65536 % 256,
							length // 256 % 256,
							length % 256
						)
				end
				local key = randomBytes(4)
				stream:write(header .. key .. applyMask(payload, key))
			end
			local function shutdown(code: number?, reason: string?)
				if not open then
					return
				end
				open = false
				pcall(stream.close, stream)
				sink.onClose(code, reason)
			end

			luneTask.spawn(function()
				local pending = rest
				local fragments: { string } = {}
				local function processFrames(): unknown
					while open do
						if #pending < 2 then
							return nil
						end
						local b1, b2 = string.byte(pending, 1, 2)
						local fin = bit32.band(b1, 0x80) ~= 0
						local opcode = bit32.band(b1, 0x0F)
						local masked = bit32.band(b2, 0x80) ~= 0
						local length = bit32.band(b2, 0x7F)
						local offset = 3
						if length == 126 then
							if #pending < 4 then
								return nil
							end
							local h, l = string.byte(pending, 3, 4)
							length = h * 256 + l
							offset = 5
						elseif length == 127 then
							if #pending < 10 then
								return nil
							end
							length = 0
							for index = 3, 10 do
								length = length * 256 + string.byte(pending, index)
							end
							offset = 11
						end
						local maskKey = ""
						if masked then
							if #pending < offset + 3 then
								return nil
							end
							maskKey = string.sub(pending, offset, offset + 3)
							offset += 4
						end
						if #pending < offset + length - 1 then
							return nil
						end
						local payload = string.sub(pending, offset, offset + length - 1)
						pending = string.sub(pending, offset + length)
						if masked then
							payload = applyMask(payload, maskKey)
						end
						if opcode == 0x1 or opcode == 0x2 or opcode == 0x0 then
							table.insert(fragments, payload)
							if fin then
								local message = table.concat(fragments)
								fragments = {}
								sink.onMessage(message)
							end
						elseif opcode == 0x8 then
							local code = if #payload >= 2
								then string.byte(payload, 1) * 256 + string.byte(payload, 2)
								else 1005
							pcall(sendFrame, 0x8, string.sub(payload, 1, 2))
							shutdown(code, string.sub(payload, 3))
						elseif opcode == 0x9 then
							pcall(sendFrame, 0xA, payload)
						end
					end
					return nil
				end
				while open do
					local okProcess, processError = pcall(processFrames)
					if not okProcess then
						shutdown(1011, tostring(processError))
						break
					end
					if not open then
						break
					end
					local okRead, chunk = pcall(stream.read, stream)
					if not okRead or chunk == nil then
						shutdown(1006, "connection lost")
						break
					end
					pending ..= chunk
				end
			end)

			return {
				send = function(message: string)
					if not open then
						error(newError("closed", "the WebSocket is closed"))
					end
					sendFrame(0x1, message)
				end,
				close = function()
					if open then
						pcall(sendFrame, 0x8, string.char(0x03, 0xE8))
						shutdown(1000, "closed by client")
					end
				end,
				isOpen = function(): boolean
					return open
				end,
			}
		end,
		decodeJson = function(text: string): any
			return serde.decode("json", text)
		end,
		spawn = function(callback: () -> ())
			luneTask.spawn(callback)
		end,
		resume = function(thread: thread)
			luneTask.spawn(thread)
		end,
		wait = function(seconds: number)
			luneTask.wait(seconds)
		end,
		delay = function(seconds: number, callback: () -> ())
			luneTask.delay(seconds, callback)
		end,
		secret = function(name: string): ApiKey?
			local value = process.env[name]
			return if value and value ~= "" then value else nil
		end,
	}
end

local Runtime: Runtime = if IS_ROBLOX then createRobloxRuntime() else createLuneRuntime()

local function decodeJson(text: string): any
	local ok, value = pcall(Runtime.decodeJson, text)
	if not ok then
		error(newError("parse", `invalid JSON from the API: {value}`, { body = text }))
	end
	return value
end

--------------------------------------------------------------------------------
-- Server-sent events
--------------------------------------------------------------------------------

type SseParser = { push: (chunk: string) -> (), flush: () -> () }

-- Both providers send one JSON object per `data:` line, so events dispatch per line. A trailing line that
-- has not seen its newline yet is still dispatched once it is complete JSON, which covers transports that
-- deliver SSE one line per message without the line terminator.
local function newSseParser(onEvent: (eventName: string?, data: string) -> ()): SseParser
	local pending = ""
	local eventName: string? = nil

	local function processLine(line: string)
		if line == "" then
			eventName = nil
			return
		end
		if string.sub(line, 1, 1) == ":" then
			return
		end
		local field, value = string.match(line, "^([^:]*):? ?(.*)$")
		if field == "event" then
			eventName = value
		elseif field == "data" and value and value ~= "" then
			onEvent(eventName, value)
		end
	end

	local function isCompleteDataLine(line: string): boolean
		if string.sub(line, 1, 5) ~= "data:" or not string.match(line, "[%]}]%s*$") then
			return false
		end
		local ok = pcall(Runtime.decodeJson, (string.gsub(line, "^data: ?", "")))
		return ok
	end

	return {
		push = function(chunk: string)
			pending ..= chunk
			while true do
				local newline = string.find(pending, "\n", 1, true)
				if newline == nil then
					break
				end
				local line = string.sub(pending, 1, newline - 1)
				pending = string.sub(pending, newline + 1)
				processLine((string.gsub(line, "\r$", "")))
			end
			if pending ~= "" then
				local line = string.gsub(pending, "\r$", "")
				if isCompleteDataLine(line) then
					pending = ""
					processLine(line)
				end
			end
		end,
		flush = function()
			if pending ~= "" then
				local line = pending
				pending = ""
				processLine((string.gsub(line, "\r$", "")))
			end
		end,
	}
end

--------------------------------------------------------------------------------
-- Streams
--------------------------------------------------------------------------------

type StreamControl = {
	stream: Stream,
	emit: (event: StreamEvent) -> (),
	finish: (err: AIError?) -> (),
	onFinish: (callback: () -> ()) -> (),
	finished: () -> boolean,
}

local function newStream(
	onEvent: ((event: StreamEvent) -> ())?,
	guard: ((response: Response) -> AIError?)?
): StreamControl
	local queue: { StreamEvent } = {}
	local head = 1
	local tail = 0
	local closed = false
	local isFinished = false
	local finalError: AIError? = nil
	local waiters: { thread } = {}
	local hooks: { () -> () } = {}

	local function wake()
		local threads = waiters
		waiters = {}
		for _, thread in threads do
			Runtime.resume(thread)
		end
	end

	local stream: Stream

	local function deliver(event: StreamEvent)
		if event.Type == "text" then
			stream.Text ..= event.Delta
		end
		tail += 1
		queue[tail] = event
		wake()
		if onEvent then
			onEvent(event)
		end
	end

	local function finish(err: AIError?)
		if isFinished then
			return
		end
		isFinished = true
		if err then
			finalError = err
			if err.Kind ~= "cancelled" then
				deliver({ Type = "error", Error = err })
			end
		end
		closed = true
		wake()
		for _, hook in hooks do
			pcall(hook)
		end
		table.clear(hooks)
	end

	local function emit(event: StreamEvent)
		if isFinished then
			return
		end
		if event.Type == "error" then
			finish(event.Error)
		elseif event.Type == "done" then
			if guard then
				local okGuard, guardError = pcall(guard, event.Response)
				local failure = if okGuard then guardError else asError(guardError, "moderation")
				if failure then
					finish(failure)
					return
				end
			end
			stream.Response = event.Response
			stream.Text = event.Response.Text
			deliver(event)
			finish(nil)
		else
			deliver(event)
		end
	end

	local function nextEvent(_self: Stream): StreamEvent?
		while true do
			if head <= tail then
				local event = queue[head]
				queue[head] = nil
				head += 1
				return event
			end
			if closed then
				return nil
			end
			table.insert(waiters, coroutine.running())
			coroutine.yield()
		end
	end

	stream = {
		Text = "",
		Response = nil,
		Next = nextEvent,
		Iter = function(self: Stream): () -> StreamEvent?
			return function(): StreamEvent?
				return nextEvent(self)
			end
		end,
		Await = function(self: Stream): Response
			while true do
				local event = nextEvent(self)
				if event == nil then
					break
				elseif event.Type == "done" then
					return event.Response
				elseif event.Type == "error" then
					error(event.Error)
				end
			end
			local response = self.Response
			if response then
				return response
			end
			error(finalError or newError("cancelled", "the stream was cancelled"))
		end,
		Cancel = function(_self: Stream)
			finish(newError("cancelled", "the stream was cancelled"))
		end,
	}

	return {
		stream = stream,
		emit = emit,
		finish = finish,
		onFinish = function(callback: () -> ())
			if isFinished then
				pcall(callback)
			else
				table.insert(hooks, callback)
			end
		end,
		finished = function(): boolean
			return isFinished
		end,
	}
end

-- Replays a complete response as stream events, for runtimes where streaming is unavailable.
local function emitResponse(response: Response, emit: (event: StreamEvent) -> ())
	emit({ Type = "start", Id = response.Id, Model = response.Model })
	for index, part in response.Content do
		if part.Type == "text" then
			emit({ Type = "text", Delta = part.Text, Index = index })
		elseif part.Type == "thinking" then
			emit({ Type = "thinking", Delta = part.Text, Index = index })
		elseif part.Type == "refusal" then
			emit({ Type = "refusal", Delta = part.Text, Index = index })
		elseif part.Type == "tool_call" then
			emit({ Type = "tool_call_start", Index = index, Id = part.Id, Name = part.Name })
			emit({ Type = "tool_call_delta", Index = index, Delta = part.RawArguments })
			emit({ Type = "tool_call", Index = index, Call = part })
		end
	end
	emit({ Type = "done", Response = response })
end

--------------------------------------------------------------------------------
-- Formats
--------------------------------------------------------------------------------

local knownFormats: { [Format]: boolean } = {}

local function newFormat(name: string, protocol: Protocol, version: string?): Format
	local format: Format = table.freeze({ Name = name, Protocol = protocol, Version = version })
	knownFormats[format] = true
	return format
end

local ANTHROPIC_2023_06_01 = newFormat("Anthropic 2023-06-01", "anthropic", "2023-06-01")
local OPENAI_RESPONSES = newFormat("OpenAI Responses", "openai", nil)

local FORMATS: Formats = table.freeze({
	Anthropic = table.freeze({
		V2023_06_01 = ANTHROPIC_2023_06_01,
		["2023-06-01"] = ANTHROPIC_2023_06_01,
		Latest = ANTHROPIC_2023_06_01,
	}),
	OpenAI = table.freeze({
		Responses = OPENAI_RESPONSES,
		Latest = OPENAI_RESPONSES,
	}),
})

--------------------------------------------------------------------------------
-- Shared adapter helpers
--------------------------------------------------------------------------------

type ResolvedConfig = {
	format: Format,
	protocol: Protocol,
	baseUrl: string,
	apiKey: ApiKey?,
	headers: { [string]: string },
	defaultModel: string?,
	maxTokens: number,
	maxRetries: number,
	transport: Transport,
	streamFallback: boolean,
	connectTimeout: number,
	anthropicBeta: { string }?,
	organization: string?,
	project: string?,
	moderation: ModerationGuard?,
}

type StreamHandler = (data: any, emit: (event: StreamEvent) -> ()) -> boolean

-- Translates between AI.luau's types and one wire protocol.
type Adapter = {
	path: string,
	buildBody: (config: ResolvedConfig, request: Request, stream: boolean) -> { [string]: any },
	parseResponse: (format: Format, raw: any) -> Response,
	newStreamHandler: (format: Format) -> StreamHandler,
}

local function optionalString(value: any): string?
	if type(value) == "string" then
		return value
	elseif type(value) == "number" then
		return tostring(value)
	end
	return nil
end

local function errorFromBody(kind: AIErrorKind, status: number?, body: string, retryable: boolean): AIError
	local message: string? = nil
	local code: string? = nil
	local errorType: string? = nil
	local ok, decoded = pcall(Runtime.decodeJson, body)
	if ok and type(decoded) == "table" then
		local inner = decoded.error
		if type(inner) == "table" then
			message = optionalString(inner.message)
			code = optionalString(inner.code)
			errorType = optionalString(inner.type)
		elseif type(inner) == "string" then
			message = inner
		end
		message = message or optionalString(decoded.message)
	end
	if message == nil then
		message = if body ~= "" then string.sub(body, 1, 500) elseif status then `HTTP {status}` else "request failed"
	end
	return newError(kind, message :: string, {
		status = status,
		code = code,
		errorType = errorType,
		body = body,
		retryable = retryable,
	})
end

local function isRetryableStatus(status: number): boolean
	return status == 408 or status == 409 or status == 429 or status >= 500
end

local RETRYABLE_ERROR_TYPES: { [string]: boolean } = {
	overloaded_error = true,
	rate_limit_error = true,
	api_error = true,
	server_error = true,
	rate_limit_exceeded = true,
}

-- Builds an error from an `error` stream event of either protocol.
local function errorFromEvent(data: any): AIError
	local inner = if type(data.error) == "table" then data.error else data
	local code = optionalString(inner.code)
	local errorType = optionalString(inner.type)
	local status = if type(data.status) == "number" then data.status else nil
	return newError("api", optionalString(inner.message) or "the API reported an error", {
		status = status,
		code = code,
		errorType = errorType,
		retryable = RETRYABLE_ERROR_TYPES[errorType or ""] == true
			or RETRYABLE_ERROR_TYPES[code or ""] == true
			or (status ~= nil and isRetryableStatus(status)),
	})
end

local function collectMessages(request: Request): { Message }
	local messages: { Message } = table.clone(request.Messages or {})
	if request.Prompt then
		table.insert(messages, { Role = "user", Content = request.Prompt })
	end
	if #messages == 0 and request.PreviousResponseId == nil then
		error(newError("config", "a request needs `Prompt` or `Messages`"))
	end
	return messages
end

local function collectSystem(request: Request, messages: { Message }): string?
	local parts: { string } = {}
	if request.System then
		table.insert(parts, request.System)
	end
	for _, message in messages do
		if message.Role == "system" then
			local content = message.Content
			if type(content) == "string" then
				table.insert(parts, content)
			else
				for _, part in content do
					if part.Type == "text" then
						table.insert(parts, part.Text)
					end
				end
			end
		end
	end
	return if #parts > 0 then table.concat(parts, "\n\n") else nil
end

local function requireModel(config: ResolvedConfig, request: Request): string
	local model = request.Model or config.defaultModel
	if model == nil then
		error(newError("config", "no model given; set `Model` on the request or `DefaultModel` on the provider"))
	end
	return model
end

local function mergeExtra(body: { [string]: any }, request: Request): { [string]: any }
	if request.Extra then
		for key, value in request.Extra do
			body[key] = value
		end
	end
	return markObject(body)
end

local function parseArguments(text: string): { [string]: any }
	if text == "" then
		return markObject({})
	end
	local ok, value = pcall(Runtime.decodeJson, text)
	if ok and type(value) == "table" then
		return markObject(value)
	end
	return markObject({})
end

local function buildResponse(
	format: Format,
	id: string,
	model: string,
	content: { ContentPart },
	stopReason: StopReason,
	usage: Usage,
	raw: any
): Response
	local texts: { string } = {}
	local toolCalls: { ToolCallPart } = {}
	for _, part in content do
		if part.Type == "text" then
			table.insert(texts, part.Text)
		elseif part.Type == "tool_call" then
			table.insert(toolCalls, part)
		end
	end
	return {
		Id = id,
		Model = model,
		Format = format,
		Content = content,
		Text = table.concat(texts),
		ToolCalls = toolCalls,
		StopReason = stopReason,
		Usage = usage,
		Raw = raw,
	}
end

local function numberOr(value: any, default: number): number
	return if type(value) == "number" then value else default
end

local function imageDataUri(part: ImagePart): string?
	if part.Url then
		return part.Url
	elseif part.Data then
		return `data:{part.MediaType or "image/png"};base64,{part.Data}`
	end
	return nil
end

--------------------------------------------------------------------------------
-- Anthropic Messages API
--------------------------------------------------------------------------------

local function anthropicBlocks(content: string | { ContentPart }): any
	if type(content) == "string" then
		return content
	end
	local blocks: { any } = {}
	for _, part in content do
		if part.Type == "text" then
			table.insert(blocks, { type = "text", text = part.Text })
		elseif part.Type == "image" then
			if part.Url then
				table.insert(blocks, { type = "image", source = { type = "url", url = part.Url } })
			elseif part.Data then
				table.insert(blocks, {
					type = "image",
					source = { type = "base64", media_type = part.MediaType or "image/png", data = part.Data },
				})
			end
		elseif part.Type == "tool_call" then
			table.insert(
				blocks,
				{ type = "tool_use", id = part.Id, name = part.Name, input = markObject(part.Arguments) }
			)
		elseif part.Type == "tool_result" then
			table.insert(blocks, {
				type = "tool_result",
				tool_use_id = part.ToolCallId,
				content = part.Content,
				is_error = if part.IsError then true else nil,
			})
		elseif part.Type == "refusal" then
			table.insert(blocks, { type = "text", text = part.Text })
		elseif (part.Type == "thinking" or part.Type == "raw") and part.Protocol == "anthropic" then
			local raw = part.Raw
			if type(raw) == "table" and type(raw.input) == "table" then
				markObject(raw.input)
			end
			table.insert(blocks, markObject(raw))
		end
	end
	return blocks
end

local ANTHROPIC_STOP_REASONS: { [string]: StopReason } = {
	end_turn = "stop",
	stop_sequence = "stop",
	max_tokens = "length",
	model_context_window_exceeded = "length",
	tool_use = "tool_calls",
	refusal = "refusal",
	pause_turn = "pause",
}

local function anthropicUsage(raw: any): Usage
	local usage = if type(raw) == "table" then raw else {}
	local input = numberOr(usage.input_tokens, 0)
	local output = numberOr(usage.output_tokens, 0)
	return {
		InputTokens = input,
		OutputTokens = output,
		TotalTokens = input + output,
		CacheReadTokens = usage.cache_read_input_tokens,
		CacheWriteTokens = usage.cache_creation_input_tokens,
	}
end

local function anthropicPart(block: any): ContentPart
	local kind = block.type
	if kind == "text" then
		return { Type = "text", Text = block.text or "" }
	elseif kind == "tool_use" then
		local input = if type(block.input) == "table" then block.input else {}
		return {
			Type = "tool_call",
			Id = block.id,
			Name = block.name,
			Arguments = markObject(input),
			RawArguments = encodeJson(markObject(input)),
		}
	elseif kind == "thinking" then
		return { Type = "thinking", Text = block.thinking or "", Protocol = "anthropic", Raw = block }
	elseif kind == "redacted_thinking" then
		return { Type = "thinking", Text = "", Protocol = "anthropic", Raw = block }
	end
	return { Type = "raw", Protocol = "anthropic", Raw = block }
end

local AnthropicAdapter: Adapter = {
	path = "/messages",
	buildBody = function(config: ResolvedConfig, request: Request, stream: boolean): { [string]: any }
		local messages = collectMessages(request)
		local wire: { any } = {}
		for _, message in messages do
			if message.Role ~= "system" then
				table.insert(wire, { role = message.Role, content = anthropicBlocks(message.Content) })
			end
		end
		local body: { [string]: any } = {
			model = requireModel(config, request),
			max_tokens = request.MaxTokens or config.maxTokens,
			messages = wire,
			system = collectSystem(request, messages),
			temperature = request.Temperature,
			top_p = request.TopP,
			stop_sequences = request.Stop,
			stream = if stream then true else nil,
		}
		local tools = request.Tools
		if tools and #tools > 0 then
			local wireTools: { any } = {}
			for _, tool in tools do
				table.insert(wireTools, {
					name = tool.Name,
					description = tool.Description,
					input_schema = normalizeSchema(tool.Parameters),
				})
			end
			body.tools = wireTools
		end
		local choice = request.ToolChoice
		if choice == "auto" then
			body.tool_choice = { type = "auto" }
		elseif choice == "none" then
			body.tool_choice = { type = "none" }
		elseif choice == "required" then
			body.tool_choice = { type = "any" }
		elseif type(choice) == "table" then
			body.tool_choice = { type = "tool", name = choice.Name }
		end
		local reasoning = request.Reasoning
		if reasoning and reasoning.BudgetTokens then
			body.thinking = { type = "enabled", budget_tokens = reasoning.BudgetTokens }
		end
		if request.PreviousResponseId or request.Store ~= nil then
			error(newError("config", "`PreviousResponseId` and `Store` are only supported by OpenAI formats"))
		end
		return mergeExtra(body, request)
	end,
	parseResponse = function(format: Format, raw: any): Response
		if type(raw) ~= "table" then
			error(newError("parse", "unexpected response shape from the Messages API"))
		end
		if raw.type == "error" then
			error(errorFromEvent(raw))
		end
		local content: { ContentPart } = {}
		for _, block in raw.content or {} do
			table.insert(content, anthropicPart(block))
		end
		return buildResponse(
			format,
			raw.id or "",
			raw.model or "",
			content,
			ANTHROPIC_STOP_REASONS[raw.stop_reason or ""] or "unknown",
			anthropicUsage(raw.usage),
			raw
		)
	end,
	newStreamHandler = function(format: Format): StreamHandler
		type Block = {
			kind: string,
			text: string,
			json: string,
			signature: string?,
			raw: any,
		}
		local message: any = {}
		local usage: { [string]: any } = {}
		local blocks: { [number]: Block } = {}
		local stopReason: string? = nil

		local function finalBlock(block: Block): any
			local raw = table.clone(block.raw)
			if block.kind == "text" then
				raw.text = block.text
			elseif block.kind == "thinking" then
				raw.thinking = block.text
				raw.signature = block.signature
			elseif block.json ~= "" then
				raw.input = parseArguments(block.json)
			end
			return raw
		end

		return function(data: any, emit: (event: StreamEvent) -> ()): boolean
			local kind = data.type
			if kind == "message_start" then
				message = data.message or {}
				for key, value in message.usage or {} do
					usage[key] = value
				end
				emit({ Type = "start", Id = message.id or "", Model = message.model or "" })
			elseif kind == "content_block_start" then
				local index = numberOr(data.index, #blocks) + 1
				local block = data.content_block or {}
				blocks[index] = {
					kind = block.type or "unknown",
					text = block.text or block.thinking or "",
					json = "",
					signature = block.signature,
					raw = block,
				}
				if block.type == "tool_use" then
					emit({ Type = "tool_call_start", Index = index, Id = block.id or "", Name = block.name or "" })
				end
			elseif kind == "content_block_delta" then
				local index = numberOr(data.index, 0) + 1
				local block = blocks[index]
				local delta = data.delta or {}
				if block then
					if delta.type == "text_delta" then
						block.text ..= delta.text
						emit({ Type = "text", Delta = delta.text, Index = index })
					elseif delta.type == "input_json_delta" then
						block.json ..= delta.partial_json
						if block.kind == "tool_use" then
							emit({ Type = "tool_call_delta", Index = index, Delta = delta.partial_json })
						end
					elseif delta.type == "thinking_delta" then
						block.text ..= delta.thinking
						emit({ Type = "thinking", Delta = delta.thinking, Index = index })
					elseif delta.type == "signature_delta" then
						block.signature = (block.signature or "") .. delta.signature
					end
				end
			elseif kind == "content_block_stop" then
				local index = numberOr(data.index, 0) + 1
				local block = blocks[index]
				if block and block.kind == "tool_use" then
					local part = anthropicPart(finalBlock(block))
					if part.Type == "tool_call" then
						emit({ Type = "tool_call", Index = index, Call = part })
					end
				end
			elseif kind == "message_delta" then
				local delta = data.delta or {}
				stopReason = delta.stop_reason or stopReason
				for key, value in data.usage or {} do
					usage[key] = value
				end
			elseif kind == "message_stop" then
				local rawBlocks: { any } = {}
				local content: { ContentPart } = {}
				local count = 0
				for index in blocks do
					count = math.max(count, index)
				end
				for index = 1, count do
					local block = blocks[index]
					if block then
						local raw = finalBlock(block)
						table.insert(rawBlocks, raw)
						table.insert(content, anthropicPart(raw))
					end
				end
				local raw = table.clone(message)
				raw.content = rawBlocks
				raw.stop_reason = stopReason
				raw.usage = usage
				emit({
					Type = "done",
					Response = buildResponse(
						format,
						message.id or "",
						message.model or "",
						content,
						ANTHROPIC_STOP_REASONS[stopReason or ""] or "unknown",
						anthropicUsage(usage),
						raw
					),
				})
				return true
			elseif kind == "error" then
				emit({ Type = "error", Error = errorFromEvent(data) })
				return true
			end
			return false
		end
	end,
}

--------------------------------------------------------------------------------
-- OpenAI Responses API
--------------------------------------------------------------------------------

local function openaiInput(messages: { Message }): { any }
	local items: { any } = {}
	for _, message in messages do
		local role = message.Role
		local content = message.Content
		if role == "system" then
			continue
		elseif type(content) == "string" then
			table.insert(items, { role = role, content = content })
			continue
		end
		local parts: { any } = {}
		local assistantText: { string } = {}
		local function flush()
			if role == "assistant" then
				if #assistantText > 0 then
					table.insert(items, { role = "assistant", content = table.concat(assistantText) })
					assistantText = {}
				end
			elseif #parts > 0 then
				table.insert(items, { role = role, content = parts })
				parts = {}
			end
		end
		for _, part in content do
			if part.Type == "text" or part.Type == "refusal" then
				if role == "assistant" then
					table.insert(assistantText, part.Text)
				else
					table.insert(parts, { type = "input_text", text = part.Text })
				end
			elseif part.Type == "image" then
				local url = imageDataUri(part)
				if url then
					table.insert(parts, { type = "input_image", image_url = url })
				end
			elseif part.Type == "tool_call" then
				flush()
				table.insert(items, {
					type = "function_call",
					id = part.ItemId,
					call_id = part.Id,
					name = part.Name,
					arguments = if part.RawArguments ~= ""
						then part.RawArguments
						else encodeJson(markObject(part.Arguments)),
				})
			elseif part.Type == "tool_result" then
				flush()
				table.insert(items, { type = "function_call_output", call_id = part.ToolCallId, output = part.Content })
			elseif (part.Type == "thinking" or part.Type == "raw") and part.Protocol == "openai" then
				flush()
				table.insert(items, markObject(part.Raw))
			end
		end
		flush()
	end
	return items
end

local function openaiUsage(raw: any): Usage
	local usage = if type(raw) == "table" then raw else {}
	local input = numberOr(usage.input_tokens, 0)
	local output = numberOr(usage.output_tokens, 0)
	local details = usage.input_tokens_details
	return {
		InputTokens = input,
		OutputTokens = output,
		TotalTokens = numberOr(usage.total_tokens, input + output),
		CacheReadTokens = if type(details) == "table" then details.cached_tokens else nil,
		CacheWriteTokens = nil,
	}
end

local function openaiToolCall(item: any): ToolCallPart
	local rawArguments = if type(item.arguments) == "string" then item.arguments else ""
	return {
		Type = "tool_call",
		Id = item.call_id or item.id or "",
		Name = item.name or "",
		Arguments = parseArguments(rawArguments),
		RawArguments = rawArguments,
		ItemId = if type(item.id) == "string" and item.call_id ~= nil then item.id else nil,
	}
end

local function openaiParse(format: Format, raw: any): Response
	if type(raw) ~= "table" then
		error(newError("parse", "unexpected response shape from the Responses API"))
	end
	if raw.status == "failed" then
		error(errorFromEvent(raw))
	end
	local content: { ContentPart } = {}
	for _, item in raw.output or {} do
		local kind = item.type
		if kind == "message" then
			for _, block in item.content or {} do
				if block.type == "output_text" then
					table.insert(content, { Type = "text", Text = block.text or "" })
				elseif block.type == "refusal" then
					table.insert(content, { Type = "refusal", Text = block.refusal or "" })
				end
			end
		elseif kind == "function_call" then
			table.insert(content, openaiToolCall(item))
		elseif kind == "reasoning" then
			local summary: { string } = {}
			for _, entry in item.summary or {} do
				if type(entry.text) == "string" then
					table.insert(summary, entry.text)
				end
			end
			table.insert(content, {
				Type = "thinking",
				Text = table.concat(summary, "\n\n"),
				Protocol = "openai",
				Raw = item,
			})
		else
			table.insert(content, { Type = "raw", Protocol = "openai", Raw = item })
		end
	end
	local stopReason: StopReason = "unknown"
	if raw.status == "completed" then
		stopReason = "stop"
		for _, part in content do
			if part.Type == "tool_call" then
				stopReason = "tool_calls"
				break
			elseif part.Type == "refusal" then
				stopReason = "refusal"
			end
		end
	elseif raw.status == "incomplete" then
		local details = raw.incomplete_details
		local reason = if type(details) == "table" then details.reason else nil
		stopReason = if reason == "max_output_tokens"
			then "length"
			elseif reason == "content_filter" then "content_filter"
			else "unknown"
	end
	return buildResponse(format, raw.id or "", raw.model or "", content, stopReason, openaiUsage(raw.usage), raw)
end

local OpenAIAdapter: Adapter = {
	path = "/responses",
	buildBody = function(config: ResolvedConfig, request: Request, stream: boolean): { [string]: any }
		if request.Stop then
			error(newError("config", "the Responses API does not support stop sequences"))
		end
		local messages = collectMessages(request)
		local body: { [string]: any } = {
			model = requireModel(config, request),
			input = openaiInput(messages),
			instructions = collectSystem(request, messages),
			max_output_tokens = request.MaxTokens,
			temperature = request.Temperature,
			top_p = request.TopP,
			store = request.Store,
			previous_response_id = request.PreviousResponseId,
			stream = if stream then true else nil,
		}
		local tools = request.Tools
		if tools and #tools > 0 then
			local wireTools: { any } = {}
			for _, tool in tools do
				table.insert(wireTools, {
					type = "function",
					name = tool.Name,
					description = tool.Description,
					parameters = normalizeSchema(tool.Parameters),
					strict = if tool.Strict ~= nil then tool.Strict else false,
				})
			end
			body.tools = wireTools
		end
		local choice = request.ToolChoice
		if type(choice) == "string" then
			body.tool_choice = choice
		elseif type(choice) == "table" then
			body.tool_choice = { type = "function", name = choice.Name }
		end
		local reasoning = request.Reasoning
		if reasoning and (reasoning.Effort or reasoning.Summary) then
			body.reasoning = { effort = reasoning.Effort, summary = reasoning.Summary }
		end
		return mergeExtra(body, request)
	end,
	parseResponse = openaiParse,
	newStreamHandler = function(format: Format): StreamHandler
		return function(data: any, emit: (event: StreamEvent) -> ()): boolean
			local kind = data.type
			local index = numberOr(data.output_index, 0) + 1
			if kind == "response.created" then
				local response = data.response or {}
				emit({ Type = "start", Id = response.id or "", Model = response.model or "" })
			elseif kind == "response.output_item.added" then
				local item = data.item or {}
				if item.type == "function_call" then
					emit({ Type = "tool_call_start", Index = index, Id = item.call_id or "", Name = item.name or "" })
				end
			elseif kind == "response.output_text.delta" then
				emit({ Type = "text", Delta = data.delta or "", Index = index })
			elseif kind == "response.refusal.delta" then
				emit({ Type = "refusal", Delta = data.delta or "", Index = index })
			elseif kind == "response.function_call_arguments.delta" then
				emit({ Type = "tool_call_delta", Index = index, Delta = data.delta or "" })
			elseif kind == "response.reasoning_summary_text.delta" or kind == "response.reasoning_text.delta" then
				emit({ Type = "thinking", Delta = data.delta or "", Index = index })
			elseif kind == "response.output_item.done" then
				local item = data.item or {}
				if item.type == "function_call" then
					emit({ Type = "tool_call", Index = index, Call = openaiToolCall(item) })
				end
			elseif kind == "response.completed" or kind == "response.incomplete" then
				emit({ Type = "done", Response = openaiParse(format, data.response) })
				return true
			elseif kind == "response.failed" then
				emit({ Type = "error", Error = errorFromEvent(data.response or data) })
				return true
			elseif kind == "error" then
				emit({ Type = "error", Error = errorFromEvent(data) })
				return true
			end
			return false
		end
	end,
}

--------------------------------------------------------------------------------
-- Moderation
--------------------------------------------------------------------------------

local function moderationInput(input: ModerationInput): any
	if type(input) == "string" then
		return input
	end
	local list = input :: { any }
	if #list == 0 then
		error(newError("config", "moderation input is empty"))
	end
	if type(list[1]) == "string" then
		return list
	end
	local parts: { any } = {}
	for _, part in list :: { ContentPart } do
		if part.Type == "text" or part.Type == "refusal" then
			table.insert(parts, { type = "text", text = part.Text })
		elseif part.Type == "tool_result" then
			table.insert(parts, { type = "text", text = part.Content })
		elseif part.Type == "image" then
			local url = imageDataUri(part)
			if url then
				table.insert(parts, { type = "image_url", image_url = { url = url } })
			end
		end
	end
	if #parts == 0 then
		error(newError("config", "moderation input has no text or image parts"))
	end
	return parts
end

local function toSet(list: { string }?): { [string]: boolean }?
	if list == nil then
		return nil
	end
	local set: { [string]: boolean } = {}
	for _, item in list do
		set[item] = true
	end
	return set
end

local function evaluatePolicy(moderation: ModerationResponse, policy: ContentPolicy?): ContentCheck
	local rules: ContentPolicy = policy or {}
	local allow = toSet(rules.Allow) or {}
	local block = toSet(rules.Block)
	local thresholds = rules.Thresholds or {}
	local violations: { ContentViolation } = {}
	for resultIndex, result in moderation.Results do
		local considered: { [string]: boolean } = {}
		local function consider(category: string)
			if considered[category] or allow[category] or (block and not block[category]) then
				return
			end
			considered[category] = true
			local score = result.Scores[category] or 0
			local threshold = thresholds[category] or rules.DefaultThreshold
			local violated = if threshold then score >= threshold else result.Categories[category] == true
			if violated then
				table.insert(violations, {
					Category = category,
					Score = score,
					Threshold = threshold,
					Result = resultIndex,
				})
			end
		end
		for category in result.Scores do
			consider(category)
		end
		for category in result.Categories do
			consider(category)
		end
	end
	table.sort(violations, function(a: ContentViolation, b: ContentViolation): boolean
		if a.Score ~= b.Score then
			return a.Score > b.Score
		end
		return a.Category < b.Category
	end)
	return {
		Allowed = #violations == 0,
		Flagged = moderation.Flagged,
		Violations = violations,
		Moderation = moderation,
	}
end

local function parseModeration(raw: any): ModerationResponse
	if type(raw) ~= "table" or type(raw.results) ~= "table" then
		error(newError("parse", "unexpected response shape from the moderation API"))
	end
	local results: { ModerationResult } = {}
	local anyFlagged = false
	for _, entry in raw.results do
		local categories: { [string]: boolean } = {}
		for category, flagged in entry.categories or {} do
			categories[category] = flagged == true
		end
		local scores: { [string]: number } = {}
		for category, score in entry.category_scores or {} do
			if type(score) == "number" then
				scores[category] = score
			end
		end
		local flagged = entry.flagged == true
		anyFlagged = anyFlagged or flagged
		table.insert(results, {
			Flagged = flagged,
			Categories = categories,
			Scores = scores,
			AppliedInputTypes = entry.category_applied_input_types or {},
		})
	end
	return { Id = raw.id or "", Model = raw.model or "", Flagged = anyFlagged, Results = results, Raw = raw }
end

-- The content of the latest non-assistant message, which is what an input guard checks.
local function latestUserContent(request: Request): ModerationInput?
	if request.Prompt then
		return request.Prompt
	end
	local messages = request.Messages or {}
	for index = #messages, 1, -1 do
		local message = messages[index]
		if message.Role ~= "assistant" then
			local content = message.Content
			if type(content) == "string" then
				return if content ~= "" then content else nil
			end
			for _, part in content do
				if part.Type == "text" or part.Type == "image" or part.Type == "tool_result" then
					return content
				end
			end
			return nil
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Providers
--------------------------------------------------------------------------------

local DEFAULT_BASE_URLS: { [Protocol]: string } = {
	anthropic = "https://api.anthropic.com/v1",
	openai = "https://api.openai.com/v1",
}

local DEFAULT_SECRET_NAMES: { [Protocol]: string } = {
	anthropic = "ANTHROPIC_API_KEY",
	openai = "OPENAI_API_KEY",
}

local ADAPTERS: { [Protocol]: Adapter } = {
	anthropic = AnthropicAdapter,
	openai = OpenAIAdapter,
}

local DEFAULT_LANE = "\0default"

type ProviderState = {
	config: ResolvedConfig,
	adapter: Adapter,
	provider: Provider?,
}

type SessionState = {
	submit: (request: Request, control: StreamControl) -> (),
	close: () -> (),
	isOpen: () -> boolean,
}

local function bearer(key: ApiKey): ApiKey
	if typeof(key) == "string" then
		return "Bearer " .. key
	end
	return key:AddPrefix("Bearer ")
end

local function requestHeaders(config: ResolvedConfig, json: boolean): Headers
	local headers: Headers = {}
	if json then
		headers["Content-Type"] = "application/json"
	end
	local key = config.apiKey
	if config.protocol == "anthropic" then
		headers["anthropic-version"] = config.format.Version or "2023-06-01"
		local beta = config.anthropicBeta
		if beta and #beta > 0 then
			headers["anthropic-beta"] = table.concat(beta, ",")
		end
		if key ~= nil then
			headers["x-api-key"] = key
		end
	else
		if key ~= nil then
			headers["Authorization"] = bearer(key)
		end
		if config.organization then
			headers["OpenAI-Organization"] = config.organization
		end
		if config.project then
			headers["OpenAI-Project"] = config.project
		end
	end
	for name, value in config.headers do
		headers[name] = value
	end
	return headers
end

local function backoff(attempt: number, retryAfter: number?): number
	if retryAfter and retryAfter >= 0 then
		return math.min(retryAfter, 60)
	end
	return math.min(8, 0.5 * 2 ^ (attempt - 1)) * (0.75 + math.random() * 0.5)
end

local function postJson(state: ProviderState, path: string, body: any): any
	local config = state.config
	local request: HttpRequest = {
		url = config.baseUrl .. path,
		method = "POST",
		headers = requestHeaders(config, true),
		body = encodeJson(body),
	}
	local attempt = 0
	while true do
		local ok, result = pcall(Runtime.request, request)
		local failure: AIError
		local retryAfter: number? = nil
		if ok then
			if result.status >= 200 and result.status < 300 then
				return decodeJson(result.body)
			end
			failure = errorFromBody("http", result.status, result.body, isRetryableStatus(result.status))
			retryAfter = tonumber(result.headers["retry-after"] or "")
		else
			failure = asError(result, "network")
		end
		if not failure.Retryable or attempt >= config.maxRetries then
			error(failure)
		end
		attempt += 1
		Runtime.wait(backoff(attempt, retryAfter))
	end
end

local function moderatorFor(state: ProviderState, guard: ModerationGuard): Provider
	local moderator = guard.Provider or state.provider
	if moderator == nil or moderator.Format.Protocol ~= "openai" then
		error(newError("config", "moderation needs an OpenAI provider; set `Moderation.Provider`"))
	end
	return moderator
end

local function moderationError(check: ContentCheck, direction: string): AIError
	local top = check.Violations[1]
	local detail = if top then ` ({top.Category}, score {string.format("%.3f", top.Score)})` else ""
	return newError("moderation", `the {direction} was blocked by moderation{detail}`, { check = check })
end

local function guardInput(state: ProviderState, request: Request)
	local guard = state.config.moderation
	if guard == nil or guard.Input == false then
		return
	end
	local content = latestUserContent(request)
	if content == nil then
		return
	end
	local check = moderatorFor(state, guard):Check(content, guard.Policy)
	if not check.Allowed then
		error(moderationError(check, "input"))
	end
end

local function outputGuard(state: ProviderState): ((response: Response) -> AIError?)?
	local guard = state.config.moderation
	if guard == nil or guard.Output == false then
		return nil
	end
	return function(response: Response): AIError?
		if response.Text == "" then
			return nil
		end
		local check = moderatorFor(state, guard):Check(response.Text, guard.Policy)
		return if check.Allowed then nil else moderationError(check, "output")
	end
end

local function createResponse(state: ProviderState, request: Request): Response
	local adapter = state.adapter
	local raw = postJson(state, adapter.path, adapter.buildBody(state.config, request, false))
	return adapter.parseResponse(state.config.format, raw)
end

-- Streams by making one regular request and replaying it, where the runtime cannot stream.
local function fallbackStream(state: ProviderState, request: Request, control: StreamControl)
	Runtime.spawn(function()
		local ok, result = pcall(createResponse, state, request)
		if ok then
			emitResponse(result, control.emit)
		else
			control.finish(asError(result, "network"))
		end
	end)
end

local function openHttpStream(state: ProviderState, request: Request, control: StreamControl)
	local config = state.config
	local adapter = state.adapter
	local body = adapter.buildBody(config, request, true)
	local handle = adapter.newStreamHandler(config.format)
	local sse = newSseParser(function(_eventName: string?, data: string)
		if data == "[DONE]" or control.finished() then
			return
		end
		local okDecode, decoded = pcall(Runtime.decodeJson, data)
		if not okDecode or type(decoded) ~= "table" then
			control.finish(newError("parse", "invalid JSON in stream event", { body = data }))
			return
		end
		local okHandle, handleError = pcall(handle, decoded, control.emit)
		if not okHandle then
			control.finish(asError(handleError, "parse"))
		end
	end)
	local httpRequest: HttpRequest = {
		url = config.baseUrl .. adapter.path,
		method = "POST",
		headers = requestHeaders(config, true),
		body = encodeJson(body),
	}
	local ok, close = pcall(Runtime.stream, httpRequest, {
		onData = sse.push,
		onError = function(status: number?, message: string)
			if status then
				control.finish(errorFromBody("http", status, message, isRetryableStatus(status)))
			else
				control.finish(newError("network", message, { retryable = true }))
			end
		end,
		onClose = function()
			sse.flush()
			control.finish(newError("network", "the stream ended before the response completed", { retryable = true }))
		end,
	})
	if ok then
		control.onFinish(close)
		return
	end
	local failure = asError(close, "network")
	if failure.Kind == "unsupported" and config.streamFallback then
		fallbackStream(state, request, control)
	else
		control.finish(failure)
	end
end

local function websocketUrl(baseUrl: string): string
	local url = string.gsub(baseUrl, "^[Hh][Tt][Tt][Pp]", "ws")
	return url .. "/responses"
end

-- Opens a Responses WebSocket and routes server events to the request at the head of each lane.
local function openSessionState(state: ProviderState): SessionState
	local config = state.config
	local adapter = state.adapter
	type Pending = { control: StreamControl, handle: StreamHandler }
	local lanes: { [string]: { Pending } } = {}
	local closed = false

	local function failAll(err: AIError)
		local current = lanes
		lanes = {}
		for _, queue in current do
			for _, pending in queue do
				pending.control.finish(err)
			end
		end
	end

	local function onMessage(message: string)
		local ok, data = pcall(Runtime.decodeJson, message)
		if not ok or type(data) ~= "table" then
			return
		end
		local lane = if type(data.stream_id) == "string" then data.stream_id else DEFAULT_LANE
		local queue = lanes[lane]
		local pending = queue and queue[1]
		if pending == nil then
			if data.type == "error" and data.stream_id == nil then
				failAll(errorFromEvent(data))
			end
			return
		end
		local okHandle, terminal = pcall(pending.handle, data, pending.control.emit)
		if not okHandle then
			pending.control.finish(asError(terminal, "parse"))
			terminal = true
		end
		if terminal then
			table.remove(queue, 1)
			if #queue == 0 and lanes[lane] == queue then
				lanes[lane] = nil
			end
		end
	end

	local socket = Runtime.socket(websocketUrl(config.baseUrl), requestHeaders(config, false), {
		onMessage = onMessage,
		onClose = function(code: number?, reason: string?)
			closed = true
			local suffix = if reason and reason ~= "" then `: {reason}` else ""
			failAll(newError("closed", `the WebSocket closed ({code or "no code"}){suffix}`, { retryable = true }))
		end,
	}, config.connectTimeout)

	return {
		submit = function(request: Request, control: StreamControl)
			if closed or not socket.isOpen() then
				control.finish(newError("closed", "the WebSocket session is closed"))
				return
			end
			local okBody, body = pcall(adapter.buildBody, config, request, false)
			if not okBody then
				control.finish(asError(body, "config"))
				return
			end
			body.type = "response.create"
			body.stream = nil
			body.background = nil
			if request.StreamId then
				body.stream_id = request.StreamId
			end
			local lane = request.StreamId or DEFAULT_LANE
			local queue = lanes[lane]
			if queue == nil then
				queue = {}
				lanes[lane] = queue
			end
			table.insert(queue, { control = control, handle = adapter.newStreamHandler(config.format) })
			local okSend, sendError = pcall(function(): unknown
				socket.send(encodeJson(body))
				return nil
			end)
			if not okSend then
				control.finish(asError(sendError, "closed"))
			end
		end,
		close = function()
			closed = true
			socket.close()
			failAll(newError("closed", "the WebSocket session was closed"))
		end,
		isOpen = function(): boolean
			return not closed and socket.isOpen()
		end,
	}
end

local function streamResponse(state: ProviderState, request: Request, onEvent: ((event: StreamEvent) -> ())?): Stream
	guardInput(state, request)
	local config = state.config
	local control = newStream(onEvent, outputGuard(state))
	if config.protocol == "openai" and config.transport == "websocket" then
		Runtime.spawn(function()
			local ok, session = pcall(openSessionState, state)
			if not ok then
				local failure = asError(session, "network")
				if failure.Kind == "unsupported" and config.streamFallback then
					fallbackStream(state, request, control)
				else
					control.finish(failure)
				end
				return
			end
			control.onFinish(session.close)
			session.submit(request, control)
		end)
	else
		openHttpStream(state, request, control)
	end
	return control.stream
end

local function resolveConfig(config: ProviderConfig): ResolvedConfig
	if type(config) ~= "table" then
		error(newError("config", "Provider.new expects a config table"))
	end
	local format = config.Format
	if format == nil or not knownFormats[format] then
		error(newError("config", "`Format` must be one of the values in AI.Format, such as AI.Format.OpenAI.Responses"))
	end
	local protocol: Protocol = format.Protocol
	local baseUrl = string.gsub(config.BaseUrl or DEFAULT_BASE_URLS[protocol], "/+$", "")
	local apiKey: ApiKey? = config.ApiKey
	if apiKey == nil then
		local secretName = config.Secret or DEFAULT_SECRET_NAMES[protocol]
		apiKey = Runtime.secret(secretName)
		if apiKey == nil and config.Secret ~= nil then
			local where = if Runtime.name == "roblox" then "in the secret store" else "in the environment"
			error(newError("config", `secret '{secretName}' was not found {where}`))
		end
	end
	if apiKey == nil and config.BaseUrl == nil then
		error(newError("config", `no API key for {format.Name}; set \`ApiKey\` or \`Secret\``))
	end
	local transport: Transport = config.Transport or "websocket"
	if transport ~= "websocket" and transport ~= "sse" then
		error(newError("config", `unknown transport '{tostring(transport)}'`))
	end
	return {
		format = format,
		protocol = protocol,
		baseUrl = baseUrl,
		apiKey = apiKey,
		headers = config.Headers or {},
		defaultModel = config.DefaultModel,
		maxTokens = config.MaxTokens or 4096,
		maxRetries = config.MaxRetries or 2,
		transport = transport,
		streamFallback = config.StreamFallback ~= false,
		connectTimeout = config.ConnectTimeout or 30,
		anthropicBeta = config.AnthropicBeta,
		organization = config.Organization,
		project = config.Project,
		moderation = config.Moderation,
	}
end

local function newSession(state: ProviderState, sessionState: SessionState): Session
	local session: Session = {
		Stream = function(_self: Session, request: Request, onEvent: ((event: StreamEvent) -> ())?): Stream
			guardInput(state, request)
			local control = newStream(onEvent, outputGuard(state))
			sessionState.submit(request, control)
			return control.stream
		end,
		Create = function(self: Session, request: Request): Response
			return self:Stream(request):Await()
		end,
		Close = function(_self: Session)
			sessionState.close()
		end,
		IsOpen = function(_self: Session): boolean
			return sessionState.isOpen()
		end,
	}
	return session
end

local function toolResultText(value: any): string
	if value == nil then
		return ""
	elseif type(value) == "string" then
		return value
	end
	local ok, encoded = pcall(encodeJson, value)
	return if ok then encoded else tostring(value)
end

local Provider = {}

--[=[
	@within Provider
	Creates a provider for one [Format].

	```lua
	-- Roblox: reads the "openai" key from the experience's secret store.
	local openai = AI.Provider.new({
		Format = AI.Format.OpenAI.Responses,
		Secret = "openai",
		DefaultModel = "gpt-5.2",
	})

	-- Any OpenAI-compatible server with the Responses API, here a local one without a key.
	local ollama = AI.Provider.new({
		Format = AI.Format.OpenAI.Responses,
		BaseUrl = "http://localhost:11434/v1",
		Transport = "sse",
	})
	```

	@param config ProviderConfig
	@return Provider
	@error AIError -- `"config"` errors for invalid options or a missing key.
]=]
function Provider.new(config: ProviderConfig): Provider
	local resolved = resolveConfig(config)
	local state: ProviderState = {
		config = resolved,
		adapter = ADAPTERS[resolved.protocol],
		provider = nil,
	}

	local provider: Provider = {
		Format = resolved.format,
		BaseUrl = resolved.baseUrl,
		Create = function(_self: Provider, request: Request): Response
			guardInput(state, request)
			local response = createResponse(state, request)
			local guard = outputGuard(state)
			local failure = if guard then guard(response) else nil
			if failure then
				error(failure)
			end
			return response
		end,
		Stream = function(_self: Provider, request: Request, onEvent: ((event: StreamEvent) -> ())?): Stream
			return streamResponse(state, request, onEvent)
		end,
		Connect = function(_self: Provider): Session
			if resolved.protocol ~= "openai" then
				error(newError("unsupported", "WebSocket sessions are only available for OpenAI formats"))
			end
			return newSession(state, openSessionState(state))
		end,
		Run = function(
			self: Provider,
			request: Request,
			handlers: { [string]: ToolHandler },
			options: RunOptions?
		): RunResult
			local maxSteps = if options and options.MaxSteps then options.MaxSteps else 8
			local onStep = if options then options.OnStep else nil
			local messages = collectMessages(request)
			local steps = 0
			while true do
				steps += 1
				local step = table.clone(request)
				step.Prompt = nil
				step.Messages = messages
				local response = self:Create(step)
				table.insert(messages, { Role = "assistant", Content = response.Content })
				if onStep then
					onStep(response)
				end
				if #response.ToolCalls == 0 or steps >= maxSteps then
					return { Response = response, Messages = messages, Steps = steps }
				end
				local results: { ContentPart } = {}
				for _, call in response.ToolCalls do
					local handler = handlers[call.Name]
					local ok, value
					if handler then
						ok, value = pcall(handler, call.Arguments, call)
					else
						ok, value = false, `unknown tool '{call.Name}'`
					end
					table.insert(results, {
						Type = "tool_result",
						ToolCallId = call.Id,
						Content = if ok then toolResultText(value) else tostring(value),
						IsError = if ok then nil else true,
					})
				end
				table.insert(messages, { Role = "user", Content = results })
			end
		end,
		Moderate = function(_self: Provider, input: ModerationInput, options: ModerationOptions?): ModerationResponse
			if resolved.protocol ~= "openai" then
				error(newError("unsupported", "moderation is only available for OpenAI formats"))
			end
			local body = {
				model = if options and options.Model then options.Model else "omni-moderation-latest",
				input = moderationInput(input),
			}
			return parseModeration(postJson(state, "/moderations", body))
		end,
		Check = function(self: Provider, input: ModerationInput, policy: ContentPolicy?): ContentCheck
			local moderation = self:Moderate(input, { Model = if policy then policy.Model else nil })
			return evaluatePolicy(moderation, policy)
		end,
	}
	state.provider = provider
	return provider
end

--[=[
	@prop Format Format
	@within Provider
	@readonly
]=]

--[=[
	@prop BaseUrl string
	@within Provider
	@readonly
]=]

--[=[
	@method Create
	@within Provider
	@yields
	Sends a request and waits for the complete response. Rate limits, overloads and network errors are retried
	with exponential backoff, up to `MaxRetries` times.

	@param request Request
	@return Response
	@error AIError
]=]

--[=[
	@method Stream
	@within Provider
	Starts streaming a response. OpenAI formats stream over WebSocket mode by default (one connection per call;
	use [Provider:Connect] to reuse one), and Anthropic formats stream over server-sent events.

	Where the runtime cannot stream, such as live Roblox servers (`CreateWebStreamClient` is Studio-only), the
	response is fetched in one request and replayed as events, unless `StreamFallback` is `false`.

	```lua
	local stream = provider:Stream({ Prompt = "Tell me a story." }, function(event)
		if event.Type == "text" then
			label.Text ..= event.Delta
		end
	end)
	local response = stream:Await()
	```

	@param request Request
	@param onEvent ((event: StreamEvent) -> ())? -- Called for every event, before it is queued.
	@return Stream
	@error AIError -- Only for moderation of the input; everything else arrives as an `error` event.
]=]

--[=[
	@method Connect
	@within Provider
	@yields
	Opens a persistent Responses WebSocket [Session]. OpenAI formats only.

	```lua
	local session = openai:Connect()
	local first = session:Create({ Prompt = "Pick a number.", Store = false })
	local second = session:Create({ Prompt = "Double it.", PreviousResponseId = first.Id, Store = false })
	session:Close()
	```

	@return Session
	@error AIError
]=]

--[=[
	@method Run
	@within Provider
	@yields
	Runs a tool-use loop: calls the model, executes requested tools with `handlers`, sends back the results, and
	repeats until the model stops calling tools or `MaxSteps` is reached.

	```lua
	local result = provider:Run({
		Prompt = "What's 2 ^ 10?",
		Tools = {
			{
				Name = "pow",
				Parameters = { type = "object", properties = { a = { type = "number" }, b = { type = "number" } } },
			},
		},
	}, {
		pow = function(args)
			return args.a ^ args.b
		end,
	})
	print(result.Response.Text)
	```

	@param request Request -- Must include the `Tools` the handlers implement.
	@param handlers { [string]: ToolHandler }
	@param options RunOptions?
	@return RunResult
	@error AIError
]=]

--[=[
	@method Moderate
	@within Provider
	@yields
	Classifies text and images with the OpenAI moderation API. OpenAI formats only.

	@param input ModerationInput
	@param options ModerationOptions?
	@return ModerationResponse
	@error AIError
]=]

--[=[
	@method Check
	@within Provider
	@yields
	Moderates content and evaluates the result against a [ContentPolicy].

	```lua
	local check = openai:Check(message, { Thresholds = { harassment = 0.4 }, Allow = { "violence" } })
	if not check.Allowed then
		warn("blocked:", check.Violations[1].Category)
	end
	```

	@param input ModerationInput
	@param policy ContentPolicy?
	@return ContentCheck
	@error AIError
]=]

--[=[
	@prop Text string
	@within Stream
	@readonly
	All text received so far.
]=]

--[=[
	@prop Response Response?
	@within Stream
	@readonly
	The final response, once the stream is done.
]=]

--[=[
	@method Next
	@within Stream
	@yields
	Waits for the next event. Returns `nil` once the stream has ended and every event has been read.

	@return StreamEvent?
]=]

--[=[
	@method Iter
	@within Stream
	Returns an iterator over the remaining events, for use in a generic `for` loop.

	@return () -> StreamEvent?
]=]

--[=[
	@method Await
	@within Stream
	@yields
	Reads the remaining events and returns the final response.

	@return Response
	@error AIError -- The stream's error, or a `"cancelled"` error.
]=]

--[=[
	@method Cancel
	@within Stream
	Stops the stream and releases its connection. Pending [Stream:Await] calls raise a `"cancelled"` error.
]=]

--[=[
	@method Stream
	@within Session
	Sends a `response.create` event over the session's connection. Requests with the same `StreamId` run in
	order; requests on different lanes run concurrently.

	@param request Request
	@param onEvent ((event: StreamEvent) -> ())?
	@return Stream
]=]

--[=[
	@method Create
	@within Session
	@yields
	Like [Session:Stream], but waits for the final response.

	@param request Request
	@return Response
	@error AIError
]=]

--[=[
	@method Close
	@within Session
	Closes the connection. In-flight streams end with a `"closed"` error.
]=]

--[=[
	@method IsOpen
	@within Session
	@return boolean
]=]

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[=[
	@prop Version string
	@within AI
	@readonly
	The version of AI.luau.
]=]
AI.Version = "0.2.0"

--[=[
	@prop Format Formats
	@within AI
	@readonly
	Every supported wire format, by provider and API version.

	```lua
	AI.Format.Anthropic.V2023_06_01 -- the same value as AI.Format.Anthropic["2023-06-01"]
	AI.Format.Anthropic.Latest
	AI.Format.OpenAI.Responses
	```
]=]
AI.Format = FORMATS

--[=[
	@prop Provider { new: (config: ProviderConfig) -> Provider }
	@within AI
	@readonly
	The [Provider] constructor table.
]=]
AI.Provider = table.freeze(Provider)

--[=[
	@within AI
	Evaluates a moderation response against a policy, without another request.

	@param moderation ModerationResponse
	@param policy ContentPolicy?
	@return ContentCheck
]=]
function AI.Evaluate(moderation: ModerationResponse, policy: ContentPolicy?): ContentCheck
	return evaluatePolicy(moderation, policy)
end

--[=[
	@within AI
	Returns true if `value` is an [AIError].

	```lua
	local ok, err = pcall(provider.Create, provider, request)
	if not ok and AI.IsError(err) and err.Kind == "moderation" then
		print("blocked")
	end
	```

	@param value unknown
	@return boolean
]=]
function AI.IsError(value: unknown): boolean
	return isError(value)
end

--[=[
	@within AI
	Marks a table so it encodes as a JSON object even when empty. Tool schemas are handled automatically.

	@param value T
	@return T
]=]
function AI.Object<T>(value: T): T
	return markObject(value)
end

--[=[
	@prop Null {}
	@within AI
	@readonly
	A sentinel that encodes as JSON `null`, for `Extra` fields that must be sent as null.
]=]
AI.Null = JSON_NULL

--[=[
	@within AI
	Encodes a value as JSON, honoring [AI.Object] and [AI.Null]. Keys are sorted.

	@param value any
	@return string
]=]
function AI.EncodeJson(value: any): string
	return encodeJson(value)
end

--[=[
	@within AI
	@param content string | { ContentPart }
	@return Message
]=]
function AI.User(content: string | { ContentPart }): Message
	return { Role = "user", Content = content }
end

--[=[
	@within AI
	Turns a response, or plain content, into an assistant message for the next turn.

	@param content Response | string | { ContentPart }
	@return Message
]=]
function AI.Assistant(content: Response | string | { ContentPart }): Message
	if type(content) == "table" and (content :: any).Format ~= nil and (content :: any).Content ~= nil then
		return { Role = "assistant", Content = (content :: Response).Content }
	end
	return { Role = "assistant", Content = content :: string | { ContentPart } }
end

--[=[
	@within AI
	@param text string
	@return Message
]=]
function AI.System(text: string): Message
	return { Role = "system", Content = text }
end

--[=[
	@within AI
	Builds a tool result part answering a [ToolCallPart].

	@param toolCallId string
	@param content string
	@param isError boolean?
	@return ToolResultPart
]=]
function AI.ToolResult(toolCallId: string, content: string, isError: boolean?): ToolResultPart
	return { Type = "tool_result", ToolCallId = toolCallId, Content = content, IsError = isError }
end

--[=[
	@within AI
	Builds an image part from a URL.

	@param url string
	@return ImagePart
]=]
function AI.Image(url: string): ImagePart
	return { Type = "image", Url = url }
end

--[=[
	@within AI
	Builds an image part from base64 data.

	@param data string
	@param mediaType string? -- Defaults to `"image/png"`.
	@return ImagePart
]=]
function AI.ImageData(data: string, mediaType: string?): ImagePart
	return { Type = "image", Data = data, MediaType = mediaType or "image/png" }
end

--[=[
	@prop Runtime "roblox" | "lune"
	@within AI
	@readonly
	The runtime AI.luau detected.
]=]
AI.Runtime = Runtime.name

return table.freeze(AI)
