# heliograph

Run commands on a machine you cannot SSH into.

<!-- mcp-name: io.github.heliograph-io/heliograph -->

```bash
npx -y @dbhq/heliograph mcp     # as an MCP server
npx -y @dbhq/heliograph --help  # as a CLI
```

This package downloads the released Go binary for your platform and verifies it
against the checksums published beside it. If the checksum does not match, the
file is deleted and the install fails.

Full documentation: <https://docs.heliograph.io>
