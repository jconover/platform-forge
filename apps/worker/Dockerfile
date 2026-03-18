# syntax=docker/dockerfile:1
FROM golang:1.22-alpine AS builder

WORKDIR /build

# go.sum may be empty on first build; go mod tidy regenerates it.
COPY src/go.mod src/go.sum ./
RUN go mod tidy && go mod download

COPY src/ .

ARG GIT_SHA=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.version=${GIT_SHA}" \
    -o /worker \
    .

# ---
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /worker /worker

EXPOSE 8082

ENTRYPOINT ["/worker"]
