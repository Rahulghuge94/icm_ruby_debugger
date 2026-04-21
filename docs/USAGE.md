# Using ICM Ruby Debugger

This extension debugs InfoWorks ICM Ruby scripts by launching the embedded Ruby runtime inside `iexchange.exe`.

## Quick Start

1. Open this extension repository in VS Code.
2. Press `F5`.
3. In the Extension Development Host window, open the folder containing your ICM Ruby scripts.
4. Open the `.rb` file you want to debug.
5. Run `ICM Ruby Debugger: Select Exchange Executable`.
6. Pick the exact ICM version you want to use, for example:

   ```text
   C:\Program Files\Innovyze Workgroup Client 2024.5\iexchange.exe
   ```

7. Add breakpoints by clicking left of the line number or pressing `F9`.
8. Run `ICM Ruby Debugger: Debug Current File` or press `F5` with an `icm-ruby` launch configuration selected.

## Launch Command

The extension generates a temporary bootstrap script and launches Exchange like this:

```text
iexchange.exe generated_bootstrap.rb /ICM arg1 arg2 ... argn
```

The bootstrap script:

1. Requires `lib/debugger.rb`.
2. Enables the VS Code debug protocol bridge.
3. Inserts VS Code breakpoints into `RubyDebugger`.
4. Starts `RubyDebugger`.
5. Loads your original target script.

## Choosing ICM Versions

Each ICM version has its own embedded Ruby runtime through its own `iexchange.exe`.

Common paths:

```text
C:\Program Files\Innovyze Workgroup Client 2024.5\iexchange.exe
C:\Program Files\Innovyze Workgroup Client 2023.0\iexchange.exe
```

Use `ICM Ruby Debugger: Select Exchange Executable` whenever you need to switch versions.

## Breakpoints

Supported breakpoint features:

- Line breakpoints
- Conditional breakpoints
- Numeric hit-count breakpoints

Breakpoint setup happens before `RubyDebugger.start`, so the debugger does not trace its own breakpoint insertion.

## Debug Controls

Use the normal VS Code debug controls:

- Continue
- Step Over
- Step Into
- Step Out
- Stop

The Variables, Call Stack, and Debug Console panels are driven by `debugger.rb`.

## Script Arguments

Set global script arguments in VS Code settings:

```json
"icmRubyDebugger.scriptArgs": ["arg1", "arg2"]
```

Or set them in `.vscode/launch.json`:

```json
"args": ["arg1", "arg2"]
```
