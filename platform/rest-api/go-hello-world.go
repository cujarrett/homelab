// APPLICATION DEVELOPER ROLE (servicebinding.io/application-developer):
//
// The Service Binding controller mounts secrets as files under:
//   ${SERVICE_BINDING_ROOT}/<binding-name>/<secret-key>
//
// Each binding directory has a "type" file used to identify the service.
// Only include this binding if its type matches what we're looking for.
//
// References:
//   https://servicebinding.io/application-developer/

package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// bindingRoot returns the directory where the Service Binding controller mounts secrets.
// The controller sets SERVICE_BINDING_ROOT automatically; /bindings is the common default.
func bindingRoot() string {
	if root := os.Getenv("SERVICE_BINDING_ROOT"); root != "" {
		return root
	}
	return "/bindings"
}

// readBindingsByType scans SERVICE_BINDING_ROOT for binding directories whose
// "type" file matches the given type string (e.g. "s3", "redis").
// The spec recommends selecting by type, not by binding name, so the app is
// decoupled from whatever name the operator chose.
// Returns a map of key->value for each matched binding.
func readBindingsByType(bindingType string) []map[string]string {
	root := bindingRoot()
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}

	var matches []map[string]string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(root, entry.Name())

		// Per the spec, each binding directory contains a "type" file.
		// Only include this binding if its type matches what we're looking for.
		typeVal := readFile(filepath.Join(dir, "type"))
		if typeVal != bindingType {
			continue
		}

		// Read all files in the directory into a map.
		// Each file name is the key, file content is the value.
		b := map[string]string{}
		files, _ := os.ReadDir(dir)
		for _, f := range files {
			if !f.IsDir() {
				b[f.Name()] = readFile(filepath.Join(dir, f.Name()))
			}
		}
		matches = append(matches, b)
	}
	return matches
}

// readFile reads a file and trims whitespace. Returns "" on error.
func readFile(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "Hello, World!\n\n")

		// S3: select by type, not binding name (spec recommendation)
		s3Bindings := readBindingsByType("s3")
		if len(s3Bindings) == 0 {
			fmt.Fprintf(w, "S3: not bound\n")
		} else {
			b := s3Bindings[0]
			fmt.Fprintf(w, "S3 Bucket: %s\n", b["bucket-name"])
			fmt.Fprintf(w, "S3 Region: %s\n", b["region"])
		}

		// ElastiCache: select by type "redis"
		cacheBindings := readBindingsByType("redis")
		if len(cacheBindings) == 0 {
			fmt.Fprintf(w, "ElastiCache: not bound\n")
		} else {
			b := cacheBindings[0]
			fmt.Fprintf(w, "ElastiCache: configured (%s:%s)\n", b["host"], b["port"])
		}
	})

	log.Println("Go REST API listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
