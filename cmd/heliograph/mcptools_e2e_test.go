package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/heliograph-io/heliograph/internal/estate"
	"github.com/heliograph-io/heliograph/internal/mcp"
	"github.com/heliograph-io/heliograph/internal/wire"
)

// call finds a shipped tool by name and runs it. Going through the real tool
// list rather than the function behind it means a tool that is defined but
// never registered fails here rather than in a client.
func call(t *testing.T, name string, args map[string]any) (string, error) {
	t.Helper()
	for _, tl := range tools() {
		if tl.Name == name {
			if tl.CallWithProgress != nil {
				return tl.CallWithProgress(args, func(float64, float64, string) {})
			}
			return tl.Call(args)
		}
	}
	t.Fatalf("no tool named %q", name)
	return "", nil
}

// estateOnDisk builds a real share estate in a temp directory and points the
// config at it, so the tools resolve it exactly as they would in the field.
func estateOnDisk(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	share := filepath.Join(root, "share")
	if err := os.MkdirAll(share, 0o755); err != nil {
		t.Fatal(err)
	}
	e := estate.Estate{Name: "payments", Transport: "share", Dir: share, Scope: "probe"}
	if err := e.Save(); err != nil {
		t.Fatal(err)
	}
	return share
}

// scopeDir is where the share transport keeps one investigation. Written to
// directly here because these tests stand in for the far side, which this
// process never runs.
func scopeDir(t *testing.T, share string) string {
	t.Helper()
	d := filepath.Join(share, "probe")
	if err := os.MkdirAll(filepath.Join(d, "ops-logs"), 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestEstatesListsWhatWasConfigured(t *testing.T) {
	estateOnDisk(t)
	out, err := call(t, "heliograph_estates", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "payments") || !strings.Contains(out, "transport=share") {
		t.Errorf("got %q", out)
	}
}

// A single estate needs no naming. Making an agent state it every time is how
// a wrong estate gets a request when there is more than one.
func TestOneEstateIsTheDefault(t *testing.T) {
	share := estateOnDisk(t)
	scopeDir(t, share)
	if _, err := call(t, "heliograph_send", map[string]any{"step": "net-probe"}); err != nil {
		t.Fatalf("a single estate was not defaulted to: %v", err)
	}
}

// With two, guessing is worse than asking. The error has to name them, because
// an agent that cannot see the config cannot look them up.
func TestSeveralEstatesRefuseToGuess(t *testing.T) {
	estateOnDisk(t)
	second := estate.Estate{Name: "cardnet", Transport: "share", Dir: t.TempDir(), Scope: "probe"}
	if err := second.Save(); err != nil {
		t.Fatal(err)
	}
	_, err := call(t, "heliograph_status", map[string]any{})
	if err == nil {
		t.Fatal("a guess was made between two estates")
	}
	for _, want := range []string{"payments", "cardnet"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the error does not name %s: %v", want, err)
		}
	}
}

// The whole point of the send tool: what an agent asks for has to arrive on the
// far side as a document the station can act on, with the env intact.
func TestSendWritesARequestTheStationCanRead(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)

	out, err := call(t, "heliograph_send", map[string]any{
		"step": "net-probe",
		"env":  map[string]any{"HOSTS": "sql01 sql02", "PORT": "1433"},
		"note": "checking the cluster",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "net-probe") {
		t.Errorf("the reply does not say what was sent: %q", out)
	}

	b, err := os.ReadFile(filepath.Join(d, "request"))
	if err != nil {
		t.Fatalf("no request reached the far side: %v", err)
	}
	got := string(b)
	// The space-bearing value must arrive quoted. Unquoted, the station sets
	// HOSTS=sql01 and then tries to RUN sql02.
	if !strings.Contains(got, `HOSTS='sql01 sql02'`) {
		t.Errorf("HOSTS arrived unquoted:\n%s", got)
	}
	if !strings.Contains(got, "step: net-probe") {
		t.Errorf("step missing:\n%s", got)
	}
	if !strings.Contains(got, "note: checking the cluster") {
		t.Errorf("note missing:\n%s", got)
	}
	// Sorted, so two identical calls produce identical documents rather than
	// ones that differ only in map order.
	if strings.Index(got, "HOSTS") > strings.Index(got, "PORT") {
		t.Errorf("env is not in a stable order:\n%s", got)
	}
}

func TestStatusReportsWhatTheStationPublished(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"),
		"state: running\nid: 20260101T000000Z-net-probe\nstep: net-probe\nhost: sql01\nprogress: 412 lines\nlast: probing 5985\n")

	out, err := call(t, "heliograph_status", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"state: running", "step: net-probe", "progress: 412 lines", "last: probing 5985"} {
		if !strings.Contains(out, want) {
			t.Errorf("status is missing %q:\n%s", want, out)
		}
	}
}

