// Command heliograph-site builds the documentation.
//
// Three renderings of one source: HTML at /page, the markdown mirror at
// /page.md, and llms.txt at the root.
//
// The markdown mirror is not a nicety. Measured across all 29 pages, the same
// page costs two and a half to twenty times more bytes as HTML than as markdown -
// about seven times on the median page, five times across the whole site - so serving
// chrome to an agent is a token tax on every read, and agents read these pages
// far more often than people do. The figure used to say "roughly 31 times",
// which nobody had measured; TestTheMirrorSavingIsTheOneTheCommentsClaim now
// measures it on every build, so this sentence cannot drift again.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/heliograph-io/heliograph/internal/site"
)

// order fixes the navigation. Alphabetical would put the CLI reference before
// the quick start, which is the wrong way round for somebody arriving.
var order = []string{
	"index", "install", "quickstart", "compared",
	"claude-code", "codex", "mcp",
	"station", "bootstrap", "steps", "runner", "conformance",
	"hosts", "containers", "service", "azure", "pipelines", "windows", "air-gapped",
	"transports", "matrix", "relay", "flare", "cli", "secrets", "security", "provenance", "method",
	"licence", "roadmap",
}

// The canonical host, and it moved on 2026-09-16.
//
// This site was `heliograph.dbhq.uk` and is now `docs.heliograph.io`, so the
// documentation for a product sits on that product's domain rather than on the
// company's. The old name 301s here, root to the apex and every deep path to
// the matching page, so no published link breaks.
//
// It is one constant on purpose: it is the canonical URL, the sitemap's base,
// the Open Graph image's host and the hostname the analytics gate compares
// against. Missing one of those is how a site ends up telling a crawler it
// lives somewhere it redirects away from.
const baseURL = "https://docs.heliograph.io"

// redirects keeps a published path alive after its page is renamed, so a
// reader who followed an old link gets the new page rather than the 404
// handler.
//
// THE DAY THE HOST CHANGED ARRIVED ON 2026-09-16. This comment used to say
// _redirects was "kept here anyway because it costs nothing and is correct the
// day the host changes", and that day is past: GitHub Pages is gone and the
// site is served by a `heliograph-docs` Worker. The Worker carries its own
// copy of this map and serves a real 301 (heliograph-cloud#62), which is
// something neither GitHub Pages nor the meta-refresh stub it needed could do.
//
// The _redirects file is still emitted because Cloudflare's static-asset
// serving reads it and because it documents the moves in the build output.
// **It is not the mechanism.** If a move is added here it has to be added to
// the Worker's map too, or the file will describe a redirect nobody serves.
var redirects = [][2]string{
	{"/intercom", "/flare"},
}

func redirectsFile() string {
	var b strings.Builder
	for _, r := range redirects {
		fmt.Fprintf(&b, "%s %s 301\n", r[0], r[1])
	}
	return b.String()
}

func main() {
	src := flagOr(1, "site/content")
	out := flagOr(2, "site/dist")
	n, err := build(src, out)
	if err != nil {
		fmt.Fprintln(os.Stderr, "heliograph-site: "+err.Error())
		os.Exit(1)
	}
	fmt.Printf("built %d pages into %s\n", n, out)
}

func flagOr(i int, def string) string {
	if len(os.Args) > i {
		return os.Args[i]
	}
	return def
}

func build(src, out string) (int, error) {
	ents, err := os.ReadDir(src)
	if err != nil {
		return 0, err
	}
	var pages []site.Page
	seen := map[string]bool{}
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(src, e.Name()))
		if err != nil {
			return 0, err
		}
		slug := strings.TrimSuffix(e.Name(), ".md")
		body := string(b)
		title := site.Title(body)
		if title == "" {
			// A page with no H1 has no title, no nav entry and no llms.txt
			// line. Better to refuse the build than to publish it nameless.
			return 0, fmt.Errorf("%s has no H1, so it has no title", e.Name())
		}
		mod, err := lastModified(src, e.Name())
		if err != nil {
			return 0, err
		}
		pub, err := firstPublished(src, e.Name(), mod)
		if err != nil {
			return 0, err
		}
		pages = append(pages, site.Page{Slug: slug, Title: title, Body: body, Modified: mod, Published: pub})
		seen[slug] = true
	}
	if len(pages) == 0 {
		return 0, fmt.Errorf("no pages in %s", src)
	}

	if err := validateNavigation(src, pages, seen); err != nil {
		return 0, err
	}

	sort.Slice(pages, func(a, b int) bool { return rank(pages[a].Slug) < rank(pages[b].Slug) })

	if err := os.MkdirAll(out, 0o755); err != nil {
		return 0, err
	}
	for _, p := range pages {
		if err := os.WriteFile(filepath.Join(out, p.Slug+".html"),
			[]byte(page(p, pages)), 0o644); err != nil {
			return 0, err
		}
		// The markdown mirror, byte for byte the source - except for a
		// ```matrix fence, which is a name in the source and a grid in the
		// HTML. Left alone, the mirror says "here is a grid" and carries no
		// grid, which is a page that lies to the audience that reads mirrors
		// most.
		if err := os.WriteFile(filepath.Join(out, p.Slug+".md"),
			[]byte(site.ExpandMatrix(p.Body)), 0o644); err != nil {
			return 0, err
		}
	}
	if err := os.WriteFile(filepath.Join(out, "404.html"), []byte(notFound(pages)), 0o644); err != nil {
		return 0, err
	}
	if err := os.WriteFile(filepath.Join(out, "llms.txt"), []byte(llms(pages)), 0o644); err != nil {
		return 0, err
	}
	if err := os.WriteFile(filepath.Join(out, "llms-full.txt"), []byte(llmsFull(pages)), 0o644); err != nil {
		return 0, err
	}
	if err := os.WriteFile(filepath.Join(out, "style.css"), []byte(site.CSS+site.MatrixCSS), 0o644); err != nil {
		return 0, err
	}
	if err := os.WriteFile(filepath.Join(out, "sitemap.xml"), []byte(sitemap(pages)), 0o644); err != nil {
		return 0, err
	}
	// robots.txt names the sitemap and the markdown mirrors. Agents are the
	// heavier readership here, and llms.txt is not discoverable on its own.
	//
	// ⚠️ THE MIRRORS ARE NOW HANDLED BY X-Robots-Tag, NOT BY Disallow
	// (20 Sep 2026), and the two are not interchangeable.
	//
	// What was here before kept Googlebot and Bingbot off the mirrors with
	// `Disallow: /*.md$`, reasoning that "on GitHub Pages a .md file can carry
	// neither a canonical tag nor an X-Robots-Tag header". That was true of
	// GitHub Pages and stopped being true when this site moved to Cloudflare
	// Pages as docs.heliograph.io - the same move that made the _redirects
	// file below work at all. Cloudflare Pages honours a _headers file, so a
	// .md response can carry X-Robots-Tag after all.
	//
	// It mattered because Disallow is not noindex. Disallow stops a crawler
	// FETCHING a URL; it does not stop the URL being indexed, and it
	// guarantees the crawler never sees any instruction the response carries.
	// Each page links its mirror three times, so Google knew every mirror
	// existed, could not fetch one to learn what it was, and reported the
	// whole site under "Duplicate, Google chose different canonical than user"
	// and "Alternative page with proper canonical tag" on 20 Sep 2026.
	//
	// So the mirrors are now CRAWLABLE and marked noindex in _headers below.
	// Google fetches one, is told plainly not to index it, and stops treating
	// it as a rival for the HTML page's place. Do not reinstate the Disallow
	// alongside the header: it would hide the header and put this back.
	robots := "User-agent: *\nAllow: /\n\n" +
		"# The markdown mirrors are for agents, not for search indexes. They are\n" +
		"# crawlable on purpose and carry X-Robots-Tag: noindex - a Disallow here\n" +
		"# would stop a crawler ever seeing that header, which is how the mirrors\n" +
		"# came to be reported as duplicates.\n" +
		"Sitemap: " + baseURL + "/sitemap.xml\n" +
		"\n# Markdown mirrors of every page at <path>.md, and " + baseURL + "/llms.txt\n"
	if err := os.WriteFile(filepath.Join(out, "robots.txt"), []byte(robots), 0o644); err != nil {
		return 0, err
	}
	// Cloudflare Pages honours this file; GitHub Pages never did, which is why
	// the mirrors used to be handled with a robots.txt Disallow instead. The
	// markdown mirrors are the same content as the HTML page at a second
	// address, so they are marked noindex rather than hidden from the crawler:
	// a crawler that cannot fetch the file cannot read this header either.
	headers := "/*.md\n  X-Robots-Tag: noindex\n"
	if err := os.WriteFile(filepath.Join(out, "_headers"), []byte(headers), 0o644); err != nil {
		return 0, err
	}
	if err := os.WriteFile(filepath.Join(out, "_redirects"), []byte(redirectsFile()), 0o644); err != nil {
		return 0, err
	}
	// Fonts and the logo. Copied by the build rather than by a step in the
	// deploy workflow: a site that renders locally and ships without its
	// typeface is a failure nobody sees until it is live.
	if err := copyTree(filepath.Join(filepath.Dir(src), "assets"), filepath.Join(out, "assets")); err != nil {
		return 0, fmt.Errorf("copying assets: %w", err)
	}
	return len(pages), nil
}

