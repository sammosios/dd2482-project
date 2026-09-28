package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestValidateUserForm(t *testing.T) {
	valid := userForm{Name: "Ada Lovelace", Email: "ada@example.com", Role: RoleMember, Password: "correct horse"}
	tests := []struct {
		name             string
		edit             func(*userForm)
		passwordRequired bool
		wantErrors       []string
	}{
		{"valid", func(f *userForm) {}, true, nil},
		{"no name", func(f *userForm) { f.Name = "" }, true, []string{"name"}},
		{"long name", func(f *userForm) { f.Name = strings.Repeat("a", 101) }, true, []string{"name"}},
		{"bad email", func(f *userForm) { f.Email = "ada" }, true, []string{"email"}},
		{"email with a display name", func(f *userForm) { f.Email = "Ada <ada@example.com>" }, true, []string{"email"}},
		{"unknown role", func(f *userForm) { f.Role = "owner" }, true, []string{"role"}},
		{"short password", func(f *userForm) { f.Password = "short" }, true, []string{"password"}},
		{"password over 72 bytes", func(f *userForm) { f.Password = strings.Repeat("é", 40) }, true, []string{"password"}},
		{"empty password on create", func(f *userForm) { f.Password = "" }, true, []string{"password"}},
		{"empty password on edit keeps it", func(f *userForm) { f.Password = "" }, false, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := valid
			tt.edit(&f)
			f.validate(tt.passwordRequired)
			if len(f.Errors) != len(tt.wantErrors) {
				t.Fatalf("errors = %v, want errors for %v", f.Errors, tt.wantErrors)
			}
			for _, field := range tt.wantErrors {
				if f.Errors[field] == "" {
					t.Errorf("no error for %q: %v", field, f.Errors)
				}
			}
		})
	}
}

func TestHelpers(t *testing.T) {
	for in, want := range map[string]string{"Ada Lovelace": "AL", "grace": "G", "Jean Claude Van Damme": "JD", "  ": "?", "Ζωή Παππά": "ΖΠ"} {
		if got := initials(in); got != want {
			t.Errorf("initials(%q) = %q, want %q", in, got, want)
		}
	}
	if got, want := likePattern(`50%_off\`), `%50\%\_off\\%`; got != want {
		t.Errorf("likePattern = %q, want %q", got, want)
	}
	in := `{"toast":"Zoë Παππά 🚀"}`
	out := asciiJSON([]byte(in))
	var decoded map[string]string
	if err := json.Unmarshal([]byte(out), &decoded); err != nil || decoded["toast"] != "Zoë Παππά 🚀" {
		t.Errorf("asciiJSON(%s) = %s, which doesn't decode back (%v)", in, out, err)
	}
	for _, r := range out {
		if r >= utf8.RuneSelf {
			t.Errorf("asciiJSON left %q in %s", r, out)
		}
	}
	if got := normalizeEmail("  Ada@Example.COM "); got != "ada@example.com" {
		t.Errorf("normalizeEmail = %q", got)
	}
}

// TestTemplates renders every page and fragment with sample data, which
// catches template mistakes without needing a database.
func TestTemplates(t *testing.T) {
	v, err := newViews()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	admin := &User{ID: 1, Name: "Ada Admin", Email: "ada@example.com", Role: RoleAdmin, Active: true, CreatedAt: now, LastLoginAt: &now}
	member := &User{ID: 2, Name: "Bob Member", Email: "bob@example.com", JobTitle: "Engineer", Role: RoleMember, CreatedAt: now}
	rows := []userRow{{User: *admin, Self: true}, {User: *member}}
	errs := map[string]string{"name": "Enter a name.", "email": "Taken.", "password": "Too short.", "confirm": "No match.", "current": "Wrong."}

	pages := []struct {
		page string
		view view
		want string
	}{
		{"overview.html", view{Title: "Overview", User: admin, Data: overviewPage{Stats: userStats{2, 1, 1, 1}, Recent: []User{*admin, *member}}}, "Recently added"},
		{"overview.html", view{Title: "Overview", User: member, Data: overviewPage{}}, "Member since"},
		{"users.html", view{Title: "Users", User: admin, Data: usersPage{Table: usersTable{Rows: rows}}}, `hx-post="/users/2/enable"`},
		{"users.html", view{Title: "Users", User: admin, Data: usersPage{Filter: userFilter{Query: "zed"}, Table: usersTable{Filtered: true}}}, "No users match"},
		{"profile.html", view{Title: "Profile", User: member, Data: profilePage{Profile: profileForm(member)}}, "Change password"},
		{"login.html", view{Title: "Sign in", Signup: true, Data: loginForm{Email: "a@b.c", Error: "Invalid email or password."}}, "Create an account"},
		{"signup.html", view{Title: "Create an account", Data: userForm{Errors: errs}}, "Taken."},
		{"error.html", view{Title: "Not Found", Data: errorPage{Status: 404, Message: "Nothing here."}}, "Error 404"},
	}
	for _, p := range pages {
		var buf bytes.Buffer
		if err := v.pages[p.page].ExecuteTemplate(&buf, p.page, p.view); err != nil {
			t.Errorf("%s: %v", p.page, err)
		} else if !strings.Contains(buf.String(), p.want) {
			t.Errorf("%s: output doesn't contain %q", p.page, p.want)
		}
	}

	fragments := []struct {
		name string
		data any
		want string
	}{
		{"users-table", usersTable{Rows: rows}, "(you)"},
		{"user-row", userRow{User: *member}, "Disabled"},
		{"user-form", userForm{Role: RoleMember, Errors: errs}, `hx-post="/users"`},
		{"user-form", userForm{ID: 1, Role: RoleAdmin, Self: true}, "change your own role"},
		{"profile-form", profileForm(member), `hx-put="/profile"`},
		{"profile-saved", profileSaved{Form: profileForm(member), User: member}, `hx-swap-oob="innerHTML:#sidebar-user"`},
		{"password-form", passwordForm{Errors: errs}, "Wrong."},
	}
	for _, f := range fragments {
		var buf bytes.Buffer
		if err := v.base.ExecuteTemplate(&buf, f.name, f.data); err != nil {
			t.Errorf("%s: %v", f.name, err)
		} else if !strings.Contains(buf.String(), f.want) {
			t.Errorf("%s: output doesn't contain %q", f.name, f.want)
		}
	}
}
