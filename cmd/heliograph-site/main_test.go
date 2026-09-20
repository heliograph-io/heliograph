package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/heliograph-io/heliograph/internal/site"
)

// buildSite builds the real content into a temporary directory once per test.
// The tests assert on what ships, not on helpers, because the defects they
// guard against were all visible only in the built output.
func buildSite(t *testing.T) string {
	t.Helper()
	out := t.TempDir()
	if _, err := build("../../site/content", out); err != nil {
		t.Fatalf("build: %v", err)
	}
	return out
}

func htmlPages(t *testing.T, out string) map[string]string {
	t.Helper()
	pages := map[string]string{}
	ents, err := os.ReadDir(out)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".html") {
			b, err := os.ReadFile(filepath.Join(out, e.Name()))
			if err != nil {
				t.Fatal(err)
			}
			pages[e.Name()] = string(b)
		}
	}
	return pages
}

// Every page used to preload two font files that did not exist: the fonts
// had been renamed and the head had not. Two 404s on every page view, and
// nothing failed.
func TestEveryReferencedAssetExists(t *testing.T) {
	out := buildSite(t)
	re := regexp.MustCompile(`(?:href|src|content)="(?:https://heliograph\.dbhq\.uk)?(/assets/[^"]+)"`)
	for name, h := range htmlPages(t, out) {
		for _, m := range re.FindAllStringSubmatch(h, -1) {
			if _, err := os.Stat(filepath.Join(out, m[1])); err != nil {
				t.Errorf("%s references %s, which is not in the build", name, m[1])
			}
		}
	}
}

// A sitemap without lastmod tells Google nothing about what changed. The
// dbhq.uk audit of 2026-08-09 traced a page that was never crawled to
// exactly this.
func TestSitemapCarriesALastmodForEveryURL(t *testing.T) {
	out := buildSite(t)
	b, err := os.ReadFile(filepath.Join(out, "sitemap.xml"))
	if err != nil {
		t.Fatal(err)
	}
	urls := strings.Count(string(b), "<url>")
	dated := regexp.MustCompile(`<lastmod>\d{4}-\d{2}-\d{2}</lastmod>`).FindAllString(string(b), -1)
	if urls == 0 || len(dated) != urls {
		t.Errorf("%d urls, %d with a lastmod:\n%s", urls, len(dated), b)
	}
}

// A shallow checkout reports the deploy date for every page, which reads as
// a site where everything changed today. That is worse than no date, so the
// build refuses it and says what to do.
func TestShallowCloneIsRefusedWithARemedy(t *testing.T) {
	origin := gitRepo(t, "2024-03-04T05:06:07Z")
	shallow := t.TempDir()
	run(t, shallow, "git", "clone", "--quiet", "--depth", "1", "file://"+origin, ".")
	_, err := lastModified(shallow, "page.md")
	if err == nil || !strings.Contains(err.Error(), "fetch-depth") {
		t.Errorf("a shallow clone was accepted, or the error does not say the remedy: %v", err)
	}
}

func TestLastModifiedIsTheLastCommitThatTouchedThePage(t *testing.T) {
	repo := gitRepo(t, "2024-03-04T05:06:07Z")
	got, err := lastModified(repo, "page.md")
	if err != nil {
		t.Fatal(err)
	}
	if got != "2024-03-04" {
		t.Errorf("got %q, want 2024-03-04", got)
	}
}

// gitRepo makes a repository with one committed page.md at the given date.
func gitRepo(t *testing.T, date string) string {
	t.Helper()
	dir := t.TempDir()
	run(t, dir, "git", "init", "--quiet")
	run(t, dir, "git", "config", "user.email", "t@example.com")
	run(t, dir, "git", "config", "user.name", "t")
	if err := os.WriteFile(filepath.Join(dir, "page.md"), []byte("# p\n\nbody\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, dir, "git", "add", "page.md")
	cmd := exec.Command("git", "commit", "--quiet", "-m", "p")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_DATE="+date, "GIT_COMMITTER_DATE="+date)
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v\n%s", err, b)
	}
	return dir
}

func run(t *testing.T, dir string, name string, args ...string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s %v: %v\n%s", name, args, err, b)
	}
}

