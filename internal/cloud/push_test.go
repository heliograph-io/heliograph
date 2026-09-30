package cloud

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// archiveStub is the ingest surface of `heliograph-io/heliograph-cloud`, as it
// stands in that repository's `cloud/src/http/ingest.ts` and
// `cloud/src/http/upload.ts`.
//
// IT IS DELIBERATELY STRICT, and every strictness is one the real thing has. A
// double more permissive than the real thing is worse than none: that lesson is
// in AGENTS.md and it was paid for by a relay stub with one token where the relay
// has two asymmetric ones. So this one refuses a chunk at an offset it did not
// expect, refuses a chunk whose digest does not match its bytes, refuses a body
// whose whole digest does not match the manifest, and answers `unknown-run` for
// a run whose status document has not arrived - which is the ordering rule the
// whole protocol rests on.
type archiveStub struct {
	mu sync.Mutex

	// what a record exists for, keyed by the run id inside the status document
	records map[string]bool
	// the status documents received, in order, with the query they arrived on
	statuses []receivedStatus
	// declared by the manifest: run id -> whole-body digest and size
	declared map[string]declaredBody
	// chunks durably held: run id -> offset -> bytes
	held map[string]map[int64][]byte
	// completed bodies, assembled
	stored map[string][]byte

	manifests int
	chunkPuts int
	auth      []string

	failAfterChunks int  // drop the connection after this many chunk PUTs
	corruptChunk    int  // answer 422 on this chunk, whatever its digest says
	overAcknowledge bool // claim more received bytes than arrived
	missingSequence []string
}

type receivedStatus struct {
	body      string
	station   string
	transport string
	sequence  string
	runID     string
}

type declaredBody struct {
	sha256 string
	bytes  int64
}

func newArchiveStub() *archiveStub {
	return &archiveStub{
		records:  map[string]bool{},
		declared: map[string]declaredBody{},
		held:     map[string]map[int64][]byte{},
		stored:   map[string][]byte{},
	}
}

func (a *archiveStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	a.auth = append(a.auth, r.Header.Get("Authorization"))
	a.mu.Unlock()
	switch {
	case r.URL.Path == "/ingest/status" && r.Method == http.MethodPost:
		a.status(w, r)
	case r.URL.Path == "/ingest/manifest" && r.Method == http.MethodPost:
		a.manifest(w, r)
	case strings.HasSuffix(r.URL.Path, "/chunk") && r.Method == http.MethodPut:
		a.chunk(w, r)
	case strings.HasSuffix(r.URL.Path, "/complete") && r.Method == http.MethodPost:
		a.complete(w, r)
	default:
		http.Error(w, `{"problem":"not found"}`, 404)
	}
}

func (a *archiveStub) status(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	// The document is the body, and it is line-based text. Anything that
	// arrives as a JSON envelope is a rendering of the evidence rather than the
	// evidence, and is refused here the way it would be there.
	if strings.HasPrefix(strings.TrimSpace(string(raw)), "{") {
		http.Error(w, `{"problem":"the status document must arrive as its own bytes, not wrapped in JSON"}`, 400)
		return
	}
	id := fieldOf(string(raw), "id")
	if id == "" {
		http.Error(w, `{"problem":"the status document carries no id:"}`, 400)
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	created := !a.records[id]
	a.records[id] = true
	a.statuses = append(a.statuses, receivedStatus{
		body: string(raw), station: r.URL.Query().Get("station"),
		transport: r.URL.Query().Get("transport"), sequence: r.URL.Query().Get("sequence"),
		runID: id,
	})
	status := 200
	if created {
		status = 201
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"run": id, "station": r.URL.Query().Get("station"),
		"state": fieldOf(string(raw), "state"), "created": created, "gap": nil,
	})
}

