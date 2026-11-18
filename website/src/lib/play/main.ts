/**
 * The playground: a data file and an optional schema, analysed as you type.
 * Everything runs in the browser; a shared link carries both texts in its
 * fragment (after #), which browsers never send to a server.
 */
import type { CompletionContext, CompletionResult } from "@codemirror/autocomplete";
import type { EditorView } from "@codemirror/view";
import { completeAt, hoverAt, hoverText } from "../../../../typescript/packages/haus/src/index.ts";
import { analyze, type Analysis } from "./analyze";
import { prettyDeclarations } from "./pretty";
import { inYourCode, type How } from "./in-code";
import { createEditor, lintAgain, setLanguage, setText } from "./editor";
import { presets } from "./presets";
import { copyLink, decodeState, encodeState } from "../share";

/** The output tabs; "code" shows the outputs of the chosen target. */
type Output = "code" | "json" | "inferred" | "formatted";
type Target = "plain" | "effect";

/** The Effect target's declarations of a schema, loaded with Effect only when asked for. */
async function effectDeclarations(schemaText: string): Promise<string> {
  const [{ parseSchemaFile }, Haus] = await Promise.all([
    import("../../../../typescript/packages/haus/src/index.ts"),
    import("../../../../typescript/packages/effect/src/index.ts"),
  ]);
  return Haus.schemaDeclarations(parseSchemaFile(schemaText) as never);
}

const $ = <E extends HTMLElement>(sel: string) => document.querySelector<E>(sel)!;

// ── sharing ──────────────────────────────────────────────────

const encode = (data: string, schema: string, off: boolean) => encodeState({ d: data, s: schema, ...(off ? { x: 1 } : {}) });

async function decode(hash: string): Promise<{ data: string; schema: string; off: boolean } | undefined> {
  const state = (await decodeState(hash)) as { d?: unknown; s?: unknown; x?: unknown } | undefined;
  return typeof state?.d === "string" && typeof state.s === "string" ? { data: state.d, schema: state.s, off: state.x === 1 } : undefined;
}

// ── the page ─────────────────────────────────────────────────

