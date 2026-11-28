package timeutil

import (
	"testing"
	"time"
)

func TestAppleEpochRoundTrip(t *testing.T) {
	if got := ToAppleSeconds(AppleEpoch); got != 0 {
		t.Fatalf("epoch = %v, want 0", got)
	}
	if got := FromAppleSeconds(0); !got.Equal(AppleEpoch) {
		t.Fatalf("zero = %v, want %v", got, AppleEpoch)
	}
}

func TestAppleSecondsKnownValue(t *testing.T) {
	// 2024-01-01T00:00:00Z is 8400 days after the Apple epoch
	// (23 years plus the leap days in 2004, 2008, 2012, 2016 and 2020).
	value := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	got := ToAppleSeconds(value)
	const want = 725_760_000
	if got != want {
		t.Fatalf("ToAppleSeconds = %v, want %v", got, want)
	}
	if back := FromAppleSeconds(got); !back.Equal(value) {
		t.Fatalf("round trip = %v, want %v", back, value)
	}
}

func TestFromAppleSecondsSubSecond(t *testing.T) {
	// 786000000.25 seconds after the epoch must keep the fraction.
	got := FromAppleSeconds(786000000.25)
	if got.Nanosecond() != 250000000 {
		t.Fatalf("nanoseconds = %d, want 250000000", got.Nanosecond())
	}
}
