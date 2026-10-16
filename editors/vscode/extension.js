// The Rig extension's client: it starts `rig lsp` (the executable the
// setting `rig.lsp.path` names, `rig` on PATH by default) and connects it
// to the open .rig files. The TextMate grammar colours them whether or not
// the server starts.
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

/** @type {LanguageClient | undefined} */
let client;

async function start() {
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
