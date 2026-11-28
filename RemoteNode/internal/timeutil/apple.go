// Package timeutil converts between Go time and the date representation the
// FlowCue iPhone app expects on the wire.
//
// The iPhone decodes responses with a plain JSONDecoder, whose default date
// strategy is .deferredToDate. That means dates are encoded as seconds since
// Apple's reference date (2001-01-01T00:00:00Z), NOT Unix seconds. Sending
// Unix seconds would silently decode into the year 2057.
package timeutil

import "time"

// AppleEpoch is Apple's reference date used by Foundation's Date.
var AppleEpoch = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

// FromAppleSeconds converts seconds since 2001-01-01Z into a time.Time.
func FromAppleSeconds(seconds float64) time.Time {
	return AppleEpoch.Add(time.Duration(seconds * float64(time.Second)))
}

// ToAppleSeconds converts a time.Time into seconds since 2001-01-01Z.
func ToAppleSeconds(t time.Time) float64 {
	return t.Sub(AppleEpoch).Seconds()
}