func (a *archiveStub) manifest(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Station string `json:"station"`
		Runs    []struct {
			RunID  string `json:"run_id"`
			Seq    uint64 `json:"seq"`
			SHA256 string `json:"sha256"`
			Bytes  int64  `json:"bytes"`
		} `json:"runs"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, `{"problem":"the manifest must be JSON"}`, 400)
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.manifests++

	items := []map[string]any{}
	for _, run := range body.Runs {
		switch {
		case !a.records[run.RunID]:
			// THE STATUS DOCUMENT ARRIVES FIRST. The record is built from it,
			// because a manifest is a summary and the archive does not build
			// evidence out of summaries.
			items = append(items, map[string]any{"runId": run.RunID, "verdict": "unknown-run"})
		case len(a.stored[run.RunID]) > 0:
			items = append(items, map[string]any{
				"runId": run.RunID, "verdict": "have",
				"sha256": sha256Of(a.stored[run.RunID]), "bytes": len(a.stored[run.RunID]),
			})
		default:
			a.declared[run.RunID] = declaredBody{sha256: run.SHA256, bytes: run.Bytes}
			offsets := []int64{}
			var received int64
			for o, b := range a.held[run.RunID] {
				offsets = append(offsets, o)
				received += int64(len(b))
			}
			sort.Slice(offsets, func(i, j int) bool { return offsets[i] < offsets[j] })
			if len(offsets) == 0 {
				items = append(items, map[string]any{"runId": run.RunID, "verdict": "send"})
			} else {
				items = append(items, map[string]any{
					"runId": run.RunID, "verdict": "resume",
					"held": offsets, "receivedBytes": received,
				})
			}
		}
	}
	completeness := "unverified"
	if len(a.missingSequence) > 0 {
		completeness = "gap-detected"
	}
	_ = json.NewEncoder(w).Encode(map[string]any{
		"station": body.Station,
		"runs": map[string]any{
			"items": items, "completeness": completeness, "missing": a.missingSequence,
		},
	})
}

func (a *archiveStub) chunk(w http.ResponseWriter, r *http.Request) {
	run := runFromPath(r.URL.Path)
	offset, _ := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	declared := r.URL.Query().Get("sha256")
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, `{"problem":"short body"}`, 400)
		return
	}

	a.mu.Lock()
	defer a.mu.Unlock()
	a.chunkPuts++

	if a.failAfterChunks > 0 && a.chunkPuts > a.failAfterChunks {
		// A DROPPED CONNECTION, not a refusal. The client has to survive never
		// hearing back at all, which is the case resume exists for.
		if hj, ok := w.(http.Hijacker); ok {
			if conn, _, herr := hj.Hijack(); herr == nil {
				_ = conn.Close()
				return
			}
		}
		panic(http.ErrAbortHandler)
	}
	if a.corruptChunk > 0 && a.chunkPuts == a.corruptChunk {
		w.WriteHeader(422)
		_, _ = fmt.Fprintf(w, `{"problem":"the chunk at offset %d of run %s hashes to %s and the upload said %s. %d bytes were received; resend that chunk"}`,
			offset, run, sha256Of(body), declared, len(body))
		return
	}
	if _, open := a.declared[run]; !open {
		w.WriteHeader(409)
		_, _ = fmt.Fprintf(w, `{"problem":"no upload is open for run %s. Declare it in a manifest first"}`, run)
		return
	}
	if got := sha256Of(body); got != declared {
		w.WriteHeader(422)
		_, _ = fmt.Fprintf(w, `{"problem":"the chunk at offset %d of run %s hashes to %s and the upload said %s"}`,
			offset, run, got, declared)
		return
	}
	if a.held[run] == nil {
		a.held[run] = map[int64][]byte{}
	}
	duplicate := false
	if prev, ok := a.held[run][offset]; ok {
		if sha256Of(prev) != sha256Of(body) {
			w.WriteHeader(409)
			_, _ = fmt.Fprintf(w, `{"problem":"offset %d of run %s already holds different bytes"}`, offset, run)
			return
		}
		duplicate = true
	}
	a.held[run][offset] = body
	var received int64
	for _, b := range a.held[run] {
		received += int64(len(b))
	}
	if a.overAcknowledge {
		received += 512
	}
	status := 201
	if duplicate {
		status = 200
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"receipt": "chunk-" + run + "-" + strconv.FormatInt(offset, 10),
		"runId":   run, "offset": offset, "bytes": len(body), "sha256": sha256Of(body),
		"storedAt": "2026-09-13T09:00:00Z", "receivedBytes": received,
		"declaredBytes": a.declared[run].bytes,
	})
}

func (a *archiveStub) complete(w http.ResponseWriter, r *http.Request) {
	run := runFromPath(r.URL.Path)
	a.mu.Lock()
	defer a.mu.Unlock()

	d, open := a.declared[run]
	if !open {
		w.WriteHeader(409)
		_, _ = fmt.Fprintf(w, `{"problem":"no upload is open for run %s"}`, run)
		return
	}
	offsets := []int64{}
	for o := range a.held[run] {
		offsets = append(offsets, o)
	}
	sort.Slice(offsets, func(i, j int) bool { return offsets[i] < offsets[j] })
	var whole []byte
	for _, o := range offsets {
		whole = append(whole, a.held[run][o]...)
	}
	// VERIFIED BEFORE IT IS STORED, so a body that is not the body that was
	// promised is never written at all.
	if sha256Of(whole) != d.sha256 {
		w.WriteHeader(422)
		_, _ = fmt.Fprintf(w, `{"problem":"run %s assembles to %s and the manifest said %s"}`,
			run, sha256Of(whole), d.sha256)
		return
	}
	a.stored[run] = whole
	_ = json.NewEncoder(w).Encode(map[string]any{
		"receipt": "receipt-" + run, "runId": run, "bytes": len(whole),
		"sha256": d.sha256, "chunks": len(offsets), "storedAt": "2026-09-13T09:00:00Z", "gap": nil,
	})
}

// The stub is driven from the test goroutine while its handlers run on
// others, so every field a test reads or writes goes through the same mutex
// the handlers use. Without these the hijacked connection in the interruption
// case races the assertion that follows it.

func (a *archiveStub) setFailAfter(n int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.failAfterChunks = n
}

func (a *archiveStub) setCorruptChunk(n int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.corruptChunk = n
}

func (a *archiveStub) setOverAcknowledge(v bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.overAcknowledge = v
}

func (a *archiveStub) setMissingSequence(m []string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.missingSequence = m
}

func (a *archiveStub) body(run string) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return string(a.stored[run])
}

func (a *archiveStub) bodiesStored() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.stored)
}

func (a *archiveStub) heldBytes(run string) int {
	a.mu.Lock()
	defer a.mu.Unlock()
	n := 0
	for _, b := range a.held[run] {
		n += len(b)
	}
	return n
}

func (a *archiveStub) chunkCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.chunkPuts
}

func (a *archiveStub) manifestCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.manifests
}

func (a *archiveStub) received() []receivedStatus {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]receivedStatus{}, a.statuses...)
}

func (a *archiveStub) authSeen() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]string{}, a.auth...)
}

func runFromPath(p string) string {
	parts := strings.Split(strings.Trim(p, "/"), "/")
	for i, s := range parts {
		if s == "run" && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return ""
}

func sha256Of(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func fieldOf(doc, key string) string {
	for _, line := range strings.Split(doc, "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(k) == key {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// --- fixtures ----------------------------------------------------------------

func bigLog(n int) string {
	var b strings.Builder
	b.WriteString(envLog)
	for i := 0; b.Len() < n; i++ {
		fmt.Fprintf(&b, "09:00:%02d | line %d of a capture that does not fit in one chunk\n", i%60, i)
	}
	return b.String()
}

func statusFor(runID, state, logName string, extra string) string {
	s := "state: " + state + "\nid: " + runID + "\nstep: env\n" + extra
	if logName != "" {
		s += "log: ops-logs/" + logName + "\n"
	}
	return s
}

func pushService(t *testing.T, a *archiveStub) *Service {
	t.Helper()
	srv := httptest.NewServer(a)
	t.Cleanup(srv.Close)
	s, err := NewService(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func pushSpool(t *testing.T, s *Service, dir string, chunk int) (Result, error) {
	t.Helper()
	sp, err := Read(dir)
	if err != nil {
		t.Fatal(err)
	}
	return s.Push(Target{Station: "db-a", Auth: Control("estate-token"), ChunkBytes: chunk}, sp)
}

// --- the tests ---------------------------------------------------------------

// THE STATUS DOCUMENT ARRIVES FIRST AND IT ARRIVES RAW. The archive builds the
// record from those bytes and derives every column from them, so a control node
// that re-encoded one into JSON would hand over a rendering of the evidence.
// The transport context goes in the query string for exactly that reason.
func TestPushSendsEachStatusDocumentRawAndBeforeTheBody(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000001.txt": statusFor("run-1", "running", "", "utc: 20260913T090001Z\n"),
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\nutc: 20260913T090012Z\n"),
		"ops-logs/env-1.txt":         envLog,
	})
	a := newArchiveStub()
	s := pushService(t, a)

	res, err := pushSpool(t, s, dir, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if len(a.received()) != 2 {
		t.Fatalf("want both transitions sent, got %d", len(a.received()))
	}
	// EVERY TRANSITION, because ingest upserts and never goes backwards, so
	// re-sending is safe and expected - and a record that never saw the run
	// start is a record with no `started`.
	for i, want := range []string{"running", "idle"} {
		if fieldOf(a.received()[i].body, "state") != want {
			t.Errorf("status %d is %q, want %q in order", i, fieldOf(a.received()[i].body, "state"), want)
		}
	}
	if a.received()[0].transport != "relay" {
		t.Errorf("transport %q, want relay in the query string", a.received()[0].transport)
	}
	if a.received()[0].station != "db-a" {
		t.Errorf("station %q, want the station wire id in the query string", a.received()[0].station)
	}
	if a.received()[1].sequence != "2" {
		t.Errorf("sequence %q, want the signed sequence in the query string", a.received()[1].sequence)
	}
	// Byte for byte, exactly as it was collected.
	want := statusFor("run-1", "idle", "env-1.txt", "exit: 0\nutc: 20260913T090012Z\n")
	if a.received()[1].body != want {
		t.Errorf("the status body was altered:\n got %q\nwant %q", a.received()[1].body, want)
	}
	if len(res.StatusesSent) != 2 {
		t.Errorf("the result reports %d statuses sent", len(res.StatusesSent))
	}
}

func TestPushStoresEveryBodyByteForByteAsItWasDelivered(t *testing.T) {
	body := bigLog(20000)
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"statuses/status-000004.txt": statusFor("run-2", "idle", "env-2.txt", "exit: 1\n"),
		"ops-logs/env-1.txt":         envLog,
		"ops-logs/env-2.txt":         body,
	})
	a := newArchiveStub()
	s := pushService(t, a)

	res, err := pushSpool(t, s, dir, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Uploaded) != 2 {
		t.Fatalf("want 2 uploaded, got %v", res.Uploaded)
	}
	if a.body("run-1") != envLog {
		t.Errorf("run-1 stored %d bytes, want the log exactly", len(a.body("run-1")))
	}
	if a.body("run-2") != body {
		t.Errorf("run-2 stored %d bytes, want %d exactly", len(a.body("run-2")), len(body))
	}
	for _, id := range []string{"run-1", "run-2"} {
		if res.Receipts[id].Receipt == "" {
			t.Errorf("%s: no receipt was recorded, so nothing can be proved later about what was handed over", id)
		}
		if res.Receipts[id].SHA256 != sha256Of([]byte(a.body(id))) {
			t.Errorf("%s: the receipt's digest is not the digest of what was stored", id)
		}
	}
}

func TestPushIsIdempotentBecauseTheManifestSaysWhatToSkip(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         bigLog(9000),
	})
	a := newArchiveStub()
	s := pushService(t, a)

	if _, err := pushSpool(t, s, dir, 4096); err != nil {
		t.Fatal(err)
	}
	first := a.chunkCount()
	stored := len(a.body("run-1"))

	res, err := pushSpool(t, s, dir, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Uploaded) != 0 {
		t.Errorf("a second push uploaded %v: push has to be cheap to run habitually", res.Uploaded)
	}
	if len(res.Skipped) != 1 {
		t.Errorf("the second push skipped %v, want the one run the archive already holds", res.Skipped)
	}
	if a.chunkCount() != first {
		t.Errorf("%d chunk(s) were sent again on a repeat push", a.chunkCount()-first)
	}
	if len(a.body("run-1")) != stored {
		t.Errorf("the body grew to %d bytes from %d: it was stored twice over", len(a.body("run-1")), stored)
	}
}

func TestAnInterruptedPushResumesAndProducesOneStoredBody(t *testing.T) {
	body := bigLog(40000)
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         body,
	})
	a := newArchiveStub()
	a.setFailAfter(3)
	s := pushService(t, a)

	if _, err := pushSpool(t, s, dir, 4096); err == nil {
		t.Fatal("a push whose connection dropped reported success")
	}
	partial := a.heldBytes("run-1")
	if partial == 0 || partial >= len(body) {
		t.Fatalf("the interruption left %d of %d bytes, which is not an interruption", partial, len(body))
	}
	if len(a.body("run-1")) != 0 {
		t.Fatal("an interrupted run was completed")
	}

	a.setFailAfter(0)
	before := a.chunkCount()
	res, err := pushSpool(t, s, dir, 4096)
	if err != nil {
		t.Fatalf("the resumed push failed: %v", err)
	}
	if len(res.Uploaded) != 1 {
		t.Fatalf("the resumed push uploaded %v", res.Uploaded)
	}
	if a.body("run-1") != body {
		t.Errorf("the resumed body is %d bytes and the log is %d: it was duplicated or truncated",
			len(a.body("run-1")), len(body))
	}
	if len(res.Resumed) != 1 || res.Resumed[0] != "run-1" {
		t.Errorf("the push did not report that it resumed: %v", res.Resumed)
	}
	// AND IT RESUMED RATHER THAN STARTED AGAIN. The chunks already held were
	// not sent a second time.
	outstanding := (len(body)-partial+4095)/4096 + 1
	if sent := a.chunkCount() - before; sent > outstanding {
		t.Errorf("the resumed push sent %d chunks for %d outstanding: it started again", sent, outstanding)
	}
}

func TestACorruptedChunkIsRefusedWithAMessageNamingTheChunk(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         bigLog(20000),
	})
	a := newArchiveStub()
	a.setCorruptChunk(2)
	s := pushService(t, a)

	_, err := pushSpool(t, s, dir, 4096)
	if err == nil {
		t.Fatal("a corrupted chunk was accepted")
	}
	// "Upload failed" at the end of a 200 MB transfer tells somebody to send
	// the whole thing again. The offset says which 4 KB to resend.
	if !strings.Contains(err.Error(), "offset 4096") {
		t.Errorf("the error does not name which chunk was rejected: %v", err)
	}
	if !strings.Contains(err.Error(), "run-1") {
		t.Errorf("the error does not name the run: %v", err)
	}
}

func TestAReceiptClaimingMoreThanWasSentIsNotBelieved(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         bigLog(9000),
	})
	a := newArchiveStub()
	a.setOverAcknowledge(true)
	s := pushService(t, a)

	_, err := pushSpool(t, s, dir, 4096)
	if err == nil {
		t.Fatal("a receipt acknowledging bytes that were never sent was accepted")
	}
	if !strings.Contains(err.Error(), "acknowledged") {
		t.Errorf("the error does not say what disagreed: %v", err)
	}
}

// The project's rule, applied here: a failed push never loses a log, and it
// names the local path rather than exiting on it. Each round trip through an
// operator is expensive and none may be wasted by tooling that only reports
// success.
func TestAFailedPushNamesTheLocalPathOfWhatItCouldNotSend(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         bigLog(20000),
	})
	a := newArchiveStub()
	a.setFailAfter(1)
	s := pushService(t, a)

	_, err := pushSpool(t, s, dir, 4096)
	if err == nil {
		t.Fatal("the push reported success")
	}
	want := filepath.Join(dir, "ops-logs", "env-1.txt")
	if !strings.Contains(err.Error(), want) {
		t.Errorf("the failure does not name the local copy at %s: %v", want, err)
	}
}

// "It puts it back afterwards" is not "it changes nothing". Snapshot the tree,
// not one path: that lesson is in AGENTS.md, paid for by a preflight that wrote a
// probe file with a fixed name and destroyed what was already there.
func TestThePushLeavesTheSpoolExactlyAsItFoundIt(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"statuses/status-000004.txt": statusFor("run-2", "idle", "env-2.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         envLog,
		"ops-logs/env-2.txt":         bigLog(9000),
		"ops-logs/relay-000009.txt":  "an orphan\n",
		"status":                     statusFor("run-2", "idle", "env-2.txt", "exit: 0\n"),
	})
	before := snapshot(t, dir)

	a := newArchiveStub()
	s := pushService(t, a)
	if _, err := pushSpool(t, s, dir, 4096); err != nil {
		t.Fatal(err)
	}
	if after := snapshot(t, dir); after != before {
		t.Errorf("the spool changed.\nbefore:\n%s\nafter:\n%s", before, after)
	}
}

// AND IT STAYS UNTOUCHED WHEN THE PUSH FAILS, which is the harder half: a
// failure path that tidied up would be the one that mutated the archive.
func TestTheSpoolIsUntouchedByAFailedPushToo(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         bigLog(20000),
	})
	before := snapshot(t, dir)

	a := newArchiveStub()
	a.setFailAfter(1)
	s := pushService(t, a)
	if _, err := pushSpool(t, s, dir, 4096); err == nil {
		t.Fatal("the push reported success")
	}
	if after := snapshot(t, dir); after != before {
		t.Errorf("a failed push changed the spool.\nbefore:\n%s\nafter:\n%s", before, after)
	}
}

// A body no status names cannot be attributed to a run, so it is reported by
// name rather than uploaded under an invented id. Silence about it would be the
// worse answer: somebody would believe the archive holds it.
func TestABodyNoStatusNamesIsReportedAndNotUploaded(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         envLog,
		"ops-logs/relay-000009.txt":  "collected with no status naming it\n",
	})
	a := newArchiveStub()
	s := pushService(t, a)

	res, err := pushSpool(t, s, dir, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Unattributable) != 1 || !strings.Contains(res.Unattributable[0], "relay-000009.txt") {
		t.Fatalf("the unattributable body was not reported: %v", res.Unattributable)
	}
	if a.bodiesStored() != 1 {
		t.Errorf("%d bodies were stored, want only the one that has a run to belong to", a.bodiesStored())
	}
}

// `unknown-run` means the archive has no record to attach a body to. Retrying
// the body would fail for ever; the answer is to say so, naming the run.
func TestAnUnknownRunVerdictIsReportedRatherThanRetried(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         envLog,
	})
	a := newArchiveStub()
	// The record is never created, so the manifest answers unknown-run.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/ingest/status" {
			_, _ = io.ReadAll(r.Body)
			w.WriteHeader(201)
			_, _ = w.Write([]byte(`{"run":"run-1","created":true}`))
			return
		}
		a.ServeHTTP(w, r)
	}))
	defer srv.Close()
	s, err := NewService(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	sp, err := Read(dir)
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Push(Target{Station: "db-a", Auth: Control("t"), ChunkBytes: 4096}, sp)
	if err == nil {
		t.Fatal("an unknown-run verdict was reported as a successful push")
	}
	if !strings.Contains(err.Error(), "run-1") {
		t.Errorf("the error does not name the run: %v", err)
	}
	if a.chunkCount() != 0 {
		t.Errorf("%d chunk(s) were sent for a run the archive has no record of", a.chunkCount())
	}
	if len(res.Uploaded) != 0 {
		t.Errorf("uploaded %v", res.Uploaded)
	}
}

// The archive's completeness sentences are the archive's, and they reach the
// reader unedited. A client that summarised them would be composing its own
// claim about what is missing.
func TestPushCarriesTheServicesOwnCompletenessSentences(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         envLog,
	})
	a := newArchiveStub()
	a.setMissingSequence([]string{"sequences 2 to 3 were never received"})
	s := pushService(t, a)

	res, err := pushSpool(t, s, dir, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Missing) != 1 || res.Missing[0] != "sequences 2 to 3 were never received" {
		t.Fatalf("the service's own sentence did not reach the result: %v", res.Missing)
	}
	if res.Completeness != "gap-detected" {
		t.Errorf("completeness %q, want the service's own word", res.Completeness)
	}
}

// Ingest is sent the ESTATE credential under the `Control` scheme, and not the
// account one. Presenting the wrong credential is refused at the parser, so a
// client that reused a variable would fail in a way that reads as a service
// fault.
func TestIngestPresentsTheEstateCredentialUnderControl(t *testing.T) {
	dir := writeSpool(t, map[string]string{
		"statuses/status-000002.txt": statusFor("run-1", "idle", "env-1.txt", "exit: 0\n"),
		"ops-logs/env-1.txt":         envLog,
	})
	a := newArchiveStub()
	s := pushService(t, a)
	if _, err := pushSpool(t, s, dir, 4096); err != nil {
		t.Fatal(err)
	}
	if len(a.authSeen()) == 0 {
		t.Fatal("nothing was sent")
	}
	for i, got := range a.authSeen() {
		if got != "Control estate-token" {
			t.Fatalf("call %d carried %q, want the estate credential under Control", i, got)
		}
	}
}

func TestPushingAnEmptySpoolSendsNothingAndSaysSo(t *testing.T) {
	a := newArchiveStub()
	s := pushService(t, a)
	res, err := pushSpool(t, s, t.TempDir(), 4096)
	if err != nil {
		t.Fatalf("an empty spool is the ordinary state of a new estate: %v", err)
	}
	if a.manifestCount() != 0 || len(a.received()) != 0 {
		t.Errorf("an empty spool produced %d manifest(s) and %d status(es)", a.manifestCount(), len(a.received()))
	}
	if len(res.Uploaded) != 0 || len(res.Skipped) != 0 {
		t.Errorf("result %+v", res)
	}
}

// snapshot describes a whole tree: every path, its mode, its size and a digest
// of its contents.
func snapshot(t *testing.T, dir string) string {
	t.Helper()
	var lines []string
	err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, rerr := filepath.Rel(dir, p)
		if rerr != nil {
			return rerr
		}
		if info.IsDir() {
			lines = append(lines, fmt.Sprintf("d %s %04o", rel, info.Mode().Perm()))
			return nil
		}
		b, rerr := os.ReadFile(p)
		if rerr != nil {
			return rerr
		}
		lines = append(lines, fmt.Sprintf("f %s %04o %d %s",
			rel, info.Mode().Perm(), info.Size(), sha256Of(b)[:16]))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}
