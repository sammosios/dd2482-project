package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestEndToEnd drives the real handlers against a real Postgres. It only
// runs when TEST_DATABASE_URL is set (in URL form), e.g.
//
//	TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres go test ./...
//
// Everything happens in a throwaway schema that's dropped afterwards.
func TestEndToEnd(t *testing.T) {
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	log := slog.New(slog.DiscardHandler)

	root, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("roster_test_%d", time.Now().UnixNano())
	if _, err := root.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		root.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
		root.Close()
	})
	u, err := url.Parse(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	pool, err := connect(ctx, u.String(), log)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)

	cfg := config{adminEmail: "admin@example.com", adminPassword: "admin-password", adminName: "Ada Admin"}
	for range 2 { // a second replica starting up must change nothing
		if err := prepareDatabase(ctx, pool, cfg, log); err != nil {
			t.Fatal(err)
		}
	}
	v, err := newViews()
	if err != nil {
		t.Fatal(err)
	}
	limiter, mr := newTestLimiter(t)
	srv := httptest.NewServer((&app{db: &store{pool: pool}, limiter: limiter, views: v, log: log, host: "test", allowSignup: true}).routes())
	t.Cleanup(srv.Close)

	userID := func(email string) int64 {
		var id int64
		if err := pool.QueryRow(ctx, `SELECT id FROM users WHERE email = $1`, email).Scan(&id); err != nil {
			t.Fatalf("user %s: %v", email, err)
		}
		return id
	}
	roleOf := func(id int64) (role string) {
		pool.QueryRow(ctx, `SELECT role FROM users WHERE id = $1`, id).Scan(&role)
		return role
	}
	hx := map[string]string{"HX-Request": "true"}
	hxTable := map[string]string{"HX-Request": "true", "HX-Target": "users-table"}

	// Signed out.
	anon := newClient(t, srv.URL)
	anon.expect("GET", "/healthz", nil, nil, 200, "ok")
	anon.expect("GET", "/readyz", nil, nil, 200, "ok")
	if resp := anon.expect("GET", "/", nil, nil, 303, ""); resp.Header.Get("Location") != "/login" {
		t.Fatal("signed-out users should be sent to /login")
	}
	if resp := anon.expect("GET", "/users", nil, hx, 401, ""); resp.Header.Get("HX-Redirect") != "/login" {
		t.Fatal("signed-out htmx requests should get HX-Redirect")
	}
	anon.expect("GET", "/nope", nil, nil, 404, "Error 404")
	if resp := anon.expect("GET", "/static/app.css?v=x", nil, nil, 200, ".panel"); !strings.Contains(resp.Header.Get("Cache-Control"), "immutable") {
		t.Fatal("versioned assets should be cacheable")
	}
	anon.expect("GET", "/static/", nil, nil, 404, "")

	// The seeded admin signs in.
	admin := newClient(t, srv.URL)
	admin.expect("POST", "/login", form("email", "admin@example.com", "password", "wrong-password"), nil, 422, "Invalid email or password.")
	admin.login("Admin@Example.com", "admin-password")
	admin.expect("GET", "/", nil, nil, 200, "Total users")
	adminID := userID("admin@example.com")

	// Create a member, with the checks along the way.
	bobForm := form("name", "Bob Member", "email", " Bob@Example.com ", "role", "member", "password", "bob-password")
	if resp := admin.expect("POST", "/users", bobForm, hx, 204, ""); !strings.Contains(resp.Header.Get("HX-Trigger"), "usersChanged") {
		t.Fatal("creating a user should trigger usersChanged")
	}
	admin.expect("POST", "/users", bobForm, hx, 422, "Another account already uses this email.")
	admin.expect("POST", "/users", form("name", "", "email", "x", "role", "member", "password", "pw"), hx, 422, "Enter a name.")
	bobID := userID("bob@example.com")

	// Search and filters return just the table.
	if _, body := admin.do("GET", "/users?q=bob", nil, hxTable); !strings.Contains(body, "bob@example.com") || strings.Contains(body, "admin@example.com") || strings.Contains(body, "<html") {
		t.Fatalf("search for bob returned:\n%s", body)
	}
	admin.expect("GET", "/users?q=100%25", nil, hxTable, 200, "No users match")
	admin.expect("GET", "/users?status=disabled", nil, hxTable, 200, "No users match")
	admin.expect("GET", "/users?role=member", nil, nil, 200, "<html")

	// Bob signs in: his own things only.
	bob := newClient(t, srv.URL)
	bob.login("bob@example.com", "bob-password")
	bob.expect("GET", "/", nil, nil, 200, "Member since")
	bob.expect("GET", "/users", nil, nil, 403, "Only admins")
	bob.expect("POST", fmt.Sprintf("/users/%d/disable", adminID), nil, hx, 403, "Only admins")
	bob.expect("PUT", "/profile", form("name", "Robert Member", "email", "bob@example.com", "job_title", "Engineer", "role", "admin"), hx, 200, `hx-swap-oob="innerHTML:#sidebar-user"`)
	if roleOf(bobID) != "member" {
		t.Fatal("members must not be able to change their own role")
	}
	bob.expect("PUT", "/profile", form("name", "Robert Member", "email", "admin@example.com"), hx, 422, "Another account already uses this email.")
	bob.expect("PUT", "/profile/password", form("current", "nope", "password", "new-bob-password", "confirm", "new-bob-password"), hx, 422, "not your current password")
	bob.expect("PUT", "/profile/password", form("current", "bob-password", "password", "new-bob-password", "confirm", "new-bob-password"), hx, 200, "Change password")
	bob.expect("GET", "/profile", nil, nil, 200, "Robert Member") // this session survived the change

	// The admin disables Bob: he's signed out and can't sign back in.
	admin.expect("POST", fmt.Sprintf("/users/%d/disable", bobID), nil, hx, 200, "Disabled")
	bob.expect("GET", "/", nil, nil, 303, "")
	bob.expect("POST", "/login", form("email", "bob@example.com", "password", "new-bob-password"), nil, 422, "This account is disabled.")
	admin.expect("POST", fmt.Sprintf("/users/%d/enable", bobID), nil, hx, 200, "Active")
	bob.login("bob@example.com", "new-bob-password")

	// Admins can't lock themselves out.
	admin.expect("POST", fmt.Sprintf("/users/%d/disable", adminID), nil, hx, 403, "your own account")
	admin.expect("DELETE", fmt.Sprintf("/users/%d", adminID), nil, hx, 403, "your own account")
	admin.expect("PUT", fmt.Sprintf("/users/%d", adminID), form("name", "Ada Admin", "email", "admin@example.com", "role", "member"), hx, 204, "")
	if roleOf(adminID) != "admin" {
		t.Fatal("admins must not be able to demote themselves")
	}

	// Edit: promote Bob and reset his password, which signs him out.
	admin.expect("GET", fmt.Sprintf("/users/%d/edit", bobID), nil, hx, 200, "Robert Member")
	admin.expect("PUT", fmt.Sprintf("/users/%d", bobID), form("name", "Robert Member", "email", "bob@example.com", "role", "admin", "password", "reset-password"), hx, 204, "")
	if roleOf(bobID) != "admin" {
		t.Fatal("promotion didn't stick")
	}
	bob.expect("GET", "/", nil, nil, 303, "")

	// Delete.
	admin.expect("DELETE", fmt.Sprintf("/users/%d", bobID), nil, hx, 204, "")
	admin.expect("GET", fmt.Sprintf("/users/%d/edit", bobID), nil, hx, 404, "doesn't exist")

	// Cross-site form posts are refused (CSRF).
	admin.expect("POST", "/users", bobForm, map[string]string{"Sec-Fetch-Site": "cross-site"}, 403, "")

	// Sign-up creates a member and signs them in; logout ends the session.
	carol := newClient(t, srv.URL)
	carol.expect("POST", "/signup", form("name", "Carol", "email", "carol@example.com", "password", "carol-password", "confirm", "different"), nil, 422, "The passwords don&#39;t match.")
	carol.expect("POST", "/signup", form("name", "Carol", "email", "carol@example.com", "password", "carol-password", "confirm", "carol-password"), nil, 303, "")
	carol.expect("GET", "/", nil, nil, 200, "Member since")
	carol.expect("POST", "/logout", nil, nil, 303, "")
	carol.expect("GET", "/", nil, nil, 303, "")

	// Rate limiting: after loginAttempts tries the account is locked, even
	// for the right password, until the window runs out. Unknown emails
	// behave the same, so a lockout doesn't reveal who has an account.
	guesser := newClient(t, srv.URL)
	for _, email := range []string{"admin@example.com", "nobody@example.com"} {
		for range loginAttempts {
			guesser.expect("POST", "/login", form("email", email, "password", "a-wrong-guess"), nil, 422, "Invalid email or password.")
		}
		resp := guesser.expect("POST", "/login", form("email", email, "password", "admin-password"), nil, 429, "Too many sign-in attempts")
		if resp.Header.Get("Retry-After") == "" {
			t.Fatal("a lockout should say when to retry")
		}
	}
	mr.FastForward(loginWindow)
	guesser.login("admin@example.com", "admin-password")
}

