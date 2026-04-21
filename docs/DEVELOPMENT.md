# Development

## Repository Layout

```text
.
|-- .vscode/
|   `-- launch.json              # Launches the Extension Development Host
|-- docs/
|   |-- CONFIGURATION.md
|   |-- DEVELOPMENT.md
|   |-- TROUBLESHOOTING.md
|   `-- USAGE.md
|-- example/
|   `-- example.rb               # RubyDebugger API demonstration
|-- examples/
|   |-- launch.icm.json          # Example launch config for script workspaces
|   `-- simple_icm_script.rb     # Small script for breakpoint testing
|-- lib/
|   `-- debugger.rb              # Ruby TracePoint debugger and VS Code protocol bridge
|-- extension.js                 # VS Code extension and inline debug adapter
|-- package.json                 # VS Code extension manifest
|-- README.md
`-- .vscodeignore
```

## Local Development

1. Open this repository in VS Code.
2. Run `npm run check`.
3. Press `F5`.
4. In the Extension Development Host, open a folder containing ICM Ruby scripts.
5. Select an `iexchange.exe` path.
6. Add breakpoints and start debugging.

## Validation

The available local check is:

```powershell
npm run check
```

This validates JavaScript syntax for `extension.js`.

Full validation requires an ICM machine because the Ruby runtime is embedded inside `iexchange.exe`.

## Runtime Architecture

The VS Code side uses an inline Debug Adapter implementation in `extension.js`.

The Ruby side uses `TracePoint` in `lib/debugger.rb`. When debugging through VS Code, the generated bootstrap calls:

```ruby
RubyDebugger.instance.attach_vscode_protocol
RubyDebugger.instance.break_at(...)
RubyDebugger.start
load target_script
```

Communication between Node and embedded Ruby uses line-delimited JSON over standard input and output.
