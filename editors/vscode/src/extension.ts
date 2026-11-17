// Starts the haus language server for .haus files.
import { realpathSync } from "node:fs"
import { isAbsolute, relative, resolve, sep } from "node:path"
import * as vscode from "vscode"
import { LanguageClient, TransportKind, type ServerOptions } from "vscode-languageclient/node"
import { extendMarkdownIt } from "./highlight"

let client: LanguageClient | undefined

/** Diagnostic code of "not in the schema" hints (see server.ts). */
const NOT_IN_SCHEMA = "not-in-schema"

/** What the extension gives VS Code: haus highlighting for the Markdown preview. */
interface Api {
  extendMarkdownIt: typeof extendMarkdownIt
}

export async function activate(context: vscode.ExtensionContext): Promise<Api> {
  const hints = new Map<string, readonly vscode.Diagnostic[]>()
  const notInSchema = vscode.window.createTextEditorDecorationType({
    light: { textDecoration: "underline dotted rgba(0, 0, 0, 0.45)" },
    dark: { textDecoration: "underline dotted rgba(255, 255, 255, 0.45)" },
  })
  const decorate = (editor: vscode.TextEditor) => {
    const found = hints.get(editor.document.uri.toString()) ?? []
    editor.setDecorations(notInSchema, found.map((d) => ({ range: d.range, hoverMessage: d.message })))
  }
  const module = context.asAbsolutePath("dist/server.js")
  const serverOptions: ServerOptions = {
    run: { module, transport: TransportKind.ipc },
    debug: { module, transport: TransportKind.ipc, options: { execArgv: ["--nolazy", "--inspect=6009"] } },
  }
  client = new LanguageClient("haus", "haus language server", serverOptions, {
    documentSelector: [{ language: "haus" }, { language: "haus-schema" }],
    middleware: {
      // "Not in the schema" hints are shown as a dotted underline over the
      // whole name instead of as diagnostics (VS Code would add its own dots
      // under the first characters and list them with the problems).
      handleDiagnostics(uri, diagnostics, next) {
        hints.set(uri.toString(), diagnostics.filter((d) => d.code === NOT_IN_SCHEMA))
        next(uri, diagnostics.filter((d) => d.code !== NOT_IN_SCHEMA))
        for (const editor of vscode.window.visibleTextEditors) if (editor.document.uri.toString() === uri.toString()) decorate(editor)
      },
    },
  })
  await client.start()

  // `haus.packages` of each workspace folder, as real absolute paths, for the server.
  let warned = ""
  const sendPackages = () => {
    const ignored: string[] = []
    const settings = Object.fromEntries(
      (vscode.workspace.workspaceFolders ?? []).map((folder) => {
        const { paths, problems } = packagePaths(folder)
        ignored.push(...problems)
        return [folder.uri.fsPath, paths]
      }),
    )
    void client?.sendNotification("haus/packages", settings)
    const message = ignored.join("; ")
    if (message !== "" && message !== warned) void vscode.window.showWarningMessage(`haus: some haus.packages entries are not used: ${message}`)
    warned = message
  }
  sendPackages()
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => e.affectsConfiguration("haus.packages") && sendPackages()),
    vscode.workspace.onDidChangeWorkspaceFolders(sendPackages),
    vscode.workspace.onDidGrantWorkspaceTrust(sendPackages),
  )

  vscode.window.visibleTextEditors.forEach(decorate)
  context.subscriptions.push(notInSchema, vscode.window.onDidChangeVisibleTextEditors((editors) => editors.forEach(decorate)))

  context.subscriptions.push(
    vscode.commands.registerCommand("haus.inferSchema", async () => {
      const document = vscode.window.activeTextEditor?.document
      if (!document || document.languageId !== "haus" || !client) return
      const schema = await client.sendRequest<string | null>("haus/inferSchema", { uri: document.uri.toString() })
      if (schema === null) {
        void vscode.window.showWarningMessage("haus: fix the syntax errors in this file first.")
        return
      }
      const result = await vscode.workspace.openTextDocument({ language: "haus-schema", content: schema })
      await vscode.window.showTextDocument(result, vscode.ViewColumn.Beside)
    }),
    // Format Document uses the pretty layout; these switch a document between the three layouts.
    ...(["pretty", "compact", "minimised"] as const).map((style) =>
      vscode.commands.registerCommand(`haus.print.${style}`, async () => {
        const editor = vscode.window.activeTextEditor
        const document = editor?.document
        if (!editor || !document || document.languageId !== "haus" || !client) return
        const text = await client.sendRequest<string | null>("haus/print", { uri: document.uri.toString(), style })
        if (text === null) {
          void vscode.window.showWarningMessage("haus: fix the syntax errors in this file first.")
          return
        }
        if (text === document.getText()) return
        const all = new vscode.Range(document.positionAt(0), document.positionAt(document.getText().length))
        await editor.edit((edit) => edit.replace(all, text))
      }),
    ),
  )

  return { extendMarkdownIt }
}

export function deactivate(): Promise<void> | undefined {
  return client?.stop()
}

// ── haus.packages ────────────────────────────────────────────

/** A network path (`\\host\share`, `//host/share`, `\\?\UNC\…`): never used, from any settings. */
const isNetworkPath = (path: string): boolean => /^[\\/]{2}/.test(path)

const isInside = (root: string, path: string): boolean => {
  const rel = relative(root, path)
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
}

/**
 * The paths `haus.packages` gives a workspace folder, as real paths, and why
 * others are not used. Paths from user settings may be anywhere local; paths
 * from workspace or folder settings must stay inside the folder (symbolic
 * links resolved), and are ignored in an untrusted workspace. Network paths
 * are never used.
 */
function packagePaths(folder: vscode.WorkspaceFolder): { readonly paths: readonly string[]; readonly problems: readonly string[] } {
  const inspected = vscode.workspace.getConfiguration("haus", folder.uri).inspect<string[]>("packages")
  const trusted = vscode.workspace.isTrusted
  // The most specific level that has a value wins, as for `get`.
  const level =
    trusted && inspected?.workspaceFolderValue !== undefined ? { paths: inspected.workspaceFolderValue, workspace: true }
    : trusted && inspected?.workspaceValue !== undefined ? { paths: inspected.workspaceValue, workspace: true }
    : { paths: inspected?.globalValue ?? [], workspace: false }
  const problems: string[] = []
  if (!trusted && (inspected?.workspaceFolderValue !== undefined || inspected?.workspaceValue !== undefined)) {
    problems.push(`the workspace settings are ignored in ${folder.name} until you trust the workspace`)
  }
  let root: string
  try {
    root = realpathSync(folder.uri.fsPath)
  } catch {
    return { paths: [], problems }
  }
  const paths: string[] = []
  for (const given of Array.isArray(level.paths) ? level.paths : []) {
    if (typeof given !== "string") continue
    const absolute = isAbsolute(given) ? given : resolve(folder.uri.fsPath, given)
    if (isNetworkPath(given) || isNetworkPath(absolute)) {
      problems.push(`${given} is a network path`)
      continue
    }
    let real: string
    try {
      real = realpathSync(absolute)
    } catch {
      problems.push(`${given} doesn't exist`)
      continue
    }
    if (isNetworkPath(real)) problems.push(`${given} is a network path`)
    else if (level.workspace && !isInside(root, real)) problems.push(`${given} is outside the workspace folder ${folder.name} (only user settings may point outside it)`)
    else paths.push(real)
  }
  return { paths, problems }
}
