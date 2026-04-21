# debugger.rb — A full-featured Ruby 2.4 debugger written from scratch.
# Only uses modules packaged with Ruby (no gems).
#
# Features:
#   - Breakpoints (line, method, conditional, one-shot, counted)
#   - Watchpoints (break on variable change)
#   - Step / Next / Continue / Finish
#   - Call stack & frame inspection
#   - Variable inspection (local, instance, class, global)
#   - Expression evaluation in the current binding
#   - Thread awareness
#   - Catch-points (break on exception)
#   - Command history
#   - Source listing with line numbers
#   - Post-mortem debugging mode
#   - Tracing (execution trace to STDOUT or file)
#   - Simple pretty-printer for inspected values
#   - Colour terminal output

require 'set'
require 'pp'
require 'ostruct'
require 'monitor'
require 'stringio'
require 'json'

# ---------------------------------------------------------------------------
# RubyDebugger — top-level namespace
# ---------------------------------------------------------------------------
module RubyDebugger

  VERSION = '1.0.0'.freeze

  # ANSI colour helpers (degrade gracefully when stdout is not a tty)
  module Color
    CODES = { reset: 0, bold: 1, red: 31, green: 32, yellow: 33,
              blue: 34, magenta: 35, cyan: 36, white: 37, grey: 90 }.freeze

    def self.enabled?
      $stdout.tty?
    end

    def self.colorize(text, *codes)
      return text unless enabled?
      "\e[#{codes.map { |c| CODES.fetch(c, 0) }.join(';')}m#{text}\e[0m"
    end

    CODES.each_key do |name|
      define_method(name) { |text| Color.colorize(text, name) }
      module_function name
    end
  end

  # ---------------------------------------------------------------------------
  # SourceCache — reads and caches source files for listing
  # ---------------------------------------------------------------------------
  class SourceCache
    def initialize
      @files = {}  # path -> Array<String> of lines (1-indexed via [lineno-1])
      @lock  = Monitor.new
    end

    def lines_for(file)
      @lock.synchronize do
        @files[file] ||= load_file(file)
      end
    end

    def snippet(file, center, context = 5)
      all = lines_for(file)
      return [] if all.nil?
      first = [center - context, 1].max
      last  = [center + context, all.size].min
      (first..last).map { |n| [n, all[n - 1]] }
    end

    private

    def load_file(path)
      return nil unless path && File.exist?(path)
      File.readlines(path)
    rescue
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Breakpoint — represents a single breakpoint
  # ---------------------------------------------------------------------------
  class Breakpoint
    @@counter = 0

    attr_reader   :id, :file, :line, :method_name, :condition, :type
    attr_accessor :enabled, :hit_count, :hit_target

    def initialize(opts = {})
      @@counter += 1
      @id          = @@counter
      @file        = opts[:file]
      @line        = opts[:line]
      @method_name = opts[:method]
      @condition   = opts[:condition]   # String to eval, or nil
      @type        = opts[:type] || :line  # :line | :method | :one_shot | :counted
      @enabled     = true
      @hit_count   = 0
      @hit_target  = opts[:hit_target]  # for :counted type
    end

    def matches_location?(file, line)
      return false unless @enabled
      return false unless @type == :line || @type == :one_shot || @type == :counted
      # normalise paths so relative == absolute
      File.expand_path(@file.to_s) == File.expand_path(file.to_s) && @line == line
    end

    def matches_method?(klass, meth)
      return false unless @enabled
      return false unless @type == :method
      @method_name.to_s == "#{klass}##{meth}" ||
        @method_name.to_s == meth.to_s
    end

    def condition_met?(binding_ctx)
      return true if @condition.nil? || @condition.strip.empty?
      !!binding_ctx.eval(@condition)
    rescue => e
      warn "[Debugger] Condition eval error: #{e.message}"
      false
    end

    def trigger!(binding_ctx)
      @hit_count += 1
      case @type
      when :one_shot
        @enabled = false
      when :counted
        return false if @hit_count < @hit_target
      end
      condition_met?(binding_ctx)
    end

    def to_s
      status = @enabled ? Color.green('enabled') : Color.red('disabled')
      loc = @file ? "#{File.basename(@file.to_s)}:#{@line}" : @method_name
      cond = @condition ? " if #{Color.yellow(@condition)}" : ''
      hits = @hit_count > 0 ? " (hits: #{@hit_count})" : ''
      "##{@id} [#{status}] #{loc}#{cond}#{hits}"
    end
  end

  # ---------------------------------------------------------------------------
  # Watchpoint — break when a variable changes value
  # ---------------------------------------------------------------------------
  class Watchpoint
    @@counter = 0
    attr_reader :id, :expression, :last_value

    def initialize(expression)
      @@counter += 1
      @id         = @@counter
      @expression = expression
      @last_value = :__unset__
    end

    # Evaluate and return true if the value changed
    def changed?(binding_ctx)
      current = binding_ctx.eval(@expression)
      if @last_value == :__unset__ || current != @last_value
        @old_value  = @last_value
        @last_value = current
        return @old_value != :__unset__  # don't fire on first eval
      end
      false
    rescue
      false
    end

    def change_description
      "#{@expression}: #{@old_value.inspect} → #{@last_value.inspect}"
    end

    def to_s
      "##{@id} watch #{Color.yellow(@expression)} (last: #{@last_value.inspect})"
    end
  end

  # ---------------------------------------------------------------------------
  # CatchPoint — break when a specific exception class is raised
  # ---------------------------------------------------------------------------
  class CatchPoint
    attr_reader :exception_class_name
    def initialize(klass_name); @exception_class_name = klass_name; end
    def matches?(exc)
      exc.class.ancestors.any? { |a| a.name == @exception_class_name }
    end
    def to_s; "catch #{Color.magenta(@exception_class_name)}"; end
  end

  # ---------------------------------------------------------------------------
  # Frame — one entry in the call stack
  # ---------------------------------------------------------------------------
  Frame = Struct.new(:binding, :file, :line, :method_name, :klass) do
    def to_s
      loc = "#{File.basename(file.to_s)}:#{line}"
      meth = method_name ? " in #{klass}##{method_name}" : ''
      "#{loc}#{meth}"
    end
  end

  # ---------------------------------------------------------------------------
  # ExecutionTracer — records a trace log of executed lines
  # ---------------------------------------------------------------------------
  class ExecutionTracer
    def initialize(output: $stdout, filter: nil)
      @output = output
      @filter = filter   # Regexp or nil (nil = trace everything)
      @active = false
    end

    def start
      @active = true
      @tp = TracePoint.new(:line, :call, :return) do |tp|
        next unless @active
        next if @filter && tp.path !~ @filter

        event = tp.event
        file  = tp.path
        line  = tp.lineno
        meth  = tp.method_id

        case event
        when :line
          @output.puts Color.grey("TRACE #{file}:#{line}")
        when :call
          @output.puts Color.cyan("CALL  #{file}:#{line} → #{meth}")
        when :return
          @output.puts Color.grey("RET   #{file}:#{line} ← #{meth}")
        end
      end
      @tp.enable
    end

    def stop
      @active = false
      @tp&.disable
    end

    def active?; @active; end
  end

  # ---------------------------------------------------------------------------
  # CommandHistory
  # ---------------------------------------------------------------------------
  class CommandHistory
    def initialize(max = 100)
      @entries = []
      @max     = max
      @pos     = 0
    end

    def push(cmd)
      return if cmd.strip.empty?
      @entries.delete(cmd)
      @entries << cmd
      @entries.shift if @entries.size > @max
      @pos = @entries.size
    end

    def previous
      @pos = [@pos - 1, 0].max
      @entries[@pos]
    end

    def next_cmd
      @pos = [@pos + 1, @entries.size].min
      @entries[@pos]
    end

    def all; @entries.dup; end
  end

  # ---------------------------------------------------------------------------
  # PrettyPrinter — formats Ruby objects nicely for the REPL
  # ---------------------------------------------------------------------------
  module PrettyPrinter
    MAX_LEN   = 2000
    MAX_DEPTH = 4

    def self.format(obj, depth = 0)
      return '…' if depth > MAX_DEPTH

      case obj
      when NilClass  then Color.grey('nil')
      when TrueClass, FalseClass then Color.yellow(obj.to_s)
      when Integer, Float        then Color.cyan(obj.to_s)
      when Symbol    then Color.magenta(":#{obj}")
      when String
        truncated = obj.length > 200 ? obj[0, 200] + '…' : obj
        Color.green(truncated.inspect)
      when Array
        inner = obj.first(10).map { |e| format(e, depth + 1) }.join(', ')
        suffix = obj.size > 10 ? ", … (#{obj.size} total)" : ''
        "[#{inner}#{suffix}]"
      when Hash
        pairs = obj.first(10).map { |k, v| "#{format(k, depth+1)} => #{format(v, depth+1)}" }.join(', ')
        suffix = obj.size > 10 ? ", … (#{obj.size} total)" : ''
        "{#{pairs}#{suffix}}"
      else
        s = obj.inspect
        s.length > MAX_LEN ? s[0, MAX_LEN] + '…' : s
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Core — the central debugger singleton
  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # VSCodeProtocol - JSON line protocol used by the VS Code debug adapter
  # ---------------------------------------------------------------------------
  class VSCodeProtocol
    PREFIX = '__ICM_RUBY_DEBUGGER__'.freeze
    COMMAND_PREFIX = '__ICM_RUBY_DEBUGGER_CMD__'.freeze

    def initialize(core, input: $stdin, output: $stdout)
      @core = core
      @input = input
      @output = output
      @frame_bindings = {}
      @current_binding = nil
    end

    def stopped(binding_ctx, file:, line:, reason:)
      @current_binding = binding_ctx
      frames = build_frames(binding_ctx, file, line)
      emit('stopped', reason: reason, file: file, line: line, frames: frames)

      loop do
        begin
          raw = @input.gets
          terminate! if raw.nil?
          next unless raw.start_with?(COMMAND_PREFIX)

          message = JSON.parse(raw[COMMAND_PREFIX.length..-1])
          return if handle_command(message)
        rescue => e
          emit('output', category: 'stderr', output: "Debugger protocol error: #{e.class}: #{e.message}\n")
        end
      end
    end

    private

    def handle_command(message)
      command = message['command']
      body = message['body'] || {}

      case command
      when 'continue'
        @core.vscode_continue
        true
      when 'next'
        @core.vscode_next
        true
      when 'stepIn'
        @core.vscode_step
        true
      when 'stepOut'
        @core.vscode_finish
        true
      when 'evaluate'
        respond(message, evaluate(body))
        false
      when 'variables'
        respond(message, variables(body))
        false
      when 'terminate'
        terminate!
      else
        respond(message, {}, success: false, error: "Unknown debugger command: #{command}")
        false
      end
    end

    def build_frames(binding_ctx, file, line)
      raw_frames = @core.call_stack.first(50)
      raw_frames = [Frame.new(binding_ctx, file, line, nil, nil)] if raw_frames.empty?

      if raw_frames.first.file != file || raw_frames.first.line != line
        raw_frames = [Frame.new(binding_ctx, file, line, nil, nil)] + raw_frames
      end

      @frame_bindings = {}
      raw_frames.each_with_index.map do |frame, index|
        @frame_bindings[index] = frame.binding || binding_ctx
        {
          index: index,
          file: frame.file || file,
          line: frame.line || line,
          name: frame_name(frame)
        }
      end
    end

    def frame_name(frame)
      if frame.method_name
        klass = frame.klass ? frame.klass.to_s : 'Object'
        "#{klass}##{frame.method_name}"
      else
        File.basename(frame.file.to_s)
      end
    end

    def evaluate(body)
      expr = body['expression'].to_s
      frame_index = body['frameIndex'].to_i
      bnd = binding_for(frame_index)
      result = bnd.eval(expr, '(debugger)', 1)
      { result: safe_format(result) }
    rescue => e
      { result: "#{e.class}: #{e.message}" }
    end

    def variables(body)
      frame_index = body['frameIndex'].to_i
      scope = body['scope'].to_s
      bnd = binding_for(frame_index)

      values = case scope
               when 'locals' then local_variables_for(bnd)
               when 'instance' then instance_variables_for(bnd)
               when 'globals' then global_variables_for
               else []
               end

      { variables: values }
    end

    def local_variables_for(bnd)
      variables = []
      bnd.local_variables.sort.each do |name|
        begin
          variables << dap_variable(name.to_s, bnd.local_variable_get(name))
        rescue => e
          variables << dap_variable(name.to_s, "#{e.class}: #{e.message}")
        end
      end
      variables
    end

    def instance_variables_for(bnd)
      obj = bnd.eval('self')
      variables = []
      obj.instance_variables.sort.each do |name|
        begin
          variables << dap_variable(name.to_s, obj.instance_variable_get(name))
        rescue => e
          variables << dap_variable(name.to_s, "#{e.class}: #{e.message}")
        end
      end
      variables
    rescue => e
      [dap_variable('error', "#{e.class}: #{e.message}")]
    end

    def global_variables_for
      variables = []
      names = global_variables
        .reject { |name| name.to_s.start_with?('$LOADED', '$"') }
        .sort
        .first(100)

      names.each do |name|
        begin
          variables << dap_variable(name.to_s, eval(name.to_s))
        rescue => e
          variables << dap_variable(name.to_s, "#{e.class}: #{e.message}")
        end
      end

      variables
    end

    def dap_variable(name, value)
      {
        name: name,
        value: safe_format(value),
        variablesReference: 0
      }
    end

    def binding_for(frame_index)
      @frame_bindings[frame_index] || @current_binding || TOPLEVEL_BINDING
    end

    def safe_format(value)
      PrettyPrinter.format(value).to_s
    rescue
      value.inspect
    end

    def respond(message, body, success: true, error: nil)
      payload = {
        event: 'response',
        request_id: message['id'],
        command: message['command'],
        success: success,
        body: body
      }
      payload[:message] = error if error
      write(payload)
    end

    def emit(event, body = {})
      write(event: event, body: body)
    end

    def write(payload)
      @output.puts PREFIX + JSON.generate(payload)
      @output.flush
    end

    def terminate!
      emit('terminated')
      @core.stop
      exit(0)
    end
  end

  class Core
    include MonitorMixin

    attr_reader :breakpoints, :watchpoints, :catchpoints, :call_stack,
                :current_frame_index, :source_cache, :tracer

    def initialize
      super  # MonitorMixin
      @breakpoints       = []
      @watchpoints       = []
      @catchpoints       = []
      @call_stack        = []
      @current_frame_index = 0
      @source_cache      = SourceCache.new
      @history           = CommandHistory.new
      @tracer            = ExecutionTracer.new
      @active            = false
      @step_mode         = :run   # :run | :step | :next | :finish
      @step_depth        = 0
      @post_mortem       = false
      @post_mortem_binding = nil
      @setup_done        = false
      @vscode_protocol   = nil
      @suspend_trace      = false

      # Internal TracePoint
      @trace = nil
    end

    # -----------------------------------------------------------------------
    # Public API
    # -----------------------------------------------------------------------

    def start
      return if @active
      @active = true
      setup_tracepoints
      self
    end

    def stop
      @active = false
      @trace&.disable
      @tracer.stop
      @trace = nil
    end

    # Add a line breakpoint
    def break_at(file, line, condition: nil, type: :line, hit_target: nil)
      with_trace_suspended do
        bp = Breakpoint.new(file: File.expand_path(file), line: line,
                            condition: condition, type: type,
                            hit_target: hit_target)
        synchronize { @breakpoints << bp }
        puts "[Debugger] #{Color.green('Breakpoint')} ##{bp.id} set at #{file}:#{line}"
        bp
      end
    end

    # Add a one-shot breakpoint
    def break_once(file, line)
      break_at(file, line, type: :one_shot)
    end

    # Add a counted breakpoint (fires on the Nth hit)
    def break_count(file, line, n)
      break_at(file, line, type: :counted, hit_target: n)
    end

    # Add a method breakpoint
    def break_on_method(method_name)
      with_trace_suspended do
        bp = Breakpoint.new(method: method_name, type: :method)
        synchronize { @breakpoints << bp }
        puts "[Debugger] #{Color.green('Method breakpoint')} ##{bp.id} on #{method_name}"
        bp
      end
    end

    # Watch expression
    def watch(expression)
      with_trace_suspended do
        wp = Watchpoint.new(expression)
        synchronize { @watchpoints << wp }
        puts "[Debugger] #{Color.green('Watchpoint')} ##{wp.id} on #{expression}"
        wp
      end
    end

    # Catch exception
    def catch_exception(klass_name)
      with_trace_suspended do
        cp = CatchPoint.new(klass_name)
        synchronize { @catchpoints << cp }
        puts "[Debugger] #{Color.green('Catchpoint')} for #{klass_name}"
        cp
      end
    end

    def delete_breakpoint(id)
      removed = nil
      synchronize { removed = @breakpoints.reject! { |b| b.id == id } }
      puts removed ? "[Debugger] Breakpoint ##{id} deleted." : "[Debugger] No breakpoint ##{id}."
    end

    def enable_breakpoint(id);  toggle_bp(id, true);  end
    def disable_breakpoint(id); toggle_bp(id, false); end

    def list_breakpoints
      if @breakpoints.empty?
        puts Color.grey('No breakpoints set.')
      else
        @breakpoints.each { |b| puts "  #{b}" }
      end
    end

    def list_watchpoints
      if @watchpoints.empty?
        puts Color.grey('No watchpoints set.')
      else
        @watchpoints.each { |w| puts "  #{w}" }
      end
    end

    def list_catchpoints
      if @catchpoints.empty?
        puts Color.grey('No catchpoints set.')
      else
        @catchpoints.each { |c| puts "  #{c}" }
      end
    end

    # Enable post-mortem debugging (call before running code)
    def post_mortem!
      @post_mortem = true
      at_exit do
        if $! && !$!.is_a?(SystemExit)
          puts Color.red("\n[Debugger] Post-mortem: #{$!.class}: #{$!.message}")
          $!.backtrace.first(5).each { |l| puts Color.grey("  #{l}") }
          @post_mortem_binding = $!.__binding__ rescue nil
          open_repl(@post_mortem_binding || TOPLEVEL_BINDING,
                    file: ($!.backtrace_locations&.first&.path rescue '?'),
                    line: ($!.backtrace_locations&.first&.lineno rescue 0),
                    reason: "post-mortem: #{$!.class}")
        end
      end
    end

    # Start / stop execution trace
    def trace!(output: $stdout, filter: nil)
      @tracer = ExecutionTracer.new(output: output, filter: filter)
      @tracer.start
      puts "[Debugger] Tracing #{Color.yellow('started')}."
    end

    def trace_off!
      @tracer.stop
      puts "[Debugger] Tracing #{Color.yellow('stopped')}."
    end

    # Attach the machine protocol used by the VS Code debug adapter.
    def attach_vscode_protocol(input: $stdin, output: $stdout)
      @vscode_protocol = VSCodeProtocol.new(self, input: input, output: output)
      self
    end

    def vscode_continue
      @step_mode = :run
      @step_depth = 0
    end

    def vscode_step
      @step_mode = :step
      @step_depth = 0
    end

    def vscode_next
      @step_mode = :next
      @step_depth = frame_depth
    end

    def vscode_finish
      @step_mode = :finish
      @step_depth = frame_depth
    end

    # Open the REPL at the current location (used by `debugger` helper)
    def open_repl(binding_ctx, file:, line:, reason: 'breakpoint')
      if @vscode_protocol
        @current_binding = binding_ctx
        @vscode_protocol.stopped(binding_ctx, file: file, line: line, reason: reason)
        return
      end

      header(file, line, reason)
      print_source(file, line)
      repl_loop(binding_ctx, file, line)
    end

    # Convenience: embed `debugger` inside user code
    def trigger(binding_ctx, file, line)
      @step_mode = :run
      open_repl(binding_ctx, file: file, line: line, reason: 'debugger call')
    end

    private

    # -----------------------------------------------------------------------
    # TracePoint setup
    # -----------------------------------------------------------------------

    def setup_tracepoints
      @trace = TracePoint.new(:line, :call, :return, :raise) do |tp|
        next unless @active
        next if @suspend_trace
        # Ignore debugger internals
        next if tp.path && tp.path.include?(__FILE__)

        case tp.event
        when :line   then handle_line(tp)
        when :call   then handle_call(tp)
        when :return then handle_return(tp)
        when :raise  then handle_raise(tp)
        end
      end
      @trace.enable
    end

    def handle_line(tp)
      file  = tp.path
      line  = tp.lineno
      bnd   = tp.binding

      # Push frame info
      frame = Frame.new(bnd, file, line, tp.method_id, tp.defined_class)
      push_frame(frame)

      # Check step mode
      stop_reason = @step_mode == :run ? 'breakpoint' : @step_mode.to_s
      should_stop = case @step_mode
                    when :step then true
                    when :next then tp.binding.eval('__method__').nil? || frame_depth == @step_depth
                    when :finish then frame_depth < @step_depth
                    else false
                    end

      # Check watchpoints
      @watchpoints.each do |wp|
        if wp.changed?(bnd)
          puts "\n" + Color.yellow("[Watchpoint ##{wp.id}] #{wp.change_description}")
          stop_reason = 'watchpoint'
          should_stop = true
        end
      end

      # Check line breakpoints
      unless should_stop
        @breakpoints.select { |b| b.matches_location?(file, line) }.each do |bp|
          if bp.trigger!(bnd)
            puts "\n" + Color.yellow("[Breakpoint ##{bp.id}] #{File.basename(file)}:#{line}")
            stop_reason = 'breakpoint'
            should_stop = true
          end
        end
      end

      if should_stop
        @step_mode = :run
        @step_depth = 0
        open_repl(bnd, file: file, line: line, reason: stop_reason)
      end
    end

    def handle_call(tp)
      @watchpoints.each { |wp| wp.changed?(tp.binding) rescue nil }
      klass = tp.defined_class
      meth  = tp.method_id
      @breakpoints.select { |b| b.matches_method?(klass, meth) }.each do |bp|
        if bp.trigger!(tp.binding)
          puts "\n" + Color.yellow("[Method breakpoint ##{bp.id}] #{klass}##{meth}")
          @step_mode = :run
          open_repl(tp.binding, file: tp.path, line: tp.lineno,
                    reason: "method #{klass}##{meth}")
        end
      end
    end

    def handle_return(tp)
      pop_frame
    end

    def handle_raise(tp)
      exc = tp.raised_exception
      @catchpoints.each do |cp|
        if cp.matches?(exc)
          puts "\n" + Color.red("[Catchpoint] #{exc.class}: #{exc.message}")
          @step_mode = :run
          open_repl(tp.binding, file: tp.path, line: tp.lineno,
                    reason: "caught #{exc.class}")
        end
      end
    end

    # -----------------------------------------------------------------------
    # REPL loop
    # -----------------------------------------------------------------------

    def repl_loop(binding_ctx, file, line)
      @current_binding = binding_ctx

      loop do
        prompt = Color.bold(Color.blue("(rdbg) "))
        print prompt
        input = read_line.strip
        next if input.empty?

        @history.push(input)

        break if dispatch(input, binding_ctx, file, line) == :quit
      end
    end

    def read_line
      $stdin.gets || 'quit'
    rescue Interrupt
      puts
      'quit'
    end

    # Returns :quit to exit the REPL, nil to stay
    def dispatch(input, bnd, file, line)
      cmd, *args = input.split(/\s+/)

      case cmd
      # Navigation
      when 's', 'step'      then @step_mode = :step; return :quit
      when 'n', 'next'      then @step_mode = :next; @step_depth = frame_depth; return :quit
      when 'c', 'continue'  then @step_mode = :run;  return :quit
      when 'f', 'finish'    then @step_mode = :finish; @step_depth = frame_depth; return :quit
      when 'q', 'quit', 'exit' then stop; puts Color.red('Debugger stopped.'); exit(0)

      # Stack
      when 'bt', 'backtrace', 'where'
        print_backtrace

      when 'up'
        move_frame(-1)
      when 'down'
        move_frame(1)
      when 'frame'
        n = args.first&.to_i
        n ? set_frame(n) : print_current_frame

      # Breakpoints
      when 'b', 'break'
        handle_break_cmd(args)
      when 'b!', 'break!'
        handle_break_once_cmd(args)
      when 'd', 'delete'
        args.each { |a| delete_breakpoint(a.to_i) }
      when 'enable'
        args.each { |a| enable_breakpoint(a.to_i) }
      when 'disable'
        args.each { |a| disable_breakpoint(a.to_i) }
      when 'info'
        handle_info_cmd(args, bnd)

      # Watchpoints
      when 'watch'
        expr = args.join(' ')
        watch(expr) unless expr.empty?

      # Catchpoints
      when 'catch'
        klass = args.first
        catch_exception(klass) if klass

      # Source listing
      when 'l', 'list'
        ctx = (args.first&.to_i || 5)
        print_source(file, line, ctx)

      # Variable inspection
      when 'v', 'var'
        handle_var_cmd(args, bnd)

      # Eval
      when 'p', 'pp', 'eval'
        expr = args.join(' ')
        eval_and_print(expr, bnd)

      # Expression directly (fallback)
      when 'irb'
        puts Color.grey('(Mini-REPL: type `done` to exit)')
        mini_repl(bnd)

      # Trace
      when 'trace'
        sub = args.first
        if sub == 'off'
          trace_off!
        else
          trace!
        end

      # Thread info
      when 'threads'
        print_threads

      # History
      when 'history'
        @history.all.each_with_index { |h, i| puts "  #{i + 1}: #{h}" }

      # Help
      when 'h', 'help', '?'
        print_help

      else
        # Treat unrecognised input as an expression to evaluate
        eval_and_print(input, bnd)
      end

      nil  # stay in loop
    end

    # -----------------------------------------------------------------------
    # Command handlers
    # -----------------------------------------------------------------------

    def handle_break_cmd(args)
      return list_breakpoints if args.empty?
      loc = args.first
      cond = args[2..-1]&.join(' ') if args[1] == 'if'
      if loc.include?(':')
        f, l = loc.split(':')
        break_at(f, l.to_i, condition: cond)
      elsif loc =~ /\A[A-Z]/ || loc.include?('#')
        break_on_method(loc)
      else
        puts Color.red("Invalid break location: #{loc}")
      end
    end

    def handle_break_once_cmd(args)
      return unless args.first&.include?(':')
      f, l = args.first.split(':')
      break_once(f, l.to_i)
    end

    def handle_info_cmd(args, bnd)
      sub = args.first || 'all'
      case sub
      when 'breakpoints', 'b' then list_breakpoints
      when 'watchpoints', 'w' then list_watchpoints
      when 'catchpoints', 'c' then list_catchpoints
      when 'locals'           then print_locals(bnd)
      when 'instance', 'i'   then print_instance_vars(bnd)
      when 'globals', 'g'    then print_globals
      when 'all'
        list_breakpoints; list_watchpoints; list_catchpoints
      end
    end

    def handle_var_cmd(args, bnd)
      sub = args.first || 'locals'
      case sub
      when 'locals', 'l'    then print_locals(bnd)
      when 'instance', 'i'  then print_instance_vars(bnd)
      when 'class', 'c'     then print_class_vars(bnd)
      when 'global', 'g'    then print_globals
      when 'all', 'a'
        print_locals(bnd); print_instance_vars(bnd); print_globals
      end
    end

    # -----------------------------------------------------------------------
    # Variable printers
    # -----------------------------------------------------------------------

    def print_locals(bnd)
      vars = bnd.local_variables
      if vars.empty?
        puts Color.grey('  (no local variables)')
        return
      end
      vars.sort.each do |name|
        val = bnd.local_variable_get(name)
        puts "  #{Color.cyan(name.to_s)} = #{PrettyPrinter.format(val)}"
      end
    end

    def print_instance_vars(bnd)
      obj = bnd.eval('self')
      ivars = obj.instance_variables
      if ivars.empty?
        puts Color.grey('  (no instance variables)')
        return
      end
      ivars.sort.each do |name|
        val = obj.instance_variable_get(name)
        puts "  #{Color.magenta(name.to_s)} = #{PrettyPrinter.format(val)}"
      end
    end

    def print_class_vars(bnd)
      obj = bnd.eval('self.class')
      cvars = obj.class_variables rescue []
      if cvars.empty?
        puts Color.grey('  (no class variables)')
        return
      end
      cvars.sort.each do |name|
        val = obj.class_variable_get(name) rescue '?'
        puts "  #{Color.yellow(name.to_s)} = #{PrettyPrinter.format(val)}"
      end
    end

    def print_globals
      interesting = global_variables.select { |g| !g.to_s.start_with?('$LOADED', '$"') }
      interesting.sort.first(20).each do |name|
        val = eval(name.to_s) rescue nil
        puts "  #{Color.grey(name.to_s)} = #{PrettyPrinter.format(val)}"
      end
    end

    # -----------------------------------------------------------------------
    # Eval
    # -----------------------------------------------------------------------

    def eval_and_print(expr, bnd)
      result = bnd.eval(expr, '(debugger)', 1)
      puts "=> #{PrettyPrinter.format(result)}"
    rescue => e
      puts Color.red("#{e.class}: #{e.message}")
      e.backtrace.first(3).each { |l| puts Color.grey("    #{l}") }
    end

    def mini_repl(bnd)
      loop do
        print Color.grey('irb> ')
        line = read_line.strip
        break if line == 'done' || line.empty?
        eval_and_print(line, bnd)
      end
    end

    # -----------------------------------------------------------------------
    # Source listing
    # -----------------------------------------------------------------------

    def print_source(file, center, context = 5)
      return if file.nil? || file.start_with?('(')
      lines = @source_cache.snippet(file, center, context)
      if lines.nil? || lines.empty?
        puts Color.grey("  (source unavailable for #{file})")
        return
      end
      lines.each do |n, text|
        marker = n == center ? Color.bold(Color.yellow('=>')) : '  '
        num    = Color.grey(n.to_s.rjust(4))
        puts "#{num} #{marker} #{text.chomp}"
      end
    end

    # -----------------------------------------------------------------------
    # Call stack
    # -----------------------------------------------------------------------

    def push_frame(frame)
      synchronize do
        if @call_stack.first && same_execution_frame?(@call_stack.first, frame)
          @call_stack[0] = frame
        else
          @call_stack.unshift(frame)
        end
      end
    end

    def pop_frame
      synchronize { @call_stack.shift }
    end

    def same_execution_frame?(left, right)
      left.method_name == right.method_name && left.klass == right.klass
    end

    def frame_depth
      @call_stack.size
    end

    def print_backtrace
      if @call_stack.empty?
        puts Color.grey('  (stack empty)')
        return
      end
      @call_stack.first(20).each_with_index do |f, i|
        marker = i == @current_frame_index ? Color.bold(Color.yellow('→')) : ' '
        puts "  #{marker} ##{i} #{f}"
      end
    end

    def print_current_frame
      f = @call_stack[@current_frame_index]
      f ? puts("  Frame ##{@current_frame_index}: #{f}") : puts(Color.grey('  (no frame)'))
    end

    def move_frame(delta)
      set_frame(@current_frame_index + delta)
    end

    def set_frame(n)
      max = @call_stack.size - 1
      @current_frame_index = n.clamp(0, [max, 0].max)
      print_current_frame
    end

    # -----------------------------------------------------------------------
    # Threads
    # -----------------------------------------------------------------------

    def print_threads
      Thread.list.each_with_index do |t, i|
        status = t.status || 'dead'
        current = t == Thread.current ? Color.yellow(' ← current') : ''
        puts "  Thread ##{i} [#{status}] #{t.inspect}#{current}"
      end
    end

    # -----------------------------------------------------------------------
    # Display helpers
    # -----------------------------------------------------------------------

    def header(file, line, reason)
      sep = Color.blue('─' * 60)
      puts "\n#{sep}"
      puts "  #{Color.bold(Color.yellow('RubyDebugger'))} stopped: #{Color.cyan(reason)}"
      puts "  at #{Color.white(File.basename(file.to_s))}:#{Color.yellow(line.to_s)}"
      puts sep
    end

    def print_help
      help = <<~HELP
        #{Color.bold('Navigation')}
          s / step        — Step into next line
          n / next        — Step over next line
          c / continue    — Resume execution
          f / finish      — Run until current method returns
          q / quit        — Exit debugger

        #{Color.bold('Stack')}
          bt / backtrace  — Print call stack
          up / down       — Move up/down the stack
          frame [N]       — Select or show frame

        #{Color.bold('Breakpoints')}
          b file:line [if cond]  — Set line breakpoint
          b ClassName#method     — Set method breakpoint
          b!  file:line          — One-shot breakpoint
          d N                    — Delete breakpoint N
          enable/disable N       — Toggle breakpoint N
          info [breakpoints|watchpoints|catchpoints]

        #{Color.bold('Watchpoints & Catchpoints')}
          watch EXPR      — Break when EXPR changes
          catch ExcClass  — Break when exception is raised

        #{Color.bold('Inspection')}
          v locals        — Local variables
          v instance      — Instance variables
          v class         — Class variables
          v global        — Global variables (first 20)
          p EXPR          — Evaluate and print expression
          irb             — Mini-REPL (type `done` to exit)

        #{Color.bold('Source & Tracing')}
          l / list [N]    — List source (N lines context)
          trace           — Start execution trace
          trace off       — Stop execution trace
          threads         — List threads
          history         — Show command history
          h / help        — This help message
      HELP
      puts help
    end

    # -----------------------------------------------------------------------
    # Misc helpers
    # -----------------------------------------------------------------------

    def toggle_bp(id, state)
      synchronize do
        bp = @breakpoints.find { |b| b.id == id }
        if bp
          bp.enabled = state
          puts "[Debugger] Breakpoint ##{id} #{state ? 'enabled' : 'disabled'}."
        else
          puts "[Debugger] No breakpoint ##{id}."
        end
      end
    end

    def with_trace_suspended
      previous = @suspend_trace
      @suspend_trace = true
      yield
    ensure
      @suspend_trace = previous
    end
  end # Core

  # ---------------------------------------------------------------------------
  # Singleton instance
  # ---------------------------------------------------------------------------

  def self.instance
    @instance ||= Core.new
  end

  def self.start(**opts, &block)
    dbg = instance
    dbg.start
    block ? (yield dbg) : dbg
  end

  def self.stop
    instance.stop
  end

  # ---------------------------------------------------------------------------
  # Kernel-level helpers mixed into Object
  # ---------------------------------------------------------------------------

  module KernelMethods
    # `debugger` — drop into the REPL from any point in code
    def debugger
      dbg = RubyDebugger.instance
      dbg.start unless dbg.instance_variable_get(:@active)
      file = caller_locations(1, 1).first.path
      line = caller_locations(1, 1).first.lineno
      dbg.trigger(binding, file, line)
    end

    # `bp_here` — alias preferred by some
    alias bp_here debugger
  end
end

# Mix helpers into Object so they are globally available
Object.prepend(RubyDebugger::KernelMethods)