// copyTree copies a directory, and refuses an empty one.
//
// An empty assets directory means the fonts and the mark are missing, and the
// site would still build, deploy, and serve in a fallback typeface. Better to
// fail here than to find out from the live page.
func copyTree(from, to string) error {
	ents, err := os.ReadDir(from)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(to, 0o755); err != nil {
		return err
	}
	n := 0
	for _, e := range ents {
		src, dst := filepath.Join(from, e.Name()), filepath.Join(to, e.Name())
		if e.IsDir() {
			if err := copyTree(src, dst); err != nil {
				return err
			}
			continue
		}
		b, err := os.ReadFile(src)
		if err != nil {
			return err
		}
		if err := os.WriteFile(dst, b, 0o644); err != nil {
			return err
		}
		n++
	}
	if n == 0 && len(ents) == 0 {
		return fmt.Errorf("%s is empty", from)
	}
	return nil
}

func sitemap(pages []site.Page) string {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	b.WriteString(`<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">` + "\n")
	for _, p := range pages {
		loc := baseURL + "/" + p.Slug
		if p.Slug == "index" {
			loc = baseURL + "/"
		}
		fmt.Fprintf(&b, "  <url><loc>%s</loc><lastmod>%s</lastmod></url>\n", loc, p.Modified)
	}
	b.WriteString("</urlset>\n")
	return b.String()
}

// validateNavigation refuses to build a site somebody could get lost in.
//
// `order` used to be the navigation, so membership in it proved reachability.
// It is now only the sort order and the llms.txt sequence: the SIDEBAR is what
// a reader navigates by, and a page can sit in `order` while appearing in no
// group at all. So all four structures are checked, because each can now be
// wrong on its own.
func validateNavigation(src string, pages []site.Page, seen map[string]bool) error {
	ordered := map[string]bool{}
	for _, slug := range order {
		if ordered[slug] {
			return fmt.Errorf("`order` names %q more than once", slug)
		}
		ordered[slug] = true
		if !seen[slug] {
			return fmt.Errorf("`order` names %q, which does not exist in %s", slug, src)
		}
	}

	// One group per page, and every page in one. A page in two groups appears
	// twice in the sidebar, which reads as two different pages.
	grouped := map[string]string{}
	for _, g := range groups {
		for _, slug := range g.slugs {
			if !seen[slug] {
				return fmt.Errorf("sidebar group %q names %q, which does not exist in %s", g.name, slug, src)
			}
			if prev, ok := grouped[slug]; ok {
				return fmt.Errorf("%q is in both sidebar groups %q and %q", slug, prev, g.name)
			}
			grouped[slug] = g.name
		}
	}

	for _, p := range pages {
		if !ordered[p.Slug] {
			return fmt.Errorf("%s.md is missing from `order`", p.Slug)
		}
		if _, ok := grouped[p.Slug]; !ok {
			return fmt.Errorf("%s.md is in no sidebar group, so nobody would find it: add it to `groups`", p.Slug)
		}
		if strings.TrimSpace(labels[p.Slug]) == "" {
			return fmt.Errorf("%s.md has no short navigation label: add it to `labels`", p.Slug)
		}
	}
	for slug := range labels {
		if !seen[slug] {
			return fmt.Errorf("`labels` names %q, which does not exist in %s", slug, src)
		}
	}

	// The home page's only route into the documentation. Without one, the site
	// has twenty-three pages and no way in.
	docs := false
	for _, item := range homeNav {
		if strings.TrimSpace(item.label) == "" {
			return fmt.Errorf("the home navigation has an empty label for %q", item.slug)
		}
		if !seen[item.slug] {
			return fmt.Errorf("the home navigation names %q, which does not exist in %s", item.slug, src)
		}
		if item.slug != "index" {
			docs = true
		}
	}
	if !docs {
		return fmt.Errorf("the home navigation has no entry into the documentation")
	}
	return nil
}

