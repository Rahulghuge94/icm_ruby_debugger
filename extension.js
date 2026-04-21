"use strict";

const childProcess = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const vscode = require("vscode");

const CONFIG_SECTION = "icmRubyDebugger";
const DEBUG_TYPE = "icm-ruby";
const PROTOCOL_PREFIX = "__ICM_RUBY_DEBUGGER__";
const COMMAND_PREFIX = "__ICM_RUBY_DEBUGGER_CMD__";
const EXCHANGE_FILENAMES = new Set([
  "icmexchange.exe",
  "iexchange.exe",
  "wspromexchange.exe",
  "wsproexchange.exe"
]);

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "icmRubyDebugger.debugCurrentFile",
      () => debugCurrentRubyFile()
    ),
    vscode.commands.registerCommand(
      "icmRubyDebugger.runCurrentFile",
      () => runCurrentRubyFile(context)
    ),
    vscode.commands.registerCommand(
      "icmRubyDebugger.selectExchangeExecutable",
      () => selectExchangeExecutable()
    ),
    vscode.debug.registerDebugConfigurationProvider(
      DEBUG_TYPE,
      new IcmRubyConfigurationProvider()
    ),
    vscode.debug.registerDebugAdapterDescriptorFactory(
      DEBUG_TYPE,
      new IcmRubyDebugAdapterFactory(context)
    )
  );
}

function deactivate() {}

class IcmRubyConfigurationProvider {
  resolveDebugConfiguration(folder, config) {
    if (!config.type && !config.request && !config.name) {
      const editor = vscode.window.activeTextEditor;
      config.type = DEBUG_TYPE;
      config.request = "launch";
      config.name = "Debug ICM Ruby Script";
      config.script = editor?.document.uri.scheme === "file" ? editor.document.uri.fsPath : "${file}";
    }

    config.type = config.type || DEBUG_TYPE;
    config.request = config.request || "launch";
    config.name = config.name || "Debug ICM Ruby Script";
    config.script = config.script || "${file}";
    if (config.script === "${file}") {
      const editor = vscode.window.activeTextEditor;
      if (editor?.document.uri.scheme === "file") {
        config.script = editor.document.uri.fsPath;
      }
    }
    config.exchangeExecutable = config.exchangeExecutable || getConfig().get("exchangeExecutable", "");
    config.productCode = config.productCode ?? getConfig().get("productCode", "/ICM");
    config.args = config.args || getConfig().get("scriptArgs", []);
    config.breakOnStart = config.breakOnStart ?? getConfig().get("breakOnStart", false);
    return config;
  }
}

class IcmRubyDebugAdapterFactory {
  constructor(context) {
    this.context = context;
  }

  createDebugAdapterDescriptor() {
    return new vscode.DebugAdapterInlineImplementation(
      new IcmRubyDebugSession(this.context)
    );
  }
}

class IcmRubyDebugSession {
  constructor(context) {
    this.context = context;
    this.sequence = 1;
    this.rubyRequestSequence = 1;
    this.breakpointSequence = 1;
    this.breakpoints = new Map();
    this.variableHandles = new Map();
    this.nextVariableReference = 1000;
    this.pendingRubyRequests = new Map();
    this.frames = [];
    this.launchArgs = undefined;
    this.process = undefined;
    this.stdoutBuffer = "";
    this.stderrBuffer = "";
    this.started = false;
    this.terminated = false;
    this.stopped = false;
    this._onDidSendMessage = new vscode.EventEmitter();
    this.onDidSendMessage = this._onDidSendMessage.event;
  }

  handleMessage(message) {
    if (message.type !== "request") {
      return;
    }

    this.dispatchRequest(message).catch((error) => {
      this.sendResponse(message, {}, false, error.message || String(error));
    });
  }

