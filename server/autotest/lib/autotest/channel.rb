# frozen_string_literal: true

module Autotest
  # The autopilot's file channel, driver side: one command at a time, written by
  # rename, answered in resp.txt with the same id.
  class Channel
    POLL = 0.05

    def initialize(dir)
      @dir = dir
      @seq = 0
    end

    # -> the reply Hash. Raises ChannelTimeout when nothing comes back in time.
    def call(line, timeout: 30)
      @seq += 1
      id   = "#{Process.pid}-#{@seq}"
      resp = File.join(@dir, "resp.txt")
      FileUtils.rm_f(resp)
      tmp = File.join(@dir, ".cmd.tmp")
      File.binwrite(tmp, "#{id} #{line}\n")
      File.rename(tmp, File.join(@dir, "cmd.txt"))
      deadline = Autotest.mono + timeout
      loop do
        reply = read(resp, id)
        return reply if reply
        raise ChannelTimeout, "no reply to #{line.inspect} within #{timeout}s" if Autotest.mono > deadline

        sleep POLL
      end
    end

    private

    def read(path, id)
      return nil unless File.file?(path)

      reply = JSON.parse(File.read(path))
      return nil unless reply["id"] == id

      FileUtils.rm_f(path)
      reply
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end
  end
end
