# frozen_string_literal: true

module Autotest
  # One test: a server with its flags, the players it launches, and named checks.
  #
  #   Autotest.scenario "a new account plays the intro", flags: { PEMK_FLAG_STATE: "on" } do |s|
  #     a = s.player(:a)
  #     a.new_game("Ash")
  #     s.check("in the house") { a.state.dig("map", "name").end_with?("house") }
  #   end
  #
  # Anything raised (a failed command, a timeout, the budget) ends the scenario as an
  # error, written up with each player's state, screenshot and log.
  class Scenario
    Check = Struct.new(:name, :ok, :detail)

    attr_reader :name, :file, :flags, :budget, :checks, :transcript, :players,
                :status, :error, :duration, :server, :run_ctx, :diagnostics
    attr_accessor :index

    def initialize(name, file:, flags:, budget:, &body)
      @name        = name
      @file        = file
      @flags       = flags
      @budget      = budget
      @body        = body
      @checks      = []
      @transcript  = []
      @players     = {}
      @diagnostics = {}
    end

    def run(run_ctx)
      @run_ctx = run_ctx
      @dir     = run_ctx.dir_for(self)
      started  = Autotest.mono
      @server  = TestServer.new(port: run_ctx.port, flags: @flags,
                                log_path: File.join(@dir, "server.log")).start
      watchdog = Thread.new(Thread.current) do |main|
        sleep @budget
        main.raise(BudgetExceeded, "over the #{@budget}s budget")
      end
      @body.call(self)
      @status = @checks.all?(&:ok) ? :passed : :failed
      @diagnostics = diagnose if @status == :failed
    rescue StandardError => e
      @status = :error
      @error  = "#{e.class}: #{e.message}"
      @diagnostics = diagnose
    ensure
      watchdog&.kill
      @players.each_value { |p| p.hard_kill rescue nil }
      @server&.stop
      @duration = Autotest.mono - started
    end

    # A window on a fresh account, launched on first use.
    def player(key)
      @players[key] ||= Player.new(self, key.to_s, instance: "at#{@index}#{key}",
                                   email: "#{@run_ctx.run_id}-#{@index}-#{key}@autotest.local")
                              .launch(fresh: true)
    end

    # Runs the blocks side by side, one window each (two intros at once), and hands
    # back their results. The first failure is raised once none is left running; the
    # budget still cuts in, since the jobs keep their errors to themselves.
    def together(*jobs)
      results = Array.new(jobs.size)
      errors  = Array.new(jobs.size)
      threads = jobs.each_with_index.map do |job, i|
        Thread.new do
          results[i] = job.call
        rescue StandardError => e
          errors[i] = e
        end
      end
      threads.each(&:join)
      raise errors.compact.first if errors.any?

      results
    ensure
      threads&.each { |t| t.kill if t.alive? }
    end

    def check(name, detail = nil)
      ok = begin
        yield ? true : false
      rescue StandardError => e
        detail = "#{e.class}: #{e.message}"
        false
      end
      @checks << Check.new(name, ok, detail)
      ok
    end

    # Polls until the block holds (server writes land asynchronously). Bounded.
    def wait_for(what, seconds: 10)
      deadline = Autotest.mono + seconds
      loop do
        value = yield
        return value if value
        raise Failure, "#{what}: not after #{seconds}s" if Autotest.mono > deadline

        sleep 0.25
      end
    end

    # Server-side truth, straight from the autotest database.
    def db
      @db ||= PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    end

    def account_id(player)
      db[:accounts].where(email: player.email).get(:id)
    end

    def dir
      @dir
    end

    private

    # Everything needed to see what went wrong without running it again.
    def diagnose
      out = { "server_log" => (@server ? @server.lines.last(40) : []) }
      @players.each do |key, p|
        entry = { "log" => p.log_tail(40) }
        begin
          entry["state"] = p.ap("state", timeout: 5)
          shot = p.ap("screenshot #{File.join(Windows.to_win(@dir), "#{key}-failure.png")}", timeout: 5)
          entry["screenshot"] = "#{key}-failure.png" if shot["ok"]
        rescue StandardError => e
          entry["unreachable"] = "#{e.class}: #{e.message}"
        end
        out[key.to_s] = entry
      end
      out
    rescue StandardError => e
      { "diagnose_error" => "#{e.class}: #{e.message}" }
    end
  end

  @scenarios = []

  class << self
    attr_reader :scenarios

    def scenario(name, flags: {}, budget: 240, &body)
      file = caller_locations(1, 1).first.path
      @scenarios << Scenario.new(name, file: file, flags: flags, budget: budget, &body)
    end
  end
end