  async dispatchRequest(request) {
    switch (request.command) {
      case "initialize":
        this.sendResponse(request, {
          supportsConfigurationDoneRequest: true,
          supportsEvaluateForHovers: true,
          supportsConditionalBreakpoints: true,
          supportsHitConditionalBreakpoints: true,
          supportsStepInTargetsRequest: false,
          supportsTerminateRequest: true
        });
        this.sendEvent("initialized");
        break;

      case "launch":
        this.launchArgs = request.arguments || {};
        this.sendResponse(request);
        break;

      case "setBreakpoints":
        this.handleSetBreakpoints(request);
        break;

      case "setExceptionBreakpoints":
        this.sendResponse(request, { breakpoints: [] });
        break;

      case "configurationDone":
        await this.startProcess();
        this.sendResponse(request);
        break;

      case "threads":
        this.sendResponse(request, {
          threads: [{ id: 1, name: "ICM Exchange Ruby" }]
        });
        break;

      case "stackTrace":
        this.handleStackTrace(request);
        break;

      case "scopes":
        this.handleScopes(request);
        break;

      case "variables":
        this.handleVariables(request);
        break;

      case "evaluate":
        this.handleEvaluate(request);
        break;

      case "continue":
        this.resume(request, "continue");
        break;

      case "next":
        this.resume(request, "next");
        break;

      case "stepIn":
        this.resume(request, "stepIn");
        break;

      case "stepOut":
        this.resume(request, "stepOut");
        break;

      case "pause":
        this.sendResponse(request, {}, false, "Pause is not available until the Ruby code reaches debugger.rb.");
        break;

      case "terminate":
      case "disconnect":
        this.terminateProcess();
        this.sendResponse(request);
        break;

      default:
        this.sendResponse(request);
        break;
    }
  }

  handleSetBreakpoints(request) {
    const sourcePath = normalizeFilePath(request.arguments?.source?.path);
    const requestedBreakpoints = request.arguments?.breakpoints || [];
    const responseBreakpoints = requestedBreakpoints.map((bp) => {
      const id = this.breakpointSequence++;
      return {
        id,
        verified: true,
        line: bp.line,
        source: request.arguments.source
      };
    });

    if (sourcePath) {
      this.breakpoints.set(sourcePath.toLowerCase(), requestedBreakpoints.map((bp, index) => ({
        id: responseBreakpoints[index].id,
        file: sourcePath,
        line: bp.line,
        condition: bp.condition,
        hitCondition: bp.hitCondition
      })));
    }

    this.sendResponse(request, { breakpoints: responseBreakpoints });
  }

  handleStackTrace(request) {
    const startFrame = request.arguments?.startFrame || 0;
    const levels = request.arguments?.levels || this.frames.length;
    const selected = this.frames.slice(startFrame, startFrame + levels);
    const stackFrames = selected.map((frame) => ({
      id: frame.index + 1,
      name: frame.name || "(top level)",
      source: {
        name: path.basename(frame.file || this.launchArgs?.script || "script.rb"),
        path: frame.file || this.launchArgs?.script
      },
      line: frame.line || 1,
      column: 1
    }));

    this.sendResponse(request, {
      stackFrames,
      totalFrames: this.frames.length
    });
  }

  handleScopes(request) {
    const frameIndex = Math.max((request.arguments?.frameId || 1) - 1, 0);
    const scopes = [
      {
        name: "Locals",
        variablesReference: this.createVariableReference({ frameIndex, scope: "locals" }),
        expensive: false
      },
      {
        name: "Instance",
        variablesReference: this.createVariableReference({ frameIndex, scope: "instance" }),
        expensive: false
      },
      {
        name: "Globals",
        variablesReference: this.createVariableReference({ frameIndex, scope: "globals" }),
        expensive: true
      }
    ];

    this.sendResponse(request, { scopes });
  }

  handleVariables(request) {
    const handle = this.variableHandles.get(request.arguments?.variablesReference);
    if (!handle || !this.stopped) {
      this.sendResponse(request, { variables: [] });
      return;
    }

    this.sendRubyCommand("variables", handle, request);
  }

  handleEvaluate(request) {
    if (!this.stopped) {
      this.sendResponse(request, {
        result: "The script is running.",
        variablesReference: 0
      });
      return;
    }

    this.sendRubyCommand("evaluate", {
      expression: request.arguments?.expression || "",
      frameIndex: Math.max((request.arguments?.frameId || 1) - 1, 0)
    }, request);
  }

  resume(request, command) {
    if (!this.stopped) {
      this.sendResponse(request);
      return;
    }

    this.stopped = false;
    this.variableHandles.clear();
    this.sendRubyCommand(command);
    this.sendResponse(request, { allThreadsContinued: true });
    this.sendEvent("continued", { threadId: 1, allThreadsContinued: true });
  }

