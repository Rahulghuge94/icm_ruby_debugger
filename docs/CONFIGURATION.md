# Configuration

## VS Code Settings

| Setting | Default | Description |
| --- | --- | --- |
| `icmRubyDebugger.exchangeExecutable` | `""` | Full path to the selected `iexchange.exe` or `ICMExchange.exe`. |
| `icmRubyDebugger.productCode` | `"/ICM"` | Product/incarnation argument passed after the bootstrap script. |
| `icmRubyDebugger.scriptArgs` | `[]` | Arguments passed after `/ICM`. |
| `icmRubyDebugger.breakOnStart` | `false` | Stop before loading the target script. |
| `icmRubyDebugger.searchRoots` | `%ProgramFiles%`, `%ProgramFiles(x86)%`, Autodesk folders | Roots scanned for versioned ICM Exchange executables. |
| `icmRubyDebugger.terminalName` | `"ICM Exchange Debugger"` | Terminal name used by the non-debug run command. |

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

You can omit `exchangeExecutable` if it has already been selected with `ICM Ruby Debugger: Select Exchange Executable`.

## Generated Files

During debugging, the extension writes bootstrap files under the script workspace:

```text
.vscode/icm-ruby-debugger/
```

These are generated files and should not be edited by hand.