// The description is the one sentence a search result shows. The first
// paragraph of a page was doing that job: seven pages ran past 200
// characters, two were under 40, and /windows opened with "Two different
// questions get confused here".
func TestDescriptionsAndTitlesFitASearchResult(t *testing.T) {
	out := buildSite(t)
	desc := regexp.MustCompile(`<meta name="description" content="([^"]*)"`)
	title := regexp.MustCompile(`<title>([^<]*)</title>`)
	for name, h := range htmlPages(t, out) {
		if name == "404.html" {
			continue
		}
		d := desc.FindStringSubmatch(h)
		if d == nil {
			t.Errorf("%s has no description", name)
			continue
		}
		if n := len(unescape(d[1])); n < 70 || n > 160 {
			t.Errorf("%s: description is %d characters, want 70 to 160: %q", name, n, d[1])
		}
		if m := title.FindStringSubmatch(h); m == nil || len(unescape(m[1])) > 70 {
			t.Errorf("%s: title missing or over 70 characters: %v", name, m)
		}
	}
}

func unescape(s string) string {
	return strings.NewReplacer("&amp;", "&", "&quot;", `"`, "&lt;", "<", "&gt;", ">").Replace(s)
}

// The documentation site makes no third-party request and publishes no price.
//
// Both were live on 2026-09-16 and neither was anybody's decision here. The
// GA4 property is `dbhq.uk`'s, promised under a privacy policy that covers
// `dbhq.uk` and not this domain, and left pointing at it when the site moved
// to `docs.heliograph.io` on 2026-09-16. The JSON-LD carried
// `"price": "0", "priceCurrency": "GBP"` on the index, which is a price on a
// page for a product whose every metering dimension ships marked unmeasured.
// A text capture of the page misses it, because it sits inside a `<script>`.
//
// The rule these hold is the private register's: no price, no tier, no
// allowance and no launch date on any surface until it has been measured.
// `isAccessibleForFree` stays, because heliograph is free and that is a fact
// rather than a number.
//
// Watched failing first, against the tree that still carried both.
func TestNoThirdPartyRequestAndNoPrice(t *testing.T) {
	out := buildSite(t)
	banned := []string{
		"googletagmanager.com",
		"google-analytics.com",
		"G-3H3NFGSX85",
		"dbhq.uk/privacy",
		`"price"`,
		"priceCurrency",
		`"offers"`,
	}
	for name, h := range htmlPages(t, out) {
		for _, b := range banned {
			if strings.Contains(h, b) {
				t.Errorf("%s: contains %q", name, b)
			}
		}
	}
}

func TestStructuredDataIsValidJSONOfTheRightType(t *testing.T) {
	out := buildSite(t)
	re := regexp.MustCompile(`(?s)<script type="application/ld\+json">(.*?)</script>`)
	for name, h := range htmlPages(t, out) {
		if name == "404.html" {
			continue
		}
		blocks := re.FindAllStringSubmatch(h, -1)
		if len(blocks) == 0 {
			t.Errorf("%s: no JSON-LD", name)
			continue
		}
		var types []string
		for _, b := range blocks {
			var v map[string]any
			if err := json.Unmarshal([]byte(b[1]), &v); err != nil {
				t.Errorf("%s: JSON-LD does not parse: %v\n%s", name, err, b[1])
				continue
			}
			types = append(types, v["@type"].(string))
		}
		want := "TechArticle"
		if name == "index.html" {
			want = "SoftwareApplication"
		}
		if !contains(types, want) {
			t.Errorf("%s: types %v, want %s", name, types, want)
		}
		if name != "index.html" && !contains(types, "BreadcrumbList") {
			t.Errorf("%s: no BreadcrumbList", name)
		}
	}
}

// The nav and the content directory must agree. A slug in order with no
// markdown behind it renders an empty page, and a markdown file no slug names
// is never published at all.
func TestFlareReplacesIntercom(t *testing.T) {
	for _, slug := range order {
		if slug == "intercom" {
			t.Error("the nav still lists intercom; the page is /flare now")
		}
	}
	var found bool
	for _, slug := range order {
		if slug == "flare" {
			found = true
		}
	}
	if !found {
		t.Fatal("the nav does not list flare")
	}
	if _, err := os.Stat(filepath.Join("..", "..", "site", "content", "flare.md")); err != nil {
		t.Fatalf("site/content/flare.md is missing: %v", err)
	}
}

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

// GitHub Pages serves 404.html for a missing path. Without one, a mistyped
// URL gets GitHub's page, with no way back into the docs.
func TestNotFoundPageIsNoindexAndCarriesTheSidebar(t *testing.T) {
	out := buildSite(t)
	b, err := os.ReadFile(filepath.Join(out, "404.html"))
	if err != nil {
		t.Fatalf("no 404.html: %v", err)
	}
	h := string(b)
	if !strings.Contains(h, `<meta name="robots" content="noindex">`) {
		t.Error("404.html is indexable")
	}
	if !strings.Contains(h, `class="side-nav"`) {
		t.Error("404.html has no sidebar")
	}
	if strings.Contains(h, `/404.md`) {
		t.Error("404.html announces a markdown mirror that does not exist")
	}
	sm, _ := os.ReadFile(filepath.Join(out, "sitemap.xml"))
	if strings.Contains(string(sm), "/404") {
		t.Error("the 404 page is in the sitemap")
	}
}