  async startProcess() {
    if (this.started) {
      return;
    }
    this.started = true;

    const launchArgs = this.launchArgs || {};
    const script = normalizeFilePath(launchArgs.script);
    if (!script || !fs.existsSync(script)) {
      throw new Error(`Ruby script was not found: ${launchArgs.script}`);
    }

    const exchangeExecutable = await resolveExchangeExecutable(launchArgs.exchangeExecutable);
    if (!exchangeExecutable) {
      throw new Error("No ICM Exchange executable was selected.");
    }

    const bootstrapPath = await writeDebugBootstrap(
      this.context,
      script,
      this.flattenBreakpoints(),
      !!launchArgs.breakOnStart
    );

    const productCode = launchArgs.productCode ?? getConfig().get("productCode", "/ICM");
    const args = [bootstrapPath];
    if (productCode) {
      args.push(productCode);
    }
    for (const arg of launchArgs.args || []) {
      args.push(String(arg));
    }

    this.sendOutput("console", `${exchangeExecutable} ${args.join(" ")}${os.EOL}`);
    this.process = childProcess.spawn(exchangeExecutable, args, {
      cwd: path.dirname(script),
      windowsHide: false
    });

    this.sendEvent("process", {
      name: path.basename(exchangeExecutable),
      systemProcessId: this.process.pid,
      isLocalProcess: true,
      startMethod: "launch"
    });

    this.process.stdout.on("data", (chunk) => this.consumeOutput("stdout", chunk));
    this.process.stderr.on("data", (chunk) => this.consumeOutput("stderr", chunk));
    this.process.on("error", (error) => {
      this.sendOutput("stderr", `${error.message}${os.EOL}`);
      this.sendTerminated();
    });
    this.process.on("exit", (code, signal) => {
      this.flushOutputBuffer("stdout");
      this.flushOutputBuffer("stderr");
      if (code && code !== 0) {
        this.sendOutput("stderr", `ICM Exchange exited with code ${code}${signal ? ` (${signal})` : ""}.${os.EOL}`);
      }
      this.sendTerminated();
    });
  }

  flattenBreakpoints() {
    const result = [];
    for (const breakpoints of this.breakpoints.values()) {
      for (const breakpoint of breakpoints) {
        result.push({
          file: breakpoint.file,
          line: breakpoint.line,
          condition: breakpoint.condition,
          hitCondition: breakpoint.hitCondition
        });
      }
    }
    return result;
  }

  consumeOutput(category, chunk) {
    const text = chunk.toString();
    const bufferName = category === "stdout" ? "stdoutBuffer" : "stderrBuffer";
    this[bufferName] += text;

    let newlineIndex;
    while ((newlineIndex = this[bufferName].indexOf("\n")) >= 0) {
      const line = this[bufferName].slice(0, newlineIndex).replace(/\r$/, "");
      this[bufferName] = this[bufferName].slice(newlineIndex + 1);
      this.consumeLine(category, line);
    }
  }

  consumeLine(category, line) {
    if (line.startsWith(PROTOCOL_PREFIX)) {
      try {
        const message = JSON.parse(line.slice(PROTOCOL_PREFIX.length));
        this.consumeProtocolMessage(message);
      } catch (error) {
        this.sendOutput("stderr", `Could not parse debugger protocol message: ${error.message}${os.EOL}`);
      }
      return;
    }

    this.sendOutput(category, `${line}${os.EOL}`);
  }

  flushOutputBuffer(category) {
    const bufferName = category === "stdout" ? "stdoutBuffer" : "stderrBuffer";
    if (!this[bufferName]) {
      return;
    }

    const text = this[bufferName];
    this[bufferName] = "";
    this.consumeLine(category, text);
  }

  consumeProtocolMessage(message) {
    if (message.event === "stopped") {
      this.stopped = true;
      this.frames = message.body?.frames || [];
      this.sendEvent("stopped", {
        reason: dapStopReason(message.body?.reason),
        description: message.body?.reason,
        threadId: 1,
        allThreadsStopped: true
      });
      return;
    }

    if (message.event === "output") {
      this.sendOutput(message.body?.category || "stdout", message.body?.output || "");
      return;
    }

    if (message.event === "terminated") {
      this.sendTerminated();
      return;
    }

    if (message.event === "response") {
      const pending = this.pendingRubyRequests.get(message.request_id);
      if (!pending) {
        return;
      }

      this.pendingRubyRequests.delete(message.request_id);
      if (message.command === "variables") {
        this.sendResponse(pending, { variables: message.body?.variables || [] }, message.success !== false, message.message);
      } else if (message.command === "evaluate") {
        this.sendResponse(pending, {
          result: message.body?.result ?? "",
          variablesReference: 0
        }, message.success !== false, message.message);
      } else {
        this.sendResponse(pending, message.body || {}, message.success !== false, message.message);
      }
    }
  }