// A refusal is not a failure, and an agent that reads it as one will retry the
// same step forever. The reply says what would permit it instead.
func TestRefusalExplainsItself(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"),
		"state: refused\nid: 20260101T000000Z-restart\nstep: restart-svc\nreason: this step changes state\n")

	out, err := call(t, "heliograph_status", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "reason: this step changes state") {
		t.Errorf("the station's own reason was dropped:\n%s", out)
	}
	if !strings.Contains(out, "--allow-actions") || !strings.Contains(out, "CONFIRM=yes") {
		t.Errorf("the reply does not say what would permit it:\n%s", out)
	}
}

// An empty status means the station was never started. Reporting that as
// "state: " sends somebody to debug the transport instead.
func TestNoStatusSaysTheStationMayNotBeRunning(t *testing.T) {
	share := estateOnDisk(t)
	scopeDir(t, share)
	out, err := call(t, "heliograph_status", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "not have been started") {
		t.Errorf("got %q", out)
	}
}

const stalledLog = `12:00:00 | starting net-probe
12:00:01 | resolving sql01
12:00:02 | connecting to sql01:5985
12:02:30 | timed out after 148s
12:02:31 | resolving sql02
12:02:32 | connected
`

func TestReadLogReturnsItWhole(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "ops-logs", "20260101T000000Z-net-probe.txt"), stalledLog)

	out, err := call(t, "heliograph_read_log", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if out != stalledLog {
		t.Errorf("the log came back altered:\n%q", out)
	}
}

func TestLogsNamesTheCaptures(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "ops-logs", "20260101T000000Z-net-probe.txt"), stalledLog)
	write(t, filepath.Join(d, "ops-logs", "20260102T000000Z-disk-check.txt"), stalledLog)

	out, err := call(t, "heliograph_logs", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	// Newest first, because the one you want is almost always the last run.
	if lines[0] != "20260102T000000Z-disk-check.txt" {
		t.Errorf("logs are not newest first: %v", lines)
	}
}

// The gap is attributed to the line BEFORE it, which is what was running. Get
// this backwards and the tool blames the timeout message for the timeout.
func TestGapsBlamesTheLineThatWasRunning(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "ops-logs", "20260101T000000Z-net-probe.txt"), stalledLog)

	out, err := call(t, "heliograph_gaps", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "connecting to sql01:5985") {
		t.Errorf("the stall was not attributed to the connect:\n%s", out)
	}
	if strings.Contains(out, "No interval") {
		t.Errorf("a 148 second stall was reported as nothing:\n%s", out)
	}
}

func TestGapsRespectsItsThreshold(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "ops-logs", "20260101T000000Z-net-probe.txt"), stalledLog)

	out, err := call(t, "heliograph_gaps", map[string]any{"min_seconds": 300.0})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "No interval") {
		t.Errorf("a 148 second stall was reported above a 300 second threshold:\n%s", out)
	}
}

// Every line carrying the same timestamp means the capture was buffered, and a
// buffered log cannot answer the question at all. Reporting "no gaps" from one
// is worse than reporting nothing: it is a clean bill of health from an
// instrument that was switched off.
func TestGapsRefusesABufferedLog(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "ops-logs", "20260101T000000Z-net-probe.txt"),
		"12:00:00 | starting\n12:00:00 | working\n12:00:00 | done\n")

	out, err := call(t, "heliograph_gaps", map[string]any{})
	if err == nil {
		t.Fatalf("a buffered log was analysed anyway: %q", out)
	}
}

