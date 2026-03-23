package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// version is injected at build time via -ldflags.
var version = "dev"

type healthResponse struct {
	Status  string `json:"status"`
	Service string `json:"service"`
	Version string `json:"version"`
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if err := json.NewEncoder(w).Encode(healthResponse{
		Status:  "healthy",
		Service: "api-gateway",
		Version: version,
	}); err != nil {
		slog.Error("failed to encode health response", "error", err)
	}
}

func newReverseProxy(backendURL string) (http.Handler, error) {
	target, err := url.Parse(backendURL)
	if err != nil {
		return nil, fmt.Errorf("invalid backend URL %q: %w", backendURL, err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)

	// Customise error handler so upstream failures return 502 with a JSON body.
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		slog.Error("proxy error", "path", r.URL.Path, "error", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"error":   "bad_gateway",
			"message": "upstream service unavailable",
		})
	}

	// Rewrite the request so the backend sees the original path.
	original := proxy.Director
	proxy.Director = func(req *http.Request) {
		original(req)
		req.Host = target.Host
	}

	return proxy, nil
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		slog.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"remote_addr", r.RemoteAddr,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

func main() {
	// Structured JSON logging.
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	backendURL := os.Getenv("BACKEND_API_URL")
	if backendURL == "" {
		backendURL = "http://backend-api:8081"
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	proxy, err := newReverseProxy(backendURL)
	if err != nil {
		slog.Error("failed to create reverse proxy", "error", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", healthHandler)
	mux.Handle("GET /metrics", promhttp.Handler())
	mux.Handle("/api/", proxy)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      loggingMiddleware(mux),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Graceful shutdown on SIGTERM / SIGINT.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		slog.Info("api-gateway starting", "port", port, "backend", backendURL, "version", version)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down gracefully")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}
	slog.Info("server stopped")
}
// initial build 1774275258
// initial build 1774289541
