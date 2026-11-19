package money_test

import (
	"errors"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/ext/money"
	"github.com/betalyra/haus-fmt/go/internal/vectors"
	"github.com/betalyra/haus-fmt/go/schema"
)

const dir = "../../../extensions/money"

func TestIsoVectors(t *testing.T) {
	accepted, rejected := vectors.Run(t, dir, dir+"/profiles/iso.vectors.haus",
		map[string]schema.Codec{"Money": money.Iso, "Currency": money.IsoCurrency})
	t.Logf("iso: %d Accept, %d Reject", accepted, rejected)
}

func TestIsoEncodeChecksTheRule(t *testing.T) {
	_, err := money.Iso.Encode(money.Money{Amount: haus.NumberFromInt(1), Currency: "Eur"})
	var e *haus.Error
	if !errors.As(err, &e) || e.Code != haus.CodeCannotEncode {
		t.Errorf("got %v", err)
	}
}
