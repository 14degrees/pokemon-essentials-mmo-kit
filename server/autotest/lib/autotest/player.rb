# frozen_string_literal: true

module Autotest
  # One game window and the account it plays. Its instance name keeps its config,
  # session, log and local save apart from every other window (PEMK_INSTANCE); the
  # account is created on first login through the config credentials.
  class Player
    PASSWORD = "autotest-password"
    VERBS = %w[press hold release wait wait_until choose type pick dismiss walk_to talk_to enter
               face interact warp events event_pages battle decide fast advance screenshot save
               set_switch get_switch set_var get_var set_selfswitch get_selfswitch
               add_item add_pokemon heal money abort].freeze

    attr_reader :name, :instance, :email, :pid

    def initialize(scenario, name, instance:, email:)
      @scenario = scenario
      @name     = name
      @instance = instance
      @email    = email
      @dir      = File.join(GAME_DIR, "autopilot", instance)
      @channel  = Channel.new(@dir)
    end

    def config_path;  File.join(GAME_DIR, "mmo_config_#{@instance}.txt"); end
    def log_path;     File.join(GAME_DIR, "mmo_#{@instance}.log"); end
    def channel_dir;  @dir; end

    def local_files
      [File.join(Windows.appdata, "Pokemon Essentials MMO Kit", "Game_#{@instance}.rxdata"),
       log_path, File.join(GAME_DIR, "mmo_session_#{@instance}.dat"),
       File.join(GAME_DIR, "mmo_account_#{@instance}.dat")]
    end

    # fresh: forget every local trace of an earlier run under this instance name.
    def launch(fresh: false)
      local_files.each { |f| FileUtils.rm_f(f) } if fresh
      File.write(config_path, "host = 127.0.0.1\nport = #{@scenario.server.port}\n" \
                              "email = #{@email}\npassword = #{PASSWORD}\n")
      FileUtils.mkdir_p(@dir)
      %w[cmd.txt resp.txt .cmd.tmp .resp.tmp].each { |f| FileUtils.rm_f(File.join(@dir, f)) }
      @pid = Windows.launch(@instance, @dir)
      @scenario.run_ctx.track_pid(@pid)
      wait_for_ping(90)
      self
    end

    def wait_for_ping(seconds)
      deadline = Autotest.mono + seconds
      loop do
        return true if (@channel.call("ping", timeout: 3) rescue nil)
        raise Failure, "#{@name}: the window exited while booting" unless Windows.alive?(@pid)
        raise Failure, "#{@name}: no answer from the window after #{seconds}s" if Autotest.mono > deadline

        sleep 1
      end
    end

    # One autopilot command; recorded in the scenario transcript.
    def ap(line, timeout: 30)
      reply = @channel.call(line, timeout: timeout)
      @scenario.transcript << { "player" => @name, "command" => line, "reply" => reply }
      reply
    end

    # The same, but a failed reply fails the scenario on the spot.
    def ap!(line, timeout: 30)
      reply = ap(line, timeout: timeout)
      raise Failure, "#{@name}: #{line} -> #{reply['error'] || reply['detail'] || reply.to_s[0, 300]}" unless reply["ok"]

      reply
    end

    VERBS.each do |verb|
      define_method(verb) { |*args, timeout: 30| ap([verb, *args].join(" ").strip, timeout: timeout) }
      define_method("#{verb}!") { |*args, timeout: 30| ap!([verb, *args].join(" ").strip, timeout: timeout) }
    end

    def state
      ap("state")
    end

    def idle?(within = 2)
      ap("wait_until idle within #{within}", timeout: within + 10)["ok"]
    end

    # A crash, as far as the game can tell: no exit backstop, no last save.
    def hard_kill
      return unless @pid

      Windows.kill(@pid)
      deadline = Autotest.mono + 10
      sleep 0.3 while Windows.alive?(@pid) && Autotest.mono < deadline
      @pid = nil
    end

    # Close and start again on the same account; hands back once the saved game is
    # loaded and idle (the login bypasses the load screen when the server has a save).
    def relaunch
      hard_kill
      launch(fresh: false)
      wait_in_game
    end

    def wait_in_game(seconds = 60)
      deadline = Autotest.mono + seconds
      loop do
        st = state
        return st if st["map"] && st.dig("online", "logged_in") && idle?(1)
        raise Failure, "#{@name}: not back in the game after #{seconds}s" if Autotest.mono > deadline

        sleep 0.5
      end
    end

    def log_tail(count = 40)
      File.exist?(log_path) ? File.readlines(log_path, chomp: true).last(count) : []
    end

    # Reads a conversation to its end, answering each question with the next answer:
    # a menu entry, an item to pick, or a text to type. Fails when a question comes
    # with no answer left, or when answers are left over.
    def converse(*answers, seconds: 90)
      queue = answers.map(&:to_s)
      deadline = Autotest.mono + seconds
      loop do
        raise Failure, "#{@name}: the conversation is still going after #{seconds}s" if Autotest.mono > deadline

        r = dismiss!(timeout: 90)
        stop = r["stopped"]
        if stop.nil?
          raise Failure, "#{@name}: the conversation ended with answers left: #{queue.inspect}" unless queue.empty?
          return r if idle?(5)

          next
        end
        answer = queue.shift
        unless answer
          raise Failure, "#{@name}: a #{stop} came with no answer left (#{r['message'].inspect} #{r['menus'].inspect})"
        end

        case stop
        when "menu" then choose!(answer)
        when "item" then pick!(answer)
        when "text" then type!(answer)
        else raise Failure, "#{@name}: the conversation stopped at a #{stop}"
        end
      end
    end

    def party_species
      Array(state["party"]).map { |p| p["species"] }
    end

    # A new account starts the intro at once: skip the help, choose, type the name,
    # read on, until the player stands idle in their house. Bounded.
    def new_game(player_name = "Autotest", seconds: 150)
      deadline = Autotest.mono + seconds
      loop do
        raise Failure, "#{@name}: the intro did not finish in #{seconds}s" if Autotest.mono > deadline

        st = state
        return st if st.dig("map", "id").to_i > 1 && idle?

        if st["text_entry"]
          type!(player_name)
        elsif (menu = Array(st["menus"]).last)
          commands = Array(menu["commands"])
          # Skip the help, pick a character, confirm the name ("So you're Ash?").
          pick = (["No info needed", "Boy", "Yes"] & commands).first
          raise Failure, "#{@name}: an unexpected menu in the intro: #{commands.inspect}" unless pick

          choose!(pick)
        elsif st["message"]
          dismiss!(200, timeout: 120)
        else
          ap("wait_until message|menu|text|idle within 5", timeout: 15)
        end
      end
    end
  end
end
