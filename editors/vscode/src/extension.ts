// Starts the haus language server for .haus files.
import { realpathSync, statSync } from "node:fs"
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

  // `haus.packages` and the build's root (`haus.root`) of each workspace folder, as real absolute paths, for the server.
  let warned = ""
  const sendSettings = () => {
    const ignored: string[] = []
    const settings = Object.fromEntries(
      (vscode.workspace.workspaceFolders ?? []).flatMap((folder) => {
        const { paths, problems } = packagePaths(folder)
        const root = rootOf(folder)
        ignored.push(...problems, ...root.problems)
        return root.path === undefined ? [] : [[folder.uri.fsPath, { packages: paths, root: root.path }]]
      }),
    )
    void client?.sendNotification("haus/settings", settings)
    const message = ignored.join("; ")
    if (message !== "" && message !== warned) void vscode.window.showWarningMessage(`haus: some settings are not used: ${message}`)
    warned = message
  }
  sendSettings()
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => (e.affectsConfiguration("haus.packages") || e.affectsConfiguration("haus.root")) && sendSettings()),
    vscode.workspace.onDidChangeWorkspaceFolders(sendSettings),
    vscode.workspace.onDidGrantWorkspaceTrust(sendSettings),
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

// ── haus.packages and haus.root ──────────────────────────────

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
  const { value, workspace, problems } = setting<string[]>(folder, "packages")
  const paths: string[] = []
  for (const given of Array.isArray(value) ? value : []) {
    if (typeof given !== "string") continue
    const real = settingPath(folder, given, workspace, problems)
    if (real !== undefined) paths.push(real)
  }
  return { paths, problems }
}

/**
 * The build's root for the files of a workspace folder (spec §13.3, "The
 * root"), as a real path: their relative imports stay inside it. The folder
 * itself, or the directory `haus.root` gives, relative to the folder, by the
 * same rules as `haus.packages`: from workspace or folder settings it must
 * stay inside the folder and is ignored in an untrusted workspace; from user
 * settings it may be anywhere local; never a network path. Undefined if the
 * folder itself can't be found.
 */
function rootOf(folder: vscode.WorkspaceFolder): { readonly path: string | undefined; readonly problems: readonly string[] } {
  const { value, workspace, problems } = setting<string>(folder, "root")
  let own: string
  try {
    own = realpathSync(folder.uri.fsPath)
  } catch {
    return { path: undefined, problems }
  }
  if (typeof value !== "string" || value === "") return { path: own, problems }
  const real = settingPath(folder, value, workspace, problems)
  if (real === undefined) return { path: own, problems }
  if (!statSync(real).isDirectory()) return { path: own, problems: [...problems, `haus.root ${value} is not a directory`] }
  return { path: real, problems }
}

/**
 * The value of `haus.<name>` for a workspace folder, and whether it comes from
 * the workspace (workspace or folder settings) rather than the user's. The
 * most specific level that has a value wins, as for `get`; the workspace's
 * levels only in a trusted workspace.
 */
function setting<T>(folder: vscode.WorkspaceFolder, name: string): { readonly value: T | undefined; readonly workspace: boolean; readonly problems: string[] } {
  const inspected = vscode.workspace.getConfiguration("haus", folder.uri).inspect<T>(name)
  const trusted = vscode.workspace.isTrusted
  const problems: string[] = []
  if (!trusted && (inspected?.workspaceFolderValue !== undefined || inspected?.workspaceValue !== undefined)) {
    problems.push(`the workspace's haus.${name} is ignored in ${folder.name} until you trust the workspace`)
  }
  if (trusted && inspected?.workspaceFolderValue !== undefined) return { value: inspected.workspaceFolderValue, workspace: true, problems }
  if (trusted && inspected?.workspaceValue !== undefined) return { value: inspected.workspaceValue, workspace: true, problems }
  return { value: inspected?.globalValue, workspace: false, problems }
}

/**
 * A path of a setting (`given`, relative to the workspace folder), as a real
 * path, or undefined with why in `problems`: a network path, one that doesn't
 * exist, or one from the workspace's settings outside the folder.
 */
function settingPath(folder: vscode.WorkspaceFolder, given: string, workspace: boolean, problems: string[]): string | undefined {
  const absolute = isAbsolute(given) ? given : resolve(folder.uri.fsPath, given)
  if (isNetworkPath(given) || isNetworkPath(absolute)) {
    problems.push(`${given} is a network path`)
    return undefined
  }
  let real: string
  let root: string
  try {
    real = realpathSync(absolute)
    root = realpathSync(folder.uri.fsPath)
  } catch {
    problems.push(`${given} doesn't exist`)
    return undefined
  }
  if (isNetworkPath(real)) problems.push(`${given} is a network path`)
  else if (workspace && !isInside(root, real)) problems.push(`${given} is outside the workspace folder ${folder.name} (only user settings may point outside it)`)
  else return real
  return undefined
}