func TestSharedLinksCarryAnImage(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		if !strings.Contains(h, `<meta property="og:image" content="https://docs.heliograph.io/assets/og.png">`) {
			t.Errorf("%s: no og:image", name)
		}
		if !strings.Contains(h, `<meta name="twitter:card" content="summary_large_image">`) {
			t.Errorf("%s: twitter:card is not summary_large_image", name)
		}
	}
}

// The sitemap is the list Google works from. Every page in the build is in
// it exactly once, and nothing that is not a page is. The markdown mirrors
// are deliberately absent: they are announced as alternates from each page,
// and listing them would ask Google to index every page twice.
func TestSitemapListsEveryPageOnceAndNothingElse(t *testing.T) {
	out := buildSite(t)
	sm, err := os.ReadFile(filepath.Join(out, "sitemap.xml"))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]int{}
	for _, m := range regexp.MustCompile(`<loc>([^<]+)</loc>`).FindAllStringSubmatch(string(sm), -1) {
		seen[m[1]]++
	}
	for name := range htmlPages(t, out) {
		if name == "404.html" {
			continue
		}
		want := baseURL + "/" + strings.TrimSuffix(name, ".html")
		if name == "index.html" {
			want = baseURL + "/"
		}
		if seen[want] != 1 {
			t.Errorf("%s is in the sitemap %d times, want once", want, seen[want])
		}
		delete(seen, want)
	}
	for extra := range seen {
		t.Errorf("the sitemap lists %s, which is not a page", extra)
	}
}

// A link to a page that does not exist is the defect a content edit
// introduces most easily and the one a crawler scores hardest. Anchors are
// checked too: a heading rename silently breaks every link to it.
func TestInternalLinksResolve(t *testing.T) {
	out := buildSite(t)
	re := regexp.MustCompile(`href="(/[^"#]*)(#[^"]*)?"`)
	for name, h := range htmlPages(t, out) {
		for _, m := range re.FindAllStringSubmatch(h, -1) {
			path, frag := m[1], m[2]
			target := path
			if target == "/" {
				target = "/index"
			}
			file := filepath.Join(out, target)
			if _, err := os.Stat(file); err != nil {
				if _, err := os.Stat(file + ".html"); err != nil {
					t.Errorf("%s links to %s, which is not in the build", name, path)
					continue
				}
				file += ".html"
			}
			if frag == "" || !strings.HasSuffix(file, ".html") {
				continue
			}
			b, _ := os.ReadFile(file)
			if !strings.Contains(string(b), `id="`+frag[1:]+`"`) {
				t.Errorf("%s links to %s%s, and that anchor is not on the page", name, path, frag)
			}
		}
	}
}

// One H1 per page. The home page had two: the hero's, and the source's
// "# heliograph" rendered underneath it.
func TestOneH1PerPage(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		if n := strings.Count(h, "<h1"); n != 1 {
			t.Errorf("%s has %d h1 elements", name, n)
		}
	}
}

// The site's own links to the repository carry the GitHub mark: the footer
// on every page, and the header and hero on the home page. A word on its own
// asks the reader to parse it; the mark is recognised before it is read.
//
// Links inside a page's prose are left alone. A mark mid-sentence is noise,
// and the sentence already says where it goes.
func TestTheChromeLinksToGitHubCarryTheMark(t *testing.T) {
	out := buildSite(t)
	re := regexp.MustCompile(`(?s)<a[^>]*href="https://github\.com/heliograph-io/heliograph"[^>]*>(.*?)</a>`)
	region := func(h, open, close string) string {
		i := strings.Index(h, open)
		if i < 0 {
			return ""
		}
		j := strings.Index(h[i:], close)
		if j < 0 {
			return ""
		}
		return h[i : i+j]
	}
	for name, h := range htmlPages(t, out) {
		regions := map[string]string{"footer": region(h, "<footer>", "</footer>")}
		if name == "index.html" {
			regions["header"] = region(h, `<header class="site-header">`, "</header>")
			regions["hero"] = region(h, `<div class="cta">`, "</div>")
		}
		for where, frag := range regions {
			links := re.FindAllStringSubmatch(frag, -1)
			if len(links) == 0 {
				t.Errorf("%s: the %s does not link to the repository", name, where)
			}
			for _, l := range links {
				if !strings.Contains(l[1], `class="gh"`) {
					t.Errorf("%s: the %s link has no GitHub mark: %s", name, where, l[1])
				}
			}
		}
	}
}