func inOrder(s string) bool {
	for _, o := range order {
		if o == s {
			return true
		}
	}
	return false
}

func rank(s string) int {
	for i, o := range order {
		if o == s {
			return i
		}
	}
	return len(order)
}

// groups fix the sidebar's sections. A flat list of eight is a list somebody
// scans twice; three short groups is one somebody reads once. The names say
// what a reader is trying to do, not what the pages are about.
var groups = []struct {
	name  string
	slugs []string
}{
	{"Start here", []string{"index", "install", "quickstart", "compared"}},
	{"Drive it from an agent", []string{"claude-code", "codex", "mcp"}},
	{"The far side", []string{"station", "bootstrap", "steps", "runner", "conformance"}},
	{"Where it runs", []string{"hosts", "containers", "service", "azure", "pipelines", "windows", "air-gapped"}},
	{"Reference", []string{"transports", "matrix", "relay", "flare", "cli", "secrets", "security", "provenance", "method", "licence", "roadmap"}},
}

// labels are the navigation's own words, and they are a THIRD set of words for
// each page, deliberately. The three have different jobs and nothing is gained
// by making one do all of them:
//
//	H1       explains the page to somebody already reading it
//	<title>  has to work with no page around it, in a tab or a search result
//	label    has to be scannable in a narrow column, at a glance
//
// The navigation used the H1, and at eight pages that was survivable. At
// twenty-three it produced a header reading "Making the loop outlive the
// session", "Flare - when you can reach the station", "Where a station can
// run" - a sitemap poured into a nav bar, three rows deep.
var labels = map[string]string{
	"index":       "Overview",
	"install":     "Install",
	"quickstart":  "Quick start",
	"compared":    "Versus Run Command",
	"claude-code": "Claude Code",
	"codex":       "Codex",
	"mcp":         "MCP server",
	"station":     "Station",
	"bootstrap":   "Plant a station",
	"steps":       "Write a step",
	"runner":      "Runner reference",
	"conformance": "Capture contract",
	"hosts":       "Host requirements",
	"containers":  "Containers",
	"service":     "Survive logout",
	"azure":       "Azure",
	"pipelines":   "Pipelines",
	"windows":     "Windows",
	"air-gapped":  "Air-gapped",
	"transports":  "Transports",
	"matrix":      "What works with what",
	"relay":       "Relay",
	"flare":       "Flare",
	"cli":         "CLI reference",
	"secrets":     "Secrets",
	"security":    "Security",
	"provenance":  "Provenance",
	"method":      "Debugging method",
	"licence":     "Licensing",
	"roadmap":     "Roadmap",
}

func label(o site.Page) string { return labels[o.Slug] }

// homeNav is the header on the marketing page, and it is SHORT on purpose.
//
// The header used to render every page. A visitor arriving at the home page was
// met with the entire documentation tree before a single sentence about what
// the thing does, which is the opposite of what a home page is for.
//
// Three links. `Docs` opens the quick start, because that is where somebody who
// has decided to try this actually wants to be, and the docs shell brings its
// grouped sidebar with it - so one link reaches all twenty-three pages. The
// brand links home and the hero already offers Source, so neither is repeated
// here.
type homeNavItem struct {
	label string
	slug  string
}

var homeNav = []homeNavItem{
	{label: "Docs", slug: "quickstart"},
	{label: "Install", slug: "install"},
	{label: "Security", slug: "security"},
}

// headerNav renders the header navigation, which exists only on the index.
//
// It used to be rendered on every page and hidden on docs pages with CSS. That
// worked and was still wrong: every docs page shipped a second copy of the
// whole navigation, which a screen reader still reaches and a stylesheet
// failure would reveal.
func headerNav(p site.Page) string {
	if p.Slug != "index" {
		return ""
	}
	var b strings.Builder
	b.WriteString(`<nav aria-label="Primary">`)
	for _, item := range homeNav {
		fmt.Fprintf(&b, `<a href="%s">%s</a>`, href(item.slug), escAttr(item.label))
	}
	// The repository, last and marked. Three words and a logo: a header that
	// lists everything is the one nobody reads.
	b.WriteString(`<a href="https://github.com/heliograph-io/heliograph">` +
		site.GitHubMark + `Source</a>` + `</nav>`)
	return b.String()
}

func href(slug string) string {
	if slug == "index" {
		return "/"
	}
	return "/" + slug
}

// sidebarItems is the documentation navigation, emitted as labelled lists.
//
// It was a flat run of <p> and <a> siblings. A group heading that is only
// visually above its links is a heading to a sighted reader and nothing at all
// to anybody else, so the groups are real lists now, each pointed at its
// heading by aria-labelledby.
//
// `prefix` exists because this is emitted TWICE on a docs page - once in the
// desktop sidebar, once inside the mobile drawer - and two elements may not
// share an id. The duplication is deliberate: a permanent sidebar and a modal
// drawer are not the same component, and pretending they are is what produces
// a drawer that cannot trap focus.
func sidebarItems(p site.Page, all []site.Page, prefix string) string {
	byslug := map[string]site.Page{}
	for _, o := range all {
		byslug[o.Slug] = o
	}
	var b strings.Builder
	for i, g := range groups {
		id := fmt.Sprintf("%s-group-%d", prefix, i)
		fmt.Fprintf(&b, `<div class="side-group"><p class="grp" id="%s">%s</p><ul aria-labelledby="%s">`,
			id, escAttr(g.name), id)
		for _, slug := range g.slugs {
			o, ok := byslug[slug]
			if !ok {
				continue
			}
			// aria-current is the machine-readable half. `here` styles it; on
			// its own it told a screen reader nothing about which page it was
			// already on.
			attrs := ""
			if o.Slug == p.Slug {
				attrs = ` class="here" aria-current="page"`
			}
			fmt.Fprintf(&b, `<li><a href="%s"%s>%s</a></li>`, href(slug), attrs, escAttr(label(o)))
		}
		b.WriteString(`</ul></div>`)
	}
	return b.String()
}

