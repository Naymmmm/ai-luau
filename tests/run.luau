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

local anthropic =
	AI.new({ provider = "anthropic", apiKey = "sk-ant-test", baseUrl = BASE, defaultModel = "claude-test" })
local openai = AI.new({ provider = "openai", apiKey = "sk-test", baseUrl = BASE, defaultModel = "gpt-test" })

test("json encoding marks empty objects and escapes strings", function()
	equal(AI.encodeJson({}), "[]")
	equal(AI.encodeJson(AI.object({})), "{}")
	equal(AI.encodeJson({ b = 1, a = { 1, 2.5, true } }), '{"a":[1,2.5,true],"b":1}')
	equal(AI.encodeJson('quote " slash \\ line\n tab\t \1'), '"quote \\" slash \\\\ line\\n tab\\t \\u0001"')
	equal(AI.encodeJson({ x = AI.null }), '{"x":null}')
	local ok, err = pcall(AI.encodeJson, 0 / 0)
	expect(not ok and AI.isError(err) and err.kind == "config", "NaN should not encode")
end)

test("config errors", function()
	local ok, err = pcall(AI.new, { provider = "nope" :: any, apiKey = "x" })
	expect(not ok and AI.isError(err) and err.kind == "config")
	ok, err = pcall(AI.new, { provider = "openai", secret = "AI_LUAU_DEFINITELY_MISSING" })
	expect(not ok and err.kind == "config" and string.find(err.message, "AI_LUAU_DEFINITELY_MISSING", 1, true))
	ok, err = pcall(function()
		return anthropic:create({ model = "claude-test" })
	end)
	expect(not ok and err.kind == "config", "missing prompt should be a config error")
end)

test("secret falls back to environment variables on Lune", function()
	process.env.AI_LUAU_TEST_KEY = "sk-from-env"
	local client =
		AI.new({ provider = "openai", secret = "AI_LUAU_TEST_KEY", baseUrl = BASE, defaultModel = "gpt-test" })
	client:create({ prompt = "ping" })
	equal(lastRequest().headers["authorization"], "Bearer sk-from-env", "authorization")
end)

