package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

type app struct {
	db          *store
	limiter     *loginLimiter // nil when REDIS_URL isn't set
	views       *views
	log         *slog.Logger
	host        string // the container's hostname, shown in the header: which replica answered
	allowSignup bool
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()

	mux.Handle("GET /static/", a.views.static())
	mux.HandleFunc("GET /healthz", a.healthz)
	mux.HandleFunc("GET /readyz", a.readyz)

	mux.HandleFunc("GET /login", a.loginPage)
	mux.HandleFunc("POST /login", a.login)
	mux.HandleFunc("GET /signup", a.signupPage)
	mux.HandleFunc("POST /signup", a.signup)
	mux.HandleFunc("POST /logout", a.logout)

	// Every signed-in user: the overview and their own profile.
	mux.Handle("GET /{$}", a.signedIn(a.overview))
	mux.Handle("GET /profile", a.signedIn(a.profilePage))
	mux.Handle("PUT /profile", a.signedIn(a.updateProfile))
	mux.Handle("PUT /profile/password", a.signedIn(a.changePassword))

	// Admins only. Most of these answer htmx requests with HTML fragments.
	mux.Handle("GET /users", a.adminOnly(a.listUsers))
	mux.Handle("GET /users/new", a.adminOnly(a.newUserForm))
	mux.Handle("POST /users", a.adminOnly(a.createUser))
	mux.Handle("GET /users/{id}/edit", a.adminOnly(a.editUserForm))
	mux.Handle("PUT /users/{id}", a.adminOnly(a.updateUser))
	mux.Handle("POST /users/{id}/enable", a.adminOnly(a.setActive(true)))
	mux.Handle("POST /users/{id}/disable", a.adminOnly(a.setActive(false)))
	mux.Handle("DELETE /users/{id}", a.adminOnly(a.deleteUser))

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		a.fail(w, r, http.StatusNotFound, "There's nothing at this address.")
	})

	// Rejects cross-site POST/PUT/DELETE requests based on the browser's
	// Sec-Fetch-Site and Origin headers: CSRF protection without tokens.
	csrf := http.NewCrossOriginProtection()
	return a.logRequests(secureHeaders(csrf.Handler(mux)))
}

// healthz is the liveness check behind the image's HEALTHCHECK. It leaves
// the database out on purpose: if Postgres is down, restarting every
// replica won't bring it back.
func (a *app) healthz(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "ok")
}

// readyz also checks the database, for humans and monitoring.
func (a *app) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := a.db.pool.Ping(ctx); err != nil {
		http.Error(w, "database unreachable", http.StatusServiceUnavailable)
		return
	}
	fmt.Fprintln(w, "ok")
}

type ctxKey struct{}

// currentUser is the signed-in user, set by signedIn.
func currentUser(r *http.Request) *User {
	u, _ := r.Context().Value(ctxKey{}).(*User)
	return u
}

// signedIn lets a request through only with a valid session. The user is
// loaded fresh on every request, so disabling an account or changing its
// role takes effect immediately.
func (a *app) signedIn(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, err := a.sessionUser(r)
		if err != nil {
			a.serverError(w, r, err)
			return
		}
		if u == nil {
			if isHTMX(r) {
				// A 303 would be followed by the XHR and the login page
				// swapped into the table; HX-Redirect navigates instead.
				w.Header().Set("HX-Redirect", "/login")
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, u)))
	})
}

func (a *app) adminOnly(next http.HandlerFunc) http.Handler {
	return a.signedIn(func(w http.ResponseWriter, r *http.Request) {
		if !currentUser(r).IsAdmin() {
			a.fail(w, r, http.StatusForbidden, "Only admins can manage users.")
			return
		}
		next(w, r)
	})
}

func secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		// Only our own scripts and styles: no inline JS or CSS anywhere.
		h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func (a *app) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Docker probes /healthz every few seconds: not worth a log line.
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		a.log.Info("request", "method", r.Method, "path", r.URL.Path, "status", rec.status,
			"duration", time.Since(start).Round(time.Microsecond), "htmx", isHTMX(r))
	})
}

func isHTMX(r *http.Request) bool { return r.Header.Get("HX-Request") == "true" }

// fail answers with an error: plain text for htmx requests (app.js shows it
// in a toast), a full error page otherwise.
func (a *app) fail(w http.ResponseWriter, r *http.Request, status int, msg string) {
	if isHTMX(r) {
		http.Error(w, msg, status)
		return
	}
	a.render(w, r, status, "error.html", view{Title: http.StatusText(status), Data: errorPage{Status: status, Message: msg}})
}

func (a *app) serverError(w http.ResponseWriter, r *http.Request, err error) {
	a.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
	a.fail(w, r, http.StatusInternalServerError, "Something went wrong on our side. Try again in a moment.")
}

type errorPage struct {
	Status  int
	Message string
}

// trigger makes htmx fire these events in the browser when the response
// arrives (the HX-Trigger header). "toast" shows a notification; the users
// page listens for "usersChanged" and "closeModal".
func trigger(w http.ResponseWriter, events map[string]any) {
	b, err := json.Marshal(events)
	if err != nil {
		return
	}
	w.Header().Set("HX-Trigger", asciiJSON(b))
}

// asciiJSON escapes non-ASCII characters as \uXXXX. Browsers read header
// values as Latin-1, so a toast about "Zoë" sent as raw UTF-8 would arrive
// garbled.
func asciiJSON(b []byte) string {
	var sb strings.Builder
	for _, r := range string(b) {
		switch {
		case r < utf8.RuneSelf:
			sb.WriteRune(r)
		case r > 0xFFFF:
			hi, lo := utf16.EncodeRune(r)
			fmt.Fprintf(&sb, `\u%04x\u%04x`, hi, lo)
		default:
			fmt.Fprintf(&sb, `\u%04x`, r)
		}
	}
	return sb.String()
}
