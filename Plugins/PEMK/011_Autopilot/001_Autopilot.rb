#===============================================================================
# PEMK :: Autopilot  (debug-only remote control for automated testing)
#-------------------------------------------------------------------------------
# Lets a test harness or an AI agent drive this game window and read its state
# without touching the mouse, the keyboard or the window focus: commands go through
# the engine's own Input module (002_VirtualInput) and state is read straight from
# the game objects (003_Observe).
#
# OFF unless BOTH hold: a debug launch ($DEBUG) and PEMK_AUTOPILOT=<directory>. A
# player build has neither, and when off nothing below is even hooked.
#
# The channel is two files in that directory, so any language can drive it and no
# port is opened:
#   cmd.txt   one line, "<id> <verb> [args]", written by the driver (via rename)
#   resp.txt  one JSON object {"id": ..., "ok": ...}, written by the game (via rename)
# One command at a time. The game polls cmd.txt once per frame from Graphics.update
# (mkxp-z starves background threads, so there is no listener thread); a command that
# spans frames (press, wait) answers when it is done. tools/autopilot/ap.sh is a
# ready-made driver.
#===============================================================================
module PEMK
  module Autopilot
    CMD_FILE  = "cmd.txt"
    RESP_FILE = "resp.txt"
    MAX_LINE  = 1024
    JOB_LIMIT = 3600   # frames a multi-frame command may take before it gives up

    @dir      = nil
    @job      = nil
    @job_id   = nil
    @deadline = nil
    # Frames are counted here, not read from Graphics.frame_count: loading a save
    # restores that counter to the saved play time, which would fire every pending
    # deadline at once.
    @frames   = 0

    module_function

    def active?
      !@dir.nil?
    end

    def dir
      @dir
    end

    # Called once at load. -> true when this window is remote-controlled.
    def boot(env = ENV, debug = $DEBUG)
      raw = env["PEMK_AUTOPILOT"].to_s.strip
      return false if raw.empty?

      unless debug
        PEMK.log("autopilot: PEMK_AUTOPILOT is set but this is not a debug launch - ignored")
        return false
      end
      dir = File.expand_path(raw)
      make_dirs(dir)
      @dir = dir
      PEMK.log("autopilot: on, channel #{dir}")
      true
    rescue StandardError => e
      PEMK.log("autopilot: cannot open channel #{raw.inspect}: #{e.class}: #{e.message}")
      false
    end

    # mkdir -p without fileutils, which mkxp-z does not ship.
    def make_dirs(path)
      return if File.directory?(path)

      parent = File.dirname(path)
      make_dirs(parent) unless parent == path
      Dir.mkdir(path)
    end

    # Once per frame, from Graphics.update.
    def tick
      return unless @dir

      @frames += 1
      return step_job if @job

      path = File.join(@dir, CMD_FILE)
      return unless File.file?(path)

      line = File.binread(path, MAX_LINE).to_s.force_encoding(Encoding::UTF_8)
      File.delete(path)
      run(line)
    rescue StandardError => e
      PEMK.log("autopilot: tick error #{e.class}: #{e.message}")
    end

    def run(line)
      id, verb, rest = line.strip.split(/\s+/, 3)
      return if id.nil? || id.empty?

      case verb
      when "ping"       then respond(id, "ok" => true, "frame" => frame)
      when "state"      then respond(id, { "ok" => true }.merge(Observe.snapshot))
      when "keys"       then respond(id, "ok" => true, "keys" => VInput::NAMES)
      when "press"      then cmd_press(id, rest)
      when "hold"       then cmd_hold(id, rest)
      when "release"    then cmd_release(id, rest)
      when "wait"       then cmd_wait(id, rest)
      when "screenshot" then cmd_screenshot(id, rest)
      else respond(id, "ok" => false, "error" => "unknown verb #{verb.inspect}")
      end
    rescue StandardError => e
      respond(id, "ok" => false, "error" => "#{e.class}: #{e.message}")
    end

    # press KEY [steps] - hold KEY for that many Input steps (default 2), then release.
    # Answers once the release has happened and the scene has run one frame on it, so
    # a "state" sent next already sees the effect.
    def cmd_press(id, rest)
      name, count = rest.to_s.split
      key = VInput.key(name)
      return respond(id, "ok" => false, "error" => "unknown key #{name.inspect}") unless key

      VInput.hold(key, count ? count.to_i.clamp(1, 600) : 2)
      settled = nil
      start_job(id) do
        next false if VInput.down?(key)

        settled ||= frame
        next false if frame == settled

        respond(id, "ok" => true, "frame" => frame)
      end
    end

    # hold KEY - keep KEY down until "release KEY" (walking, fast-forwarding text).
    def cmd_hold(id, rest)
      key = VInput.key(rest.to_s.strip)
      return respond(id, "ok" => false, "error" => "unknown key #{rest.to_s.strip.inspect}") unless key

      VInput.hold(key, nil)
      respond(id, "ok" => true, "frame" => frame)
    end

    # release KEY | release all
    def cmd_release(id, rest)
      name = rest.to_s.strip
      if name.casecmp?("all")
        VInput.release_all
      else
        key = VInput.key(name)
        return respond(id, "ok" => false, "error" => "unknown key #{name.inspect}") unless key

        VInput.release(key)
      end
      respond(id, "ok" => true, "frame" => frame)
    end

    # wait FRAMES - answer after that many frames (60 = one second).
    def cmd_wait(id, rest)
      target = frame + rest.to_i.clamp(1, JOB_LIMIT - 1)
      start_job(id) do
        next false if frame < target

        respond(id, "ok" => true, "frame" => frame)
      end
    end

    # screenshot [PATH] - PNG of the current frame; a relative PATH lands in the channel
    # directory, and no PATH picks shot-<frame>.png there.
    def cmd_screenshot(id, rest)
      path = rest.to_s.strip
      path = "shot-#{frame}.png" if path.empty?
      path = File.expand_path(path, @dir)
      Graphics.screenshot(path)
      respond(id, "ok" => true, "path" => path, "frame" => frame)
    end

    # A multi-frame command: the block runs once per frame until it returns true.
    def start_job(id, &block)
      @job      = block
      @job_id   = id
      @deadline = frame + JOB_LIMIT
    end

    def step_job
      if frame > @deadline
        VInput.release_all
        respond(@job_id, "ok" => false, "error" => "timeout after #{JOB_LIMIT} frames")
        @job = nil
      elsif @job.call
        @job = nil
      end
    rescue StandardError => e
      @job = nil
      respond(@job_id, "ok" => false, "error" => "#{e.class}: #{e.message}")
    end

    def respond(id, payload)
      body = PEMK::WorldExport.jval({ "id" => id }.merge(payload))
      tmp  = File.join(@dir, ".resp.tmp")
      File.open(tmp, "wb") { |f| f.write(body) }
      File.rename(tmp, File.join(@dir, RESP_FILE))
      true
    end

    def frame
      @frames
    end
  end
end

# The per-frame poll. Hooked only when this window is remote-controlled.
if PEMK::Autopilot.boot
  module Graphics
    class << self
      unless method_defined?(:pemk_ap_orig_update)
        alias_method :pemk_ap_orig_update, :update
        def update(*args)
          pemk_ap_orig_update(*args)
          PEMK::Autopilot.tick
        end
      end
    end
  end
end
