package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHealthHandler_NotStress(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	healthHandler(false)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var resp healthResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode error: %v", err)
	}

	if resp.Status != "healthy" {
		t.Errorf("expected status=healthy, got %q", resp.Status)
	}
	if resp.Service != "worker" {
		t.Errorf("expected service=worker, got %q", resp.Service)
	}
	if resp.StressMode != false {
		t.Errorf("expected stress_mode=false")
	}
}

func TestHealthHandler_Stress(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	healthHandler(true)(rec, req)

	var resp healthResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if !resp.StressMode {
		t.Errorf("expected stress_mode=true")
	}
}

func TestHealthHandlerContentType(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	healthHandler(false)(rec, req)

	ct := rec.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("expected application/json, got %q", ct)
	}
}

func TestMakeMatrix(t *testing.T) {
	m := makeMatrix(10)
	if len(m) != 100 {
		t.Errorf("expected 100 elements, got %d", len(m))
	}
}

func TestMultiplyMatrices(t *testing.T) {
	n := 3
	a := []float64{1, 0, 0, 0, 1, 0, 0, 0, 1} // identity
	b := []float64{1, 2, 3, 4, 5, 6, 7, 8, 9}
	c := make([]float64, n*n)

	multiplyMatrices(a, b, c, n)

	// identity * b == b
	for i, v := range b {
		if c[i] != v {
			t.Errorf("c[%d]: expected %f, got %f", i, v, c[i])
		}
	}
}

func TestLightWorker_Cancels(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	done := make(chan struct{})
	go func() {
		lightWorker(ctx)
		close(done)
	}()

	select {
	case <-done:
		// ok
	case <-time.After(2 * time.Second):
		t.Error("lightWorker did not stop after context cancellation")
	}
}

func TestCPUStressWorker_Cancels(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	done := make(chan struct{})
	go func() {
		cpuStressWorker(ctx, 0, 10) // small matrix so test is fast
		close(done)
	}()

	select {
	case <-done:
		// ok
	case <-time.After(2 * time.Second):
		t.Error("cpuStressWorker did not stop after context cancellation")
	}
}
