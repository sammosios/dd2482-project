package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"net/http"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	sessionCookie = "roster_session"
	sessionTTL    = 7 * 24 * time.Hour
)

func hashPassword(password string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	return string(hash), err
}

func checkPassword(hash, password string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

// dummyHash is checked against when nobody has the email that was entered,
// so a failed sign-in takes as long for unknown emails as for known ones
// and response times don't reveal who has an account.
var dummyHash = sync.OnceValue(func() string {
	hash, _ := hashPassword("not the password")
	return hash
})

// The session cookie holds a random token; the database only stores its
// SHA-256 hash.
func hashToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

func (a *app) startSession(w http.ResponseWriter, r *http.Request, userID int64) error {
	token := rand.Text()
	expires := time.Now().Add(sessionTTL)
	if err := a.db.CreateSession(r.Context(), hashToken(token), userID, expires); err != nil {
		return err
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    token,
		Path:     "/",
		Expires:  expires,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		// Behind Traefik, HTTPS ends at the proxy, which says so in
		// X-Forwarded-Proto. Over plain HTTP a Secure cookie would never
		// come back, so only set it when the browser actually used HTTPS.
		Secure: r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https",
	})
	return nil
}

// sessionUser returns the signed-in user, or nil if there's none.
func (a *app) sessionUser(r *http.Request) (*User, error) {
	hash := sessionHash(r)
	if hash == nil {
		return nil, nil
	}
	u, err := a.db.SessionUser(r.Context(), hash)
	if errors.Is(err, errNotFound) {
		return nil, nil
	}
	return u, err
}

// sessionHash identifies the session of this request (nil without one).
func sessionHash(r *http.Request) []byte {
	c, err := r.Cookie(sessionCookie)
	if err != nil || c.Value == "" {
		return nil
	}
	return hashToken(c.Value)
}

// cleanupSessions deletes expired sessions every hour. Each replica does
// it; that's harmless.
func (a *app) cleanupSessions(ctx context.Context) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			n, err := a.db.DeleteExpiredSessions(ctx)
			if err != nil {
				a.log.Warn("clean up sessions", "err", err)
			} else if n > 0 {
				a.log.Info("deleted expired sessions", "count", n)
			}
		}
	}
}

type loginForm struct {
	Email string
	Error string
}

func (a *app) loginPage(w http.ResponseWriter, r *http.Request) {
	if u, _ := a.sessionUser(r); u != nil {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	a.render(w, r, http.StatusOK, "login.html", view{Title: "Sign in", Data: loginForm{}})
}

func (a *app) login(w http.ResponseWriter, r *http.Request) {
	form := loginForm{Email: normalizeEmail(r.PostFormValue("email"))}
	password := r.PostFormValue("password")

	u, err := a.db.UserByEmail(r.Context(), form.Email)
	if err != nil && !errors.Is(err, errNotFound) {
		a.serverError(w, r, err)
		return
	}
	switch {
	case u == nil:
		checkPassword(dummyHash(), password)
		form.Error = "Invalid email or password."
	case !checkPassword(u.PasswordHash, password):
		form.Error = "Invalid email or password."
	case !u.Active:
		// Only said after a correct password, so it doesn't reveal which
		// accounts exist.
		form.Error = "This account is disabled. Ask an admin to enable it again."
	}
	if form.Error != "" {
		a.render(w, r, http.StatusUnprocessableEntity, "login.html", view{Title: "Sign in", Data: form})
		return
	}

	if err := a.startSession(w, r, u.ID); err != nil {
		a.serverError(w, r, err)
		return
	}
	if err := a.db.TouchLogin(r.Context(), u.ID); err != nil {
		a.log.Warn("record sign-in time", "err", err)
	}
	a.log.Info("signed in", "user", u.ID, "role", u.Role)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *app) signupPage(w http.ResponseWriter, r *http.Request) {
	if !a.allowSignup {
		a.fail(w, r, http.StatusNotFound, "Sign-up is turned off. Ask an admin to create an account for you.")
		return
	}
	a.render(w, r, http.StatusOK, "signup.html", view{Title: "Create an account", Data: userForm{}})
}

// signup creates a member account and signs it in.
func (a *app) signup(w http.ResponseWriter, r *http.Request) {
	if !a.allowSignup {
		a.fail(w, r, http.StatusNotFound, "Sign-up is turned off. Ask an admin to create an account for you.")
		return
	}
	f := formFromRequest(r)
	f.Role = RoleMember
	f.validate(true)
	if f.Password != f.Confirm && f.Errors["password"] == "" {
		f.Errors["confirm"] = "The passwords don't match."
	}

	var u *User
	if len(f.Errors) == 0 {
		hash, err := hashPassword(f.Password)
		if err != nil {
			a.serverError(w, r, err)
			return
		}
		u, err = a.db.CreateUser(r.Context(), User{Email: f.Email, Name: f.Name, JobTitle: f.JobTitle, Role: RoleMember, PasswordHash: hash})
		switch {
		case errors.Is(err, errEmailTaken):
			f.Errors["email"] = "There's already an account with this email."
		case err != nil:
			a.serverError(w, r, err)
			return
		}
	}
	if len(f.Errors) > 0 {
		f.Password, f.Confirm = "", ""
		a.render(w, r, http.StatusUnprocessableEntity, "signup.html", view{Title: "Create an account", Data: f})
		return
	}

	if err := a.startSession(w, r, u.ID); err != nil {
		a.serverError(w, r, err)
		return
	}
	if err := a.db.TouchLogin(r.Context(), u.ID); err != nil {
		a.log.Warn("record sign-in time", "err", err)
	}
	a.log.Info("signed up", "user", u.ID)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *app) logout(w http.ResponseWriter, r *http.Request) {
	if hash := sessionHash(r); hash != nil {
		if err := a.db.DeleteSession(r.Context(), hash); err != nil {
			a.log.Warn("delete session", "err", err)
		}
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}
