# example.rb — Demonstrates the RubyDebugger feature set.
# Run with: ruby example.rb
#
# This file does NOT enter an interactive loop; instead it configures and
# exercises the programmatic API so you can see all features without needing
# a real TTY attached.  To use interactively, put `debugger` inside any
# method and run your script normally.

$LOAD_PATH.unshift File.dirname(__FILE__)
require 'debugger'

puts RubyDebugger::Color.bold(RubyDebugger::Color.blue(
  "=== RubyDebugger #{RubyDebugger::VERSION} Feature Demo ==="))
puts

# ---------------------------------------------------------------------------
# 1. PrettyPrinter
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- PrettyPrinter ---")
pp_mod = RubyDebugger::PrettyPrinter
puts pp_mod.format(nil)
puts pp_mod.format(true)
puts pp_mod.format(42)
puts pp_mod.format(3.14)
puts pp_mod.format(:hello)
puts pp_mod.format("a string with words")
puts pp_mod.format([1, 2, 3, :sym, nil, true])
puts pp_mod.format({name: 'Ruby', version: 2.4, cool: true})
puts pp_mod.format((1..50).to_a)           # truncated array
puts pp_mod.format('x' * 250)              # truncated string
puts

# ---------------------------------------------------------------------------
# 2. Breakpoint creation & display
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- Breakpoints ---")
dbg = RubyDebugger.instance

bp1 = dbg.break_at(__FILE__, 80)
bp2 = dbg.break_at(__FILE__, 90, condition: 'x > 10')
bp3 = dbg.break_once(__FILE__, 100)
bp4 = dbg.break_count(__FILE__, 110, 3)
bp5 = dbg.break_on_method('MyClass#compute')

puts
puts "All breakpoints:"
dbg.list_breakpoints
puts

# disable / re-enable
dbg.disable_breakpoint(bp2.id)
dbg.enable_breakpoint(bp2.id)
puts

# ---------------------------------------------------------------------------
# 3. Watchpoints
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- Watchpoints ---")
wp1 = dbg.watch('@counter')
wp2 = dbg.watch('result')
dbg.list_watchpoints
puts

# ---------------------------------------------------------------------------
# 4. Catchpoints
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- Catchpoints ---")
dbg.catch_exception('RuntimeError')
dbg.catch_exception('ArgumentError')
dbg.list_catchpoints
puts

# ---------------------------------------------------------------------------
# 5. SourceCache
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- Source snippet ---")
lines = dbg.source_cache.snippet(__FILE__, 10, 3)
lines.each do |n, text|
  marker = n == 10 ? '=>' : '  '
  puts "  #{n.to_s.rjust(4)} #{marker} #{text.chomp}"
end
puts

# ---------------------------------------------------------------------------
# 6. CommandHistory
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- CommandHistory ---")
hist = RubyDebugger::CommandHistory.new(5)
%w[next step continue backtrace step].each { |c| hist.push(c) }
puts "History: #{hist.all.inspect}"
puts "Previous: #{hist.previous}"
puts "Previous: #{hist.previous}"
puts

# ---------------------------------------------------------------------------
# 7. ExecutionTracer — capture a few lines to a StringIO
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- ExecutionTracer ---")
buf = StringIO.new
tracer = RubyDebugger::ExecutionTracer.new(
  output: buf,
  filter: Regexp.new(Regexp.escape(__FILE__))  # only this file
)
tracer.start

# Tiny bit of code for the tracer to observe
x = 2 + 2
y = x * 3

tracer.stop
output = buf.string.split("\n").first(6)
output.each { |l| puts "  #{l}" }
puts "(tracer captured #{buf.string.split("\n").size} events)" if buf.string.split("\n").size > 6
puts

# ---------------------------------------------------------------------------
# 8. Thread listing
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- Threads ---")
# Spin a background thread so there is more than one
t = Thread.new { sleep 0.5 }
dbg.send(:print_threads)   # call private via send for demo purposes
t.join
puts

# ---------------------------------------------------------------------------
# 9. Delete breakpoints
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- Delete breakpoints ---")
dbg.delete_breakpoint(bp3.id)
dbg.delete_breakpoint(9999)   # non-existent
puts
puts "Remaining breakpoints:"
dbg.list_breakpoints
puts

# ---------------------------------------------------------------------------
# 10. Kernel#debugger integration note
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- Kernel integration ---")
puts "Object.ancestors includes KernelMethods: " +
     Object.ancestors.include?(RubyDebugger::KernelMethods).to_s
puts "Respond to `debugger`: #{Object.new.respond_to?(:debugger, true)}"
puts "Respond to `bp_here` : #{Object.new.respond_to?(:bp_here,  true)}"
puts

# ---------------------------------------------------------------------------
# 11. Post-mortem hook registration (just registers; won't fire in demo)
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.cyan("--- Post-mortem ---")
puts "(post_mortem! registers an at_exit hook — skipped in demo to avoid exit interception)"
puts

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
puts RubyDebugger::Color.bold(RubyDebugger::Color.green("All features exercised successfully."))
puts
puts RubyDebugger::Color.yellow("To use interactively:")
puts "  require_relative 'debugger'"
puts "  # ... your code ..."
puts "  debugger   # drops into REPL at this line"