func form(pairs ...string) url.Values {
	v := url.Values{}
	for i := 0; i+1 < len(pairs); i += 2 {
		v.Set(pairs[i], pairs[i+1])
	}
	return v
}

// client is a browser stand-in with its own cookies.
type client struct {
	t    *testing.T
	base string
	http *http.Client
}

func newClient(t *testing.T, base string) *client {
	jar, _ := cookiejar.New(nil)
	return &client{t: t, base: base, http: &http.Client{
		Jar: jar,
		// Don't follow redirects: the tests check them.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

func (c *client) do(method, path string, body url.Values, headers map[string]string) (*http.Response, string) {
	c.t.Helper()
	var r io.Reader
	if body != nil {
		r = strings.NewReader(body.Encode())
	}
	req, err := http.NewRequest(method, c.base+path, r)
	if err != nil {
		c.t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		c.t.Fatal(err)
	}
	return resp, string(b)
}

// expect sends a request and checks its status code and that the body
// contains want.
func (c *client) expect(method, path string, body url.Values, headers map[string]string, status int, want string) *http.Response {
	c.t.Helper()
	resp, got := c.do(method, path, body, headers)
	if resp.StatusCode != status {
		c.t.Fatalf("%s %s: status %d, want %d\n%s", method, path, resp.StatusCode, status, got)
	}
	if !strings.Contains(got, want) {
		c.t.Fatalf("%s %s: body doesn't contain %q\n%s", method, path, want, got)
	}
	return resp
}

func (c *client) login(email, password string) {
	c.t.Helper()
	resp := c.expect("POST", "/login", form("email", email, "password", password), nil, http.StatusSeeOther, "")
	if loc := resp.Header.Get("Location"); loc != "/" {
		c.t.Fatalf("sign-in as %s redirected to %q", email, loc)
	}
}
