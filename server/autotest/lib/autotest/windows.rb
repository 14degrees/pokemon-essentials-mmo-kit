# frozen_string_literal: true

module Autotest
  # The Windows side, reached from WSL through its interop (powershell.exe,
  # cmd.exe, tasklist.exe, wslpath).
  module Windows
    module_function

    def capture(*cmd)
      out, _err, _status = Open3.capture3(*cmd)
      out.to_s.encode("UTF-8", invalid: :replace, undef: :replace).delete("\r")
    end

    def to_win(path)
      capture("wslpath", "-w", path).strip
    end

    # %APPDATA%, where the game keeps its local saves, as a WSL path.
    def appdata
      @appdata ||= capture("wslpath", capture("cmd.exe", "/c", "echo %APPDATA%").strip).strip
    end

    # -> the process id of a minimized debug window driven through channel_dir.
    def launch(instance, channel_dir)
      ps1 = to_win(File.join(SERVER_DIR, "autotest", "launch.ps1"))
      out = capture("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1,
                    "-GameDir", to_win(GAME_DIR), "-Instance", instance, "-Channel", to_win(channel_dir))
      pid = out.lines.map(&:strip).reject(&:empty?).last
      Integer(pid)
    rescue ArgumentError, TypeError
      raise Error, "could not launch the game window: #{out.inspect}"
    end

    # A hard kill (TerminateProcess), like a crash: no exit backstop runs.
    def kill(pid)
      capture("powershell.exe", "-NoProfile", "-Command",
              "Stop-Process -Id #{Integer(pid)} -Force -ErrorAction SilentlyContinue")
    end

    def alive?(pid)
      capture("tasklist.exe", "/FI", "PID eq #{Integer(pid)}", "/NH").include?(" #{Integer(pid)} ")
    end
  end
end
