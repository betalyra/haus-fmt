package jsontypes

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// Node is one JSON value of a schema file: an object (its members in
// order), an array, or a scalar.
type Node struct {
	Keys    []string
	Members map[string]*Node
	Items   []*Node
	// Scalar is a string, a bool, a json.Number or nil (null), when the node
	// is neither an object nor an array.
	Scalar   any
	IsObject bool
	IsArray  bool
}

// Get returns a member of an object, or nil.
func (n *Node) Get(key string) *Node {
	if n == nil || n.Members == nil {
		return nil
	}
	return n.Members[key]
}

// Str returns a string member.
func (n *Node) Str(key string) (string, bool) {
	s, ok := n.Get(key).scalar().(string)
	return s, ok
}

// Strings returns the strings of an array member.
func (n *Node) Strings(key string) []string {
	var out []string
	if a := n.Get(key); a != nil {
		for _, x := range a.Items {
			if s, ok := x.Scalar.(string); ok {
				out = append(out, s)
			}
		}
	}
	return out
}

func (n *Node) scalar() any {
	if n == nil {
		return nil
	}
	return n.Scalar
}

// IsAny reports whether the schema is {}: anything.
func (n *Node) IsAny() bool { return n.IsObject && len(n.Keys) == 0 }

// Type returns the schema's type and whether null is allowed too: "string"
// for type: string, ("string", true) for type: ["string", "null"]; "" for
// none.
func (n *Node) Type() (string, bool) {
	t := n.Get("type")
	if t == nil {
		return "", false
	}
	if s, ok := t.Scalar.(string); ok {
		return s, false
	}
	var types []string
	nullable := false
	for _, x := range t.Items {
		if s, _ := x.Scalar.(string); s == "null" {
			nullable = true
		} else {
			types = append(types, s)
		}
	}
	if len(types) != 1 {
		return strings.Join(types, "|"), nullable
	}
	return types[0], nullable
}

// NullOr returns T of anyOf [{ type: null }, T], or nil.
func (n *Node) NullOr() *Node {
	a := n.Get("anyOf")
	if a == nil || len(a.Items) != 2 {
		return nil
	}
	if t, _ := a.Items[0].Type(); t != "null" {
		return nil
	}
	return a.Items[1]
}

// Discriminator returns the member of a variant by a member, or "".
func (n *Node) Discriminator() string {
	m, _ := n.Get("discriminator").Str("propertyName")
	return m
}

// Branch returns the branch of a variant by member whose member is value,
// or nil.
func (n *Node) Branch(member, value string) *Node {
	for _, b := range n.Get("oneOf").items() {
		if c, ok := b.Get("properties").Get(member).Str("const"); ok && c == value {
			return b
		}
	}
	return nil
}

func (n *Node) items() []*Node {
	if n == nil {
		return nil
	}
	return n.Items
}

// KeyedCase is a case of a variant told apart by required keys.
type KeyedCase struct {
	Keys    []string
	Payload *Node
}

// Keyed returns the cases of a variant by keys (oneOf [{ required }…],
// allOf [{ if: { required }, then }…]), or nil.
func (n *Node) Keyed() []KeyedCase {
	all := n.Get("allOf")
	if all == nil {
		return nil
	}
	cases := make([]KeyedCase, len(all.Items))
	for i, c := range all.Items {
		cases[i] = KeyedCase{Keys: c.Get("if").Strings("required"), Payload: c.Get("then")}
	}
	return cases
}

// CaseOf returns the one case whose keys the object has (exactly one, as
// convert's reader asks), or false.
func CaseOf(cases []KeyedCase, has func(string) bool) (KeyedCase, bool) {
	var found KeyedCase
	n := 0
	for _, c := range cases {
		all := true
		for _, k := range c.Keys {
			all = all && has(k)
		}
		if all {
			found = c
			n++
		}
	}
	return found, n == 1
}

// DefinitionsPrefix starts every $ref of a schema file.
const DefinitionsPrefix = "#/definitions/"

// File is a schema file: corpus/<source>.schema.json.
type File struct {
	Definitions *Node
	// SHA256 is the file's SHA-256, hex.
	SHA256 string
}

// ReadFile reads a schema file.
func ReadFile(path string) (*File, error) {
	text, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	root, err := Parse(text)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	defs := root.Get("definitions")
	if defs == nil || !defs.IsObject {
		return nil, fmt.Errorf("%s: no definitions", path)
	}
	sum := sha256.Sum256(text)
	return &File{Definitions: defs, SHA256: hex.EncodeToString(sum[:])}, nil
}

// RefName returns the definition a $ref names, or false.
func RefName(n *Node) (string, bool) {
	ref, ok := n.Str("$ref")
	if !ok {
		return "", false
	}
	return strings.TrimPrefix(ref, DefinitionsPrefix), true
}

// RefTo is the schema {"$ref": "#/definitions/<name>"}.
func RefTo(name string) *Node {
	return &Node{IsObject: true, Keys: []string{"$ref"}, Members: map[string]*Node{"$ref": {Scalar: DefinitionsPrefix + name}}}
}

// Resolve follows $refs to a schema that isn't one.
func (f *File) Resolve(n *Node) *Node {
	for i := 0; i < 64; i++ {
		name, ok := RefName(n)
		if !ok {
			return n
		}
		n = f.Definitions.Get(name)
	}
	return n
}

// Parse reads JSON text into a Node, objects' members in order.
func Parse(text []byte) (*Node, error) {
	d := json.NewDecoder(bytes.NewReader(text))
	d.UseNumber()
	n, err := parseNode(d)
	if err != nil {
		return nil, err
	}
	if d.More() {
		return nil, fmt.Errorf("text after the value")
	}
	return n, nil
}

func parseNode(d *json.Decoder) (*Node, error) {
	tok, err := d.Token()
	if err != nil {
		return nil, err
	}
	switch tok {
	case json.Delim('{'):
		n := &Node{IsObject: true, Members: map[string]*Node{}}
		for d.More() {
			k, err := d.Token()
			if err != nil {
				return nil, err
			}
			key := k.(string)
			v, err := parseNode(d)
			if err != nil {
				return nil, err
			}
			if _, dup := n.Members[key]; !dup {
				n.Keys = append(n.Keys, key)
			}
			n.Members[key] = v
		}
		_, err := d.Token()
		return n, err
	case json.Delim('['):
		n := &Node{IsArray: true}
		for d.More() {
			v, err := parseNode(d)
			if err != nil {
				return nil, err
			}
			n.Items = append(n.Items, v)
		}
		_, err := d.Token()
		return n, err
	default:
		return &Node{Scalar: tok}, nil
	}
}
