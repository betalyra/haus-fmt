package uuid_test

import (
	"errors"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/ext/uuid"
	"github.com/betalyra/haus-fmt/go/internal/vectors"
	"github.com/betalyra/haus-fmt/go/schema"
)

const dir = "../../../extensions/uuid"

const id = "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57"

func TestRfc9562Vectors(t *testing.T) {
	accepted, rejected := vectors.Run(t, dir, dir+"/profiles/rfc9562.vectors.haus",
		map[string]schema.Codec{"Uuid": uuid.Rfc9562})
	t.Logf("rfc9562: %d Accept, %d Reject", accepted, rejected)
}

func TestValid(t *testing.T) {
	for _, s := range []string{id, "00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"} {
		if !uuid.Valid(s) {
			t.Errorf("%s: rejected", s)
		}
	}
	for _, v := range "0123456789abcdef" {
		if s := "0190c7a8-5b6e-" + string(v) + "d3f-" + string(v) + "a41-6c2e8f1b0d57"; !uuid.Valid(s) {
			t.Errorf("%s: rejected (no version or variant check)", s)
		}
	}
	for _, s := range []string{
		strings.ToUpper(id), "{" + id + "}", "urn:uuid:" + id, strings.ReplaceAll(id, "-", ""), id[1:], id + "0",
		" " + id, id + "\n", id[:35] + "٧", "", "0190c7a-85b6e-7d3f-9a41-6c2e8f1b0d57", strings.Replace(id, "-", "0", 1),
		strings.Replace(id, "d", "g", 1),
	} {
		if uuid.Valid(s) {
			t.Errorf("%q: accepted", s)
		}
	}
}

func TestRfc9562DecodesTheText(t *testing.T) {
	v, err := haus.Parse([]byte(`Uuid("` + id + `")`))
	if err != nil {
		t.Fatal(err)
	}
	u, err := uuid.Rfc9562.Decode(v)
	if err != nil || u != uuid.UUID(id) {
		t.Fatalf("got %v, %v", u, err)
	}
	back, err := uuid.Rfc9562.Encode(u)
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := haus.Canonical(back); s != `Uuid("`+id+`")` {
		t.Errorf("encodes to %s", s)
	}
}

func TestRfc9562EncodeChecksTheRule(t *testing.T) {
	_, err := uuid.Rfc9562.Encode(uuid.UUID(strings.ToUpper(id)))
	var e *haus.Error
	if !errors.As(err, &e) || e.Code != haus.CodeCannotEncode {
		t.Errorf("got %v", err)
	}
}
