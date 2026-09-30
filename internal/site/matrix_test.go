package site

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

// A pairing naming a transport that does not exist is a cell that silently
// does nothing: the grid draws it as impossible, the count treats it as dead,
// and nothing anywhere says a word. This is the only thing that would notice.
func TestEveryPairingNamesATransportThatExists(t *testing.T) {
	known := map[string]bool{}
	for _, tr := range Transports {
		known[tr.ID] = true
	}
	for _, s := range Stations {
		for id := range s.Transports {
			if !known[id] {
				t.Errorf("station %q pairs with transport %q, which does not exist", s.ID, id)
			}
		}
	}
	for _, c := range Controllers {
		for id := range c.Transports {
			if !known[id] {
				t.Errorf("controller %q pairs with transport %q, which does not exist", c.ID, id)
			}
		}
	}
}

// Two rows with the same ID is two rows the grid cannot tell apart: the cell
// key is station.transport, so a duplicate silently overwrites a whole row of
// the payload the panel reads from.
func TestIDsAreUnique(t *testing.T) {
	for _, g := range []struct {
		name string
		ids  []string
	}{{"transport", transportIDs()}, {"station", stationIDs()}, {"controller", controllerIDs()}} {
		seen := map[string]bool{}
		for _, id := range g.ids {
			if seen[id] {
				t.Errorf("duplicate %s id %q", g.name, id)
			}
			seen[id] = true
		}
	}
}

func transportIDs() []string {
	out := make([]string, 0, len(Transports))
	for _, t := range Transports {
		out = append(out, t.ID)
	}
	return out
}

func stationIDs() []string {
	out := make([]string, 0, len(Stations))
	for _, s := range Stations {
		out = append(out, s.ID)
	}
	return out
}

func controllerIDs() []string {
	out := make([]string, 0, len(Controllers))
	for _, c := range Controllers {
		out = append(out, c.ID)
	}
	return out
}

// A transport with no station side cannot run ANYWHERE, whatever a host row
// claims about it. resolve() checks that first for exactly this reason, and
// without the check the object store and the bundle light up four rows each
// that can never run.
func TestATransportWithNoStationSideRunsNowhere(t *testing.T) {
	for _, tr := range Transports {
		if tr.Station != Missing {
			continue
		}
		for _, s := range Stations {
			if c := resolve(s, tr); c.State != CellNone {
				t.Errorf("%q has no station side, but %q resolves to %q", tr.Name, s.Name, c.State)
			}
		}
	}
}

// Every cell that cannot run has to say why. "No" with no reason is the thing
// a reader has to go and ask somebody about, which is the failure this whole
// page exists to avoid.
func TestEveryDeadCellCarriesItsReason(t *testing.T) {
	for _, s := range Stations {
		for _, tr := range Transports {
			c := resolve(s, tr)
			if c.State == CellNone && strings.TrimSpace(c.Note) == "" {
				t.Errorf("%s over %s cannot run and says nothing about why", s.Name, tr.Name)
			}
		}
	}
}

// The grid has to be complete in the HTML before a line of script runs. Most
// of this site's readers are agents, and a grid that assembles itself on load
// is an empty page to every one of them.
func TestTheGridIsCompleteWithoutJavaScript(t *testing.T) {
	h := Matrix()
	for _, s := range Stations {
		for _, tr := range Transports {
			key := s.ID + "." + tr.ID
			if !strings.Contains(h, `data-cell="`+key+`"`) {
				t.Errorf("cell %q is not in the rendered grid", key)
			}
		}
	}
	// Every state must be on the cell itself, not applied later from the
	// payload, or the no-script reader sees seventy identical squares.
	for _, want := range []string{`data-state="proven"`, `data-state="none"`} {
		if !strings.Contains(h, want) {
			t.Errorf("the grid renders no %s cell", want)
		}
	}
	// Nothing may start filtered out: dimming is what a control means, and a
	// reader with no script has pressed nothing.
	if strings.Contains(h, "data-dim") {
		t.Error("the grid ships with something already dimmed, so a no-script reader sees a filtered view")
	}
}

// The panel reads from this payload. If a cell key is absent the panel shows
// the wrong pair or nothing at all, and neither is visible from the grid.
func TestThePayloadCoversEveryCell(t *testing.T) {
	h := Matrix()
	const open = `<script type="application/json" id="mx-data">`
	i := strings.Index(h, open)
	if i < 0 {
		t.Fatal("the matrix renders no data payload, so nothing can be interactive")
	}
	raw := h[i+len(open):]
	raw = raw[:strings.Index(raw, "</script>")]

	var p struct {
		Cells map[string]Cell `json:"cells"`
	}
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("the payload is not valid JSON, so every reader gets a dead grid: %v", err)
	}
	for _, s := range Stations {
		for _, tr := range Transports {
			key := s.ID + "." + tr.ID
			if _, known := p.Cells[key]; !known {
				t.Errorf("cell %q is drawn in the grid and missing from the payload", key)
			}
		}
	}
}

