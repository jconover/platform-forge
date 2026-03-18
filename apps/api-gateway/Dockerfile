# syntax=docker/dockerfile:1
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Cache dependencies before copying source.
# go.sum may be empty on first build; go mod tidy regenerates it.
COPY src/go.mod src/go.sum ./
RUN go mod tidy && go mod download

COPY src/ .

# Build with version injection from build arg
ARG GIT_SHA=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.version=${GIT_SHA}" \
    -o /api-gateway \
    .

# ---
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /api-gateway /api-gateway

EXPOSE 8080

ENTRYPOINT ["/api-gateway"]
