# frozen_string_literal: true

module Autotest
  # report.md for people, report.json for tools, in the run's directory.
  class Report
    def initialize(run_ctx, scenarios)
      @run_ctx   = run_ctx
      @scenarios = scenarios
    end

    def write
      File.write(File.join(@run_ctx.dir, "report.json"), JSON.pretty_generate(data))
      File.write(File.join(@run_ctx.dir, "report.md"), markdown)
      File.join(@run_ctx.dir, "report.md")
    end

    def data
      { "run" => @run_ctx.run_id, "passed" => @scenarios.count { |s| s.status == :passed },
        "total" => @scenarios.length,
        "scenarios" => @scenarios.map do |s|
          { "name" => s.name, "file" => File.basename(s.file.to_s), "status" => s.status.to_s,
            "seconds" => s.duration&.round(1), "error" => s.error,
            "checks" => s.checks.map { |c| { "name" => c.name, "ok" => c.ok, "detail" => c.detail } },
            "diagnostics" => s.diagnostics, "transcript" => s.transcript.last(60) }
        end }
    end

    def markdown
      d = data
      out = +"# Autotest run #{d['run']}\n\n**#{d['passed']}/#{d['total']} passed**\n\n"
      out << "| # | Scenario | Result | Time |\n|---|---|---|---|\n"
      @scenarios.each do |s|
        out << "| #{s.index} | #{s.name} | #{s.status} | #{s.duration&.round(1)}s |\n"
      end
      @scenarios.each do |s|
        out << "\n## #{s.index}. #{s.name} - #{s.status}\n\n"
        out << "Error: `#{s.error}`\n\n" if s.error
        s.checks.each do |c|
          out << "- #{c.ok ? '[x]' : '[ ]'} #{c.name}#{c.detail ? " - #{c.detail}" : ''}\n"
        end
        next if s.status == :passed

        s.diagnostics.each do |who, diag|
          next unless diag.is_a?(Hash)

          out << "\n### #{who}\n\n"
          out << "![#{who}](#{File.basename(s.dir)}/#{diag['screenshot']})\n\n" if diag["screenshot"]
          if (st = diag["state"])
            brief = st.slice("scene", "screens", "map", "player", "message", "menus", "flags", "battle", "text_entry")
            out << "```json\n#{JSON.pretty_generate(brief)}\n```\n\n"
          end
          out << "Log tail:\n\n```\n#{Array(diag['log']).last(15).join("\n")}\n```\n" if diag["log"]
        end
        server = Array(s.diagnostics["server_log"])
        out << "\nServer log tail:\n\n```\n#{server.last(15).join("\n")}\n```\n" unless server.empty?
      end
      out
    end
  end
end
