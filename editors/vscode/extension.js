// The Rig extension's client: it starts `rig lsp` (the executable the
// setting `rig.lsp.path` names, `rig` on PATH by default) and connects it
// to the open .rig files. The TextMate grammar colours them whether or not
// the server starts.
const vscode = require("vscode");

/** @type {import("vscode-languageclient/node").LanguageClient | undefined} */
let client;

/** The client library, or undefined when `npm install` has not been run in
 * editors/vscode: the grammar still colours, and a note says what to do. */
function languageClient() {
  try {
    return require("vscode-languageclient/node").LanguageClient;
  } catch {
    vscode.window.showInformationMessage(
      "Rig: run `npm install` in editors/vscode to enable the Rig language server; highlighting works without it.",
    );
    return undefined;
  }
}

async function start() {
  const LanguageClient = languageClient();
  if (!LanguageClient) return;
  const command = vscode.workspace.getConfiguration("rig").get("lsp.path") || "rig";
  const server = { command, args: ["lsp"] };
  client = new LanguageClient("rig", "Rig", { run: server, debug: server }, {
    documentSelector: [{ language: "rig" }],
  });
  try {
    await client.start();
  } catch (err) {
    client = undefined;
    vscode.window.showWarningMessage(
      `Rig: the language server did not start (\`${command} lsp\`: ${err.message}). ` +
        "Set rig.lsp.path to the rig executable; highlighting works without it.",
    );
  }
}

async function stop() {
  const running = client;
  client = undefined;
  if (running) await running.stop();
}

/** @param {vscode.ExtensionContext} context */
async function activate(context) {
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (!e.affectsConfiguration("rig.lsp.path")) return;
      await stop();
      await start();
    }),
  );
  await start();
}

function deactivate() {
  return stop();
}

module.exports = { activate, deactivate };
