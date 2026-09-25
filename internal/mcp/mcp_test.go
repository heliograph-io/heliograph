package mcp

import (
	"encoding/json"
	"strings"
	"testing"
)

// exchange runs the server over a fixed script of lines and returns whatever it
// wrote back, one decoded frame per element. The server reads until the input
// closes, so a test is a transcript rather than a sequence of calls.
func exchange(t *testing.T, tools []Tool, lines ...string) []map[string]any {
	t.Helper()
	var out strings.Builder
	s := NewServer("test", "0.0.0", tools)
	if err := s.Serve(strings.NewReader(strings.Join(lines, "\n")+"\n"), &out); err != nil {
		t.Fatalf("serve: %v", err)
	}
	var got []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("reply is not JSON: %q: %v", l, err)
		}
		got = append(got, m)
	}
	return got
}

func echoTool() Tool {
	return Tool{
		Name:        "echo",
		Description: "returns its text",
		Schema:      map[string]any{"type": "object"},
		Call: func(a map[string]any) (string, error) {
			if Bool(a, "fail") {
				return "", errTest
			}
			return Str(a, "text"), nil
		},
	}
}

var errTest = &testError{"the far side said no"}

type testError struct{ s string }

func (e *testError) Error() string { return e.s }

func TestInitializeAnswersWithProtocolVersion(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	if len(got) != 1 {
		t.Fatalf("want 1 reply, got %d: %v", len(got), got)
	}
	res, ok := got[0]["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result: %v", got[0])
	}
	// No version asked for, so the newest.
	if res["protocolVersion"] != protocolVersions[0] {
		t.Errorf("protocolVersion = %v, want %s", res["protocolVersion"], protocolVersions[0])
	}
	caps, _ := res["capabilities"].(map[string]any)
	if _, ok := caps["tools"]; !ok {
		t.Errorf("capabilities do not advertise tools: %v", caps)
	}
	info, _ := res["serverInfo"].(map[string]any)
	if info["name"] != "test" {
		t.Errorf("serverInfo.name = %v, want test", info["name"])
	}
}

// A notification has no id. Answering one is a protocol error that some clients
// tolerate and others hang on, so the silence is the assertion.
func TestNotificationGetsNoReply(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if len(got) != 0 {
		t.Fatalf("a notification was answered: %v", got)
	}
}

// An unknown method sent as a notification is still a notification. This is the
// case a switch on the method name alone gets wrong.
func TestUnknownNotificationGetsNoReply(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","method":"notifications/somethingNewer"}`)
	if len(got) != 0 {
		t.Fatalf("an unknown notification was answered: %v", got)
	}
}

func TestUnknownMethodWithIDIsAnError(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","id":7,"method":"resources/list"}`)
	if len(got) != 1 {
		t.Fatalf("want 1 reply, got %d", len(got))
	}
	e, ok := got[0]["error"].(map[string]any)
	if !ok {
		t.Fatalf("want an error, got %v", got[0])
	}
	if e["code"].(float64) != -32601 {
		t.Errorf("code = %v, want -32601", e["code"])
	}
	if !strings.Contains(e["message"].(string), "resources/list") {
		t.Errorf("the message does not name the method: %v", e["message"])
	}
}

func TestToolsListCarriesNameDescriptionAndSchema(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	res := got[0]["result"].(map[string]any)
	list := res["tools"].([]any)
	if len(list) != 1 {
		t.Fatalf("want 1 tool, got %d", len(list))
	}
	tool := list[0].(map[string]any)
	for _, k := range []string{"name", "description", "inputSchema"} {
		if _, ok := tool[k]; !ok {
			t.Errorf("tool is missing %q: %v", k, tool)
		}
	}
	// A model picks a tool by reading this. An empty description makes the
	// choice a guess.
	if tool["description"] == "" {
		t.Error("the description is empty")
	}
}

