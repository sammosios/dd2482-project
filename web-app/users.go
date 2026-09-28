package main

import (
	"errors"
	"net/http"
	"net/mail"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// userForm backs the create/edit dialog on the users page, the sign-up
// page and the profile form.
type userForm struct {
	ID       int64 // 0 while creating
	Name     string
	Email    string
	JobTitle string
	Role     Role
	Password string
	Confirm  string
	Self     bool // an admin editing their own account: role and password are locked
	Errors   map[string]string
}

func formFromRequest(r *http.Request) userForm {
	return userForm{
		Name:     strings.TrimSpace(r.PostFormValue("name")),
		Email:    normalizeEmail(r.PostFormValue("email")),
		JobTitle: strings.TrimSpace(r.PostFormValue("job_title")),
		Role:     Role(r.PostFormValue("role")),
		Password: r.PostFormValue("password"),
		Confirm:  r.PostFormValue("confirm"),
		Errors:   map[string]string{},
	}
}

// validate records a message per invalid field. Passwords are required
// when creating an account; otherwise an empty one means "keep it".
func (f *userForm) validate(passwordRequired bool) {
	if f.Errors == nil {
		f.Errors = map[string]string{}
	}
	switch n := utf8.RuneCountInString(f.Name); {
	case n == 0:
		f.Errors["name"] = "Enter a name."
	case n > 100:
		f.Errors["name"] = "Keep the name under 100 characters."
	}
	if !validEmail(f.Email) {
		f.Errors["email"] = "Enter a valid email address."
	}
	if utf8.RuneCountInString(f.JobTitle) > 100 {
		f.Errors["job_title"] = "Keep the job title under 100 characters."
	}
	if f.Role != RoleAdmin && f.Role != RoleMember {
		f.Errors["role"] = "Pick a role."
	}
	if passwordRequired || f.Password != "" {
		if problem := passwordProblem(f.Password); problem != "" {
			f.Errors["password"] = problem
		}
	}
}

func normalizeEmail(s string) string { return strings.ToLower(strings.TrimSpace(s)) }

func validEmail(s string) bool {
	addr, err := mail.ParseAddress(s)
	return err == nil && addr.Address == s && len(s) <= 254
}

// passwordProblem says what's wrong with a new password, or returns "".
func passwordProblem(password string) string {
	switch {
	case utf8.RuneCountInString(password) < 8:
		return "Use at least 8 characters."
	case len(password) > 72: // bcrypt's limit
		return "That's too long: use at most 72 bytes."
	}
	return ""
}

type usersPage struct {
	Filter userFilter
	Table  usersTable
}

type usersTable struct {
	Rows     []userRow
	Filtered bool // for the empty state: "no matches" vs. "no users"
}

type userRow struct {
	User
	Self bool // the admin looking at the page: they can't disable or delete themselves
}

func (a *app) usersTable(r *http.Request, users []User, f userFilter) usersTable {
	me := currentUser(r)
	rows := make([]userRow, len(users))
	for i, u := range users {
		rows[i] = userRow{User: u, Self: u.ID == me.ID}
	}
	return usersTable{Rows: rows, Filtered: f != userFilter{}}
}

func (a *app) listUsers(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	f := userFilter{
		Query:  strings.TrimSpace(q.Get("q")),
		Role:   oneOf(q.Get("role"), "admin", "member"),
		Status: oneOf(q.Get("status"), "active", "disabled"),
	}
	users, err := a.db.ListUsers(r.Context(), f)
	if err != nil {
		a.serverError(w, r, err)
		return
	}
	table := a.usersTable(r, users, f)

	// Searching and the refresh after a change only replace the table.
	if isHTMX(r) && r.Header.Get("HX-Target") == "users-table" {
		a.fragment(w, http.StatusOK, "users-table", table)
		return
	}
	a.render(w, r, http.StatusOK, "users.html", view{Title: "Users", Nav: "users", Data: usersPage{Filter: f, Table: table}})
}

func oneOf(value string, allowed ...string) string {
	if slices.Contains(allowed, value) {
		return value
	}
	return ""
}

func (a *app) newUserForm(w http.ResponseWriter, r *http.Request) {
	a.fragment(w, http.StatusOK, "user-form", userForm{Role: RoleMember})
}

func (a *app) createUser(w http.ResponseWriter, r *http.Request) {
	f := formFromRequest(r)
	f.validate(true)
	if len(f.Errors) == 0 {
		hash, err := hashPassword(f.Password)
		if err != nil {
			a.serverError(w, r, err)
			return
		}
		_, err = a.db.CreateUser(r.Context(), User{Email: f.Email, Name: f.Name, JobTitle: f.JobTitle, Role: f.Role, PasswordHash: hash})
		switch {
		case errors.Is(err, errEmailTaken):
			f.Errors["email"] = "Another account already uses this email."
		case err != nil:
			a.serverError(w, r, err)
			return
		}
	}
	if len(f.Errors) > 0 {
		// 422: htmx swaps the form back into the dialog, errors and all.
		f.Password = ""
		a.fragment(w, http.StatusUnprocessableEntity, "user-form", f)
		return
	}
	trigger(w, map[string]any{"closeModal": true, "usersChanged": true, "toast": f.Name + " was added."})
	w.WriteHeader(http.StatusNoContent)
}

// targetUser loads the user in the URL's {id}. When it returns false, it
// has already answered the request.
func (a *app) targetUser(w http.ResponseWriter, r *http.Request) (*User, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "There's no such user.")
		return nil, false
	}
	u, err := a.db.UserByID(r.Context(), id)
	switch {
	case errors.Is(err, errNotFound):
		a.fail(w, r, http.StatusNotFound, "That user doesn't exist anymore.")
		return nil, false
	case err != nil:
		a.serverError(w, r, err)
		return nil, false
	}
	return u, true
}