// This site is a list of commands to run somewhere else. Selecting one by
// hand out of a <pre> is where a stray character enters a step.
func TestEveryCodeBlockHasACopyButton(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		pres := strings.Count(h, "<pre>")
		if pres == 0 {
			continue
		}
		if got := strings.Count(h, `<button class="copy"`); got != pres {
			t.Errorf("%s: %d code blocks, %d copy buttons", name, pres, got)
		}
		if !strings.Contains(h, `<div class="code">`) {
			t.Errorf("%s: code blocks are not wrapped, so the button has nothing to sit in", name)
		}
	}
}

// The markdown mirror was announced in a <link> and named once in the
// footer. An agent finds it there; a person driving one never scrolls that
// far. It belongs at the top of the page, next to the title.
func TestDocsPagesOfferTheMarkdownMirrorAtTheTop(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		if name == "index.html" || name == "404.html" {
			continue
		}
		slug := strings.TrimSuffix(name, ".html")
		head := h[:strings.Index(h, "<h1")]
		if !strings.Contains(head, `data-copy-markdown="/`+slug+`.md"`) {
			t.Errorf("%s has no copy-as-markdown control above its title", name)
		}
		if !strings.Contains(head, `href="/`+slug+`.md"`) {
			t.Errorf("%s has no view-as-markdown link above its title", name)
		}
	}
}

// The JSON-LD has said there is a breadcrumb since the SEO work. Nothing on
// the page did. A crawler was being told about navigation the reader could
// not see, which is the sort of mismatch that is worth nothing at best.
func TestDocsPagesShowTheBreadcrumbTheyClaim(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		if name == "index.html" || name == "404.html" {
			continue
		}
		if !strings.Contains(h, `<nav class="crumbs" aria-label="Breadcrumb">`) {
			t.Errorf("%s claims a BreadcrumbList in JSON-LD and shows no breadcrumb", name)
			continue
		}
		// The crumb is the navigation's label, not the H1. /compared's H1
		// begins with the product's name, so the H1 version read
		// "heliograph / heliograph compared with AWS SSM Run Command and
		// Azure Run Command" - the site's name twice, and a crumb longer
		// than the title it sits above.
		crumb := regexp.MustCompile(`<span class="here">([^<]*)</span>`).FindStringSubmatch(h)
		want := labels[strings.TrimSuffix(name, ".html")]
		if crumb == nil || crumb[1] != want {
			t.Errorf("%s: crumb is %v, want the nav label %q", name, crumb, want)
		}
		// And the JSON-LD says what the reader sees.
		if !strings.Contains(h, `"name":"`+want+`"`) {
			t.Errorf("%s: the BreadcrumbList does not name %q", name, want)
		}
	}
}

// Google reads a favicon for the search result, and iOS wants a PNG for the
// home screen. An SVG alone left both to guess.
func TestTheSiteHasAFaviconEverythingCanRead(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		for _, want := range []string{
			`<link rel="icon" href="/assets/favicon.ico" sizes="48x48">`,
			`<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">`,
			`<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">`,
		} {
			if !strings.Contains(h, want) {
				t.Errorf("%s is missing %s", name, want)
			}
		}
	}
}

// The DBHQ menu was removed on 2026-09-16 and its test with it.
//
// The test asserted the opposite of what is now wanted: that every page could
// reach the DBHQ projects page. Its own comment records the direction of
// travel, "one line of footer byline ... now a menu on the home page, a group
// in every docs sidebar, and a page", and the move to docs.heliograph.io
// reversed it. A reader on the company's domain had come to the company; a
// reader here has come to a product, mid-incident, and a header offering them
// a bulletin board and a Bell 103 modem is the company talking about itself.
//
// Nothing replaces it. The named-author attribution stays in the footer and in
// the structured data, pointing at dbhq.uk rather than at a page here, and
// TestInternalLinksResolve is what would catch a link to the removed page.

// The footer carried a byline and, from #45, a three-item "Also from DBHQ"
// list. Both said the same thing on all 27 pages, at the point a reader has
// already left. The menu and the page say it where somebody is looking.
func TestTheFooterCarriesNoDBHQBlock(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		i := strings.Index(h, "<footer>")
		if i < 0 {
			t.Errorf("%s has no footer", name)
			continue
		}
		foot := h[i:]
		for _, gone := range []string{"free, open-source tool by", "Also from DBHQ", "also-list"} {
			if strings.Contains(foot, gone) {
				t.Errorf("%s still carries %q in its footer", name, gone)
			}
		}
	}
}

