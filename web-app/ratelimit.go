package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"time"

	"github.com/redis/go-redis/v9"
)

// Sign-in attempts allowed per account per window. The window starts at
// the first attempt; after the last allowed one, the account stays locked
// until the window runs out.
const (
	loginAttempts = 5
	loginWindow   = 15 * time.Minute
)

// loginLimiter counts sign-in attempts per email in Redis. Redis rather
// than memory because every replica must see the same count: with a counter
// per replica, the load balancer spreading guesses across replicas would
// multiply the allowance by the number of replicas.
//
// A nil *loginLimiter allows everything: that's rate limiting switched off,
// when REDIS_URL isn't set.
type loginLimiter struct {
	rdb *redis.Client
	log *slog.Logger
}

// newLoginLimiter connects to Redis, or returns nil when url is empty. An
// unreachable Redis isn't an error: the limiter fails open (see allow).
func newLoginLimiter(ctx context.Context, url string, log *slog.Logger) (*loginLimiter, error) {
	if url == "" {
		log.Warn("REDIS_URL is not set: sign-in attempts are not rate limited")
		return nil, nil
	}
	opt, err := redis.ParseURL(url)
	if err != nil {
		// Not wrapping err: its message would include the URL, password and all.
		return nil, errors.New("REDIS_URL is not a valid redis:// URL")
	}
	// Signing in waits for Redis, so give up quickly when it's gone instead
	// of the client's defaults (seconds, and retries on top).
	opt.DialTimeout = time.Second
	opt.DialerRetries = 1
	opt.ReadTimeout = 500 * time.Millisecond
	opt.WriteTimeout = 500 * time.Millisecond
	opt.MaxRetries = 1
	redis.SetLogger(redisLog{log})

	l := &loginLimiter{rdb: redis.NewClient(opt), log: log}
	if err := l.rdb.Ping(ctx).Err(); err != nil {
		log.Warn("Redis is unreachable: sign-ins aren't rate limited until it's back", "err", err)
	} else {
		log.Info("rate limiting sign-ins through Redis", "addr", opt.Addr)
	}
	return l, nil
}

// allow counts one sign-in attempt for email and says whether it may go
// ahead; if not, wait is how long until the account unlocks. Every attempt
// counts and a successful one resets the count (see reset), so there are
// loginAttempts tries per loginWindow.
//
// It fails open: when Redis can't be reached, the attempt is allowed and a
// warning logged. A Redis outage shouldn't lock everyone out; the price is
// no protection until Redis is back.
func (l *loginLimiter) allow(ctx context.Context, email string) (ok bool, wait time.Duration) {
	if l == nil {
		return true, 0
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()

	key := attemptsKey(email)
	var count *redis.IntCmd
	var ttl *redis.DurationCmd
	// One round trip, applied atomically, so concurrent attempts on other
	// replicas can't slip past the count: count this attempt, start the
	// window if this is the first one (NX leaves a running window alone),
	// and read how much of it is left.
	_, err := l.rdb.TxPipelined(ctx, func(p redis.Pipeliner) error {
		count = p.Incr(ctx, key)
		p.ExpireNX(ctx, key, loginWindow)
		ttl = p.TTL(ctx, key)
		return nil
	})
	if err != nil {
		l.log.Warn("Redis is unreachable: allowing the sign-in without rate limiting", "err", err)
		return true, 0
	}
	if count.Val() > loginAttempts {
		return false, max(ttl.Val(), time.Second)
	}
	return true, 0
}

// reset forgets an account's attempts after a successful sign-in.
func (l *loginLimiter) reset(ctx context.Context, email string) {
	if l == nil {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	if err := l.rdb.Del(ctx, attemptsKey(email)).Err(); err != nil {
		l.log.Warn("Redis is unreachable: couldn't reset the sign-in count", "err", err)
	}
}

func (l *loginLimiter) close() {
	if l != nil {
		l.rdb.Close()
	}
}

// redisLog sends the Redis client's own log lines (dial errors and such)
// through the app's logger, at debug level: the limiter already logs a
// warning for every failure that matters.
type redisLog struct{ log *slog.Logger }

func (r redisLog) Printf(_ context.Context, format string, v ...any) {
	r.log.Debug(fmt.Sprintf(format, v...), "component", "redis")
}

// attemptsKey is the Redis key counting an email's attempts. Hashed, so
// Redis holds no email addresses.
func attemptsKey(email string) string {
	sum := sha256.Sum256([]byte(email))
	return "roster:login-attempts:" + hex.EncodeToString(sum[:16])
}

// lockedMessage tells a locked-out user when to try again.
func lockedMessage(wait time.Duration) string {
	if minutes := int(math.Ceil(wait.Minutes())); minutes > 1 {
		return fmt.Sprintf("Too many sign-in attempts for this account. Try again in %d minutes.", minutes)
	}
	return "Too many sign-in attempts for this account. Try again in a minute."
}
