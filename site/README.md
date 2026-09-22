# site

The documentation site for `docs.heliograph.io`. It was `heliograph.dbhq.uk` until 2026-09-16; that name 301s here, root to the apex and every deep path to its matching page.

**One canonical source, several renderings.** The 2026 consensus for developer
documentation is not separate content for humans and machines: it is one set of
pages served as HTML, as markdown, as `llms.txt`, and through an MCP server.
This follows it, with one exception that is real rather than convenient.

The exception is the **skill**. `skills/heliograph/references/method.md`
says "never truncate", "keep a control", "change one thing between runs". That
is not a description of the product, it is a procedure that changes what an
agent does, and it has no reader on a documentation site. It stays where it is.

## Why markdown mirrors

Measured across all 29 pages, the same page costs two and a half to twenty
times more bytes as HTML than as markdown - about seven times on the median
page, five times over the whole site - so chrome is a token tax on every agent
that reads the site. Every page is available at its own URL plus `.md`. A test
measures the ratio on every build, so the figure in this sentence and the site
it describes cannot drift apart.

`llms.txt` and `llms-full.txt` sit at the origin root. The honest position on
those: one log study found 408 requests to `llms.txt` out of more than 500
million AI bot visits in ninety days, so they are shipped because IDE agents
fetch them and it costs half a day, not because they will win citations.

## Analytics, and what a search result sees

**This site measures nothing.** The GA4 tag, the Consent Mode gate and the
consent banner were removed when it moved to `docs.heliograph.io` on
2026-09-16, and the reasoning is in `cmd/heliograph-site/main.go` beside the
code that used to emit them.

All three were correct while the site was `heliograph.dbhq.uk`: the measurement
id was the dbhq.uk stream's, on Google's one-stream-per-site-including-subdomains
guidance, and the banner linked the dbhq.uk privacy policy, which actually
covered the hostname the reader was on. `heliograph.io` is a different
registrable domain, so all three stopped being true in the same instant - what
would have been live is one domain's tag disclosed by another domain's policy.

Removed rather than repointed: a measurement id nobody has created cannot be
written here, and a banner cannot link a policy that does not exist. The cost is
accepted and real - the documentation has no usage signal at all.

Titles and descriptions are hand-written in `cmd/heliograph-site/main.go`
(`titles`, `descriptions`), and a test holds every description to 70 to 160
characters. The sitemap's `lastmod` is the last commit that touched each page,
so the build refuses a shallow clone. The Open Graph image is rendered from
`site/og/og.html` by `site/og/render.sh` and committed as `assets/og.png`;
re-run the script after changing the template.

Why each of these exists, and what it cost:
[`docs/specs/2026-09-09-analytics-and-seo-design.md`](../docs/specs/2026-09-09-analytics-and-seo-design.md).