// TestTheDBHQPageLinksToTheProjectsItNames was removed on 2026-09-16 with the
// page it tested. Nothing replaces it: the projects it linked are on dbhq.uk,
// which is where a reader who wants them should be, rather than inside the
// documentation of one product.
func TestTheNavigationAnnouncesASwapAndTheRailListens(t *testing.T) {
	if !strings.Contains(site.NavJS, `dispatchEvent(new CustomEvent('hg:swap'`) &&
		!strings.Contains(site.NavJS, `hg:swap`) {
		t.Error("swap() does not announce that it replaced the page")
	}
	if !strings.Contains(site.RailJS, `'hg:swap'`) {
		t.Error("the rail does not rebind after a swap")
	}
	// And it must be able to run twice without stacking observers.
	if !strings.Contains(site.RailJS, "disconnect()") {
		t.Error("the rail does not disconnect its previous observer, so they stack")
	}
}

// llms.txt is the best agent-facing thing on a site whose whole argument is
// that agents read it more than people do, and nothing in the HTML pointed at
// it. The only references were a comment in robots.txt, which nothing parses,
// and the body of the 404 page.
func TestEveryPagePointsAtLLMSTxt(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		if !strings.Contains(h, `<link rel="alternate" type="text/plain" title="llms.txt" href="/llms.txt">`) {
			t.Errorf("%s does not announce llms.txt in its head", name)
		}
		i := strings.Index(h, "<footer>")
		if i < 0 || !strings.Contains(h[i:], `href="/llms.txt"`) {
			t.Errorf("%s has no visible link to llms.txt", name)
		}
	}
	if _, err := os.Stat(filepath.Join(out, "llms.txt")); err != nil {
		t.Fatalf("llms.txt is announced and missing: %v", err)
	}
}

// author and publisher were the same Organization node on every page. So the
// strongest thing this site has - dated, measured, first-hand failure reports
// - was attributed to nobody a search engine or a model could verify. The
// company publishes; a person writes, and the person has a profile to check
// him against.
func TestTheAuthorIsAPersonAndThePublisherIsTheCompany(t *testing.T) {
	out := buildSite(t)
	re := regexp.MustCompile(`(?s)<script type="application/ld\+json">(.*?)</script>`)
	seen := 0
	for name, h := range htmlPages(t, out) {
		if name == "404.html" {
			continue
		}
		for _, b := range re.FindAllStringSubmatch(h, -1) {
			var v map[string]any
			if err := json.Unmarshal([]byte(b[1]), &v); err != nil {
				continue
			}
			author, ok := v["author"].(map[string]any)
			if !ok {
				continue
			}
			seen++
			if author["@type"] != "Person" {
				t.Errorf("%s: author is a %v, not a Person", name, author["@type"])
			}
			if author["name"] != "Daniel Grimes" {
				t.Errorf("%s: author is %v, which names no human", name, author["name"])
			}
			if _, ok := author["sameAs"]; !ok {
				t.Errorf("%s: the author has no sameAs, so nothing can verify him", name)
			}
			pub, ok := v["publisher"].(map[string]any)
			if !ok {
				t.Errorf("%s: an author with no publisher", name)
				continue
			}
			if pub["@type"] != "Organization" || pub["name"] != "DBHQ" {
				t.Errorf("%s: publisher is %v %v, want the DBHQ Organization", name, pub["@type"], pub["name"])
			}
		}
	}
	if seen == 0 {
		t.Error("no page carries an author at all")
	}
}

// The footer byline is back, and it is not the block that was removed with
// #54. That one repeated the company and three of its links on all 27 pages,
// at the point a reader has already left. This one names the human the JSON-LD
// now calls the author, in the one place every page has: a claim a reader can
// check is worth more than a link nobody clicks.
func TestTheFooterNamesTheHumanWhoWroteIt(t *testing.T) {
	out := buildSite(t)
	for name, h := range htmlPages(t, out) {
		i := strings.Index(h, "<footer>")
		if i < 0 {
			t.Errorf("%s has no footer", name)
			continue
		}
		foot := h[i:]
		if !strings.Contains(foot, "Daniel Grimes") {
			t.Errorf("%s: the footer names no human", name)
		}
		// dbhq.uk, not /dbhq. The page that said who that is was removed on
		// 2026-09-16; the attribution is the part worth keeping, because a
		// crawler and a model both want a named author, and it now points off
		// this site rather than at a page about the company inside the
		// product's documentation.
		if !strings.Contains(foot, `href="https://dbhq.uk/"`) {
			t.Errorf("%s: the byline does not link the person it names", name)
		}
	}
}

