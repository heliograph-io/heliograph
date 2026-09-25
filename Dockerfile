# =============================================================================
#  ghcr.io/heliograph-io/heliograph - the CONTROL side, as a container
# =============================================================================
#     docker run -i --rm ghcr.io/heliograph-io/heliograph mcp     # as an MCP server
#     docker run --rm ghcr.io/heliograph-io/heliograph estates    # as the CLI
#
#  This is the whole `heliograph` binary, not an MCP-only build. `mcp` is the
#  default command because that is what a directory or an MCP client starts it
#  for, but every other subcommand is here too.
#
#  NOT TO BE CONFUSED WITH ghcr.io/heliograph-io/heliograph-toolkit, which is
#  the STATION - the far side, built from station/bash/docker/Dockerfile in
#  this repository by publish-image.yml. The two images
#  sit on opposite sides of the gap and share nothing but the wire format:
#
#    heliograph          your machine. Sends steps, reads logs. This file.
#    heliograph-toolkit  the machine you cannot log into. Runs them.
#
#  -i is not optional for `mcp`: the server speaks JSON-RPC on stdin and
#  stdout, and without an attached stdin it starts, reads EOF and exits, which
#  looks exactly like a crash.
#
#  WHEN TO USE IT, AND WHEN NOT TO
#
#  Use it when you want the server without putting anything on the host, or
#  when something else needs an OCI image - that is one of the package types
#  the MCP registry accepts.
#
#  For ordinary use the released binary or the npm package is better, and it
#  is worth being plain about why rather than leaving somebody to find out:
#  heliograph reads its estates from the host's ~/.config, and a container does
#  not have that unless it is mounted. Started with nothing mounted this image
#  answers introspection and correctly reports that no estates are configured,
#  which is honest but is not yet useful for doing any work.
#
#    npx -y @dbhq/heliograph mcp        # the usual way
#    docker run -i --rm ... mcp         # this file
#
#  To actually drive a station from the container, mount the configuration:
#
#    docker run -i --rm -v ~/.config/heliograph:/home/nonroot/.config/heliograph \
#      ghcr.io/heliograph-io/heliograph mcp
#
#  or, if you would rather be explicit than rely on where HOME points:
#
#    docker run -i --rm -e XDG_CONFIG_HOME=/config -v ~/.config:/config \
#      ghcr.io/heliograph-io/heliograph mcp
#
#  Both were checked against a real estate file, not assumed from the paths.
#
#  IT CARRIES NO CREDENTIALS AND NO ESTATE. Started with nothing mounted, the
#  server answers introspection and reports honestly that no estates are
#  configured. That is the correct answer, not a failure: the tools exist, and
#  there is nowhere for them to point yet.
# =============================================================================
# PINNED TO THE PATCH. `golang:1.27-alpine` floats to whatever 1.27.x is
# current, and a Go patch release changes the bytes the compiler emits - so
# with a floating tag the binary in this image is not the binary anybody can
# reproduce from the tag. The pin is go.mod's `go` directive, and
# packaging/toolchain_test.go fails the build if this line disagrees with it.
FROM golang:1.27.1-alpine AS build
WORKDIR /src
# The module files first, so a change to the source does not re-resolve
# dependencies. There are two of them and they rarely move.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# The version is stamped in, so a directory that starts this image reports a
# real version rather than "dev". Defaulted rather than required, so a plain
# `docker build .` still works.
ARG VERSION=dev
# CGO off: the binary has to run on a distroless image with no libc of its own.
#
# -buildvcs=false for the same reason packaging/reproduce.sh uses it: Go
# otherwise stamps the git commit into the binary, this stage has no .git in
# its context, and `auto` omits the stamp silently - so the image binary would
# differ from the released one for a reason nothing reports.
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.version=${VERSION}" -o /heliograph ./cmd/heliograph

# Distroless static: no shell, no package manager, nothing to exec into. The
# server needs none of it, and an MCP server that a directory runs unattended
# should carry the smallest surface it can.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /heliograph /usr/local/bin/heliograph
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/heliograph"]
CMD ["mcp"]

LABEL org.opencontainers.image.title="heliograph" \
      org.opencontainers.image.description="The control side of heliograph: CLI and MCP server. Run commands on a machine you cannot SSH into." \
      org.opencontainers.image.url="https://heliograph.io" \
      org.opencontainers.image.source="https://github.com/heliograph-io/heliograph" \
      org.opencontainers.image.licenses="Apache-2.0"
