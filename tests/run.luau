-- Offline test suite for AI.luau, run with `lune run tests/run`.
-- Starts a local mock of the Anthropic, OpenAI Responses (HTTP, SSE and WebSocket) and moderation APIs.

local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local AI = require("../AI")

local PORT = 18000 + math.random(0, 999)
local BASE = `http://127.0.0.1:{PORT}/v1`

local function json(value: any): string
	return serde.encode("json", value)
end

local function sse(events: { { [string]: any } }): string
	local out = {}
	for _, event in events do
		table.insert(out, `event: {event.type}\ndata: {json(event)}\n\n`)
	end
	return table.concat(out)
end

local function anthropicStreamBody(): string
	return sse({
		{
			type = "message_start",
			message = {
				id = "msg_1",
				model = "claude-test",
				content = {},
				usage = { input_tokens = 10, output_tokens = 1 },
			},
		},
		{ type = "content_block_start", index = 0, content_block = { type = "text", text = "" } },
		{ type = "ping" },
		{ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "Hello" } },
		{ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = " world" } },
		{ type = "content_block_stop", index = 0 },
		{
			type = "content_block_start",
			index = 1,
			content_block = { type = "tool_use", id = "toolu_1", name = "pow", input = {} },
		},
		{ type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = '{"a":2,' } },
		{ type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = '"b":10}' } },
		{ type = "content_block_stop", index = 1 },
		{ type = "message_delta", delta = { stop_reason = "tool_use" }, usage = { output_tokens = 20 } },
		{ type = "message_stop" },
	})
end

local function openaiResponse(id: string, text: string): { [string]: any }
	return {
		id = id,
		object = "response",
		status = "completed",
		model = "gpt-test",
		output = {
			{ type = "message", role = "assistant", content = { { type = "output_text", text = text } } },
		},
		usage = { input_tokens = 5, output_tokens = 2, total_tokens = 7 },
	}
end

local function openaiEvents(id: string, text: string, streamId: string?): { { [string]: any } }
	local response = openaiResponse(id, text)
	local events = {
		{ type = "response.created", response = { id = id, model = "gpt-test", status = "in_progress" } },
		{
			type = "response.output_item.added",
			output_index = 0,
			item = { type = "message", role = "assistant", content = {} },
		},
	}
	for index = 1, #text, 1000 do
		table.insert(
			events,
			{ type = "response.output_text.delta", output_index = 0, delta = string.sub(text, index, index + 999) }
		)
	end
	table.insert(events, { type = "response.completed", response = response })
	if streamId then
		for _, event in events do
			event.stream_id = streamId
		end
	end
	return events
end

local log: { { path: string, headers: { [string]: string }, body: any } } = {}
local failNext = 0