  sendRubyCommand(command, body = {}, dapRequest = undefined) {
    if (!this.process?.stdin?.writable) {
      if (dapRequest) {
        this.sendResponse(dapRequest, {}, false, "ICM Exchange is not running.");
      }
      return;
    }

    const id = this.rubyRequestSequence++;
    if (dapRequest) {
      this.pendingRubyRequests.set(id, dapRequest);
    }

    this.process.stdin.write(`${COMMAND_PREFIX}${JSON.stringify({ id, command, body })}${os.EOL}`);
  }

  createVariableReference(handle) {
    const reference = this.nextVariableReference++;
    this.variableHandles.set(reference, handle);
    return reference;
  }

  terminateProcess() {
    if (this.process && !this.process.killed) {
      this.sendRubyCommand("terminate");
      setTimeout(() => {
        if (this.process && !this.process.killed) {
          this.process.kill();
        }
      }, 500);
    }
  }

  sendOutput(category, output) {
    this.sendEvent("output", { category, output });
  }

  sendTerminated() {
    if (this.terminated) {
      return;
    }
    this.terminated = true;
    this.sendEvent("terminated");
  }

  sendEvent(event, body = undefined) {
    this._onDidSendMessage.fire({
      seq: this.sequence++,
      type: "event",
      event,
      body
    });
  }

  sendResponse(request, body = {}, success = true, message = undefined) {
    this._onDidSendMessage.fire({
      seq: this.sequence++,
      type: "response",
      request_seq: request.seq,
      success,
      command: request.command,
      message,
      body
    });
  }
}

async function debugCurrentRubyFile() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.uri.scheme !== "file") {
    vscode.window.showWarningMessage("Open a Ruby file before debugging ICM Exchange.");
    return;
  }

  if (editor.document.isDirty) {
    await editor.document.save();
  }

  const folder = vscode.workspace.getWorkspaceFolder(editor.document.uri);
  const config = {
    type: DEBUG_TYPE,
    request: "launch",
    name: "Debug ICM Ruby Script",
    script: editor.document.uri.fsPath,
    exchangeExecutable: getConfig().get("exchangeExecutable", ""),
    productCode: getConfig().get("productCode", "/ICM"),
    args: getConfig().get("scriptArgs", []),
    breakOnStart: getConfig().get("breakOnStart", false)
  };

  await vscode.debug.startDebugging(folder, config);
}

async function runCurrentRubyFile(context) {
  try {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.uri.scheme !== "file") {
      vscode.window.showWarningMessage("Open a Ruby file before running ICM Exchange.");
      return;
    }

    const targetScript = editor.document.uri.fsPath;
    if (editor.document.isDirty) {
      await editor.document.save();
    }

    const exchangeExecutable = await resolveExchangeExecutable();
    if (!exchangeExecutable) {
      return;
    }

    const bootstrapPath = await writeRunBootstrap(context, targetScript);
    const command = buildExchangeCommand(exchangeExecutable, bootstrapPath);
    const terminal = vscode.window.createTerminal(getConfig().get("terminalName", "ICM Exchange Debugger"));
    terminal.show(true);
    terminal.sendText(command, true);
  } catch (error) {
    vscode.window.showErrorMessage(`ICM Ruby Debugger failed: ${error.message || error}`);
  }
}

async function selectExchangeExecutable() {
  const discovered = discoverExchangeExecutables();
  const picks = discovered.map((filePath) => describeExchangeExecutable(filePath));

  picks.push({
    label: "Browse...",
    description: "Choose ICMExchange.exe or IExchange.exe manually",
    filePath: undefined
  });

  const pick = await vscode.window.showQuickPick(picks, {
    placeHolder: "Select the InfoWorks Exchange executable to use"
  });

  if (!pick) {
    return undefined;
  }

  let executable = pick.filePath;
  if (!executable) {
    executable = await browseForExchangeExecutable();
  }

  if (!executable) {
    return undefined;
  }

  await getConfig().update("exchangeExecutable", executable, vscode.ConfigurationTarget.Global);
  vscode.window.showInformationMessage(`ICM Exchange executable set to ${executable}`);
  return executable;
}

