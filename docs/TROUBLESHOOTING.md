# Troubleshooting

## `Git installation not found`

This message is from VS Code's built-in Git extension, not from ICM Ruby Debugger. The debugger does not require Git.

You can ignore the message, disable VS Code's built-in Git extension, or install Git separately.

## Breakpoints Cannot Be Added

Check these items:

- The file extension is `.rb`.
- The VS Code language mode in the lower-right corner says `Ruby`.
- You are running the latest extension code from this repository.
- Restart the Extension Development Host after changing `package.json`.

This extension contributes the Ruby language and breakpoint support for `.rb` files.

## Breakpoint Crash With `deadlock; recursive locking`

This was caused by starting TracePoint before inserting generated breakpoints. The current bootstrap inserts breakpoints before `RubyDebugger.start`, and `debugger.rb` suspends tracing during debugger bookkeeping.

If you still see this error, make sure the ICM machine is running the updated copies of:

```text
extension.js
lib\debugger.rb
package.json
```

## Syntax Errors In `debugger.rb`

ICM 2024.5 uses embedded Ruby 2.4. Some newer Ruby syntax is not valid there.

The VS Code protocol bridge in `debugger.rb` should avoid newer Ruby syntax. If a syntax error appears, note the line number from the `IExchange.exe` output and update the code to Ruby 2.4-compatible syntax.

## `error reading file $...debug-test.rb$`

This usually means `IExchange.exe` failed while loading the generated bootstrap script. Read the Ruby exception above this line; that is the real cause.

Common causes:

- Wrong copy of `lib/debugger.rb`.
- Invalid Ruby syntax for embedded Ruby 2.4.
- Wrong `iexchange.exe` version selected.
- Target script path no longer exists.

## Wrong ICM Version Runs

Run `ICM Ruby Debugger: Select Exchange Executable` and choose the intended versioned path:

```text
C:\Program Files\Innovyze Workgroup Client 2024.5\iexchange.exe
C:\Program Files\Innovyze Workgroup Client 2023.0\iexchange.exe
```

The selected path is stored in `icmRubyDebugger.exchangeExecutable`.
