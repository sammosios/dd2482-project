package main

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"log/slog"
	"path"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

// migrationLockID is the key for pg_advisory_lock. Any number works, as
// long as every replica uses the same one.
const migrationLockID = 2482

// connect opens a connection pool. On a fresh deploy the database may still
// be starting, so it keeps trying for a minute before giving up (and Swarm
// then restarts the task).
func connect(ctx context.Context, url string, log *slog.Logger) (*pgxpool.Pool, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("DATABASE_URL: %w", err)
	}
	deadline := time.Now().Add(time.Minute)
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = pool.Ping(pingCtx)
		cancel()
		if err == nil {
			return pool, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			pool.Close()
			return nil, fmt.Errorf("database unreachable: %w", err)
		}
		log.Warn("waiting for the database", "err", err)
		select {
		case <-ctx.Done():
		case <-time.After(2 * time.Second):
		}
	}
}

// prepareDatabase applies pending migrations and creates the first admin.
// Every replica does this on startup, so it holds a Postgres advisory lock
// throughout: replicas starting at the same time take turns instead of
// racing to apply the same migration.
func prepareDatabase(ctx context.Context, pool *pgxpool.Pool, cfg config, log *slog.Logger) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()

	// A session-level lock belongs to one connection, so locking, the work
	// and unlocking all have to go through conn.
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", migrationLockID); err != nil {
		return fmt.Errorf("take the migration lock: %w", err)
	}
	defer conn.Exec(context.WithoutCancel(ctx), "SELECT pg_advisory_unlock($1)", migrationLockID)

	if err := migrate(ctx, conn.Conn(), log); err != nil {
		return err
	}
	return seedAdmin(ctx, conn.Conn(), cfg, log)
}

// migrate runs the files in migrations/ in name order, each at most once,
// and each in its own transaction so a failure leaves nothing half-applied.
func migrate(ctx context.Context, conn *pgx.Conn, log *slog.Logger) error {
	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version    text PRIMARY KEY,
		applied_at timestamptz NOT NULL DEFAULT now()
	)`); err != nil {
		return err
	}
	files, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	slices.Sort(files)
	for _, file := range files {
		version := path.Base(file)
		var applied bool
		err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)`, version).Scan(&applied)
		if err != nil {
			return err
		}
		if applied {
			continue
		}
		body, err := migrations.ReadFile(file)
		if err != nil {
			return err
		}
		err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, string(body)); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO schema_migrations (version) VALUES ($1)`, version)
			return err
		})
		if err != nil {
			return fmt.Errorf("migration %s: %w", version, err)
		}
		log.Info("applied migration", "version", version)
	}
	return nil
}

// seedAdmin creates the first admin from ADMIN_EMAIL and ADMIN_PASSWORD
// when there is no admin yet. It never touches an existing account:
// promoting one just because its email matches would let whoever signed up
// with that address first become admin.
func seedAdmin(ctx context.Context, conn *pgx.Conn, cfg config, log *slog.Logger) error {
	var haveAdmin bool
	if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE role = 'admin')`).Scan(&haveAdmin); err != nil {
		return err
	}
	if haveAdmin {
		return nil
	}
	if cfg.adminEmail == "" || cfg.adminPassword == "" {
		log.Warn("there is no admin account yet: set ADMIN_EMAIL and ADMIN_PASSWORD, then restart")
		return nil
	}
	if !validEmail(cfg.adminEmail) {
		return fmt.Errorf("ADMIN_EMAIL %q is not a valid email address", cfg.adminEmail)
	}
	if problem := passwordProblem(cfg.adminPassword); problem != "" {
		return fmt.Errorf("ADMIN_PASSWORD: %s", problem)
	}
	hash, err := hashPassword(cfg.adminPassword)
	if err != nil {
		return err
	}
	tag, err := conn.Exec(ctx, `
		INSERT INTO users (email, name, password_hash, role) VALUES ($1, $2, $3, 'admin')
		ON CONFLICT (lower(email)) DO NOTHING`,
		cfg.adminEmail, cfg.adminName, hash)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		log.Warn("not creating the admin: ADMIN_EMAIL already belongs to a member account", "email", cfg.adminEmail)
		return nil
	}
	log.Info("created the first admin", "email", cfg.adminEmail)
	return nil
}