// The mirrors are for agents, and they are kept out of a search index with
// X-Robots-Tag rather than with a robots.txt Disallow. The two are not
// interchangeable and swapping them back would undo this.
//
// Disallow stops a crawler FETCHING a URL. It does not stop the URL being
// indexed, and it guarantees the crawler never sees any instruction the
// response carries. Each page links its mirror three times, so Google knew
// every mirror existed, could not fetch one to learn what it was, and reported
// the site under "Duplicate, Google chose different canonical than user" on
// 20 Sep 2026. The old rule was written for GitHub Pages, where a .md file
// could carry no header at all; on Cloudflare Pages it can.
func TestMirrorsAreNoindexedRatherThanHidden(t *testing.T) {
	out := buildSite(t)

	h, err := os.ReadFile(filepath.Join(out, "_headers"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(h), "/*.md") || !strings.Contains(string(h), "X-Robots-Tag: noindex") {
		t.Errorf("_headers does not noindex the markdown mirrors:\n%s", h)
	}

	b, err := os.ReadFile(filepath.Join(out, "robots.txt"))
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "Disallow:") && strings.Contains(line, ".md") {
			t.Errorf("robots.txt blocks the mirrors with %q - that hides the "+
				"X-Robots-Tag header from the crawler that needs to read it", line)
		}
	}
	if !strings.Contains(string(b), "Sitemap: "+baseURL+"/sitemap.xml") {
		t.Error("robots.txt no longer names the sitemap")
	}
}

func containsRule(rules []string, want string) bool {
	for _, r := range rules {
		if strings.EqualFold(r, want) {
			return true
		}
	}
	return false
}

// dateModified alone says a page changed and never says when it arrived. A
// page written in September and corrected in March reads as a March page, and
// first-hand experience that has been there since the start looks new.
func TestArticlesSayWhenTheyArrivedAsWellAsWhenTheyChanged(t *testing.T) {
	out := buildSite(t)
	re := regexp.MustCompile(`(?s)<script type="application/ld\+json">(.*?)</script>`)
	date := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	for name, h := range htmlPages(t, out) {
		if name == "404.html" || name == "index.html" {
			continue
		}
		for _, b := range re.FindAllStringSubmatch(h, -1) {
			var v map[string]any
			if err := json.Unmarshal([]byte(b[1]), &v); err != nil || v["@type"] != "TechArticle" {
				continue
			}
			pub, _ := v["datePublished"].(string)
			mod, _ := v["dateModified"].(string)
			if !date.MatchString(pub) {
				t.Errorf("%s: datePublished is %q", name, pub)
				continue
			}
			if pub > mod {
				t.Errorf("%s: published %s, modified %s - a page cannot change before it exists", name, pub, mod)
			}
		}
	}
}

func TestFirstPublishedIsTheFirstCommitThatTouchedThePage(t *testing.T) {
	repo := gitRepo(t, "2024-03-04T05:06:07Z")
	commitPage(t, repo, "2025-07-08T09:10:11Z")
	pub, err := firstPublished(repo, "page.md", "2025-07-08")
	if err != nil {
		t.Fatal(err)
	}
	if pub != "2024-03-04" {
		t.Errorf("datePublished is %q, want the first commit 2024-03-04", pub)
	}
	mod, err := lastModified(repo, "page.md")
	if err != nil {
		t.Fatal(err)
	}
	if mod != "2025-07-08" {
		t.Errorf("dateModified is %q, want the last commit 2025-07-08", mod)
	}
}

// A page that is not in a checkout at all, or not committed yet, has one
// honest date and it is the one the sitemap already uses.
func TestFirstPublishedFallsBackToTheModifiedDate(t *testing.T) {
	pub, err := firstPublished(t.TempDir(), "page.md", "2026-01-02")
	if err != nil {
		t.Fatal(err)
	}
	if pub != "2026-01-02" {
		t.Errorf("got %q, want the modified date 2026-01-02", pub)
	}
}

// commitPage rewrites page.md and commits it at the given date.
func commitPage(t *testing.T, dir, date string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "page.md"), []byte("# p\n\nbody, changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, dir, "git", "add", "page.md")
	cmd := exec.Command("git", "commit", "--quiet", "-m", "changed")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_DATE="+date, "GIT_COMMITTER_DATE="+date)
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v\n%s", err, b)
	}
}

