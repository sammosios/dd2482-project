// Roster is a small users dashboard (Go + htmx + PostgreSQL), the example
// application deployed on the Dokploy cluster. See README.md.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

// config comes from environment variables, which is how Dokploy (and
// Docker in general) hands settings to a container.
type config struct {
	port          string
	databaseURL   string
	redisURL      string // optional: without it, sign-ins aren't rate limited
	adminEmail    string
	adminPassword string
	adminName     string
	allowSignup   bool
}

func loadConfig() (config, error) {
	cfg := config{
		port:          envOr("PORT", "8080"),
		databaseURL:   os.Getenv("DATABASE_URL"),
		redisURL:      os.Getenv("REDIS_URL"),
		adminEmail:    normalizeEmail(os.Getenv("ADMIN_EMAIL")),
		adminPassword: os.Getenv("ADMIN_PASSWORD"),
		adminName:     envOr("ADMIN_NAME", "Administrator"),
	}
	if cfg.databaseURL == "" {
		return cfg, errors.New("DATABASE_URL is not set")
	}
	allow, err := strconv.ParseBool(envOr("ALLOW_SIGNUP", "true"))
	if err != nil {
		return cfg, fmt.Errorf("ALLOW_SIGNUP must be true or false: %w", err)
	}
	cfg.allowSignup = allow
	return cfg, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	// The runtime image has no shell or curl, so its HEALTHCHECK runs the
	// binary itself: `roster healthcheck`.
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck(envOr("PORT", "8080")))
	}

	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("exiting", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	// Swarm stops a task with SIGTERM, then SIGKILLs it 10s later by default.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := connect(ctx, cfg.databaseURL, log)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := prepareDatabase(ctx, pool, cfg, log); err != nil {
		return err
	}
	limiter, err := newLoginLimiter(ctx, cfg.redisURL, log)
	if err != nil {
		return err
	}
	defer limiter.close()

	v, err := newViews()
	if err != nil {
		return err
	}
	host, _ := os.Hostname()
	a := &app{db: &store{pool: pool}, limiter: limiter, views: v, log: log, host: host, allowSignup: cfg.allowSignup}
	go a.cleanupSessions(ctx)

	srv := &http.Server{
		Addr:              ":" + cfg.port,
		Handler:           a.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.ListenAndServe() }()
	log.Info("listening", "addr", srv.Addr, "host", host, "signup", cfg.allowSignup)

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}
	// Let in-flight requests finish, within Swarm's grace period.
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

// healthcheck asks the running server for /healthz and returns the exit
// code Docker expects: 0 for healthy, 1 for not.
func healthcheck(port string) int {
	client := http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintln(os.Stderr, "healthz:", resp.Status)
		return 1
	}
	return 0
}