local server = net.serve(PORT, {
	handleRequest = function(request)
		local body = if request.body ~= "" then serde.decode("json", request.body) else nil
		table.insert(log, { path = request.path, headers = request.headers, body = body })
		if failNext > 0 then
			failNext -= 1
			return {
				status = 429,
				headers = { ["retry-after"] = "0" },
				body = json({ error = { type = "rate_limit_error", message = "slow down" } }),
			}
		end
		if request.path == "/v1/messages" then
			if body.stream then
				return {
					status = 200,
					headers = { ["content-type"] = "text/event-stream" },
					body = anthropicStreamBody(),
				}
			end
			local last = body.messages[#body.messages]
			if type(last.content) == "table" and last.content[1].type == "tool_result" then
				return {
					status = 200,
					body = json({
						id = "msg_3",
						type = "message",
						model = "claude-test",
						content = { { type = "text", text = `result {last.content[1].content}` } },
						stop_reason = "end_turn",
						usage = { input_tokens = 30, output_tokens = 3 },
					}),
				}
			end
			if body.tools then
				return {
					status = 200,
					body = json({
						id = "msg_2",
						type = "message",
						model = "claude-test",
						content = {
							{ type = "thinking", thinking = "use the tool", signature = "sig" },
							{ type = "tool_use", id = "toolu_9", name = "pow", input = { a = 2, b = 10 } },
						},
						stop_reason = "tool_use",
						usage = { input_tokens = 20, output_tokens = 10 },
					}),
				}
			end
			return {
				status = 200,
				body = json({
					id = "msg_0",
					type = "message",
					model = "claude-test",
					content = { { type = "text", text = "Hi there" } },
					stop_reason = "end_turn",
					usage = { input_tokens = 4, output_tokens = 2, cache_read_input_tokens = 1 },
				}),
			}
		elseif request.path == "/v1/responses" then
			if body.stream then
				return {
					status = 200,
					headers = { ["content-type"] = "text/event-stream" },
					body = sse(openaiEvents("resp_sse", "abc")),
				}
			end
			if body.model == "missing" then
				return {
					status = 404,
					body = json({
						error = {
							message = "model not found",
							type = "invalid_request_error",
							code = "model_not_found",
						},
					}),
				}
			end
			return { status = 200, body = json(openaiResponse("resp_http", "pong")) }
		elseif request.path == "/v1/moderations" then
			local inputs = if type(body.input) == "table" then body.input else { body.input }
			local results = {}
			for _, input in inputs do
				local text = if type(input) == "table" then input.text or "" else input
				local bad = string.find(text, "BAD", 1, true) ~= nil
				table.insert(results, {
					flagged = bad,
					categories = { harassment = bad, violence = false },
					category_scores = { harassment = if bad then 0.9 else 0.01, violence = 0.3 },
					category_applied_input_types = { harassment = { "text" }, violence = { "text" } },
				})
			end
			return { status = 200, body = json({ id = "modr_1", model = body.model, results = results }) }
		end
		return { status = 404, body = "not found" }
	end,
	handleWebSocket = function(socket)
		local count = 0
		while true do
			local message = socket:next()
			if message == nil then
				break
			end
			local event = serde.decode("json", message)
			count += 1
			if event.type ~= "response.create" then
				socket:send(json({ type = "error", status = 400, error = { message = "bad event type" } }))
			elseif event.model == "fail" then
				socket:send(json({
					type = "error",
					status = 400,
					stream_id = event.stream_id,
					error = { type = "invalid_request_error", code = "previous_response_not_found", message = "nope" },
				}))
			else
				local id = `resp_ws_{count}`
				local text = if event.previous_response_id then `continued {event.previous_response_id}` else "socket"
				local input = event.input[1]
				if input and type(input.content) == "string" and #input.content > 1000 then
					text = `{#input.content}:` .. string.rep("y", 70000)
				end
				if event.stream_id then
					text = event.stream_id
				end
				for _, out in openaiEvents(id, text, event.stream_id) do
					socket:send(json(out))
					if event.stream_id then
						task.wait()
					end
				end
			end
		end
	end,
})

local tests: { { name: string, run: () -> () } } = {}
local function test(name: string, run: () -> ())
	table.insert(tests, { name = name, run = run })
end

local function expect(condition: any, message: string?)
	if not condition then
		error(message or "expectation failed", 2)
	end
end

local function equal(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "value"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

local function lastRequest()
	return log[#log]
end

local anthropic = AI.Provider.new({
	Format = AI.Format.Anthropic.V2023_06_01,
	ApiKey = "sk-ant-test",
	BaseUrl = BASE,
	DefaultModel = "claude-test",
})
local openai = AI.Provider.new({
	Format = AI.Format.OpenAI.Responses,
	ApiKey = "sk-test",
	BaseUrl = BASE,
	DefaultModel = "gpt-test",
})

test("formats", function()
	equal(AI.Format.Anthropic.V2023_06_01, AI.Format.Anthropic["2023-06-01"], "dated alias")
	equal(AI.Format.Anthropic.Latest, AI.Format.Anthropic.V2023_06_01, "latest")
	equal(AI.Format.Anthropic.V2023_06_01.Version, "2023-06-01")
	equal(AI.Format.OpenAI.Responses.Protocol, "openai")
	equal(anthropic.Format, AI.Format.Anthropic.V2023_06_01)
	equal(openai.BaseUrl, BASE)
	expect(table.isfrozen(AI.Format.Anthropic.V2023_06_01), "formats are frozen")
end)

test("json encoding marks empty objects and escapes strings", function()
	equal(AI.EncodeJson({}), "[]")
	equal(AI.EncodeJson(AI.Object({})), "{}")
	equal(AI.EncodeJson({ b = 1, a = { 1, 2.5, true } }), '{"a":[1,2.5,true],"b":1}')
	equal(AI.EncodeJson('quote " slash \\ line\n tab\t \1'), '"quote \\" slash \\\\ line\\n tab\\t \\u0001"')
	equal(AI.EncodeJson({ x = AI.Null }), '{"x":null}')
	local ok, err = pcall(AI.EncodeJson, 0 / 0)
	expect(not ok and AI.IsError(err) and err.Kind == "config", "NaN should not encode")
end)

test("config errors", function()
	local ok, err = pcall(AI.Provider.new, { Format = nil :: any, ApiKey = "x" })
	expect(not ok and AI.IsError(err) and err.Kind == "config", "missing format")
	ok, err = pcall(AI.Provider.new, { Format = { Name = "fake", Protocol = "openai" } :: any, ApiKey = "x" })
	expect(not ok and err.Kind == "config", "unknown format tables are rejected")
	ok, err = pcall(AI.Provider.new, { Format = AI.Format.OpenAI.Responses, Secret = "AI_LUAU_DEFINITELY_MISSING" })
	expect(not ok and err.Kind == "config" and string.find(err.Message, "AI_LUAU_DEFINITELY_MISSING", 1, true))
	ok, err = pcall(function()
		return anthropic:Create({ Model = "claude-test" })
	end)
	expect(not ok and err.Kind == "config", "missing prompt should be a config error")
end)

test("secret falls back to environment variables on Lune", function()
	process.env.AI_LUAU_TEST_KEY = "sk-from-env"
	local provider = AI.Provider.new({
		Format = AI.Format.OpenAI.Responses,
		Secret = "AI_LUAU_TEST_KEY",
		BaseUrl = BASE,
		DefaultModel = "gpt-test",
	})
	provider:Create({ Prompt = "ping" })
	equal(lastRequest().headers["authorization"], "Bearer sk-from-env", "authorization")
end)

test("anthropic create", function()
	local response = anthropic:Create({
		System = "Be brief.",
		Messages = { AI.System("And kind."), AI.User("Hello") },
		Temperature = 0.2,
		Stop = { "STOP" },
	})
	equal(response.Text, "Hi there")
	equal(response.StopReason, "stop")
	equal(response.Format, AI.Format.Anthropic.V2023_06_01)
	equal(response.Usage.TotalTokens, 6)
	equal(response.Usage.CacheReadTokens, 1)
	local request = lastRequest()
	equal(request.headers["x-api-key"], "sk-ant-test")
	equal(request.headers["anthropic-version"], "2023-06-01")
	equal(request.body.system, "Be brief.\n\nAnd kind.")
	equal(#request.body.messages, 1, "system messages are lifted out")
	equal(request.body.max_tokens, 4096)
	equal(request.body.stop_sequences[1], "STOP")
end)

test("anthropic stream", function()
	local seen: { string } = {}
	local stream = anthropic:Stream({ Prompt = "Hello" }, function(event)
		table.insert(seen, event.Type)
	end)
	local deltas = {}
	local toolDeltas = {}
	for event in stream:Iter() do
		if event.Type == "text" then
			table.insert(deltas, event.Delta)
		elseif event.Type == "tool_call_delta" then
			table.insert(toolDeltas, event.Delta)
		elseif event.Type == "tool_call" then
			equal(event.Call.Arguments.b, 10, "streamed tool arguments")
		end
	end
	equal(table.concat(deltas, "|"), "Hello| world")
	equal(table.concat(toolDeltas), '{"a":2,"b":10}')
	local response = stream:Await()
	equal(response.Text, "Hello world")
	equal(response.StopReason, "tool_calls")
	equal(response.Usage.OutputTokens, 20)
	equal(response.ToolCalls[1].Id, "toolu_1")
	equal(stream.Text, "Hello world")
	equal(seen[1], "start")
	equal(seen[#seen], "done")
	equal(lastRequest().body.stream, true)
end)

test("anthropic tool loop round-trips thinking and tool results", function()
	local steps = 0
	local result = anthropic:Run({
		Prompt = "What is 2 ^ 10?",
		Tools = {
			{
				Name = "pow",
				Description = "Raise a to b",
				Parameters = {
					type = "object",
					properties = { a = { type = "number" }, b = { type = "number" } },
					required = { "a", "b" },
				},
			},
			{ Name = "noop" },
		},
		ToolChoice = "auto",
		Reasoning = { BudgetTokens = 1024 },
	}, {
		pow = function(args)
			return args.a ^ args.b
		end,
	}, {
		OnStep = function()
			steps += 1
		end,
	})
	equal(result.Response.Text, "result 1024")
	equal(result.Steps, 2)
	equal(steps, 2)
	equal(#result.Messages, 4)
	local request = lastRequest()
	local assistant = request.body.messages[2]
	equal(assistant.content[1].type, "thinking", "thinking block replayed")
	equal(assistant.content[1].signature, "sig")
	equal(assistant.content[2].type, "tool_use")
	equal(request.body.messages[3].content[1].tool_use_id, "toolu_9")
	equal(request.body.tool_choice.type, "auto")
	equal(request.body.thinking.budget_tokens, 1024)
	equal(serde.encode("json", request.body.tools[2].input_schema), '{"properties":{},"type":"object"}')
end)

test("retries rate limits", function()
	failNext = 2
	local before = #log
	local response = openai:Create({ Prompt = "ping" })
	equal(response.Text, "pong")
	equal(#log - before, 3, "two retries then success")
end)

test("http errors carry provider details", function()
	local ok, err = pcall(function()
		return openai:Create({ Model = "missing", Prompt = "ping" })
	end)
	expect(not ok and AI.IsError(err))
	equal(err.Kind, "http")
	equal(err.Status, 404)
	equal(err.Code, "model_not_found")
	equal(err.Message, "model not found")
	equal(err.Retryable, false)
	expect(string.find(tostring(err), "http 404", 1, true), "tostring includes the status")
end)

test("openai create maps messages, tools and images", function()
	local response = openai:Create({
		System = "sys",
		Messages = {
			AI.User({ { Type = "text", Text = "look" }, AI.Image("https://example.com/cat.png") }),
			{
				Role = "assistant",
				Content = {
					{ Type = "text", Text = "calling" },
					{
						Type = "tool_call",
						Id = "call_1",
						Name = "lookup",
						Arguments = {},
						RawArguments = "",
						ItemId = "fc_1",
					},
				},
			},
			AI.User({ AI.ToolResult("call_1", "42") }),
		},
		Tools = { { Name = "lookup", Parameters = { type = "object", properties = {} } } },
		ToolChoice = { Name = "lookup" },
		Reasoning = { Effort = "low" },
		MaxTokens = 50,
		Store = false,
		Extra = { metadata = { source = "test" } },
	})
	equal(response.Text, "pong")
	local body = lastRequest().body
	equal(body.instructions, "sys")
	equal(body.input[1].content[2].type, "input_image")
	equal(body.input[2].content, "calling")
	equal(body.input[3].type, "function_call")
	equal(body.input[3].arguments, "{}")
	equal(body.input[3].id, "fc_1")
	equal(body.input[4].type, "function_call_output")
	equal(body.input[4].output, "42")
	equal(body.tools[1].strict, false)
	equal(body.tool_choice.name, "lookup")
	equal(body.reasoning.effort, "low")
	equal(body.max_output_tokens, 50)
	equal(body.store, false)
	equal(body.metadata.source, "test")
	local ok, err = pcall(function()
		return openai:Create({ Prompt = "x", Stop = { "y" } })
	end)
	expect(not ok and err.Kind == "config", "stop sequences are rejected")
end)

test("openai stream over sse", function()
	local provider = AI.Provider.new({
		Format = AI.Format.OpenAI.Responses,
		ApiKey = "sk-test",
		BaseUrl = BASE,
		DefaultModel = "gpt-test",
		Transport = "sse",
	})
	local stream = provider:Stream({ Prompt = "hi" })
	local response = stream:Await()
	equal(response.Text, "abc")
	equal(response.Id, "resp_sse")
	equal(stream.Text, "abc")
end)

test("openai stream over websocket", function()
	local text = {}
	local stream = openai:Stream({ Prompt = "hi" }, function(event)
		if event.Type == "text" then
			table.insert(text, event.Delta)
		end
	end)
	local response = stream:Await()
	equal(response.Text, "socket")
	equal(table.concat(text), "socket")
end)

test("websocket session continues and multiplexes lanes", function()
	local session = openai:Connect()
	expect(session:IsOpen())
	local first = session:Create({ Prompt = "one", Store = false })
	local second = session:Create({ Prompt = "two", PreviousResponseId = first.Id, Store = false })
	equal(second.Text, `continued {first.Id}`)

	local a = session:Stream({ Prompt = "a", StreamId = "lane-a" })
	local b = session:Stream({ Prompt = "b", StreamId = "lane-b" })
	equal(b:Await().Text, "lane-b")
	equal(a:Await().Text, "lane-a")

	local ok, err = pcall(function()
		return session:Create({ Model = "fail", Prompt = "x" })
	end)
	expect(not ok and err.Kind == "api" and err.Code == "previous_response_not_found", "lane errors")
	equal(session:Create({ Prompt = "still open" }).Text, "socket")

	session:Close()
	expect(not session:IsOpen())
	local closed = session:Stream({ Prompt = "x" })
	local okClosed, closedErr = pcall(closed.Await, closed)
	expect(not okClosed and closedErr.Kind == "closed")
end)

test("websocket frames larger than 64 KiB", function()
	local response = openai:Create({ Prompt = "hi" })
	equal(response.Text, "pong")
	local streamed = openai:Stream({ Prompt = string.rep("x", 100000) }):Await()
	equal(#streamed.Text, 70007)
	equal(string.sub(streamed.Text, 1, 7), "100000:")
end)

test("stream cancel", function()
	local stream = anthropic:Stream({ Prompt = "Hello" })
	stream:Cancel()
	local ok, err = pcall(stream.Await, stream)
	expect(not ok and err.Kind == "cancelled")
	equal(stream:Next(), nil)
end)

test("anthropic providers reject sessions and moderation", function()
	local ok, err = pcall(anthropic.Connect, anthropic)
	expect(not ok and err.Kind == "unsupported")
	ok, err = pcall(anthropic.Moderate, anthropic, "x")
	expect(not ok and err.Kind == "unsupported")
end)

test("moderation and content checks", function()
	local moderation = openai:Moderate({ "fine", "BAD words" })
	equal(#moderation.Results, 2)
	expect(moderation.Flagged)
	equal(moderation.Results[2].Scores.harassment, 0.9)
	equal(lastRequest().body.model, "omni-moderation-latest")

	local check = openai:Check("BAD words")
	expect(not check.Allowed)
	equal(check.Violations[1].Category, "harassment")

	equal(openai:Check("BAD words", { Allow = { "harassment" } }).Allowed, true)
	local strict = openai:Check("fine", { DefaultThreshold = 0.25 })
	equal(strict.Allowed, false)
	equal(strict.Violations[1].Category, "violence")
	equal(openai:Check("fine", { Thresholds = { violence = 0.5 }, Block = { "violence" } }).Allowed, true)

	openai:Moderate({ { Type = "text", Text = "hi" }, AI.ImageData("AAAA", "image/jpeg") })
	local input = lastRequest().body.input
	equal(input[2].image_url.url, "data:image/jpeg;base64,AAAA")

	local reevaluated = AI.Evaluate(moderation, { Block = { "violence" } })
	equal(reevaluated.Allowed, true)
end)

test("moderation guard blocks input and output", function()
	local guarded = AI.Provider.new({
		Format = AI.Format.Anthropic["2023-06-01"],
		ApiKey = "sk-ant-test",
		BaseUrl = BASE,
		DefaultModel = "claude-test",
		Moderation = { Provider = openai },
	})
	equal(guarded:Create({ Prompt = "hello" }).Text, "Hi there")
	local ok, err = pcall(function()
		return guarded:Create({ Prompt = "BAD input" })
	end)
	expect(not ok and err.Kind == "moderation" and err.Check and not err.Check.Allowed)

	local before = #log
	local okStream, streamErr = pcall(function()
		return guarded:Stream({ Prompt = "BAD input" })
	end)
	expect(not okStream and streamErr.Kind == "moderation")
	equal(log[before + 1].path, "/v1/moderations", "blocked before the model was called")
	equal(#log, before + 1)

	local outputGuarded = AI.Provider.new({
		Format = AI.Format.OpenAI.Responses,
		ApiKey = "sk-test",
		BaseUrl = BASE,
		DefaultModel = "gpt-test",
		Moderation = { Input = false, Policy = { DefaultThreshold = 0.2 } },
	})
	local okOutput, outputErr = pcall(function()
		return outputGuarded:Create({ Prompt = "anything" })
	end)
	expect(not okOutput and outputErr.Kind == "moderation" and string.find(outputErr.Message, "output", 1, true))
	local streamed = outputGuarded:Stream({ Prompt = "anything" })
	local okAwait, awaitErr = pcall(streamed.Await, streamed)
	expect(not okAwait and awaitErr.Kind == "moderation")
end)

local passed, failed = 0, 0
for _, case in tests do
	local ok, err = pcall(case.run)
	if ok then
		passed += 1
		print(`  pass  {case.name}`)
	else
		failed += 1
		print(`  FAIL  {case.name}\n        {err}`)
	end
end
print(`\n{passed} passed, {failed} failed`)
server:stop()
process.exit(if failed == 0 then 0 else 1)