// A "<" reaching the browser unescaped inside a script tag ends the script
// early and takes the rest of the page with it. The JSON-LD block guards the
// same trap; this one carries prose written by whoever edits the data.
func TestThePayloadCannotCloseItsOwnScriptTag(t *testing.T) {
	h := Matrix()
	i := strings.Index(h, `id="mx-data">`)
	raw := h[i:]
	raw = raw[:strings.Index(raw, "</script>")]
	if strings.Contains(raw, "<") {
		t.Error("the payload contains a raw < inside a script tag, which truncates the page")
	}
	// Prove the assertion can see the thing it guards, rather than passing on
	// data that happens to contain no angle bracket. This is the liveness
	// check AGENTS.md's redaction-corpus lesson asks for: without it, a payload
	// with no "<" in it and no escaping at all reads exactly like a pass.
	hostile, err := json.Marshal(map[string]string{"n": "</script><img onerror=alert(1)>"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(hostile), "<") {
		t.Error("encoding/json is not escaping < any more, so the payload can close its own tag")
	}
}

// All shipped transports must carry one of the three shapes, or the page's
// central claim is decoration. The flare is the only member of its kind and
// would be the one lost. The beam is designed and not yet built (S4), so it is
// permitted here and not required.
func TestTransportShapesArePresent(t *testing.T) {
	var beacon, flare, beam int
	for _, tr := range Transports {
		switch tr.Kind {
		case Beacon:
			beacon++
		case Flare:
			flare++
		case Beam:
			beam++
		default:
			t.Errorf("transport %q has no shape", tr.ID)
		}
	}
	if beacon == 0 || flare == 0 {
		t.Fatalf("want the beacon and the flare represented, got %d beacon and %d flare", beacon, flare)
	}
}

// The count above the grid is a claim about the grid. If it is computed any
// other way than the cells are drawn, it is a number that disagrees with what
// the reader can see and count themselves.
func TestTheCountMatchesTheCellsDrawn(t *testing.T) {
	// Counted off the CELLS, not off the whole page: the legend and the panel
	// carry a data-state too, and counting those made this pass at 37 against
	// a grid drawing 36.
	h := Matrix()
	drawn := 0
	for _, m := range regexp.MustCompile(`data-cell="[^"]*" data-state="([a-z]+)"`).FindAllStringSubmatch(h, -1) {
		if m[1] != "none" {
			drawn++
		}
	}
	if got := countRunnable(); got != drawn {
		t.Errorf("the bar claims %d runnable combinations, the grid draws %d", got, drawn)
	}
}

// A column head with no short name is a column head that wraps to three lines
// and pushes the grid into a scrollbar.
func TestEveryRowAndColumnHasAShortName(t *testing.T) {
	for _, tr := range Transports {
		if len(tr.Short) == 0 || len(tr.Short) > 10 {
			t.Errorf("transport %q has short name %q, want 1 to 10 characters", tr.ID, tr.Short)
		}
	}
	for _, s := range Stations {
		if len(s.Short) == 0 || len(s.Short) > 20 {
			t.Errorf("station %q has short name %q, want 1 to 20 characters", s.ID, s.Short)
		}
	}
}

// Exactly one cell button may be in the tab order. Seventy tabbable buttons
// is a grid nobody reaches the far side of, and the script moves this one
// rather than adding to it. Found by an adversarial review, not by use.
func TestExactlyOneCellIsInTheTabOrder(t *testing.T) {
	// Counted on the CELL buttons only. The filter chips are a radiogroup and
	// carry a roving tabindex of their own, which made a first version of this
	// test report four when it meant one.
	h := Matrix()
	if n := strings.Count(h, `tabindex="0" aria-pressed=`); n != 1 {
		t.Errorf("want exactly 1 cell button in the tab order, found %d", n)
	}
	want := len(Stations)*len(Transports) - 1
	if n := strings.Count(h, `tabindex="-1" aria-pressed=`); n != want {
		t.Errorf("want %d cells out of the tab order, found %d", want, n)
	}
}

// Colour alone cannot carry five states. Every state must differ in SHAPE as
// well as hue, or the two solid swatches read identically to a colour-blind
// reader - which is exactly how proven and works shipped the first time.
func TestEveryStateHasItsOwnShapeNotJustItsOwnColour(t *testing.T) {
	shapes := map[State]string{}
	for _, st := range []State{CellProven, CellWorks, CellNeeds, CellUntest} {
		i := strings.Index(MatrixCSS, `[data-state="`+string(st)+`"] .mxa-dot{`)
		if i < 0 {
			t.Fatalf("no rule for state %q", st)
		}
		rule := MatrixCSS[i:]
		rule = rule[:strings.Index(rule, "}")]
		// The shape is what is left once the hue is taken out of the rule.
		var geom []string
		for _, decl := range strings.Split(rule, ";") {
			d := strings.TrimSpace(decl)
			switch {
			case strings.HasPrefix(d, "border-radius:"), strings.HasPrefix(d, "border:"):
				geom = append(geom, d)
			case strings.HasPrefix(d, "background:none"):
				geom = append(geom, d)
			}
		}
		key := strings.Join(geom, "|")
		if prev, clash := shapes[State(key)]; clash {
			t.Errorf("states %q and %q are the same shape (%s) and differ only by colour", prev, st, key)
		}
		shapes[State(key)] = string(st)
	}
}

// Mutually exclusive options are radios. aria-pressed on a set of them tells a
// screen reader they are independent switches, and three reading as "pressed"
// with nothing saying only one can be is worse than no markup at all.
func TestTheFilterChipsAreRadiosNotToggles(t *testing.T) {
	h := Matrix()
	if strings.Contains(h, `class="mxa-chip" role="radio"`) == false {
		t.Error("the filter chips are not radios")
	}
	if strings.Contains(h, `class="mxa-chip" data-f`) {
		t.Error("a filter chip has no role, so it reads as an independent toggle")
	}
	for _, group := range []string{"kind", "ctl", "only"} {
		n := strings.Count(h, `data-f="`+group+`" data-v=`)
		checked := strings.Count(h, `data-f="`+group+`" data-v="`+onValue(group)+`" aria-checked="true"`)
		if n < 2 {
			t.Errorf("filter group %q has %d options, want at least 2", group, n)
		}
		if checked != 1 {
			t.Errorf("filter group %q has %d options checked, want exactly 1", group, checked)
		}
	}
}

func onValue(group string) string {
	switch group {
	case "kind":
		return "all"
	case "ctl":
		return "any"
	default:
		return "all"
	}
}

// The page is an application, not an essay with a widget in it. Both shape
// definitions have to survive the prose being cut, because that cut is what
// this page was asked for and losing the distinction with it would be the
// content disappearing rather than moving.
func TestBothShapesAreDefinedInsideTheApp(t *testing.T) {
	h := Matrix()
	for _, kind := range []Kind{Beacon, Flare} {
		if !strings.Contains(h, `data-def="`+string(kind)+`"`) {
			t.Errorf("the app carries no definition of %q", kind)
		}
	}
	if !strings.Contains(h, "dead letter drop") {
		t.Error("the beacon definition has lost the phrase the station itself uses")
	}
}

// On a phone the panel is a sheet that rises over the grid, so it needs a way
// back. A sheet with no close is a sheet that eats the bottom of the screen.
func TestThePanelCanBeClosed(t *testing.T) {
	if !strings.Contains(Matrix(), "data-close") {
		t.Error("the detail panel has no close control, so the mobile sheet cannot be dismissed")
	}
	if !strings.Contains(MatrixCSS, ".mxa-panel[data-open]") {
		t.Error("the panel has no open state, so the mobile sheet can never rise")
	}
}

// Tap targets. A cell is a button on a grid somebody will use with a thumb,
// and the WCAG 2.2 minimum is 24px with 44px the comfortable target.
func TestCellsAreBigEnoughToTap(t *testing.T) {
	if !strings.Contains(MatrixCSS, "min-height:2.9rem") {
		t.Error("the mobile breakpoint does not raise the cell tap target")
	}
}

// A sticky cell has the grid scrolling underneath it, so its background must
// be OPAQUE or the cells behind show straight through.
//
// Found on a phone, not by a test: the lit row's label went translucent and
// the pinned cell scrolled under it was visible inside the word "Terminal".
// The cause is the background shorthand - `background:rgba(...)` discards the
// opaque colour the sticky rule set, where `background-image` layers over it.
func TestStickyCellsNeverLoseTheirOpaqueBackground(t *testing.T) {
	sticky := []string{".mxa-corner", ".mxa-grid tbody th", ".mxa-grid thead th"}
	for _, rule := range strings.Split(MatrixCSS, "}") {
		i := strings.Index(rule, "{")
		if i < 0 {
			continue
		}
		sel, body := rule[:i], rule[i+1:]
		// Only rules that could apply to a cell which sticks.
		var touches bool
		for _, s := range sticky {
			if strings.Contains(sel, s) || strings.Contains(sel, "th[data-lit]") || strings.Contains(sel, "tr[data-lit] th") {
				touches = true
			}
		}
		if !touches {
			continue
		}
		for _, decl := range strings.Split(body, ";") {
			d := strings.TrimSpace(decl)
			if !strings.HasPrefix(d, "background:") {
				continue
			}
			v := strings.TrimPrefix(d, "background:")
			if strings.Contains(v, "rgba(") || v == "none" {
				t.Errorf("a sticky cell sets %q, which is see-through: the grid scrolls underneath it.\n"+
					"  selector: %s\n  use background-color for the opaque base and background-image for the tint",
					d, strings.TrimSpace(sel))
			}
		}
	}
}