test("anthropic create", function()
	local response = anthropic:create({
		system = "Be brief.",
		messages = { AI.system("And kind."), AI.user("Hello") },
		temperature = 0.2,
		stop = { "STOP" },
	})
	equal(response.text, "Hi there")
	equal(response.stopReason, "stop")
	equal(response.usage.totalTokens, 6)
	equal(response.usage.cacheReadTokens, 1)
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
	local stream = anthropic:stream({ prompt = "Hello" }, function(event)
		table.insert(seen, event.type)
	end)
	local deltas = {}
	local toolDeltas = {}
	for event in stream:iter() do
		if event.type == "text" then
			table.insert(deltas, event.delta)
		elseif event.type == "tool_call_delta" then
			table.insert(toolDeltas, event.delta)
		elseif event.type == "tool_call" then
			equal(event.call.arguments.b, 10, "streamed tool arguments")
		end
	end
	equal(table.concat(deltas, "|"), "Hello| world")
	equal(table.concat(toolDeltas), '{"a":2,"b":10}')
	local response = stream:await()
	equal(response.text, "Hello world")
	equal(response.stopReason, "tool_calls")
	equal(response.usage.outputTokens, 20)
	equal(response.toolCalls[1].id, "toolu_1")
	equal(stream.text, "Hello world")
	equal(seen[1], "start")
	equal(seen[#seen], "done")
	equal(lastRequest().body.stream, true)
end)

test("anthropic tool loop round-trips thinking and tool results", function()
	local steps = 0
	local result = anthropic:run({
		prompt = "What is 2 ^ 10?",
		tools = {
			{
				name = "pow",
				description = "Raise a to b",
				parameters = {
					type = "object",
					properties = { a = { type = "number" }, b = { type = "number" } },
					required = { "a", "b" },
				},
			},
			{ name = "noop" },
		},
		toolChoice = "auto",
		reasoning = { budgetTokens = 1024 },
	}, {
		pow = function(args)
			return args.a ^ args.b
		end,
	}, {
		onStep = function()
			steps += 1
		end,
	})
	equal(result.response.text, "result 1024")
	equal(result.steps, 2)
	equal(steps, 2)
	equal(#result.messages, 4)
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
	local response = openai:create({ prompt = "ping" })
	equal(response.text, "pong")
	equal(#log - before, 3, "two retries then success")
end)

test("http errors carry provider details", function()
	local ok, err = pcall(function()
		return openai:create({ model = "missing", prompt = "ping" })
	end)
	expect(not ok and AI.isError(err))
	equal(err.kind, "http")
	equal(err.status, 404)
	equal(err.code, "model_not_found")
	equal(err.message, "model not found")
	equal(err.retryable, false)
	expect(string.find(tostring(err), "http 404", 1, true), "tostring includes the status")
end)

test("openai create maps messages, tools and images", function()
	local response = openai:create({
		system = "sys",
		messages = {
			AI.user({ { type = "text", text = "look" }, AI.image("https://example.com/cat.png") }),
			{
				role = "assistant",
				content = {
					{ type = "text", text = "calling" },
					{
						type = "tool_call",
						id = "call_1",
						name = "lookup",
						arguments = {},
						rawArguments = "",
						itemId = "fc_1",
					},
				},
			},
			AI.user({ AI.toolResult("call_1", "42") }),
		},
		tools = { { name = "lookup", parameters = { type = "object", properties = {} } } },
		toolChoice = { name = "lookup" },
		reasoning = { effort = "low" },
		maxTokens = 50,
		store = false,
		extra = { metadata = { source = "test" } },
	})
	equal(response.text, "pong")
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
		return openai:create({ prompt = "x", stop = { "y" } })
	end)
	expect(not ok and err.kind == "config", "stop sequences are rejected")
end)

test("openai stream over sse", function()
	local client = AI.new({
		provider = "openai",
		apiKey = "sk-test",
		baseUrl = BASE,
		defaultModel = "gpt-test",
		transport = "sse",
	})
	local stream = client:stream({ prompt = "hi" })
	local response = stream:await()
	equal(response.text, "abc")
	equal(response.id, "resp_sse")
	equal(stream.text, "abc")
end)

test("openai stream over websocket", function()
	local text = {}
	local stream = openai:stream({ prompt = "hi" }, function(event)
		if event.type == "text" then
			table.insert(text, event.delta)
		end
	end)
	local response = stream:await()
	equal(response.text, "socket")
	equal(table.concat(text), "socket")
end)

test("websocket session continues and multiplexes lanes", function()
	local session = openai:connect()
	expect(session:isOpen())
	local first = session:create({ prompt = "one", store = false })
	local second = session:create({ prompt = "two", previousResponseId = first.id, store = false })
	equal(second.text, `continued {first.id}`)

	local a = session:stream({ prompt = "a", streamId = "lane-a" })
	local b = session:stream({ prompt = "b", streamId = "lane-b" })
	equal(b:await().text, "lane-b")
	equal(a:await().text, "lane-a")

	local ok, err = pcall(function()
		return session:create({ model = "fail", prompt = "x" })
	end)
	expect(not ok and err.kind == "api" and err.code == "previous_response_not_found", "lane errors")
	equal(session:create({ prompt = "still open" }).text, "socket")

	session:close()
	expect(not session:isOpen())
	local closed = session:stream({ prompt = "x" })
	local okClosed, closedErr = pcall(closed.await, closed)
	expect(not okClosed and closedErr.kind == "closed")
end)

test("websocket frames larger than 64 KiB", function()
	local response = openai:create({ prompt = "hi" })
	equal(response.text, "pong")
	local streamed = openai:stream({ prompt = string.rep("x", 100000) }):await()
	equal(#streamed.text, 70007)
	equal(string.sub(streamed.text, 1, 7), "100000:")
end)

test("stream cancel", function()
	local stream = anthropic:stream({ prompt = "Hello" })
	stream:cancel()
	local ok, err = pcall(stream.await, stream)
	expect(not ok and err.kind == "cancelled")
	equal(stream:next(), nil)
end)

test("anthropic clients reject sessions and moderation", function()
	local ok, err = pcall(anthropic.connect, anthropic)
	expect(not ok and err.kind == "unsupported")
	ok, err = pcall(anthropic.moderate, anthropic, "x")
	expect(not ok and err.kind == "unsupported")
end)

test("moderation and content checks", function()
	local moderation = openai:moderate({ "fine", "BAD words" })
	equal(#moderation.results, 2)
	expect(moderation.flagged)
	equal(moderation.results[2].scores.harassment, 0.9)
	equal(lastRequest().body.model, "omni-moderation-latest")

	local check = openai:check("BAD words")
	expect(not check.allowed)
	equal(check.violations[1].category, "harassment")

	equal(openai:check("BAD words", { allow = { "harassment" } }).allowed, true)
	local strict = openai:check("fine", { defaultThreshold = 0.25 })
	equal(strict.allowed, false)
	equal(strict.violations[1].category, "violence")
	equal(openai:check("fine", { thresholds = { violence = 0.5 }, block = { "violence" } }).allowed, true)

	openai:moderate({ { type = "text", text = "hi" }, AI.imageData("AAAA", "image/jpeg") })
	local input = lastRequest().body.input
	equal(input[2].image_url.url, "data:image/jpeg;base64,AAAA")

	local reevaluated = AI.evaluate(moderation, { block = { "violence" } })
	equal(reevaluated.allowed, true)
end)

test("moderation guard blocks input and output", function()
	local guarded = AI.new({
		provider = "anthropic",
		apiKey = "sk-ant-test",
		baseUrl = BASE,
		defaultModel = "claude-test",
		moderation = { client = openai },
	})
	equal(guarded:create({ prompt = "hello" }).text, "Hi there")
	local ok, err = pcall(function()
		return guarded:create({ prompt = "BAD input" })
	end)
	expect(not ok and err.kind == "moderation" and err.check and not err.check.allowed)

	local before = #log
	local okStream, streamErr = pcall(function()
		return guarded:stream({ prompt = "BAD input" })
	end)
	expect(not okStream and streamErr.kind == "moderation")
	equal(log[before + 1].path, "/v1/moderations", "blocked before the model was called")
	equal(#log, before + 1)

	local outputGuarded = AI.new({
		provider = "openai",
		apiKey = "sk-test",
		baseUrl = BASE,
		defaultModel = "gpt-test",
		moderation = { input = false, policy = { defaultThreshold = 0.2 } },
	})
	local okOutput, outputErr = pcall(function()
		return outputGuarded:create({ prompt = "anything" })
	end)
	expect(not okOutput and outputErr.kind == "moderation" and string.find(outputErr.message, "output", 1, true))
	local streamed = outputGuarded:stream({ prompt = "anything" })
	local okAwait, awaitErr = pcall(streamed.await, streamed)
	expect(not okAwait and awaitErr.kind == "moderation")
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
