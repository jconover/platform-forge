package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// version is injected at build time via -ldflags.
var version = "dev"

var (
	cyclesTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "worker_cycles_total",
		Help: "Total number of work cycles completed.",
	})
	stressMode = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "worker_stress_mode",
		Help: "1 when running in CPU stress mode, 0 otherwise.",
	})
	activeWorkers = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "worker_active_goroutines",
		Help: "Number of active worker goroutines.",
	})
)

// workCycles tracks total cycles for the health endpoint.
var workCycles atomic.Int64

type healthResponse struct {
	Status      string `json:"status"`
	Service     string `json:"service"`
	Version     string `json:"version"`
	WorkCycles  int64  `json:"work_cycles"`
	StressMode  bool   `json:"stress_mode"`
}

func healthHandler(isStress bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if err := json.NewEncoder(w).Encode(healthResponse{
			Status:     "healthy",
			Service:    "worker",
			Version:    version,
			WorkCycles: workCycles.Load(),
			StressMode: isStress,
		}); err != nil {
			slog.Error("failed to encode health response", "error", err)
		}
	}
}

// cpuStressWorker performs matrix multiplication to saturate a CPU core.
// size controls the matrix dimension; larger = more work per cycle.
func cpuStressWorker(ctx context.Context, workerID int, size int) {
	slog.Info("stress worker started", "id", workerID, "matrix_size", size)
	activeWorkers.Inc()
	defer activeWorkers.Dec()

	a := makeMatrix(size)
	b := makeMatrix(size)
	c := make([]float64, size*size)

	for {
		select {
		case <-ctx.Done():
			slog.Info("stress worker stopped", "id", workerID)
			return
		default:
			multiplyMatrices(a, b, c, size)
			workCycles.Add(1)
			cyclesTotal.Inc()
		}
	}
}

func makeMatrix(n int) []float64 {
	m := make([]float64, n*n)
	for i := range m {
		m[i] = rand.Float64()
	}
	return m
}

func multiplyMatrices(a, b, c []float64, n int) {
	for i := 0; i < n; i++ {
		for k := 0; k < n; k++ {
			aik := a[i*n+k]
			for j := 0; j < n; j++ {
				c[i*n+j] += aik * b[k*n+j]
			}
		}
	}
}

// lightWorker simulates lightweight background processing.
func lightWorker(ctx context.Context) {
	slog.Info("light worker started")
	activeWorkers.Inc()
	defer activeWorkers.Dec()

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("light worker stopped")
			return
		case <-ticker.C:
			// Small computation to represent real work.
			sum := 0.0
			for i := 0; i < 10_000; i++ {
				sum += rand.Float64()
			}
			_ = sum
			workCycles.Add(1)
			cyclesTotal.Inc()
		}
	}
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
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	isStress := os.Getenv("STRESS_MODE") == "true"

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	// Number of parallel stress workers (defaults to GOMAXPROCS).
	numWorkers := runtime.GOMAXPROCS(0)
	if nw := os.Getenv("WORKER_COUNT"); nw != "" {
		if n, err := strconv.Atoi(nw); err == nil && n > 0 {
			numWorkers = n
		}
	}

	// Matrix size for stress mode (default 200 → 200×200 matmul per cycle).
	matrixSize := 200
	if ms := os.Getenv("MATRIX_SIZE"); ms != "" {
		if n, err := strconv.Atoi(ms); err == nil && n > 0 {
			matrixSize = n
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if isStress {
		stressMode.Set(1)
		slog.Info("starting CPU stress workers", "count", numWorkers, "matrix_size", matrixSize)
		for i := 0; i < numWorkers; i++ {
			go cpuStressWorker(ctx, i, matrixSize)
		}
	} else {
		stressMode.Set(0)
		slog.Info("starting light worker")
		go lightWorker(ctx)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", healthHandler(isStress))
	mux.Handle("GET /metrics", promhttp.Handler())

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      loggingMiddleware(mux),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		slog.Info("worker starting", "port", port, "stress_mode", isStress, "version", version)
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