// The DBHQ menu that used to sit here was removed on 2026-09-16.
//
// It listed the company's other projects in the header of the product's own
// documentation, which made sense while this site was `heliograph.dbhq.uk` and
// a reader arriving had come to a company's domain. On `docs.heliograph.io`
// they have come to a product, and a header offering them a bulletin board and
// a Bell 103 modem is a company talking about itself on a page somebody opened
// mid-incident.

// pageHead is the breadcrumb and the two markdown controls, above the title.
//
// The breadcrumb is the reader's copy of the BreadcrumbList the JSON-LD has
// claimed since the SEO work: a crawler was being told about navigation that
// nothing on the page showed. The markdown controls were a <link> in the head
// and one line in the footer, which is where an agent finds them and a person
// driving one never scrolls to.
//
// The crumb is the navigation's label rather than the H1, for the reason the
// labels exist at all: /compared's H1 begins with the product's name, so the
// H1 version read "heliograph / heliograph compared with AWS SSM Run Command
// and Azure Run Command" - the site's name twice, and a crumb longer than
// the title beneath it.
func pageHead(p site.Page) string {
	return fmt.Sprintf(`<nav class="crumbs" aria-label="Breadcrumb">`+
		`<a href="/">heliograph</a><span aria-hidden="true">/</span>`+
		`<span class="here">%[1]s</span></nav>`+
		`<div class="page-actions">`+
		`<button type="button" data-copy-markdown="/%[2]s.md" `+
		`aria-label="Copy this page as markdown">%[3]s<span>Copy as markdown</span></button>`+
		`<a href="/%[2]s.md">%[4]s<span>View as markdown</span></a>`+
		`</div>`, escAttr(crumbName(p)), p.Slug, iconCopy, iconDoc)
}

// crumbName is what the breadcrumb and its JSON-LD both call a page.
func crumbName(p site.Page) string {
	if l := labels[p.Slug]; l != "" {
		return l
	}
	return p.Title
}

// The two icons for those controls. Inline for the same reason as the brand:
// they inherit currentColor and cost no request.
const (
	iconCopy = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" ` +
		`aria-hidden="true" focusable="false"><rect x="5.4" y="5.4" width="8.2" height="8.2" rx="1.6"/>` +
		`<path d="M10.6 5.4V4A1.6 1.6 0 0 0 9 2.4H4A1.6 1.6 0 0 0 2.4 4v5A1.6 1.6 0 0 0 4 10.6h1.4"/></svg>`
	iconDoc = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" ` +
		`aria-hidden="true" focusable="false"><path d="M9 1.9H4.6A1.7 1.7 0 0 0 2.9 3.6v8.8a1.7 1.7 0 0 0 1.7 1.7h6.8a1.7 1.7 0 0 0 1.7-1.7V5.8Z"/>` +
		`<path d="M9 1.9v3.9h4.1"/></svg>`
)

// rail is the "on this page" column. Omitted below three headings: a rail with
// two entries is furniture, and it takes width from the thing it is pointing at.
func rail(p site.Page) string {
	hs := site.Headings(p.Body)
	if len(hs) < 3 {
		return ""
	}
	var b strings.Builder
	b.WriteString(`<aside class="rail" aria-labelledby="page-nav-title">` +
		`<p class="grp" id="page-nav-title">On this page</p>` +
		`<nav aria-labelledby="page-nav-title">`)
	for _, h := range hs {
		fmt.Fprintf(&b, `<a href="#%s">%s</a>`, escAttr(h[0]), escAttr(h[1]))
	}
	b.WriteString(`</nav></aside>`)
	return b.String()
}

// pageOptions is what the 404 page needs that no content page does.
type pageOptions struct {
	// noindex marks a page search engines must not keep, and one with no
	// markdown mirror to announce: the 404.
	noindex bool
}

func page(p site.Page, all []site.Page) string { return render(p, all, pageOptions{}) }

func canonicalURL(p site.Page) string {
	if p.Slug == "index" {
		return baseURL + "/"
	}
	return baseURL + "/" + p.Slug
}

