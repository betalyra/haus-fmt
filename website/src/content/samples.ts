/** Code shown on the landing page. Keep in step with the README and examples. */

/** "This is haus.": a home, device by device (Showcase.astro). */
export const homeSteps = [
  `
[
  { room: "Kitchen", device: Light { brightness: 80 } },
]
`,
  `
[
  { room: "Kitchen", device: Light { brightness: 80 } },
  { room: "Living room", device: Thermostat { target: 21.5 } },
]
`,
  `
[
  { room: "Kitchen", device: Light { brightness: 80 } },
  { room: "Living room", device: Thermostat { target: 21.5 } },
  { room: "Hall", device: Lock { locked: True } },
]
`,
  `
[
  { room: "Kitchen", device: Light { brightness: 80 }, wakeUp: Time("07:00:00") },
  { room: "Living room", device: Thermostat { target: 21.5 } },
  { room: "Hall", device: Lock { locked: True } },
]
`,
];

/** An order, for the playground's presets. */
export const heroHaus = `
// Comments are welcome, keys don't need quotes.
{
  order: 1042,
  placed: Date("2026-11-08"),
  total: 30.30,
  status: Shipped {
    tracking: "DE-4711",
    at: Instant("2026-11-09T09:12:00Z"),
  },
  gift: True,
  note: None,
}
`;

export const schemaHaus = `
import std/time (Instant)

type Comment = closed < Comment {
  author: String,
  at: Instant,
  text: String,
  likes: Int,
  replies: Array Comment,
} >

type Root = Comment
`;

export const threadHaus = `
Comment {
  author: "ada",
  at: Instant("2026-11-01T09:00:00Z"),
  text: "Should haus have null?",
  likes: 0,
  replies: [
    Comment {
      author: "bob",
      at: Instant("2026-11-02T09:00:00Z"),
      text: "JSON has it, people expect it.",
      likes: 2,
      replies: [],
    },
  ],
}
`;

export const codeTs = `
import * as Haus from "@haus-fmt/effect"
import { Effect } from "effect"
import thread from "./thread.haus"     // checked against its schema
import { Comment } from "./thread.schema.haus"

thread.author      // String        → string
thread.at          // Instant       → string, checked and exact
thread.likes       // Int           → bigint, no size limit
thread.replies     // Array Comment → Comment[]

const program = Effect.gen(function* () {
  const liked = { ...thread, likes: thread.likes + 1n }
  return yield* Haus.encode(Comment, { style: "compact" })(liked)
})
`;

export const codeTsPlain = `
import * as h from "@haus-fmt/haus/schema"
import thread from "./thread.haus"     // checked against its schema
import { Comment } from "./thread.schema.haus"

thread.author      // String        → string
thread.at          // Instant       → string, checked and exact
thread.likes       // Int           → bigint, no size limit
thread.replies     // Array Comment → Comment[]

const liked = { ...thread, likes: thread.likes + 1n }
console.log(h.stringify(Comment, liked))
`;

export const codePython = `
import haus
from haus import Record, Variant

thread = haus.parse(open("thread.haus").read())

match thread:
    case Variant("Comment", (Record(c),)):
        c["author"]    # String(value='ada')
        c["likes"]     # Number(text='0'), exact
        c["replies"]   # Array of Comment variants
`;

export const codeRust = `
mod thread {
    haus::include_schema!("thread"); // from thread.schema.haus
}
use thread::Comment;

let thread: Comment = haus::from_str(include_str!("thread.haus"))?;

thread.author      // String        → String
thread.likes       // Int           → haus::Int, no size limit
thread.replies     // Array Comment → Vec<Comment>

let likes = thread.likes.to_i128().unwrap_or_default() + 1;
let liked = Comment { likes: likes.into(), ..thread };
println!("{}", haus::to_string(&liked)?);
`;