func TestToolsListIsSorted(t *testing.T) {
	a := Tool{Name: "zebra", Schema: map[string]any{}, Call: func(map[string]any) (string, error) { return "", nil }}
	b := Tool{Name: "aardvark", Schema: map[string]any{}, Call: func(map[string]any) (string, error) { return "", nil }}
	got := exchange(t, []Tool{a, b}, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	list := got[0]["result"].(map[string]any)["tools"].([]any)
	if list[0].(map[string]any)["name"] != "aardvark" {
		t.Errorf("tools are not sorted: %v", list)
	}
}

func TestToolsCallReturnsTextContent(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}`)
	res := got[0]["result"].(map[string]any)
	content := res["content"].([]any)
	first := content[0].(map[string]any)
	if first["type"] != "text" || first["text"] != "hello" {
		t.Errorf("content = %v", content)
	}
	if _, ok := res["isError"]; ok {
		t.Errorf("a successful call set isError: %v", res)
	}
}

// A failing tool returns a RESULT with isError, not a JSON-RPC error. A model
// that sees a JSON-RPC error tends to stop; one that sees an error result reads
// the message and adjusts. This is the difference between "your call was
// malformed" and "the far side said no", and they are not the same news.
func TestToolFailureIsAResultNotAProtocolError(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"fail":true}}}`)
	if _, isRPCError := got[0]["error"]; isRPCError {
		t.Fatalf("a tool failure came back as a JSON-RPC error: %v", got[0])
	}
	res := got[0]["result"].(map[string]any)
	if res["isError"] != true {
		t.Errorf("isError not set: %v", res)
	}
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, "the far side said no") {
		t.Errorf("the tool's own message was lost: %q", text)
	}
}

// Calling a tool that does not exist IS a malformed call, so this one is a
// JSON-RPC error. The distinction only means something if both sides of it hold.
func TestUnknownToolIsAProtocolError(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}`)
	e, ok := got[0]["error"].(map[string]any)
	if !ok {
		t.Fatalf("want an error, got %v", got[0])
	}
	if !strings.Contains(e["message"].(string), "nope") {
		t.Errorf("the message does not name the tool: %v", e["message"])
	}
}

// A tool result can carry a whole captured log. The default scanner limit is
// 64KB and truncating a log is the one thing this product refuses to do
// anywhere else, so the limit has to be raised on the way in as well as out.
func TestLargeResultIsNotTruncated(t *testing.T) {
	big := strings.Repeat("x", 2<<20) // 2MB
	tool := Tool{
		Name: "big", Description: "returns a large log-shaped result",
		Schema: map[string]any{"type": "object"},
		Call:   func(map[string]any) (string, error) { return big, nil },
	}
	got := exchange(t, []Tool{tool},
		`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"big","arguments":{}}}`)
	text := got[0]["result"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"].(string)
	if len(text) != len(big) {
		t.Errorf("result was truncated: %d bytes out of %d", len(text), len(big))
	}
}

// The same limit applies to what arrives. A large argument is rarer than a
// large result, but a scanner that gives up mid-line ends the session silently.
func TestLargeRequestIsRead(t *testing.T) {
	big := strings.Repeat("y", 2<<20)
	var seen string
	tool := Tool{
		Name: "sink", Description: "records the argument it was given",
		Schema: map[string]any{"type": "object"},
		Call: func(a map[string]any) (string, error) {
			seen = Str(a, "text")
			return "ok", nil
		},
	}
	line, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": map[string]any{"name": "sink", "arguments": map[string]any{"text": big}},
	})
	if err != nil {
		t.Fatal(err)
	}
	exchange(t, []Tool{tool}, string(line))
	if len(seen) != len(big) {
		t.Errorf("argument arrived truncated: %d bytes out of %d", len(seen), len(big))
	}
}

func TestGarbageLineIsAParseErrorAndDoesNotEndTheSession(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`not json at all`,
		`{"jsonrpc":"2.0","id":9,"method":"tools/list"}`)
	if len(got) != 2 {
		t.Fatalf("the session ended early: %v", got)
	}
	e := got[0]["error"].(map[string]any)
	if e["code"].(float64) != -32700 {
		t.Errorf("code = %v, want -32700", e["code"])
	}
	if _, ok := got[1]["result"]; !ok {
		t.Errorf("the next request was not served: %v", got[1])
	}
}

func TestBlankLinesAreIgnored(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		``, `   `, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	if len(got) != 1 {
		t.Fatalf("blank lines produced replies: %v", got)
	}
}

func TestEveryReplyCarriesJSONRPCTwo(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","id":1,"method":"initialize"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"nope"}`)
	for i, m := range got {
		if m["jsonrpc"] != "2.0" {
			t.Errorf("reply %d: jsonrpc = %v", i, m["jsonrpc"])
		}
	}
}

// The id comes back verbatim, including a string id. A client that sent "a" and
// gets 0 back cannot match the reply to the call.
func TestIDIsEchoedVerbatim(t *testing.T) {
	got := exchange(t, []Tool{echoTool()},
		`{"jsonrpc":"2.0","id":"a-string-id","method":"tools/list"}`)
	if got[0]["id"] != "a-string-id" {
		t.Errorf("id = %v, want a-string-id", got[0]["id"])
	}
}