func render(p site.Page, all []site.Page, o pageOptions) string {
	nav := headerNav(p)

	// The index carries the hero, the log strip and its own three-link header.
	// A docs page carries none of them: it gets the mobile bar, the drawer and
	// the three-column shell instead.
	hero, wide := "", ""
	header, shellOpen, shellClose, railHTML, navJS := "", "", "", "", ""
	if p.Slug == "index" {
		hero, wide = heroHTML, " wide"
		header = fmt.Sprintf(`<header class="site-header">
  <a class="brand" href="/">%s heliograph</a>
  %s
</header>`, site.Mark, nav)
	} else {
		// THE DOCS HEADER IS GONE. It was a full-width sticky bar carrying only
		// the logo, which cost about 56px of every page and forced both sticky
		// columns onto a magic `top:3.6rem` offset that only approximated its
		// height. The brand moves into the sidebar, where it shares an edge
		// with something, and the sticky offsets become zero.
		header = fmt.Sprintf(`<header class="mobile-bar">
  <a class="brand" href="/">%s heliograph</a>
  <button class="menu-button" id="docs-menu-open" type="button"
    aria-controls="docs-menu" aria-expanded="false" aria-haspopup="dialog">
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M4 7h16M4 12h16M4 17h16"/></svg>
    <span>Menu</span>
  </button>
</header>
<dialog class="nav-dialog" id="docs-menu" aria-labelledby="docs-menu-title">
  <div class="nav-dialog-panel">
    <div class="nav-dialog-head">
      <h2 id="docs-menu-title">Documentation</h2>
      <button class="menu-close" type="button" data-close-menu aria-label="Close the documentation menu">
        <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M6 6l12 12M18 6L6 18"/></svg>
      </button>
    </div>
    <nav class="side-nav" aria-label="Documentation pages">%s</nav>
  </div>
</dialog>`, site.Mark, sidebarItems(p, all, "drawer"))

		// The matrix is seven columns wide and does not fit an 80ch
		// measure. It gets the shell a class rather than a page of its own
		// layout, so the sidebar, the rail and the drawer stay exactly as
		// they are everywhere else.
		shellMod := ""
		if strings.Contains(p.Body, "```matrix") {
			shellMod = " docs-shell--wide"
		}
		shellOpen = `<div class="docs-shell` + shellMod + `"><aside class="side">` +
			`<a class="brand side-brand" href="/">` + site.Mark + ` heliograph</a>` +
			`<nav class="side-nav" aria-label="Documentation">` +
			sidebarItems(p, all, "desktop") + `</nav></aside><div class="col">`
		shellClose = `</div>`
		railHTML = rail(p) + `</div>`
		navJS = site.NavJS
	}

	crumbs := ""
	if p.Slug != "index" && !o.noindex {
		crumbs = pageHead(p)
	}
	// The matrix behaviour ships only on a page that has a matrix. Inline
	// script is per-page weight, so a global bundle would put a picker nobody
	// can see into the HTML of all 29 pages - which is exactly what
	// TestTheMirrorSavingIsTheOneTheCommentsClaim caught when it was wired
	// that way.
	matrixJS := ""
	if strings.Contains(p.Body, "```matrix") {
		matrixJS = site.MatrixJS
	}
	// The footer names both mirrors: this page, and the whole site for an
	// agent that wants it in one fetch.
	mirror := ` &middot; <a href="/llms.txt">llms.txt</a>`
	if !o.noindex {
		mirror = fmt.Sprintf(` &middot; <a href="/%s.md">This page as markdown</a>`, p.Slug) + mirror
	}
	// The footer's second line is a byline, and it is not the block #54
	// removed. That one repeated the company and three of its links on all 27
	// pages, at the point a reader has already left. This one names the human
	// the JSON-LD calls the author: dated, first-hand failure reports are the
	// strongest thing here, and they were signed by nobody a reader or a model
	// could check.
	body := p.Body
	if p.Slug == "index" {
		// The hero carries the page's H1. The source keeps its own for the
		// markdown mirror and llms.txt, and it is dropped here rather than
		// demoted: an H2 reading "heliograph" under a hero is furniture.
		body = site.WithoutH1(body)
	}
	return head(p, o) + fmt.Sprintf(`<a class="skip-link" href="#main-content">Skip to content</a>
%[1]s
%[2]s
%[3]s
<main id="main-content" tabindex="-1" class="doc%[4]s">
%[11]s
%[5]s
</main>
%[6]s
%[7]s
<footer><div class="inner">
<p><a href="https://github.com/heliograph-io/heliograph">`+site.GitHubMark+`Source</a>%[8]s</p>
<p>Written and maintained by <a href="https://dbhq.uk/">Daniel Grimes</a> at DBHQ</p>
<p>Text on this site is <a href="https://creativecommons.org/licenses/by/4.0/" rel="license">CC BY 4.0</a>. The code is <a href="https://github.com/heliograph-io/heliograph/blob/main/LICENSE">Apache 2.0</a>.</p>
</div></footer>
<script>%[9]s
%[12]s
%[13]s
%[14]s</script>
%[10]s
`, header, hero, shellOpen, wide, site.RenderBody(body), shellClose, railHTML,
		mirror, site.HeroJS, navJS, crumbs, site.CopyJS, site.RailJS,
		site.OrgJS+matrixJS)
}

// head is everything before the body: the words a search result and a shared
// link are built from, and the fonts. No analytics, no third-party request.
func head(p site.Page, o pageOptions) string {
	canonical := canonicalURL(p)
	title := titles[p.Slug]
	if title == "" {
		title = p.Title + " - heliograph"
	}
	var b strings.Builder
	b.WriteString("<!doctype html>\n<html lang=\"en-GB\" class=\"no-js\">\n<meta charset=\"utf-8\">\n")
	if o.noindex {
		b.WriteString("<meta name=\"robots\" content=\"noindex\">\n")
	}
	fmt.Fprintf(&b, `<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%[1]s</title>
<meta name="description" content="%[2]s">
<meta name="theme-color" content="#080C12">
<meta property="og:title" content="%[1]s">
<meta property="og:description" content="%[2]s">
<meta property="og:type" content="website">
<meta property="og:url" content="%[3]s">
<meta property="og:site_name" content="heliograph">
<meta property="og:locale" content="en_GB">
<meta property="og:image" content="%[4]s/assets/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="heliograph: run it on a machine you cannot log into">
<meta name="twitter:card" content="summary_large_image">
<link rel="canonical" href="%[3]s">
<link rel="icon" href="/assets/favicon.ico" sizes="48x48">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
`, escAttr(title), escAttr(description(p)), canonical, baseURL)
	if !o.noindex {
		// The markdown mirror, announced so an agent does not have to guess.
		fmt.Fprintf(&b, "<link rel=\"alternate\" type=\"text/markdown\" href=\"/%s.md\">\n", p.Slug)
	}
	// llms.txt, announced rather than left to a crawler's guess. The per-page
	// mirror above is this page; this is the whole site in one file, and it
	// was reachable only by an agent that already knew the path.
	b.WriteString("<link rel=\"alternate\" type=\"text/plain\" title=\"llms.txt\" href=\"/llms.txt\">\n")
	// The two fonts the CSS actually names. This list once preloaded two files
	// that had been renamed away, and every page view 404ed twice for weeks.
	//
	// It nearly happened a second time on 2026-09-16: the site moved to Albert
	// Sans and this line still named Archivo, which had just been deleted. The
	// test below is what catches it, and the lesson the first time taught is
	// only useful if the check outlives the person who wrote the comment.
	//
	// Only the latin subset is preloaded. The extended block is a second file
	// behind a unicode-range, and preloading a face most readers never need is
	// a download charged to every page view for the benefit of a few.
	b.WriteString(`<link rel="preload" href="/assets/fonts/albert-sans-latin.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/assets/fonts/JetBrainsMono.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/style.css">
`)
	b.WriteString(structuredData(p))
	// Flipped before first paint, so a no-JS reader never sees a control that
	// cannot work. The drawer needs a real dialog; the sidebar does not.
	b.WriteString("<script>document.documentElement.classList.replace('no-js','js')</script>\n")
	return b.String()
}

// description is the sentence a search result shows under the title.
//
// Hand-written like the titles, and for the same reason: the first paragraph
// of a page was doing this job, and it ran to 349 characters on one page and
// opened with "Two different questions get confused here" on another. Pages
// without an entry fall back to the first paragraph, which llms.txt keeps
// regardless, because that is the right summary for an agent.
func description(p site.Page) string {
	if d := descriptions[p.Slug]; d != "" {
		return d
	}
	return site.Summary(p.Body)
}

