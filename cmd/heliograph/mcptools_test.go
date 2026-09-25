package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// The descriptions are the interface. A model does not read the code; it reads
// these and decides. Every assertion here is about what a model would conclude.
func TestShippedToolsAreDescribedWellEnoughToChooseBy(t *testing.T) {
	for _, tl := range tools() {
		if !strings.HasPrefix(tl.Name, "heliograph_") {
			t.Errorf("%s: a tool name should say whose it is", tl.Name)
		}
		if len(tl.Description) < 40 {
			t.Errorf("%s: description is too thin to choose by: %q", tl.Name, tl.Description)
		}
		if tl.Schema["type"] != "object" {
			t.Errorf("%s: schema type = %v, want object", tl.Name, tl.Schema["type"])
		}
		if (tl.Call == nil) == (tl.CallWithProgress == nil) {
			t.Errorf("%s: needs exactly one of Call and CallWithProgress", tl.Name)
		}
		// The schema must survive the trip. A map that will not marshal is a
		// tools/list that fails at the point a client is deciding what exists.
		if _, err := json.Marshal(tl.Schema); err != nil {
			t.Errorf("%s: schema will not marshal: %v", tl.Name, err)
		}
	}
}

func TestSendIsDescribedAsNotWaiting(t *testing.T) {
	var send string
	for _, tl := range tools() {
		if tl.Name == "heliograph_send" {
			send = tl.Description
		}
	}
	if send == "" {
		t.Fatal("there is no heliograph_send")
	}
	// A model that thinks send returns the result will read a stale log and
	// report the previous run's answer as this one's.
	if !strings.Contains(send, "does NOT wait") {
		t.Errorf("send does not say it returns before the run finishes: %q", send)
	}
	// And a model that does not know the station can refuse will read a refusal
	// as a crash.
	if !strings.Contains(send, "refused") {
		t.Errorf("send does not mention that the station may refuse: %q", send)
	}
}

func TestEveryToolTakesAnEstateExceptTheOneThatLists(t *testing.T) {
	for _, tl := range tools() {
		props := tl.Schema["properties"].(map[string]any)
		_, has := props["estate"]
		if tl.Name == "heliograph_estates" {
			if has {
				t.Errorf("%s: listing estates should not need one named", tl.Name)
			}
			continue
		}
		if !has {
			t.Errorf("%s: no estate argument, so it can only ever act on a default", tl.Name)
		}
	}
}

func TestSendRequiresAStep(t *testing.T) {
	for _, tl := range tools() {
		if tl.Name != "heliograph_send" {
			continue
		}
		req, _ := tl.Schema["required"].([]string)
		if len(req) != 1 || req[0] != "step" {
			t.Errorf("required = %v, want [step]", req)
		}
		// And the guard holds even if a client ignores the schema.
		if _, err := tl.Call(map[string]any{}); err == nil {
			t.Error("a call with no step was accepted")
		}
	}
}

func TestGapsToolDefaultsAreDocumented(t *testing.T) {
	for _, tl := range tools() {
		if tl.Name != "heliograph_gaps" {
			continue
		}
		props := tl.Schema["properties"].(map[string]any)
		min, ok := props["min_seconds"].(map[string]any)
		if !ok {
			t.Fatal("no min_seconds argument")
		}
		if !strings.Contains(min["description"].(string), "10") {
			t.Errorf("the default is not stated: %v", min["description"])
		}
		if !strings.Contains(tl.Description, "BEFORE") {
			t.Error("the description does not say which line a gap is attributed to")
		}
	}
}