func (a *app) editUserForm(w http.ResponseWriter, r *http.Request) {
	u, ok := a.targetUser(w, r)
	if !ok {
		return
	}
	a.fragment(w, http.StatusOK, "user-form", userForm{
		ID: u.ID, Name: u.Name, Email: u.Email, JobTitle: u.JobTitle, Role: u.Role,
		Self: u.ID == currentUser(r).ID,
	})
}

func (a *app) updateUser(w http.ResponseWriter, r *http.Request) {
	u, ok := a.targetUser(w, r)
	if !ok {
		return
	}
	f := formFromRequest(r)
	f.ID, f.Self = u.ID, u.ID == currentUser(r).ID
	if f.Self {
		// Admins can't demote themselves, so there's always an admin left.
		// Their own password is changed on the profile page, which asks
		// for the current one.
		f.Role, f.Password = u.Role, ""
	}
	f.validate(false)

	if len(f.Errors) == 0 {
		hash := ""
		if f.Password != "" {
			var err error
			if hash, err = hashPassword(f.Password); err != nil {
				a.serverError(w, r, err)
				return
			}
		}
		u.Name, u.Email, u.JobTitle, u.Role = f.Name, f.Email, f.JobTitle, f.Role
		_, err := a.db.UpdateUser(r.Context(), *u, hash)
		switch {
		case errors.Is(err, errEmailTaken):
			f.Errors["email"] = "Another account already uses this email."
		case err != nil:
			a.serverError(w, r, err)
			return
		case hash != "":
			// A password reset signs them out everywhere.
			if err := a.db.DeleteSessions(r.Context(), u.ID, nil); err != nil {
				a.serverError(w, r, err)
				return
			}
		}
	}
	if len(f.Errors) > 0 {
		f.Password = ""
		a.fragment(w, http.StatusUnprocessableEntity, "user-form", f)
		return
	}
	trigger(w, map[string]any{"closeModal": true, "usersChanged": true, "toast": "Saved changes to " + f.Name + "."})
	w.WriteHeader(http.StatusNoContent)
}

// setActive enables or disables an account and answers with the updated
// table row, which htmx swaps in place of the old one.
func (a *app) setActive(active bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, ok := a.targetUser(w, r)
		if !ok {
			return
		}
		if u.ID == currentUser(r).ID {
			a.fail(w, r, http.StatusForbidden, "You can't disable your own account.")
			return
		}
		u, err := a.db.SetActive(r.Context(), u.ID, active)
		if err != nil {
			a.serverError(w, r, err)
			return
		}
		msg := u.Name + " can sign in again."
		if !active {
			// Disabled accounts can't use their sessions anyway (see
			// SessionUser), but deleting them means re-enabling the
			// account doesn't bring old sign-ins back.
			if err := a.db.DeleteSessions(r.Context(), u.ID, nil); err != nil {
				a.serverError(w, r, err)
				return
			}
			msg = u.Name + " was disabled and signed out."
		}
		trigger(w, map[string]any{"toast": msg})
		a.fragment(w, http.StatusOK, "user-row", userRow{User: *u})
	}
}

func (a *app) deleteUser(w http.ResponseWriter, r *http.Request) {
	u, ok := a.targetUser(w, r)
	if !ok {
		return
	}
	if u.ID == currentUser(r).ID {
		a.fail(w, r, http.StatusForbidden, "You can't delete your own account.")
		return
	}
	if err := a.db.DeleteUser(r.Context(), u.ID); err != nil && !errors.Is(err, errNotFound) {
		a.serverError(w, r, err)
		return
	}
	trigger(w, map[string]any{"usersChanged": true, "toast": u.Name + " was deleted."})
	w.WriteHeader(http.StatusNoContent)
}