/** The body of go/examples/thread/main.go, which go test runs. */
export const codeGo = `
import (
	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

s, _ := schema.Load("thread.schema.haus", schema.Options{})
root, _ := s.Type("Root")
text, _ := os.ReadFile("thread.haus")
v, _ := haus.Parse(text)

thread, err := root.Decode(v) // checked against its schema
if err != nil {
	log.Fatal(err) // $.replies[0].likes: expected Int, found the string "lots" [type-mismatch]
}

c := thread.(haus.Variant).Args[0].(haus.Record)
author, _ := c.Get("author")   // String        → haus.String
likes, _ := c.Get("likes")     // Int           → haus.Number, exact
replies, _ := c.Get("replies") // Array Comment → haus.Array

fmt.Println(author, likes, len(replies.(haus.Array))) // ada 0 1
`;

export const codeRoc = `
import haus.Decode
import haus.Encode
import haus.Int
import Thread

path : Path
path = "thread.haus"
thread = Decode.one(path.read_utf8!()?, Thread.decode_root)?

# author  : Str            String
# likes   : Int            Int, no size limit
# replies : List(Comment)  Array Comment

liked = match thread {
    Comment(c) => Comment({ ..c, likes: Int.from_i128((c.likes.to_i128() ?? 0) + 1) })
}
Stdout.line!(Encode.to_str(Encode.value(liked, Thread.encode_comment)?)?)?
`;

/** After swift/Examples/quickstart/main.swift. */
export const codeSwift = `
import Haus

struct Comment: Codable {      // from thread.schema.haus
    let author: String         // String        → String
    let at: String             // Instant       → String, checked and exact
    let text: String
    var likes: Int             // Int           → Int, range checked
    let replies: [Comment]     // Array Comment → [Comment]
}

let schema = try HausSchema(contentsOf: "thread.schema.haus")
let root = try schema.type("Root")
let data = try String(contentsOfFile: "thread.haus", encoding: .utf8)
var thread = try root.decode(Comment.self, fromText: data)  // checked against its schema

thread.likes += 1
print(try root.stringify(thread, FormatOptions(layout: .compact)))
`;

/** After jvm/examples/…/Quickstart.java. */
export const codeJava = `
import org.hausfmt.FormatOptions;
import org.hausfmt.HausCodec;
import org.hausfmt.Schema;

record Comment(                 // from thread.schema.haus
    String author,              // String        → String
    String at,                  // Instant       → String, checked and exact
    String text,
    BigInteger likes,           // Int           → BigInteger, no size limit
    List<Comment> replies) {}   // Array Comment → List<Comment>

Schema schema = Schema.load(Path.of("thread.schema.haus"));
HausCodec<Comment> comments = schema.codec("Root", Comment.class);
Comment thread = comments.decode(Files.readString(Path.of("thread.haus")));  // checked

Comment liked = new Comment(thread.author(), thread.at(), thread.text(),
    thread.likes().add(BigInteger.ONE), thread.replies());
System.out.print(comments.encode(liked, FormatOptions.COMPACT));
`;

/** After jvm/examples/…/quickstart/Quickstart.kt. */
export const codeKotlin = `
import org.hausfmt.FormatOptions
import org.hausfmt.Schema
import org.hausfmt.kotlin.codec

data class Comment(             // from thread.schema.haus
    val author: String,         // String        → String
    val at: String,             // Instant       → String, checked and exact
    val text: String,
    val likes: BigInteger,      // Int           → BigInteger, no size limit
    val replies: List<Comment>, // Array Comment → List<Comment>
)

val schema = Schema.load(Path("thread.schema.haus"))
val comments = schema.codec<Comment>("Root")
val thread = comments.decode(Path("thread.haus").readText())  // checked against its schema

val liked = thread.copy(likes = thread.likes + BigInteger.ONE)
print(comments.encode(liked, FormatOptions.COMPACT))
`;

/** After zig/examples/quickstart.zig. */
export const codeZig = `
const haus = @import("haus");

const build = try haus.packages.build(gpa, io, "thread.schema.haus", .{});
defer build.deinit();
const root = build.root.get("Root").?;

// checked against its schema; a Decoded keeps every value exactly
const thread = try haus.decoding.decodeText(gpa, arena, root, text, .{});
const c = thread.variant.args[0];      // Comment { … }

_ = c.get("author").?.string;          // String        → []const u8
_ = c.get("likes").?.int;              // Int           → its digits, no size limit
_ = c.get("replies").?.array;          // Array Comment → []const Decoded

const value = try haus.decoding.encode(arena, root, thread, .{});
std.debug.print("{s}\\n", .{try haus.stringify(arena, value, .{ .layout = .compact })});
`;