async function start() {
  const shared = location.hash.length > 1 ? await decode(location.hash.slice(1)) : undefined;
  const first = shared ?? presets[0]!;

  const use = $<HTMLInputElement>("#play-use");
  use.checked = !shared?.off;
  /** The schema text, if it is switched on. */
  const schemaIn = (text: string) => (use.checked ? text : "");
  let analysis: Analysis = analyze(first.data, schemaIn(first.schema));
  let output: Output = "code";
  let target: Target = "plain";
  let how: How = "file";
  /** Whether "In your code" shows the generated declarations instead. */
  let declarations = false;

  const out = createEditor({ parent: $("#play-output"), doc: "", readOnly: true });

  const complete = (ctx: CompletionContext): CompletionResult | null => {
    const schema = analysis.schema;
    if (!schema) return null;
    const word = ctx.matchBefore(/[A-Za-z0-9_]*/);
    if (!word || (word.from === word.to && !ctx.explicit)) return null;
    const items = completeAt(schema.file, schema.type, ctx.state.doc.toString(), ctx.pos);
    if (items.length === 0) return null;
    return {
      from: word.from,
      options: items.map((c) => ({
        label: c.label,
        detail: c.detail,
        type: c.kind === "field" ? "property" : "enum",
        apply: c.insertText.replace(/\$\d/g, ""),
        boost: -Number(c.sortText.replace(/\D/g, "") || 0),
      })),
    };
  };

  const data: EditorView = createEditor({
    parent: $("#play-data"),
    doc: first.data,
    placeholder: "Write haus here…",
    onChange: () => update(),
    diagnostics: () => analysis.dataProblems.map((p) => ({ ...p })),
    hover: (pos) => {
      if (!analysis.hover) return undefined;
      const info = hoverAt(analysis.hover, pos, { width: 60 });
      return info && { from: info.start, to: info.end, text: hoverText(info) };
    },
    complete,
  });
  const schema: EditorView = createEditor({
    parent: $("#play-schema"),
    doc: first.schema,
    placeholder: "Optional: a schema to check the data against, e.g.\n\ntype Root = { name: String }",
    onChange: () => update(),
    diagnostics: () => analysis.schemaProblems.map((p) => ({ ...p })),
  });

  /** The text of the declarations view; the Effect one arrives later (it loads Effect). */
  let shown = 0;
  const declarationsText = async (): Promise<string> => {
    const schemaText = schemaIn(schema.state.doc.toString());
    if (target === "plain" || !analysis.schema) return analysis.outputs.typescript;
    try {
      return `// data.haus\nimport type { ${analysis.schema.type} } from "./data.schema.haus";\n\ndeclare const data: ${analysis.schema.type};\nexport default data;\n\n\n// data.schema.haus\n${prettyDeclarations(await effectDeclarations(schemaText))}`;
    } catch (e) {
      return `// ${(e as Error).message}`;
    }
  };

  const show = () => {
    const code = output === "code";
    setLanguage(out, code || output === "json" ? (code ? "typescript" : "json") : "haus");
    const turn = ++shown;
    if (code && declarations) {
      if (target === "plain" || !analysis.schema) setText(out, analysis.outputs.typescript);
      else void declarationsText().then((text) => turn === shown && setText(out, text));
    } else if (code) setText(out, analysis.code ? inYourCode(analysis.code, target, how) : "// fix the error to see this");
    else setText(out, analysis.outputs[output]);
    $("#play-use-schema").hidden = output !== "inferred";
    $("#play-code-options").hidden = !code;
    const toggle = $<HTMLButtonElement>("#play-declarations");
    toggle.hidden = !code;
    toggle.setAttribute("aria-pressed", String(declarations));
    toggle.textContent = declarations ? "Show fields and values" : "Show the generated declarations";
    document.querySelectorAll<HTMLButtonElement>("[data-target]").forEach((b) => b.setAttribute("aria-checked", String(b.dataset.target === target)));
    document.querySelectorAll<HTMLButtonElement>("[data-how]").forEach((b) => b.setAttribute("aria-checked", String(b.dataset.how === how)));
    $("#play-summary").textContent = analysis.summary;
    $("#play-summary").dataset.state = analysis.dataProblems.some((p) => p.severity === "error") || analysis.schemaProblems.length ? "error" : "ok";
    document.querySelectorAll<HTMLButtonElement>("[data-output]").forEach((b) => {
      b.setAttribute("aria-selected", String(b.dataset.output === output));
      if (b.dataset.output === output) $("#play-caption").textContent = b.dataset.caption ?? "";
    });
    if (code) {
      $("#play-caption").textContent = how === "file"
        ? "A .haus file your code imports: typed, no parsing code to write."
        : "haus your program receives: a schema checks it and gives it a type.";
    }
  };

  let saving = 0;
  const update = () => {
    analysis = analyze(data.state.doc.toString(), schemaIn(schema.state.doc.toString()));
    $("#play-schema").toggleAttribute("data-off", !use.checked);
    show();
    // Both editors' problems depend on both texts: lint again once this update is done.
    requestAnimationFrame(() => {
      lintAgain(data);
      lintAgain(schema);
    });
    clearTimeout(saving);
    saving = window.setTimeout(async () => {
      history.replaceState(null, "", `#${await encode(data.state.doc.toString(), schema.state.doc.toString(), !use.checked)}`);
    }, 400);
  };

  use.addEventListener("change", () => update());

  const load = (p: { data: string; schema: string }) => {
    use.checked = true;
    data.dispatch({ changes: { from: 0, to: data.state.doc.length, insert: p.data } });
    schema.dispatch({ changes: { from: 0, to: schema.state.doc.length, insert: p.schema } });
  };

  // Presets
  const select = $<HTMLSelectElement>("#play-preset");
  presets.forEach((p, i) => select.add(new Option(p.name, String(i))));
  select.value = shared ? "" : "0";
  select.addEventListener("change", () => {
    const p = presets[Number(select.value)];
    if (p) load(p);
  });

  // Output tabs
  document.querySelectorAll<HTMLButtonElement>("[data-output]").forEach((b) =>
    b.addEventListener("click", () => {
      output = b.dataset.output as Output;
      show();
    }));

  $("#play-use-schema").addEventListener("click", () => {
    schema.dispatch({ changes: { from: 0, to: schema.state.doc.length, insert: analysis.outputs.inferred } });
    output = "code";
    show();
  });

  // Target of "In your code", and its declarations
  document.querySelectorAll<HTMLButtonElement>("[data-target]").forEach((b) =>
    b.addEventListener("click", () => {
      target = b.dataset.target as Target;
      show();
    }));
  document.querySelectorAll<HTMLButtonElement>("[data-how]").forEach((b) =>
    b.addEventListener("click", () => {
      how = b.dataset.how as How;
      show();
    }));
  $("#play-declarations").addEventListener("click", () => {
    declarations = !declarations;
    show();
  });

  // Share: the URL already holds both texts; copy it.
  const share = $<HTMLButtonElement>("#play-share");
  share.addEventListener("click", async () => {
    history.replaceState(null, "", `#${await encode(data.state.doc.toString(), schema.state.doc.toString(), !use.checked)}`);
    await copyLink(share);
  });

  $("#play-schema").toggleAttribute("data-off", !use.checked);
  show();
}

start();
