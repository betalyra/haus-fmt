/**
 * The benchmark on Bun:
 *
 *   bun main.bun.ts <command>
 *
 * Bun always has a garbage collector to call (`Bun.gc`), and its fetch uses
 * HTTPS_PROXY.
 */
import { BunRuntime, BunServices } from "@effect/platform-bun"
import { Effect, Layer, Option } from "effect"
import { FetchHttpClient } from "effect/http"
import { cli } from "./src/cli.ts"
import { Host } from "./src/host.ts"

declare const Bun: { readonly gc: (force: boolean) => void }

cli.pipe(Effect.provide(Layer.mergeAll(BunServices.layer, FetchHttpClient.layer, Host.layer(Option.some(() => Bun.gc(true))))), BunRuntime.runMain)
