package main

import (
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
)

// newTestLimiter returns a limiter backed by an in-memory Redis, which the
// test can fast-forward instead of waiting out the window.
func newTestLimiter(t *testing.T) (*loginLimiter, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	l, err := newLoginLimiter(context.Background(), "redis://"+mr.Addr(), slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(l.close)
	return l, mr
}

func TestLoginLimiter(t *testing.T) {
	l, mr := newTestLimiter(t)
	ctx := context.Background()

	for i := 1; i <= loginAttempts; i++ {
		if ok, _ := l.allow(ctx, "ada@example.com"); !ok {
			t.Fatalf("attempt %d was refused", i)
		}
	}
	ok, wait := l.allow(ctx, "ada@example.com")
	if ok || wait <= 0 || wait > loginWindow {
		t.Fatalf("attempt %d: allowed=%v wait=%v, want a lockout within the window", loginAttempts+1, ok, wait)
	}
	if ok, _ := l.allow(ctx, "bob@example.com"); !ok {
		t.Fatal("another account was locked too")
	}

	// The lock lifts when the window runs out...
	mr.FastForward(loginWindow)
	if ok, _ := l.allow(ctx, "ada@example.com"); !ok {
		t.Fatal("still locked after the window")
	}
	// ...and a successful sign-in resets the count.
	l.reset(ctx, "ada@example.com")
	for i := 1; i <= loginAttempts; i++ {
		if ok, _ := l.allow(ctx, "ada@example.com"); !ok {
			t.Fatalf("attempt %d after a reset was refused", i)
		}
	}

	// Redis holds hashes, not email addresses.
	for _, key := range mr.Keys() {
		if strings.Contains(key, "example.com") {
			t.Errorf("key %q contains an email address", key)
		}
	}
}

func TestLoginLimiterFailsOpen(t *testing.T) {
	ctx := context.Background()

	var off *loginLimiter // REDIS_URL not set
	if ok, _ := off.allow(ctx, "ada@example.com"); !ok {
		t.Fatal("a disabled limiter refused a sign-in")
	}
	off.reset(ctx, "ada@example.com")

	l, mr := newTestLimiter(t)
	mr.Close()
	start := time.Now()
	if ok, _ := l.allow(ctx, "ada@example.com"); !ok {
		t.Fatal("refused a sign-in while Redis was down")
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Errorf("an unreachable Redis held the sign-in up for %v", took)
	}
}

func TestLockedMessage(t *testing.T) {
	for wait, want := range map[time.Duration]string{
		10 * time.Second:               "in a minute.",
		61 * time.Second:               "in 2 minutes.",
		loginWindow - time.Second:      "in 15 minutes.",
		loginWindow / 2:                "in 8 minutes.",
		time.Minute + time.Millisecond: "in 2 minutes.",
		time.Minute:                    "in a minute.",
	} {
		if got := lockedMessage(wait); !strings.HasSuffix(got, want) {
			t.Errorf("lockedMessage(%v) = %q, want it to end in %q", wait, got, want)
		}
	}
}
