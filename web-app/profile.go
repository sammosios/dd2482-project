package main

import (
	"errors"
	"net/http"
)

type overviewPage struct {
	Stats  userStats
	Recent []User
}

// overview is everyone's landing page: counts and the newest accounts for
// admins, a summary of their own account for members.
func (a *app) overview(w http.ResponseWriter, r *http.Request) {
	var data overviewPage
	if currentUser(r).IsAdmin() {
		var err error
		if data.Stats, err = a.db.Stats(r.Context()); err != nil {
			a.serverError(w, r, err)
			return
		}
		if data.Recent, err = a.db.RecentUsers(r.Context(), 5); err != nil {
			a.serverError(w, r, err)
			return
		}
	}
	a.render(w, r, http.StatusOK, "overview.html", view{Title: "Overview", Nav: "overview", Data: data})
}

type profilePage struct {
	Profile  userForm
	Password passwordForm
}

type passwordForm struct {
	Errors map[string]string
}

// profileSaved is the response to a profile update: the form, plus the
// sidebar's name and email as an out-of-band swap so they update too.
type profileSaved struct {
	Form userForm
	User *User
}

func profileForm(u *User) userForm {
	return userForm{ID: u.ID, Name: u.Name, Email: u.Email, JobTitle: u.JobTitle, Role: u.Role}
}

func (a *app) profilePage(w http.ResponseWriter, r *http.Request) {
	a.render(w, r, http.StatusOK, "profile.html", view{Title: "Profile", Nav: "profile", Data: profilePage{Profile: profileForm(currentUser(r))}})
}

// updateProfile saves the signed-in user's own details. Role and status
// aren't part of this form: only admins change those.
func (a *app) updateProfile(w http.ResponseWriter, r *http.Request) {
	me := currentUser(r)
	f := formFromRequest(r)
	f.ID, f.Role, f.Password = me.ID, me.Role, ""
	f.validate(false)
	if len(f.Errors) == 0 {
		u, err := a.db.UpdateProfile(r.Context(), me.ID, f.Name, f.Email, f.JobTitle)
		switch {
		case errors.Is(err, errEmailTaken):
			f.Errors["email"] = "Another account already uses this email."
		case err != nil:
			a.serverError(w, r, err)
			return
		default:
			me = u
		}
	}
	if len(f.Errors) > 0 {
		a.fragment(w, http.StatusUnprocessableEntity, "profile-form", f)
		return
	}
	trigger(w, map[string]any{"toast": "Your profile was saved."})
	a.fragment(w, http.StatusOK, "profile-saved", profileSaved{Form: profileForm(me), User: me})
}

func (a *app) changePassword(w http.ResponseWriter, r *http.Request) {
	me := currentUser(r)
	current, password := r.PostFormValue("current"), r.PostFormValue("password")
	f := passwordForm{Errors: map[string]string{}}
	if !checkPassword(me.PasswordHash, current) {
		f.Errors["current"] = "That's not your current password."
	}
	if problem := passwordProblem(password); problem != "" {
		f.Errors["password"] = problem
	} else if password != r.PostFormValue("confirm") {
		f.Errors["confirm"] = "The passwords don't match."
	}
	if len(f.Errors) > 0 {
		a.fragment(w, http.StatusUnprocessableEntity, "password-form", f)
		return
	}

	hash, err := hashPassword(password)
	if err != nil {
		a.serverError(w, r, err)
		return
	}
	if err := a.db.SetPassword(r.Context(), me.ID, hash); err != nil {
		a.serverError(w, r, err)
		return
	}
	// Sign out every other browser, but not this one.
	if err := a.db.DeleteSessions(r.Context(), me.ID, sessionHash(r)); err != nil {
		a.serverError(w, r, err)
		return
	}
	trigger(w, map[string]any{"toast": "Password changed. Your other sessions were signed out."})
	a.fragment(w, http.StatusOK, "password-form", passwordForm{})
}