// structuredData is the JSON-LD: the product on the home page, an article
// and its breadcrumb on every other. Built with encoding/json rather than a
// template because Marshal escapes < and >, so nothing in a page's title can
// close the script tag early.
//
// author and publisher were the same Organization node on every page, which
// left the strongest material here - dated, measured, first-hand accounts of
// what failed - attributed to a company and to no person at all. A search
// engine and a model both want to know who, and both want somewhere to check
// him. So the company publishes and a named person writes, with a profile in
// sameAs.
//
// It used to say this on a page of its own too, site/content/dbhq.md, which
// was removed on 2026-09-16 along with the DBHQ menu. The attribution stays,
// because a crawler and a model both still want a named author; what went is
// the company talking about its other projects inside the product's
// documentation. The footer now links to dbhq.uk rather than to a page on this
// site.
func structuredData(p site.Page) string {
	canonical := canonicalURL(p)
	org := map[string]any{"@type": "Organization", "name": "DBHQ", "url": "https://dbhq.uk"}
	person := map[string]any{
		"@type":    "Person",
		"name":     "Daniel Grimes",
		"url":      "https://dbhq.uk/",
		"sameAs":   []string{"https://github.com/grinidx"},
		"worksFor": org,
	}
	var blocks []map[string]any
	if p.Slug == "index" {
		blocks = append(blocks, map[string]any{
			"@context":            "https://schema.org",
			"@type":               "SoftwareApplication",
			"name":                "heliograph",
			"url":                 baseURL + "/",
			"description":         description(p),
			"applicationCategory": "DeveloperApplication",
			"operatingSystem":     "Linux, macOS, Windows",
			"license":             "https://opensource.org/license/mit",
			// `isAccessibleForFree` stays; the `offers` node is gone. It read
			// `{"@type": "Offer", "price": "0", "priceCurrency": "GBP"}`
			// until 2026-09-16, and that is a price on a page. This site is
			// about to carry the documentation of a product whose every
			// metering dimension ships marked unmeasured. Free is a fact
			// about heliograph; zero is a number, and a number published
			// before it is measured is very hard to withdraw.
			"isAccessibleForFree": true,
			"downloadUrl":         "https://github.com/heliograph-io/heliograph/releases/latest",
			"sameAs":              []string{"https://github.com/heliograph-io/heliograph"},
			"image":               baseURL + "/assets/og.png",
			"author":              person,
			"publisher":           org,
		}, map[string]any{
			"@context": "https://schema.org",
			"@type":    "Organization",
			"name":     "DBHQ",
			"url":      "https://dbhq.uk",
			"sameAs":   []string{"https://github.com/dbhq-uk"},
			"founder":  person,
		})
	} else {
		blocks = append(blocks, map[string]any{
			"@context":      "https://schema.org",
			"@type":         "TechArticle",
			"headline":      p.Title,
			"description":   description(p),
			"url":           canonical,
			"datePublished": p.Published,
			"dateModified":  p.Modified,
			"inLanguage":    "en-GB",
			"image":         baseURL + "/assets/og.png",
			"author":        person,
			"publisher":     org,
			"isPartOf":      map[string]any{"@type": "WebSite", "name": "heliograph", "url": baseURL + "/"},
		}, map[string]any{
			"@context": "https://schema.org",
			"@type":    "BreadcrumbList",
			"itemListElement": []map[string]any{
				{"@type": "ListItem", "position": 1, "name": "heliograph", "item": baseURL + "/"},
				{"@type": "ListItem", "position": 2, "name": crumbName(p), "item": canonical},
			},
		})
	}
	var b strings.Builder
	for _, blk := range blocks {
		j, err := json.Marshal(blk)
		if err != nil {
			panic(err) // a map of strings cannot fail to marshal
		}
		fmt.Fprintf(&b, "<script type=\"application/ld+json\">%s</script>\n", j)
	}
	return b.String()
}

// notFound is what GitHub Pages serves for a missing path. It sits in the
// docs shell so the reader is one click from every page, and is noindex so a
// mistyped link never becomes a page Google keeps.
func notFound(all []site.Page) string {
	p := site.Page{Slug: "404", Title: "Page not found", Body: "# Page not found\n\n" +
		"There is no page at this address. The sidebar lists every page, and the " +
		"[home page](/) has the short version.\n\n" +
		"Every page is also available as markdown at its own address plus `.md`, " +
		"and all of them together at [/llms.txt](/llms.txt).\n"}
	return render(p, all, pageOptions{noindex: true})
}

// lastModified is the date of the last commit that touched name, for the
// sitemap and the structured data.
//
// A shallow checkout is refused rather than tolerated. `git log -1` on one
// still answers, with the one commit it has, so every page would carry the
// deploy date and the sitemap would announce that everything changed today.
// That is worse than no date at all, and it is what actions/checkout does
// unless told otherwise.
func lastModified(dir, name string) (string, error) {
	shallow, err := git(dir, "rev-parse", "--is-shallow-repository")
	if err != nil {
		// Not a repository at all: a tarball, or a copy. The file's own
		// mtime is the only date there is, and the build says so.
		fi, serr := os.Stat(filepath.Join(dir, name))
		if serr != nil {
			return "", serr
		}
		fmt.Fprintf(os.Stderr, "heliograph-site: %s is not in a git checkout, using the file's mtime for lastmod\n", name)
		return fi.ModTime().UTC().Format("2006-01-02"), nil
	}
	if shallow == "true" {
		return "", fmt.Errorf("the checkout is shallow, so every page would carry today's date; " +
			"clone with full history (actions/checkout: fetch-depth: 0)")
	}
	date, err := git(dir, "log", "-1", "--format=%cs", "--", name)
	if err != nil {
		return "", err
	}
	if date == "" {
		// Never committed: a page being written. Today is the honest answer.
		return time.Now().UTC().Format("2006-01-02"), nil
	}
	return date, nil
}