func TestDoctorReportsAReachableTransportWithoutChangingAnything(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)

	out, err := call(t, "heliograph_doctor", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "ok: the transport is reachable") {
		t.Errorf("doctor could not reach a directory it can write to:\n%s", out)
	}
	if !strings.Contains(out, "estate: payments") {
		t.Errorf("doctor does not say which estate it checked:\n%s", out)
	}
	// Nothing was published, so nothing should have been.
	if _, err := os.Stat(filepath.Join(d, "request")); err == nil {
		t.Error("doctor wrote a request")
	}
}

func TestDoctorFailsLoudlyWhenTheTransportIsGone(t *testing.T) {
	share := estateOnDisk(t)
	if err := os.RemoveAll(share); err != nil {
		t.Fatal(err)
	}
	out, err := call(t, "heliograph_doctor", map[string]any{})
	// A transport that is gone is news, not an exception: the reply says so in
	// text an agent can act on rather than a protocol error it will stop at.
	if err != nil {
		return
	}
	if !strings.Contains(out, "FAIL") {
		t.Errorf("a missing share directory passed the check:\n%s", out)
	}
}

// The tools go out through the same server a client talks to, so a schema that
// will not marshal or a call that panics shows up here rather than at a client.
func TestToolsAreCallableThroughTheServer(t *testing.T) {
	estateOnDisk(t)
	var out strings.Builder
	s := mcp.NewServer("heliograph", "test", tools())
	in := strings.NewReader(
		`{"jsonrpc":"2.0","id":1,"method":"tools/list"}` + "\n" +
			`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"heliograph_estates","arguments":{}}}` + "\n")
	if err := s.Serve(in, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "heliograph_doctor") {
		t.Errorf("tools/list did not carry the tools:\n%s", out.String())
	}
	if !strings.Contains(out.String(), "payments") {
		t.Errorf("the call did not reach the estate:\n%s", out.String())
	}
}