// The markdown mirror is justified in three files by a number, and the number
// was wrong: "roughly 31 times more bytes as HTML than as markdown" was never
// measured across the site. Measured over 29 pages it is 2.5 to 20.4, about 7
// on the median page and 5.4 across the whole site.
//
// The floor is the longest page - /transports - because chrome is a fixed cost
// and a long page dilutes it, which is the same reason the saving is quoted as
// a range rather than a single figure. The ceiling is the shortest page, for
// the same reason inverted: /dbhq at 20.5 is a clear outlier, and the next
// page down is /pipelines at 14.8.
//
// THE BOUNDS ARE DELIBERATELY WIDER THAN THE MEASUREMENT. They were 2.9, which
// is where /transports sat, so the next paragraph added to that page took it to
// 2.88 and failed this - correctly by the letter and uselessly in practice,
// because "somebody wrote three more sentences" is not the drift worth
// catching. What is worth catching is the mirror generation breaking or the
// chrome ballooning, and those move this by multiples. Slack at both ends, and
// the real figures are in the sentence above so the next reader can see how
// much there is.
//
// IT HAPPENED AGAIN, for the same reason and with the same answer: #66 added
// the blocked-port and proxy sections to /transports, which took the longest
// page on the site to 2.46 and through a floor of 2.5. The floor moves to 2.2
// and the sentence above is remeasured. A floor that fails whenever the longest
// page grows is measuring how much has been written, which is not the claim.
func TestTheMirrorSavingIsTheOneTheCommentsClaim(t *testing.T) {
	out := buildSite(t)
	const lo, hi = 2.2, 23.0
	n := 0
	for name, h := range htmlPages(t, out) {
		if name == "404.html" {
			continue
		}
		md, err := os.ReadFile(filepath.Join(out, strings.TrimSuffix(name, ".html")+".md"))
		if err != nil {
			t.Errorf("%s has no markdown mirror: %v", name, err)
			continue
		}
		r := float64(len(h)) / float64(len(md))
		if r < lo || r > hi {
			t.Errorf("%s is %.1fx its mirror, outside the %.0fx to %.0fx the comments claim: remeasure and change both", name, r, lo, hi)
		}
		n++
	}
	if n == 0 {
		t.Error("no pages were measured")
	}
}

// A published path that stops existing is a 404 for everybody who linked it.
func TestRedirectsCarryTheOldIntercomPath(t *testing.T) {
	got := redirectsFile()
	if !strings.Contains(got, "/intercom /flare 301") {
		t.Errorf("_redirects does not carry the intercom redirect, got:\n%s", got)
	}
}

