/**
 * The benchmark on Node (and on Deno, through its Node compatibility):
 *
 *   node --use-env-proxy --expose-gc main.node.ts <command>
 *   deno run -A --v8-flags=--expose-gc main.node.ts <command>
 *
 * `--expose-gc` lets the speed step collect garbage before each task;
 * `--use-env-proxy` makes Node's fetch use HTTPS_PROXY (Deno's always does).
 */
import { NodeRuntime, NodeServices } from "@effect/platform-node"
import { Effect, Layer } from "effect"
import { FetchHttpClient } from "effect/http"
import { cli } from "./src/cli.ts"
import { Host } from "./src/host.ts"

cli.pipe(Effect.provide(Layer.mergeAll(NodeServices.layer, FetchHttpClient.layer, Host.v8)), NodeRuntime.runMain)
