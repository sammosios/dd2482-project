package main

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	errNotFound   = errors.New("not found")
	errEmailTaken = errors.New("email already in use")
)

// Role decides what a user can do: admins manage every account, members
// only see and edit their own.
type Role string

const (
	RoleAdmin  Role = "admin"
	RoleMember Role = "member"
)

func (r Role) Label() string {
	if r == RoleAdmin {
		return "Admin"
	}
	return "Member"
}

type User struct {
	ID           int64      `db:"id"`
	Email        string     `db:"email"`
	Name         string     `db:"name"`
	JobTitle     string     `db:"job_title"`
	PasswordHash string     `db:"password_hash"`
	Role         Role       `db:"role"`
	Active       bool       `db:"active"`
	CreatedAt    time.Time  `db:"created_at"`
	UpdatedAt    time.Time  `db:"updated_at"`
	LastLoginAt  *time.Time `db:"last_login_at"`
}

func (u User) IsAdmin() bool { return u.Role == RoleAdmin }

// userFilter is the search box and the two dropdowns on the users page.
type userFilter struct {
	Query  string
	Role   string // "", "admin" or "member"
	Status string // "", "active" or "disabled"
}

type userStats struct {
	Total, Active, Disabled, Admins int
}

// store holds all the SQL.
type store struct {
	pool *pgxpool.Pool
}

const userColumns = `id, email, name, job_title, password_hash, role, active, created_at, updated_at, last_login_at`

// one runs a query that returns a single user.
func (s *store) one(ctx context.Context, sql string, args ...any) (*User, error) {
	rows, _ := s.pool.Query(ctx, sql, args...)
	u, err := pgx.CollectExactlyOneRow(rows, pgx.RowToAddrOfStructByName[User])
	var pgErr *pgconn.PgError
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return nil, errNotFound
	case errors.As(err, &pgErr) && pgErr.Code == "23505": // unique_violation
		return nil, errEmailTaken
	}
	return u, err
}

func (s *store) UserByID(ctx context.Context, id int64) (*User, error) {
	return s.one(ctx, `SELECT `+userColumns+` FROM users WHERE id = $1`, id)
}

func (s *store) UserByEmail(ctx context.Context, email string) (*User, error) {
	return s.one(ctx, `SELECT `+userColumns+` FROM users WHERE lower(email) = lower($1)`, email)
}

func (s *store) ListUsers(ctx context.Context, f userFilter) ([]User, error) {
	rows, _ := s.pool.Query(ctx, `
		SELECT `+userColumns+` FROM users
		WHERE ($1 = '' OR name ILIKE $1 OR email ILIKE $1 OR job_title ILIKE $1)
		  AND ($2 = '' OR role = $2)
		  AND ($3 = '' OR active = ($3 = 'active'))
		ORDER BY created_at DESC, id DESC
		LIMIT 500`,
		likePattern(f.Query), f.Role, f.Status)
	return pgx.CollectRows(rows, pgx.RowToStructByName[User])
}

// likePattern turns search box input into an ILIKE pattern that matches it
// anywhere, with any % and _ in it taken literally.
func likePattern(q string) string {
	if q == "" {
		return ""
	}
	return "%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q) + "%"
}

func (s *store) RecentUsers(ctx context.Context, limit int) ([]User, error) {
	rows, _ := s.pool.Query(ctx, `SELECT `+userColumns+` FROM users ORDER BY created_at DESC, id DESC LIMIT $1`, limit)
	return pgx.CollectRows(rows, pgx.RowToStructByName[User])
}

func (s *store) Stats(ctx context.Context) (userStats, error) {
	var st userStats
	err := s.pool.QueryRow(ctx, `
		SELECT count(*),
		       count(*) FILTER (WHERE active),
		       count(*) FILTER (WHERE NOT active),
		       count(*) FILTER (WHERE role = 'admin')
		FROM users`).Scan(&st.Total, &st.Active, &st.Disabled, &st.Admins)
	return st, err
}

func (s *store) CreateUser(ctx context.Context, u User) (*User, error) {
	return s.one(ctx, `
		INSERT INTO users (email, name, job_title, password_hash, role)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING `+userColumns,
		u.Email, u.Name, u.JobTitle, u.PasswordHash, u.Role)
}

// UpdateUser saves an admin's edits. An empty passwordHash keeps the
// current password.
func (s *store) UpdateUser(ctx context.Context, u User, passwordHash string) (*User, error) {
	return s.one(ctx, `
		UPDATE users
		SET name = $2, email = $3, job_title = $4, role = $5,
		    password_hash = coalesce(nullif($6, ''), password_hash), updated_at = now()
		WHERE id = $1
		RETURNING `+userColumns,
		u.ID, u.Name, u.Email, u.JobTitle, u.Role, passwordHash)
}

// UpdateProfile saves the fields users may change about themselves.
func (s *store) UpdateProfile(ctx context.Context, id int64, name, email, jobTitle string) (*User, error) {
	return s.one(ctx, `
		UPDATE users SET name = $2, email = $3, job_title = $4, updated_at = now()
		WHERE id = $1
		RETURNING `+userColumns,
		id, name, email, jobTitle)
}

func (s *store) SetPassword(ctx context.Context, id int64, passwordHash string) error {
	_, err := s.pool.Exec(ctx, `UPDATE users SET password_hash = $2, updated_at = now() WHERE id = $1`, id, passwordHash)
	return err
}

func (s *store) SetActive(ctx context.Context, id int64, active bool) (*User, error) {
	return s.one(ctx, `UPDATE users SET active = $2, updated_at = now() WHERE id = $1 RETURNING `+userColumns, id, active)
}

// DeleteUser also deletes the user's sessions (ON DELETE CASCADE).
func (s *store) DeleteUser(ctx context.Context, id int64) error {
	tag, err := s.pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, id)
	if err == nil && tag.RowsAffected() == 0 {
		return errNotFound
	}
	return err
}

func (s *store) TouchLogin(ctx context.Context, id int64) error {
	_, err := s.pool.Exec(ctx, `UPDATE users SET last_login_at = now() WHERE id = $1`, id)
	return err
}

func (s *store) CreateSession(ctx context.Context, tokenHash []byte, userID int64, expires time.Time) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, $3)`,
		tokenHash, userID, expires)
	return err
}

// SessionUser returns the user behind a session, as long as the session
// hasn't expired and the account is still active.
func (s *store) SessionUser(ctx context.Context, tokenHash []byte) (*User, error) {
	return s.one(ctx, `
		SELECT `+userColumns+` FROM users
		WHERE active AND id = (SELECT user_id FROM sessions WHERE token_hash = $1 AND expires_at > now())`,
		tokenHash)
}

func (s *store) DeleteSession(ctx context.Context, tokenHash []byte) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, tokenHash)
	return err
}

// DeleteSessions signs a user out everywhere, except for the session
// `keep` (nil keeps none).
func (s *store) DeleteSessions(ctx context.Context, userID int64, keep []byte) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM sessions WHERE user_id = $1 AND token_hash IS DISTINCT FROM $2`, userID, keep)
	return err
}

func (s *store) DeleteExpiredSessions(ctx context.Context) (int64, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM sessions WHERE expires_at <= now()`)
	return tag.RowsAffected(), err
}