/** After zig/examples/c/quickstart.c: libhaus and haus.h, built from zig/. */
export const codeC = `
#include "haus.h"

haus_error err;
haus_schema *schema = NULL;
haus_schema_build("thread.schema.haus", NULL, &schema, &err);
const haus_type *root = haus_schema_type(schema, "Root");

/* checked against its schema; an error says where: $.likes: … [type-mismatch] */
haus_doc *doc = NULL;
const haus_value *thread = NULL;
if (haus_decode_text(root, text, len, &doc, &thread, &err) == HAUS_ERROR)
    printf("%s: %s [%s]\\n", err.path, err.message, err.code);

/* Comment { … }: its record, then fields by key */
const haus_value *c = haus_variant_arg(thread, 0);
size_t n;
const char *author = haus_string(haus_record_get(c, "author", 6), &n);  /* "ada" */
const char *likes = haus_number(haus_record_get(c, "likes", 5), &n);    /* "0" */

haus_doc_free(doc);
haus_schema_free(schema);
`;

/** The command line on the thread example with one bad value: the real output of haus check (CommandLine.astro). */
export const cliSession = `
$ brew install betalyra/tap/haus
$ haus check thread.haus
error[type-mismatch]: expected Int, found the string "lots"
  --> thread.haus:11:14
   |
11 |       likes: "lots",
   |              ^^^^^^
   |
   = at: $.replies[0].likes
   = hint: Write a value of the expected type; the message says which.
   = docs: https://haus-fmt.org/docs/errors#type-mismatch

Checked 1 file: 1 error.
`;

export const features = [
  {
    key: "write",
    file: "note.haus",
    wash: ["violet", "rose"],
    title: "Write it like a note",
    text: "Comments, keys without quotes, trailing commas, text blocks that keep their shape.",
    code: `{
  // keys without quotes, comments, trailing commas
  note: """
    Leave it at the door,
    the bell is broken.
    """,
}`,
  },
  {
    key: "cases",
    file: "payments.haus",
    wash: ["rose", "gold"],
    title: "Each case has its own data",
    text: "`Card { last4 }` or `PayPal { email }`: one value, never a pile of maybe-set fields.",
    code: `[
  Card { last4: "4242" },
  PayPal { email: "ada@example.com" },
  Invoice { dueIn: Duration("P30D") },
]`,
  },
  {
    key: "nonull",
    file: "people.haus",
    wash: ["sap", "yellow"],
    title: "No null",
    text: "A field is there or it isn't. `None` when \"nothing\" is a real answer.",
    code: `[
  { name: "Ada", nickname: Some("Countess") },
  { name: "Alan", nickname: None },   // has none
  { name: "Grace" },                  // not given
]`,
  },
  {
    key: "exact",
    file: "invoice.haus",
    wash: ["gold", "sienna"],
    title: "Exact by default",
    text: "`19.90` stays `19.90`. Dates, times and money are types, not strings.",
    code: `{
  total: Money(19.90, EUR),
  due: Date("2027-03-15"),
  views: 123_456_789_012_345_678_901,
}`,
  },
  {
    key: "grow",
    file: "team.schema.haus",
    wash: ["cerulean", "ultramarine"],
    title: "Add without breaking",
    text: "New fields and cases reach old readers safely. `closed` when every case must be handled.",
    code: `// open: new ways to reach people can come later
type Contact = < Email String | Slack { user: String } >

// closed: exactly these, nothing else
type Status = closed < Available | Away >`,
  },
  {
    key: "streams",
    file: "pages.haus",
    wash: ["cerulean", "sap"],
    title: "Every file is a stream",
    text: "Append, `tail -f`, read entries as they arrive.",
    code: `Paged { to: "Ada", at: Instant("2026-11-12T03:14:00Z") },
Acknowledged { by: "Ada" },
Escalated { to: "Grace" },`,
  },
] as const;