async function resolveExchangeExecutable(overridePath = undefined) {
  const candidate = String(overridePath || getConfig().get("exchangeExecutable", "")).trim();
  if (candidate && fs.existsSync(candidate)) {
    return candidate;
  }

  if (candidate) {
    const choice = await vscode.window.showWarningMessage(
      `Configured Exchange executable was not found: ${candidate}`,
      "Select Another",
      "Cancel"
    );
    return choice === "Select Another" ? selectExchangeExecutable() : undefined;
  }

  const discovered = discoverExchangeExecutables();
  if (discovered.length === 1) {
    await getConfig().update("exchangeExecutable", discovered[0], vscode.ConfigurationTarget.Global);
    return discovered[0];
  }

  return selectExchangeExecutable();
}

function discoverExchangeExecutables() {
  const roots = getConfig().get("searchRoots", []);
  const found = [];
  const seen = new Set();

  for (const root of roots) {
    const expandedRoot = expandEnvironmentVariables(root);
    scanForExchangeExecutables(expandedRoot, found, seen, 0);
  }

  found.sort((left, right) => right.localeCompare(left, undefined, { numeric: true }));
  return found;
}

function scanForExchangeExecutables(dir, found, seen, depth) {
  if (!dir || depth > 5 || !fs.existsSync(dir)) {
    return;
  }

  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isFile() && EXCHANGE_FILENAMES.has(entry.name.toLowerCase())) {
      const normalized = fullPath.toLowerCase();
      if (!seen.has(normalized)) {
        seen.add(normalized);
        found.push(fullPath);
      }
    } else if (entry.isDirectory() && shouldScanDirectory(dir, entry.name, depth)) {
      scanForExchangeExecutables(fullPath, found, seen, depth + 1);
    }
  }
}

function shouldScanDirectory(parentDir, name, depth) {
  const lower = name.toLowerCase();
  const skipped = [
    "common files",
    "windows kits",
    "microsoft office",
    "microsoft visual studio",
    "nodejs",
    "windows defender"
  ];

  if (skipped.includes(lower)) {
    return false;
  }

  if (depth === 0 && isProgramFilesRoot(parentDir)) {
    return isLikelyExchangeInstallDirectory(name);
  }

  return true;
}

function isProgramFilesRoot(dir) {
  const normalized = path.normalize(dir).toLowerCase();
  const programFiles = [
    process.env.ProgramFiles,
    process.env["ProgramFiles(x86)"],
    "C:\\Program Files",
    "C:\\Program Files (x86)"
  ]
    .filter(Boolean)
    .map((value) => path.normalize(value).toLowerCase());

  return programFiles.includes(normalized);
}

function isLikelyExchangeInstallDirectory(name) {
  const lower = name.toLowerCase();
  return lower.includes("innovyze") ||
    lower.includes("infoworks") ||
    lower.includes("workgroup client") ||
    lower.includes("autodesk");
}

function describeExchangeExecutable(filePath) {
  const installFolder = path.basename(path.dirname(filePath));
  const executable = path.basename(filePath);
  const version = extractVersion(installFolder);
  return {
    label: version ? `${installFolder} (${executable})` : `${installFolder} - ${executable}`,
    description: filePath,
    detail: version ? `InfoWorks ICM ${version}` : "InfoWorks ICM Exchange executable",
    filePath
  };
}

function extractVersion(text) {
  const match = String(text).match(/\b(\d{4}(?:\.\d+)?|\d+\.\d+)\b/);
  return match ? match[1] : undefined;
}

async function browseForExchangeExecutable() {
  const selected = await vscode.window.showOpenDialog({
    canSelectFiles: true,
    canSelectFolders: false,
    canSelectMany: false,
    filters: {
      "Exchange executable": ["exe"],
      "All files": ["*"]
    },
    title: "Select ICMExchange.exe or IExchange.exe"
  });

  return selected?.[0]?.fsPath;
}

