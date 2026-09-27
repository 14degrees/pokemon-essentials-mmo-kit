# frozen_string_literal: true

module PEMK
  # Text one player sends for others to see, made safe to show. The game prints it
  # through its message box, which runs codes: a "\ch[...]" in a player name sets a
  # game variable of whoever reads it, "\se[...]" plays a sound, "<...>" formats.
  module PlainText
    NAME_MAX = 16
    CHARSET  = /\A[A-Za-z0-9_\- ]{1,64}\z/   # a Graphics/Characters file name, no path

    module_function

    # A player or Pokemon name without control or direction characters, backslashes
    # or angle brackets, at most NAME_MAX characters. nil when nothing is left.
    def name(value)
      return nil unless value.is_a?(String)

      s = value.dup.force_encoding(Encoding::UTF_8).scrub("")
      s = s.gsub(/[[:cntrl:]\p{Cf}\\<>]/, "").squeeze(" ").strip
      s = s[0, NAME_MAX].strip
      s.empty? ? nil : s
    end

    # A walking sprite's file name, or nil.
    def charset(value)
      value.is_a?(String) && value.match?(CHARSET) ? value : nil
    end
  end
end
