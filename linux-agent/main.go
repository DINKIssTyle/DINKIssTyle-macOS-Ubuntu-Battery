package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type batteryPayload struct {
	Host       string `json:"host"`
	Percent    int    `json:"percent"`
	Status     string `json:"status"`
	IsCharging bool   `json:"is_charging"`
	Timestamp  int64  `json:"timestamp"`
}

func main() {
	var (
		serverURL = flag.String("server", envOrDefault("LINUX_BATTERY_SERVER", "http://macbook.local:8787/battery"), "macOS receiver URL")
		apiKey    = flag.String("api-key", envOrDefault("LINUX_BATTERY_API_KEY", ""), "macOS receiver API key")
		interval  = flag.Duration("interval", 5*time.Second, "send interval")
		battery   = flag.String("battery", envOrDefault("LINUX_BATTERY_PATH", ""), "battery directory such as /sys/class/power_supply/BAT0")
		once      = flag.Bool("once", false, "send one reading and exit")
	)
	flag.Parse()

	if strings.TrimSpace(*apiKey) == "" {
		log.Fatal("missing API key: pass -api-key or set LINUX_BATTERY_API_KEY")
	}

	hostname, err := os.Hostname()
	if err != nil || hostname == "" {
		hostname = "linux"
	}

	batteryPath := *battery
	if batteryPath == "" {
		batteryPath, err = discoverBatteryPath()
		if err != nil {
			log.Fatal(err)
		}
	}

	client := &http.Client{Timeout: 3 * time.Second}
	for {
		payload, err := readBatteryPayload(hostname, batteryPath)
		if err != nil {
			log.Printf("read battery: %v", err)
		} else if err := postPayload(context.Background(), client, *serverURL, *apiKey, payload); err != nil {
			log.Printf("post battery: %v", err)
		} else {
			log.Printf("sent %s %d%% %s", payload.Host, payload.Percent, payload.Status)
		}

		if *once {
			return
		}
		time.Sleep(*interval)
	}
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func discoverBatteryPath() (string, error) {
	entries, err := os.ReadDir("/sys/class/power_supply")
	if err != nil {
		return "", fmt.Errorf("list power supplies: %w", err)
	}

	for _, entry := range entries {
		path := filepath.Join("/sys/class/power_supply", entry.Name())
		value, err := readTrimmed(filepath.Join(path, "type"))
		if err == nil && strings.EqualFold(value, "Battery") {
			return path, nil
		}
	}

	return "", fmt.Errorf("no battery found in /sys/class/power_supply")
}

func readBatteryPayload(hostname, batteryPath string) (batteryPayload, error) {
	capacity, err := readTrimmed(filepath.Join(batteryPath, "capacity"))
	if err != nil {
		return batteryPayload{}, err
	}

	percent, err := strconv.Atoi(capacity)
	if err != nil {
		return batteryPayload{}, fmt.Errorf("parse capacity %q: %w", capacity, err)
	}

	status, err := readTrimmed(filepath.Join(batteryPath, "status"))
	if err != nil {
		return batteryPayload{}, err
	}

	return batteryPayload{
		Host:       hostname,
		Percent:    percent,
		Status:     status,
		IsCharging: strings.EqualFold(status, "Charging") || strings.EqualFold(status, "Full"),
		Timestamp:  time.Now().Unix(),
	}, nil
}

func readTrimmed(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	return strings.TrimSpace(string(data)), nil
}

func postPayload(ctx context.Context, client *http.Client, serverURL string, apiKey string, payload batteryPayload) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, serverURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+apiKey)

	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode < 200 || response.StatusCode >= 300 {
		responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 1024))
		detail := strings.TrimSpace(string(responseBody))
		if detail == "" {
			return fmt.Errorf("unexpected response: %s", response.Status)
		}
		return fmt.Errorf("unexpected response: %s: %s", response.Status, detail)
	}
	return nil
}