async function writeDebugBootstrap(context, targetScript, breakpoints, breakOnStart) {
  const debuggerPath = path.join(context.extensionPath, "lib", "debugger.rb");
  if (!fs.existsSync(debuggerPath)) {
    throw new Error(`debugger.rb was not found at ${debuggerPath}`);
  }

  const breakpointLines = breakpoints.map((bp) => {
    const condition = bp.condition ? `, condition: ${rubyString(bp.condition)}` : "";
    const hitTarget = parseHitCondition(bp.hitCondition);
    const type = hitTarget ? ", type: :counted" : "";
    const hitTargetArg = hitTarget ? `, hit_target: ${hitTarget}` : "";
    return `RubyDebugger.instance.break_at(${rubyPathString(bp.file)}, ${bp.line}${condition}${type}${hitTargetArg})`;
  });

  const content = [
    "# Auto-generated by the ICM Ruby Debugger VS Code extension.",
    "# This file is intentionally temporary; edit your original script instead.",
    `debugger_path = ${rubyPathString(debuggerPath)}`,
    `target_script = ${rubyPathString(targetScript)}`,
    "",
    "require debugger_path",
    "RubyDebugger.instance.attach_vscode_protocol",
    ...breakpointLines,
    "RubyDebugger.start",
    "",
    "if " + rubyBoolean(breakOnStart),
    "  RubyDebugger.instance.open_repl(TOPLEVEL_BINDING, file: target_script, line: 1, reason: 'start')",
    "end",
    "",
    "$PROGRAM_NAME = target_script",
    "load target_script"
  ].join(os.EOL);

  return writeBootstrapFile(targetScript, "debug", content);
}

async function writeRunBootstrap(context, targetScript) {
  const content = [
    "# Auto-generated by the ICM Ruby Debugger VS Code extension.",
    `target_script = ${rubyPathString(targetScript)}`,
    "$PROGRAM_NAME = target_script",
    "load target_script"
  ].join(os.EOL);

  return writeBootstrapFile(targetScript, "run", content);
}

async function writeBootstrapFile(targetScript, mode, content) {
  const workspaceFolder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(targetScript));
  const baseDir = workspaceFolder
    ? path.join(workspaceFolder.uri.fsPath, ".vscode", "icm-ruby-debugger")
    : path.join(os.tmpdir(), "icm-ruby-debugger");

  await fs.promises.mkdir(baseDir, { recursive: true });

  const safeName = path.basename(targetScript).replace(/[^a-z0-9_.-]/gi, "_");
  const bootstrapPath = path.join(baseDir, `${mode}-${safeName}`);
  await fs.promises.writeFile(bootstrapPath, content, "utf8");
  return bootstrapPath;
}

function buildExchangeCommand(exchangeExecutable, scriptPath) {
  const args = [scriptPath];
  const productCode = getConfig().get("productCode", "/ICM");
  if (productCode) {
    args.push(productCode);
  }

  for (const arg of getConfig().get("scriptArgs", [])) {
    args.push(arg);
  }

  return [exchangeExecutable, ...args].map(quoteForTerminal).join(" ");
}

function parseHitCondition(value) {
  if (!value) {
    return undefined;
  }

  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) {
    return Number(trimmed);
  }

  return undefined;
}

function dapStopReason(reason) {
  const text = String(reason || "breakpoint").toLowerCase();
  if (text.includes("step")) {
    return "step";
  }
  if (text.includes("exception") || text.includes("caught")) {
    return "exception";
  }
  if (text.includes("start")) {
    return "entry";
  }
  return "breakpoint";
}

function quoteForTerminal(value) {
  const text = String(value);
  if (!/[ "'&()<>^|]/.test(text)) {
    return text;
  }

  return `"${text.replace(/"/g, '\\"')}"`;
}

function rubyString(value) {
  return JSON.stringify(String(value));
}

function rubyPathString(value) {
  return rubyString(String(value).replace(/\\/g, "/"));
}

function rubyBoolean(value) {
  return value ? "true" : "false";
}

function normalizeFilePath(value) {
  if (!value) {
    return undefined;
  }

  return String(value).replace(/^file:\/\//, "");
}

function expandEnvironmentVariables(value) {
  return String(value).replace(/%([^%]+)%/g, (_, name) => process.env[name] || `%${name}%`);
}

function getConfig() {
  return vscode.workspace.getConfiguration(CONFIG_SECTION);
}

module.exports = {
  activate,
  deactivate
};
