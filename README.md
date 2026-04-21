# ICM Ruby Debugger

VS Code debug extension for InfoWorks ICM Ruby scripts running through the embedded Ruby runtime in `iexchange.exe`.

InfoWorks ICM does not use system Ruby. Each installed ICM version has its own Exchange executable and embedded Ruby runtime, for example:

```text
C:\Program Files\Innovyze Workgroup Client 2024.5\iexchange.exe
C:\Program Files\Innovyze Workgroup Client 2023.0\iexchange.exe
```

This extension launches the selected `iexchange.exe`, loads `lib/debugger.rb`, inserts VS Code breakpoints, and starts your script.

## Features

- VS Code debugger type: `icm-ruby`
- Version-specific `iexchange.exe` selection
- Launch command shape: `iexchange.exe bootstrap.rb /ICM arg1 arg2 ...`
- Line breakpoints
- Conditional breakpoints
- Numeric hit-count breakpoints
- Continue, Step Over, Step Into, Step Out, Stop
- Call stack
- Locals, instance variables, and globals
- Debug Console expression evaluation
- Script output in the Debug Console

## Quick Start

1. Open this repository in VS Code.
2. Press `F5` to start the Extension Development Host.
3. In the Extension Development Host, open your ICM Ruby script folder.
4. Open the `.rb` file you want to debug.
5. Run `ICM Ruby Debugger: Select Exchange Executable`.
6. Pick the exact ICM version's `iexchange.exe`.
7. Add breakpoints by clicking left of the line number or pressing `F9`.
8. Run `ICM Ruby Debugger: Debug Current File`.

## Commands

- `ICM Ruby Debugger: Debug Current File`
- `ICM Ruby Debugger: Run Current File`
- `ICM Ruby Debugger: Select Exchange Executable`

## Launch Configuration

Create `.vscode/launch.json` in your ICM script workspace:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "icm-ruby",
      "request": "launch",
      "name": "Debug ICM Ruby Script",
      "script": "${file}",
      "exchangeExecutable": "C:\\Program Files\\Innovyze Workgroup Client 2024.5\\iexchange.exe",
      "productCode": "/ICM",
      "args": [],
      "breakOnStart": false
    }
  ]
}
```

You can omit `exchangeExecutable` if you already selected it with `ICM Ruby Debugger: Select Exchange Executable`.

## Repository Layout

```text
.
|-- .vscode/                    # Extension development launch config
|-- docs/                       # Usage, configuration, troubleshooting, development notes
|-- example/                    # Existing RubyDebugger API demo
|-- examples/                   # ICM debug examples and launch config
|-- lib/debugger.rb             # Ruby TracePoint debugger and VS Code bridge
|-- extension.js                # VS Code extension and inline debug adapter
|-- package.json                # Extension manifest
`-- README.md
```

## Documentation

- [Usage](docs/USAGE.md)
- [Configuration](docs/CONFIGURATION.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Development](docs/DEVELOPMENT.md)

## Development Check

```powershell
npm run check
```

Full runtime testing requires an Infoworks ICM installed with exchange license.