func TestArgumentHelpers(t *testing.T) {
	args := map[string]any{
		"s": "text", "b": true, "n": 3.0,
		"m": map[string]any{"K": "v", "skipped": 1},
	}
	if Str(args, "s") != "text" || Str(args, "b") != "" || Str(args, "missing") != "" {
		t.Error("Str")
	}
	if !Bool(args, "b") || Bool(args, "s") || Bool(args, "missing") {
		t.Error("Bool")
	}
	m := StrMap(args, "m")
	if m["K"] != "v" {
		t.Errorf("StrMap dropped a string value: %v", m)
	}
	// A non-string value is dropped rather than coerced: env is shell text, and
	// guessing how a number should be spelled is how a value arrives wrong.
	if _, ok := m["skipped"]; ok {
		t.Errorf("StrMap coerced a non-string: %v", m)
	}
	if len(StrMap(args, "missing")) != 0 {
		t.Error("StrMap of a missing key should be empty, not nil-panicking")
	}
}

// The version the client asks for, when this server knows it, and its newest
// otherwise. It answered 2024-11-05 to everybody, which has no tool
// annotations, so no client could tell a read from a write.
func TestInitializeNegotiatesTheProtocolVersion(t *testing.T) {
	for asked, want := range map[string]string{
		"2025-06-18": "2025-06-18",
		"2025-03-26": "2025-03-26",
		"2024-11-05": "2024-11-05",
		"2099-01-01": "2025-06-18",
	} {
		got := exchange(t, []Tool{echoTool()},
			`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"`+asked+`"}}`)
		res := got[0]["result"].(map[string]any)
		if res["protocolVersion"] != want {
			t.Errorf("asked %s, answered %v, want %s", asked, res["protocolVersion"], want)
		}
	}
}

// A read-only tool says so, and every other tool says it may change things, so
// a client can let a model read without asking and still gate a write.
func TestToolsListCarriesAnnotations(t *testing.T) {
	ro := echoTool()
	ro.Name = "reader"
	ro.ReadOnly = true
	got := exchange(t, []Tool{echoTool(), ro},
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	for _, x := range got[0]["result"].(map[string]any)["tools"].([]any) {
		tool := x.(map[string]any)
		ann, ok := tool["annotations"].(map[string]any)
		if !ok {
			t.Fatalf("%v carries no annotations", tool["name"])
		}
		switch tool["name"] {
		case "reader":
			if ann["readOnlyHint"] != true {
				t.Errorf("a read-only tool is not marked read-only: %v", ann)
			}
		case "echo":
			if ann["readOnlyHint"] != false || ann["destructiveHint"] != true {
				t.Errorf("a tool that may change things is not marked so: %v", ann)
			}
		}
	}
}

// Progress goes to the client that asked for it, with its token, before the
// result. A client that did not ask gets none: a notification it has no
// request to match is noise at best.
func TestProgressIsSentOnlyWhenAskedFor(t *testing.T) {
	slow := Tool{
		Name:   "slow",
		Schema: map[string]any{"type": "object"},
		CallWithProgress: func(a map[string]any, p Progress) (string, error) {
			p(1, 3, "first")
			p(2, 3, "second")
			return "done", nil
		},
	}
	got := exchange(t, []Tool{slow},
		`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow","arguments":{},"_meta":{"progressToken":"tok-1"}}}`)
	if len(got) != 3 {
		t.Fatalf("want two progress notifications and a result, got %d: %v", len(got), got)
	}
	for i, want := range []string{"first", "second"} {
		if got[i]["method"] != "notifications/progress" || got[i]["id"] != nil {
			t.Fatalf("frame %d is not a progress notification: %v", i, got[i])
		}
		p := got[i]["params"].(map[string]any)
		if p["progressToken"] != "tok-1" || p["message"] != want || p["progress"] != float64(i+1) || p["total"] != float64(3) {
			t.Errorf("frame %d carries the wrong progress: %v", i, p)
		}
	}
	if got[2]["result"] == nil {
		t.Errorf("the result did not come last: %v", got[2])
	}

	quiet := exchange(t, []Tool{slow},
		`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"slow","arguments":{}}}`)
	if len(quiet) != 1 || quiet[0]["result"] == nil {
		t.Errorf("progress went to a client that did not ask for it: %v", quiet)
	}
}
