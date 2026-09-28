# Build stage: a static Go binary (no cgo), so the runtime image needs no libc.
FROM golang:1.27-alpine AS build
WORKDIR /src
# Dependencies first: this layer stays cached until go.mod or go.sum change.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/roster .

# Runtime stage: distroless has no shell or package manager, runs as a
# non-root user, and ships CA certificates and time zone data.
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/roster /roster
ENV PORT=8080
EXPOSE 8080
# Swarm only routes traffic to a replica once this passes, and a rolling
# update waits for it before stopping the old replica.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 CMD ["/roster", "healthcheck"]
ENTRYPOINT ["/roster"]