// With an id, a status about any other request is not this request's result.
// Straight after a send the status still describes the previous run, and a
// model shown that run's refusal reads it as a refusal of the step it just
// sent.
func TestStatusWithAnIDSaysNotPickedUpYet(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"),
		"state: refused\nid: 20260101T000000Z-restart\nstep: restart-svc\nreason: this step changes state\n")

	out, err := call(t, "heliograph_status", map[string]any{"id": "20260101T000100Z-env"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "Not picked up yet: 20260101T000100Z-env") {
		t.Errorf("a status about another request was not reported as not picked up:\n%s", out)
	}
	if strings.Contains(out, "--allow-actions") {
		t.Errorf("the earlier request's refusal was reported as this one's:\n%s", out)
	}

	// The id that IS on the status gets the full answer, refusal and all.
	out, err = call(t, "heliograph_status", map[string]any{"id": "20260101T000000Z-restart"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "reason: this step changes state") {
		t.Errorf("the matching id did not get the station's answer:\n%s", out)
	}

	// Sent through the tool, the reply tells the caller to pass the id.
	out, err = call(t, "heliograph_send", map[string]any{"step": "env"})
	if err != nil {
		t.Fatal(err)
	}
	id := strings.TrimPrefix(strings.SplitN(out, "\n", 2)[0], "sent ")
	if !strings.Contains(out, "heliograph_wait with id "+id) || !strings.Contains(out, "heliograph_status with it") {
		t.Errorf("the send reply does not say to wait, or poll, with the id:\n%s", out)
	}
}

// The CLI and the MCP tool publish the same request.
//
// They used to build it separately, and the MCP copy left out the target, the
// expiry and the mode and skipped Validate. A request an agent sent was valid
// for ever and bound to no station, which is the replay the CLI's defaults
// exist to prevent - and nothing said so, because both requests ran.
func TestCLIAndMCPSendTheSameRequest(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	read := func() wire.Request {
		t.Helper()
		b, err := os.ReadFile(filepath.Join(d, "request"))
		if err != nil {
			t.Fatalf("no request reached the far side: %v", err)
		}
		r, err := wire.ParseRequest(b)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	window := func(what string, r wire.Request, want time.Duration) {
		t.Helper()
		at, err := time.Parse(time.RFC3339, r.Expires)
		if err != nil {
			t.Errorf("%s: expires %q is not a time", what, r.Expires)
			return
		}
		if got := time.Until(at); got < want-time.Minute || got > want+time.Minute {
			t.Errorf("%s: expires in %s, want about %s", what, got.Round(time.Second), want)
		}
	}

	if err := cmdSend([]string{"env", "--mode", "read-only"}); err != nil {
		t.Fatal(err)
	}
	cli := read()

	if _, err := call(t, "heliograph_send", map[string]any{"step": "env", "mode": "read-only"}); err != nil {
		t.Fatal(err)
	}
	tool := read()

	if cli.Target == "" || tool.Target != cli.Target {
		t.Errorf("target: CLI %q, MCP %q - both should name the station, %q", cli.Target, tool.Target, "probe")
	}
	if tool.Mode != cli.Mode || tool.Mode != "read-only" {
		t.Errorf("mode: CLI %q, MCP %q", cli.Mode, tool.Mode)
	}
	window("CLI", cli, defaultExpiry)
	window("MCP", tool, defaultExpiry)

	// The tool's own expiry, and its way of turning it off.
	if _, err := call(t, "heliograph_send", map[string]any{"step": "net", "expires": "90m"}); err != nil {
		t.Fatal(err)
	}
	window("MCP with 90m", read(), 90*time.Minute)
	if _, err := call(t, "heliograph_send", map[string]any{"step": "tools", "expires": "0"}); err != nil {
		t.Fatal(err)
	}
	if r := read(); r.Expires != "" {
		t.Errorf("expires 0 still wrote an expiry: %q", r.Expires)
	}

	// And the tool validates, as the CLI does. A mode that is neither would be
	// refused on a machine nobody can reach.
	if _, err := call(t, "heliograph_send", map[string]any{"step": "env", "mode": "sometimes"}); err == nil {
		t.Error("the tool published a request with a mode no station accepts")
	}
	if _, err := call(t, "heliograph_send", map[string]any{"step": "env", "expires": 0.0}); err == nil {
		t.Error("a numeric expires was accepted; 0 would have silently meant a day")
	}
}

// heliograph_send makes the refusal `heliograph send` makes. A status that names
// another scope means no station has published from this one, and a request
// sent there is never picked up.
func TestSendToolRefusesAScopeNoStationReads(t *testing.T) {
	share := estateOnDisk(t)
	d := scopeDir(t, share)
	write(t, filepath.Join(d, "status"), "state:    idle\nid:       20260901T000000Z-env\nbranch:   elsewhere\n")

	out, err := call(t, "heliograph_send", map[string]any{"step": "env"})
	if err == nil {
		t.Fatalf("the tool published to a scope whose status names another:\n%s", out)
	}
	if !strings.Contains(err.Error(), `"elsewhere"`) || !strings.Contains(err.Error(), `"probe"`) {
		t.Errorf("the refusal does not name both scopes: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(d, "request")); statErr == nil {
		t.Error("the refused request was written anyway")
	}

	// Its own scope, and the same call goes through.
	write(t, filepath.Join(d, "status"), "state:    idle\nid:       20260901T000000Z-env\nbranch:   probe\n")
	if _, err := call(t, "heliograph_send", map[string]any{"step": "env"}); err != nil {
		t.Errorf("the tool refused a scope whose status is its own: %v", err)
	}
}

// heliograph_send says when it replaces a request the station has not read,
// exactly as `heliograph send` does. The station holds one request, not a
// queue, and an agent that sent two in a row believed both had run.
func TestSendToolNamesTheUnrunRequestItReplaces(t *testing.T) {
	share := estateOnDisk(t)
	scopeDir(t, share)

	first, err := call(t, "heliograph_send", map[string]any{"step": "env"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(first, "replaced") {
		t.Errorf("the first send claimed to replace something:\n%s", first)
	}
	id := strings.TrimPrefix(strings.SplitN(first, "\n", 2)[0], "sent ")

	time.Sleep(1100 * time.Millisecond)
	second, err := call(t, "heliograph_send", map[string]any{"step": "net"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(second, "replaced unrun request "+id) {
		t.Errorf("the second send did not name the unrun request it replaced (%s):\n%s", id, second)
	}
}
