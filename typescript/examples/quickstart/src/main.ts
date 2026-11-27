// The quickstart: data typed by its schema, decoding, encoding and errors.
// The same steps as rust/examples/quickstart, on the same files. Run: pnpm start
import { pipe, Result, Schema } from "@haus-fmt/haus";
// A data file is a module, typed (and checked) by the schema next to it.
import thread from "../../../../examples/thread.haus";
// A schema file exports its compiled schema and a handle per type.
import { Comment, schema } from "../../../../examples/thread.schema.haus";

const likes = (c: Comment): bigint => c.replies.reduce((sum, reply) => sum + likes(reply), c.likes);
const depth = (c: Comment): number => 1 + Math.max(0, ...c.replies.map(depth));

const reply = `Comment { author: "me", at: Instant("2026-11-16T09:00:00Z"), text: "+1", likes: 0, replies: [] }`;

// 1. The thread, as typed data: Int is bigint, Instant is its text as written.
console.log(`thread by ${thread.author}: ${depth(thread)} levels, ${likes(thread)} likes`);

// 2. Decode haus text with the schema, change it, encode it back. Every step that can fail is a Result.
const written = pipe(
  Schema.decode(schema, Comment)(reply),
  Result.map((decoded) => ({ ...decoded, likes: decoded.likes + 1n })),
  Result.flatMap((liked) => Schema.stringify(schema, Comment)(liked, { style: "compact" })),
);
Result.match(written, { onSuccess: console.log, onFailure: (e) => console.error(e.message) });

// 3. A value that doesn't match the schema is an error that says where.
const wrong = Schema.decode(schema, Comment)(reply.replace("likes: 0", `likes: "lots"`));
if (Result.isFailure(wrong)) console.log(`error: ${wrong.failure.message}`);