// firstPublished is the date of the first commit that touched name, following
// renames, for the datePublished the structured data carries beside
// dateModified.
//
// Without it a page says when it changed and never says when it arrived, so a
// page written in September and corrected in March reads as a March page. This
// site's strongest material is first-hand and dated - what deploying the Azure
// templates taught us, three ways a twin lies - and a correction should not
// make it look like something written yesterday.
//
// It never fails the build. A directory that is not a checkout, or a page not
// committed yet, falls back to the date the page already carries, because that
// is the only honest date there is and the sitemap is already using it.
func firstPublished(dir, name, modified string) (string, error) {
	out, err := git(dir, "log", "--follow", "--format=%cs", "--", name)
	if err != nil || out == "" {
		return modified, nil
	}
	lines := strings.Split(out, "\n")
	return strings.TrimSpace(lines[len(lines)-1]), nil
}

func git(dir string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out)), nil
}

// THIS SITE MAKES NO THIRD-PARTY REQUEST AND SETS NO COOKIE, and until
// 2026-09-16 it did both.
//
// A GA4 tag, a Consent Mode gate and a consent banner stood here. All three
// were correct for `heliograph.dbhq.uk`: the measurement id was the dbhq.uk
// stream's, on Google's own one-stream-per-site-including-subdomains
// guidance, and the banner linked the dbhq.uk privacy policy, which promises
// analytics "loads only after you accept" and which actually covered the
// hostname the site was served from.
//
// The site moved to `docs.heliograph.io` on 2026-09-16 and all three stopped
// being correct in the same instant. `heliograph.io` is a different
// registrable domain, so it needs its own GA4 stream, its own banner promise
// and its own privacy policy. What was live instead was one domain's tag
// disclosed by another domain's policy: the apex's `/health` reported
// `"analytics":"unconfigured"` while the documentation site on the same
// domain reported somebody else's measurement id.
//
// Removed rather than repointed. A measurement id nobody has created cannot
// be written here, and a banner cannot link a policy that does not exist.
// The cost is real and accepted: the documentation now has no usage signal
// at all. It had somebody else's, collected under a promise that did not
// cover the reader giving it.
//
// Restoring it needs three things rather than one: a heliograph.io GA4
// property, a privacy policy on heliograph.io naming it, and a banner that
// links that policy. `TestNoThirdPartyRequestAndNoPrice` fails on any of the
// old strings until all three exist.

// titles are written per page rather than derived from the H1.
//
// A title tag is the one piece of copy that has to work with no page around it:
// in a search result, a browser tab, a shared link. "Transports - heliograph"
// says nothing to somebody who has never heard of either word.
//
// They also carry the words people actually search, measured rather than
// guessed. The rule that came out of the measurement, which is the part this
// file needs: use the words a reader already has - the agent they use ("claude
// code skills", "codex cli mcp"), "ssh alternative", "air gapped" - rather than
// the words this project uses for the problem. And never "remote command
// execution": to Google that phrase means the vulnerability.
//
// The measurement behind it is go-to-market work and lives in the private
// dbhq-uk/dbhq-seo, at reports/heliograph/2026-09-09-keyword-research.md. It
// was in this repository until 2026-09-12 and should not have been.
var titles = map[string]string{
	"index":       "heliograph - run commands on a server without SSH",
	"licence":     "Licensing - Apache 2.0, fair source, and what did not change",
	"install":     "Install heliograph - a single binary, and nothing on the far side",
	"quickstart":  "Quick start - from nothing to a captured log in five steps",
	"compared":    "heliograph vs AWS SSM Run Command and Azure Run Command",
	"air-gapped":  "Air-gapped servers - run heliograph with no network path at all",
	"claude-code": "heliograph Claude Code skill - drive a machine it cannot reach",
	"transports":  "Transports - git, relay, share, and a bundle for air gaps",
	"matrix":      "What works with what - every transport, station and controller",
	"cli":         "CLI reference - send, watch, logs --gaps, plant, doctor",
	"method":      "The method - debugging a server you cannot log into",
	"roadmap":     "Roadmap - what heliograph might support next, and what it never will",
	"dbhq":        "DBHQ projects - the other things DBHQ makes",
	"mcp":         "heliograph MCP server for Claude Code, Codex and any agent",
	"codex":       "heliograph Codex CLI skill - drive a machine it cannot reach",
	"station":     "The station - what heliograph runs on the far side",
	"bootstrap":   "Planting a station - with the CLI, or without it",
	"steps":       "Writing a step - one file, one question, and the traps",
	"runner":      "Runner reference - start.sh, station.sh, run.sh and every knob",
	"conformance": "The capture contract - nine properties every implementation must pass",
	"hosts":       "Where a station can run - the host contract, and what is proven",
	"containers":  "Docker and Kubernetes - running a station in a container",
	"service":     "Survive a logout - systemd, launchd and Windows scheduled tasks",
	"azure":       "Azure - five templates, and what deploying them taught us",
	"pipelines":   "Pipelines - running a station on a GitHub or Azure DevOps agent",
	"windows":     "Windows - hosting the loop, and steps written in PowerShell",
	"relay":       "The relay - zero-infrastructure heliograph over ordinary HTTPS",
	"secrets":     "Secrets - redaction, and getting a value to the far side",
	"security":    "Security - the gates, the blast radius, and what this refuses to do",
	"flare":       "Flare - submit a step over HTTPS when you can reach the station",
	"provenance":  "Provenance - reproduce the binary and check it against the hash",
}