// A published configuration block gave `RELAY_URL=https://relay.heliograph.dbhq.uk`,
// and that host has never existed: the relay deployed at `heliograph-relay.dbhq.uk`
// because a four-label host under `dbhq.uk` needs a paid certificate pack. The same
// page carried the right host three times and the wrong one in the block people
// paste, so a first-time operator configured a station from the documentation and
// it failed at DNS.
//
// An allowlist rather than a resolver check, deliberately. A network call in the
// build fails when somebody else's DNS has a bad minute, and this defect does not
// need one: a hostname in our own zone that nobody has deployed is a typo, and a
// typo is exactly what a list catches. Adding a host here is a deliberate act,
// which is the point.
//
// The honest limit: this catches a wrong *host*. It does not catch a wrong path,
// a wrong port, or a host that resolves and serves something else. The only
// complete answer is executing the published example, which is #64's own finding.
func TestEveryHostnameWePublishIsOneWeOwn(t *testing.T) {
	deployed := map[string]bool{
		"docs.heliograph.io":       true, // the site itself, since 2026-09-16
		"heliograph.dbhq.uk":       true, // its old name, which 301s here
		"heliograph-relay.dbhq.uk": true, // the relay. NOT relay.heliograph.dbhq.uk
		"bbs.dbhq.uk":              true,
		"modem.dbhq.uk":            true,
		"skills.dbhq.uk":           true,
	}

	re := regexp.MustCompile(`[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:dbhq\.uk|heliograph\.io)`)
	ents, err := os.ReadDir("../../site/content")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		b, err := os.ReadFile(filepath.Join("../../site/content", e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		for _, host := range re.FindAllString(string(b), -1) {
			if !deployed[host] {
				t.Errorf("site/content/%s publishes %q, which is not a host we have deployed. "+
					"If it is real, add it to this test; if it is a typo, that is the bug",
					e.Name(), host)
			}
		}
	}
}

// The hosted relay was named on five published pages and no page said how to
// get a token for it. A reader could reach any of them, believe the hosted
// route was theirs to use, and find no way in and no statement of what they
// were being offered.
//
// So: name the hosted relay and you carry the way in. This asserts on the
// BUILT HTML rather than the markdown, because a page that renders wrong while
// the source reads right is the failure this repository has already had twice,
// and the anchor either exists in the output or it does not.
//
// Two honest limits. It proves a link and an anchor, not that the section
// still says anything useful: deleting the terms while leaving the heading
// passes. And it keys on the hostname, so a page that advertises "the hosted
// one" without naming it is invisible here - which is exactly what
// transports.md did, and why that one had to be found by reading.
func TestNoPageOffersTheHostedRelayWithoutTheWayIn(t *testing.T) {
	const (
		host   = "heliograph-relay.dbhq.uk"
		anchor = "the-hosted-relay-and-how-to-ask-for-a-token"
	)
	out := buildSite(t)
	pages := htmlPages(t, out)

	if !strings.Contains(pages["relay.html"], `id="`+anchor+`"`) {
		t.Errorf("relay.html has no #%s section, so every page that links to it is a 404 fragment", anchor)
	}

	named := 0
	for name, h := range pages {
		if !strings.Contains(h, host) || name == "relay.html" {
			continue
		}
		named++
		if !strings.Contains(h, `/relay#`+anchor) {
			t.Errorf("%s names %s and does not link to /relay#%s: it advertises the hosted relay "+
				"with no way in and no terms", name, host, anchor)
		}
	}
	if named == 0 {
		t.Error("no page outside relay.html names the hosted relay, so this test asserted nothing")
	}
}

// Every workflow that builds this site must clone with full history, because
// `lastmod` is the commit date of each page's own source file. `main.go`
// refuses to build on a shallow clone rather than emit a sitemap claiming
// every page changed today.
//
// WATCHED FAILING BEFORE IT WAS KEPT, and it did not need planting: v0.4.0's
// release run failed with thirteen site tests reporting "the checkout is
// shallow" and every publishing job skipped behind them. `release.yml` had no
// `fetch-depth` at all, and had not since the lastmod work landed in 397c8f3,
// after v0.3.2. `validate.yml` had it the whole time, which is exactly why no
// pull request ever said so: the gate that would have caught it was the one
// workflow that could not.
//
// IT IS SCOPED TO THE JOB AND IT IGNORES COMMENTS, because the first version
// of this test did neither and passed on a file with the fix deleted. It
// searched the whole file for the string, and the whole file included the
// comment explaining the fix. A test satisfied by prose about the thing it
// checks is worse than no test.
func TestWorkflowsThatTestTheSiteCloneFullHistory(t *testing.T) {
	for _, wf := range []string{"release.yml", "validate.yml"} {
		path := filepath.Join("..", "..", ".github", "workflows", wf)
		b, err := os.ReadFile(path)
		if err != nil {
			t.Errorf("cannot read %s: %v", wf, err)
			continue
		}
		checked := 0
		for name, body := range jobs(string(b)) {
			if !strings.Contains(stripComments(body), "go test ./...") {
				continue
			}
			checked++
			if !strings.Contains(stripComments(body), "fetch-depth: 0") {
				t.Errorf("%s job %q runs `go test ./...`, which builds this site, but its "+
					"checkout does not set fetch-depth: 0. Every site test refuses on a shallow "+
					"clone, and in a release workflow that means every publishing job skips "+
					"behind them.", wf, name)
			}
		}
		if checked == 0 {
			t.Errorf("%s: no job in it runs `go test ./...`, so this test asserted nothing about it", wf)
		}
	}
}

// jobs splits a workflow into its top-level job blocks, keyed by job id. Two
// spaces of indent then a name then a colon is a job; anything deeper belongs
// to the one above it.
func jobs(body string) map[string]string {
	out := map[string]string{}
	head := regexp.MustCompile(`^  ([a-zA-Z0-9_-]+):\s*$`)
	name, cur := "", []string{}
	for _, line := range strings.Split(body, "\n") {
		if m := head.FindStringSubmatch(line); m != nil {
			if name != "" {
				out[name] = strings.Join(cur, "\n")
			}
			name, cur = m[1], nil
			continue
		}
		if name != "" {
			cur = append(cur, line)
		}
	}
	if name != "" {
		out[name] = strings.Join(cur, "\n")
	}
	return out
}

// stripComments drops whole-line YAML comments. A comment naming the setting
// is not the setting.
func stripComments(body string) string {
	var keep []string
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		keep = append(keep, line)
	}
	return strings.Join(keep, "\n")
}
