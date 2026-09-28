package main

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"fmt"
	"html/template"
	"io/fs"
	"net/http"
	"path"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Templates and static files are compiled into the binary, so the image is
// a single file.
//
//go:embed templates static
var embedded embed.FS

// view is what every page template gets.
type view struct {
	Title  string
	Nav    string // highlights the sidebar item
	User   *User  // the signed-in user; nil on the sign-in and sign-up pages
	Host   string // the container that rendered the page
	Signup bool   // whether sign-in offers "create an account"
	Data   any    // the page's own data
}

type views struct {
	base   *template.Template            // layouts and partials: htmx fragments render from here
	pages  map[string]*template.Template // one per page: base plus that page
	files  fs.FS                         // static/
	hashes map[string]string             // static file -> short content hash, for cache busting
}

func newViews() (*views, error) {
	static, err := fs.Sub(embedded, "static")
	if err != nil {
		return nil, err
	}
	v := &views{pages: map[string]*template.Template{}, files: static, hashes: map[string]string{}}
	err = fs.WalkDir(static, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := fs.ReadFile(static, name)
		sum := sha256.Sum256(b)
		v.hashes[name] = hex.EncodeToString(sum[:5])
		return err
	})
	if err != nil {
		return nil, err
	}

	funcs := template.FuncMap{
		"asset":     v.assetURL,
		"icon":      icon,
		"initials":  initials,
		"firstName": firstName,
		"date":      func(t time.Time) string { return t.Format("Jan 2, 2006") },
		"ago":       ago,
	}
	v.base, err = template.New("").Funcs(funcs).ParseFS(embedded, "templates/layout.html", "templates/partials/*.html")
	if err != nil {
		return nil, err
	}
	pages, err := fs.Glob(embedded, "templates/pages/*.html")
	if err != nil {
		return nil, err
	}
	for _, file := range pages {
		t, err := v.base.Clone()
		if err != nil {
			return nil, err
		}
		if v.pages[path.Base(file)], err = t.ParseFS(embedded, file); err != nil {
			return nil, err
		}
	}
	return v, nil
}

// render writes a full page, filling in what every page needs.
func (a *app) render(w http.ResponseWriter, r *http.Request, status int, page string, v view) {
	v.User, v.Host, v.Signup = currentUser(r), a.host, a.allowSignup
	a.write(w, status, a.views.pages[page], page, v)
}

// fragment writes one named template, like a table row for htmx to swap in.
func (a *app) fragment(w http.ResponseWriter, status int, name string, data any) {
	a.write(w, status, a.views.base, name, data)
}

func (a *app) write(w http.ResponseWriter, status int, t *template.Template, name string, data any) {
	// Render into a buffer first: a template error then becomes a clean
	// 500 instead of half a page.
	var buf bytes.Buffer
	err := fmt.Errorf("no template %q", name)
	if t != nil {
		err = t.ExecuteTemplate(&buf, name, data)
	}
	if err != nil {
		a.log.Error("render", "template", name, "err", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	// Pages show account data: keep them out of caches, including the
	// back/forward cache after signing out.
	h.Set("Cache-Control", "no-store")
	h.Set("Vary", "HX-Request")
	w.WriteHeader(status)
	buf.WriteTo(w)
}

// assetURL links a static file with a hash of its content, so a changed
// file gets a new URL and browsers can cache each version forever.
func (v *views) assetURL(name string) string {
	return "/static/" + name + "?v=" + v.hashes[name]
}

func (v *views) static() http.Handler {
	files := http.StripPrefix("/static/", http.FileServerFS(v.files))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/") {
			http.NotFound(w, r) // no directory listings
			return
		}
		if r.URL.Query().Get("v") != "" {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		}
		files.ServeHTTP(w, r)
	})
}

// initials turns "Ada Lovelace" into "AL", for avatars.
func initials(name string) string {
	words := strings.Fields(name)
	var out []rune
	for i, word := range words {
		if i == 0 || i == len(words)-1 {
			r, _ := utf8.DecodeRuneInString(word)
			out = append(out, unicode.ToUpper(r))
		}
	}
	if len(out) == 0 {
		return "?"
	}
	return string(out)
}

func firstName(name string) string {
	if words := strings.Fields(name); len(words) > 0 {
		return words[0]
	}
	return name
}

// ago formats a moment relative to now, like "5 minutes ago".
func ago(t *time.Time) string {
	if t == nil {
		return "Never"
	}
	d := time.Since(*t)
	switch {
	case d < time.Minute:
		return "Just now"
	case d < time.Hour:
		return plural(int(d.Minutes()), "minute") + " ago"
	case d < 24*time.Hour:
		return plural(int(d.Hours()), "hour") + " ago"
	case d < 30*24*time.Hour:
		return plural(int(d.Hours()/24), "day") + " ago"
	}
	return t.Format("Jan 2, 2006")
}

func plural(n int, unit string) string {
	if n == 1 {
		return "1 " + unit
	}
	return strconv.Itoa(n) + " " + unit + "s"
}
