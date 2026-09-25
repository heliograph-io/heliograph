// Package transport moves the wire documents across the gap, and knows nothing
// about what they mean.
//
// The verbs match the station-side contract in the master design, so that the
// two halves of a transport can be described in one sentence. When the relay
// lands it satisfies this interface unchanged, and the CLI above it does not
// learn that anything happened.
package transport

import "github.com/heliograph-io/heliograph/internal/wire"

// Transport is what a control side can do to a station.
//
// Deliberately small. Every method here is something the CLI genuinely needs;
// anything a single transport happens to be able to do stays off this
// interface, because the relay must be able to satisfy all of it and an
// interface that only git can implement is not an interface.
type Transport interface {
	// FetchStatus reads what the station last published. A station that has
	// never run has published nothing, and that is not an error: the zero
	// Status says so and the caller decides what to print.
	FetchStatus() (wire.Status, error)

	// PutRequest publishes a request and does not return until it has
	// arrived. A request that is merely committed locally is invisible to the
	// station while looking, from here, exactly like success.
	PutRequest(wire.Request) error

	// ListLogs names the captured logs, newest first, because the one you
	// want is almost always the last run.
	ListLogs() ([]string, error)

	// ReadLog returns one log whole. There is no line limit and there will
	// not be one: the line somebody truncates is the line they needed.
	ReadLog(name string) ([]byte, error)

	// Check answers "will this work from here" without changing anything, so
	// the question can be settled before a long run captures evidence it then
	// cannot deliver.
	Check() error

	// Describe names the credential mechanism in force, by kind and length,
	// never by value.
	Describe() string
}

// RequestReader is a transport whose published request can be read back from
// this side: git, where it is a file in the checkout, and the file share.
//
// NOT ON Transport, because the relay cannot satisfy it. A relay request is
// sealed for the station and deleted when the station collects it, so nothing
// here can read it again.
//
// It exists for `cancel` and `stop`. Those set one field on the request already
// in the slot rather than writing a new one, because the slot may hold a
// request queued behind the running step, and a new document would replace it.
type RequestReader interface {
	// FetchRequest returns the request this side last published. A slot that
	// has never held one is the zero Request, not an error.
	FetchRequest() (wire.Request, error)
}
