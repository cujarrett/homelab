package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func bindingRoot() string {
	if v := os.Getenv("SERVICE_BINDING_ROOT"); v != "" {
		return v
	}
	return "/bindings"
}

// readBinding reads all files in $SERVICE_BINDING_ROOT/<name> and returns them as a map.
func readBinding(name string) (map[string]string, error) {
	dir := filepath.Join(bindingRoot(), name)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	result := make(map[string]string)
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		result[e.Name()] = strings.TrimSpace(string(data))
	}
	return result, nil
}

func listBindings() ([]string, error) {
	entries, err := os.ReadDir(bindingRoot())
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}, nil
		}
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	return names, nil
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func main() {
	mux := http.NewServeMux()

	// Health check — includes binding summary
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		bindingNames, _ := listBindings()
		bindingSummary := make(map[string][]string)
		for _, name := range bindingNames {
			data, err := readBinding(name)
			if err != nil {
				continue
			}
			k := keys(data)
			bindingSummary[name] = k
		}
		writeJSON(w, map[string]any{
			"status":   "ok",
			"root":     bindingRoot(),
			"bindings": bindingSummary,
		})
	})

	// List all binding names mounted under SERVICE_BINDING_ROOT
	mux.HandleFunc("GET /bindings", func(w http.ResponseWriter, r *http.Request) {
		names, err := listBindings()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, map[string]any{"root": bindingRoot(), "bindings": names})
	})

	// Show keys (not values) for a specific binding — safe to expose
	mux.HandleFunc("GET /bindings/{name}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		data, err := readBinding(name)
		if err != nil {
			http.Error(w, fmt.Sprintf("binding %q not found", name), http.StatusNotFound)
			return
		}
		keys := make([]string, 0, len(data))
		for k := range data {
			keys = append(keys, k)
		}
		writeJSON(w, map[string]any{"name": name, "keys": keys})
	})

	// Ping S3 — constructs endpoint from /bindings/s3/id (bucket name) and region, does HTTP HEAD
	mux.HandleFunc("GET /s3/ping", func(w http.ResponseWriter, r *http.Request) {
		data, err := readBinding("s3")
		if err != nil {
			http.Error(w, "s3 binding not found", http.StatusServiceUnavailable)
			return
		}
		bucket, region := data["id"], data["region"]
		if bucket == "" || region == "" {
			writeJSON(w, map[string]any{"reachable": false, "error": "s3 binding missing id or region key", "keys": keys(data)})
			return
		}
		endpoint := fmt.Sprintf("%s.s3.%s.amazonaws.com", bucket, region)
		client := &http.Client{Timeout: 5 * time.Second}
		resp, err := client.Head("https://" + endpoint)
		if err != nil {
			writeJSON(w, map[string]any{"endpoint": endpoint, "reachable": false, "error": err.Error()})
			return
		}
		resp.Body.Close()
		writeJSON(w, map[string]any{"endpoint": endpoint, "reachable": true, "statusCode": resp.StatusCode})
	})

	// Ping ElastiCache — reads primary_endpoint_address+port from /bindings/elasticache, does TCP dial
	mux.HandleFunc("GET /cache/ping", func(w http.ResponseWriter, r *http.Request) {
		data, err := readBinding("elasticache")
		if err != nil {
			http.Error(w, "elasticache binding not found", http.StatusServiceUnavailable)
			return
		}
		endpoint := data["primary_endpoint_address"]
		port := data["port"]
		if endpoint == "" || port == "" {
			writeJSON(w, map[string]any{"reachable": false, "error": "elasticache binding missing primary_endpoint_address or port", "keys": keys(data)})
			return
		}
		addr := net.JoinHostPort(endpoint, port)
		conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
		if err != nil {
			writeJSON(w, map[string]any{"addr": addr, "reachable": false, "error": err.Error()})
			return
		}
		conn.Close()
		writeJSON(w, map[string]any{"addr": addr, "reachable": true})
	})

	log.Printf("SERVICE_BINDING_ROOT=%s", bindingRoot())
	log.Printf("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

func keys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