// descriptions are the search-result sentence for each page. See description().
var descriptions = map[string]string{
	"index":       "Run a command on a machine you cannot SSH into and get back a log with every line timestamped in UTC. Free and open source: CLI, MCP server, Claude Code skill.",
	"licence":     "heliograph is Apache 2.0 and the relay is fair source under FSL-1.1-ALv2, converting to Apache 2.0 after two years. Every commit published under MIT stays MIT.",
	"install":     "Install the heliograph CLI on Linux, macOS or Windows from a single static binary, or as a Claude Code plugin. Nothing is ever installed on the far side.",
	"quickstart":  "From nothing to a captured, timestamped log in five steps: plant a station on the far side, push a step, and read the whole run back, passed or failed.",
	"compared":    "How heliograph differs from AWS SSM Run Command and Azure Run Command: nothing installed on the target, no cloud account over it, and the whole log back.",
	"air-gapped":  "heliograph on an air-gapped server: which transports work with an internal git host or a file share, and the by-hand route when nothing crosses but a person.",
	"claude-code": "Give Claude Code a way to run commands on a machine it cannot reach. Install the heliograph skill and it publishes steps and reads back timestamped logs.",
	"codex":       "Use heliograph from Codex as a skill or through its MCP server, so Codex can drive a machine it cannot log into and read every run back as a timestamped log.",
	"mcp":         "heliograph mcp exposes send, watch and logs as typed tools, so any MCP-capable agent can run steps on a machine it cannot reach and read the captured log back.",
	"station":     "The station is a directory of plain bash planted in a private transport repo. It polls for steps, runs them, and pushes back every line with a UTC timestamp.",
	"bootstrap":   "Two ways to plant a heliograph station on the far side: heliograph bootstrap from your machine, or station/bootstrap.sh run by an operator with no CLI at all.",
	"steps":       "A step is one file that answers one question. How to write one, declare it read-only or an action, and avoid the traps that make a captured run useless.",
	"runner":      "Reference for start.sh, station.sh, run.sh and caprun.sh: every environment variable and flag the heliograph station honours, and what each one defaults to.",
	"conformance": "The capture contract: nine properties every heliograph runner must pass, from a UTC timestamp on every line to a log that still ships when the step fails.",
	"hosts":       "Where a heliograph station can run when no human will keep a terminal open: containers, systemd, launchd, Azure, pipelines and Windows, and what is proven.",
	"containers":  "Run a heliograph station in Docker or Kubernetes: the published image, the entrypoint that clones and hands over to start.sh, and the manifests proven in CI.",
	"service":     "Keep a heliograph station running after the operator logs out: a systemd user service with lingering, launchd on macOS, or a scheduled task on Windows.",
	"azure":       "Azure templates that run a heliograph station with no human at a terminal, Container Apps and App Service among them, and what deploying each one taught us.",
	"pipelines":   "Run a heliograph station on a GitHub Actions or Azure DevOps agent, which is often the one machine in an estate that can already reach the far side.",
	"windows":     "heliograph on Windows: hosting the station loop through Git for Windows, and writing steps in PowerShell that are still captured line by line with timestamps.",
	"transports":  "A transport carries a step out and a log back. heliograph supports git, an HTTPS relay, a file share, a bundle and object store, behind one interface and gates.",
	"matrix":      "Every heliograph transport, station and controller in one place, which combinations work, and the beacon-versus-flare split that decides the rest.",
	"relay":       "The relay runs heliograph over ordinary HTTPS with no git host and no storage account, encrypted end to end so the relay can read nothing and run nothing.",
	"flare":       "A flare submits a step to a heliograph station over HTTPS, for the rarer case where you can reach the machine's network but still cannot log into it.",
	"cli":         "Every heliograph command: init, bootstrap, plant, send, logs --gaps, station add, mcp and doctor, with the reasoning behind the ones that are not obvious.",
	"secrets":     "Captured logs are committed to history, so heliograph redacts what it can. How redaction works, where it stops, and how to get a secret to the far side safely.",
	"security":    "What heliograph refuses to do, what it gates, and what it cannot promise: read-only by default, no root, no credentials, and the account as the blast radius.",
	"provenance":  "Build the released heliograph binary yourself from the tag and check it against the published SHA256SUMS. What is reproducible today, and what is not yet.",
	"method":      "How to debug across a gap you cannot cross: one question per step, never truncate, keep a control, and change one thing between runs.",
	"roadmap":     "Every transport, host and control node anyone has proposed for heliograph, each with a verdict - do, later, maybe or never - and the reason behind it.",
	"dbhq":        "The other free and open-source things DBHQ makes: bbs and modem in a browser, and skills for Claude Code and Codex, installed with one command.",
}

// heroHTML is the index's opening: the signal crossing the valley, then a real
// captured log with a real gap in its timestamp column.
//
// The log is not decoration. It is the single most distinctive fact about the
// product - a hang shows up as a gap, and nothing else in the category shows
// you that - so it is shown rather than described, above the fold.
const heroHTML = `<section class="hero">
  <canvas id="signal" aria-hidden="true"></canvas>
  <div class="hero-inner">
    <h1>Run it on a machine you <em>cannot log into</em>.</h1>
    <p class="lede">You push a step. It runs on the far side. The whole run comes
    back as a log with every line timestamped in UTC, whether it passed or failed.</p>
    <div class="cta">
      <a class="btn btn-primary" href="/quickstart">Quick start</a>
      <a class="btn btn-ghost" href="https://github.com/heliograph-io/heliograph">` + site.GitHubMark + `Source</a>
    </div>
  </div>
</section>
<section class="strip"><div class="strip-inner">
  <h2>A hang is a gap, and the gap is the finding</h2>
  <pre class="log"><code><span class="t">09:14:00</span> | ---------- terraform plan ----------
<span class="t">09:14:02</span> | Refreshing state...
<span class="gap">           3m12s   nothing was produced here. This is the answer.</span>
<span class="t">09:17:14</span> | Plan: 3 to add, 0 to change
<span class="t">09:17:15</span> | done</code></pre>
</div></section>
`

func escAttr(s string) string {
	r := strings.NewReplacer(`&`, "&amp;", `"`, "&quot;", `<`, "&lt;", `>`, "&gt;")
	return r.Replace(s)
}

// llms.txt: a curated index, organised by section rather than as one flat list.
//
// Shipped because IDE agents fetch it and it costs almost nothing, not because
// it will win citations: one log study found 408 requests to llms.txt out of
// more than 500 million AI bot visits in ninety days.
func llms(pages []site.Page) string {
	var b strings.Builder
	b.WriteString("# heliograph\n\n")
	b.WriteString("> Remote, captured, auditable execution on a machine you cannot log into. ")
	b.WriteString("You push a step, it runs on the far side, and the whole run comes back as a log ")
	b.WriteString("with every line timestamped in UTC, whether it passed or failed.\n\n")
	b.WriteString("## Docs\n\n")
	for _, p := range pages {
		fmt.Fprintf(&b, "- [%s](%s/%s.md): %s\n", p.Title, baseURL, p.Slug, site.Summary(p.Body))
	}
	b.WriteString("\n## Source\n\n")
	b.WriteString("- [heliograph](https://github.com/heliograph-io/heliograph): the control CLI and transports\n")
	b.WriteString("- [station/bash](https://github.com/heliograph-io/heliograph/tree/main/station/bash): the far-side station, plain bash, in this repository\n")
	return b.String()
}

func llmsFull(pages []site.Page) string {
	var b strings.Builder
	for _, p := range pages {
		b.WriteString(p.Body)
		b.WriteString("\n\n---\n\n")
	}
	return b.String()
}
