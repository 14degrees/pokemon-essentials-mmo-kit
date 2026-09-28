#===============================================================================
# PEMK :: PeerPokemon  (client side — a Pokemon another player built)
#-------------------------------------------------------------------------------
# A trade's escrow and a PvP team arrive as Marshal bodies another client made. Two
# checks stand before this game holds one:
#   1. the classes (MarshalScan): the bytes may name nothing outside PEER_CLASSES, so
#      loading them cannot build anything else;
#   2. the shape: a modified client can put anything in an instance variable, and the
#      game trusts its own objects - a move list that is not a list crashes the
#      summary screen, a nickname carrying message codes runs them when printed.
# Legality (IVs, levels, learnsets) is the server's business (team audit, monster
# registry); this is about what the game can safely hold.
#
# The server advertises peer_check at login. off: the pre-check behaviour (only the
# texts are cleaned, always); shadow: both checks run and log, the Pokemon is kept;
# on: a Pokemon that fails either is refused.
#===============================================================================
module PEMK
  module PeerPokemon
    TEXT_MAX = 250   # a mail's message; names are held to PEMK::NAME_MAX
    # Scalars the game reads with arithmetic or as a flag (an absent one reads nil).
    NUMBERS = %i[@forced_form @time_form_set @steps_to_hatch @obtain_method @obtain_map @obtain_level
                 @hatched_map @timeReceived @timeEggHatched @heart_gauge @saved_exp].freeze
    FLAGS   = %i[@shiny @super_shiny @hyper_mode].freeze

    @mode = :off

    module_function

    def reset
      @mode = :off
    end

    def adopt_mode(v)
      @mode = %w[shadow on].include?(v.to_s) ? v.to_s.to_sym : :off
    end

    def mode
      @mode
    end

    # A peer body -> the object it holds, or nil when it is refused. +what+ names it
    # for the log. The texts of every Pokemon in it are cleaned.
    def load(bytes, what)
      return nil unless bytes.is_a?(String)

      if @mode != :off
        why = PEMK::MarshalScan.refusal(bytes, PEMK::Config::PEER_CLASSES)
        if why
          PEMK.log("peer: #{what} refused before loading (#{why})#{@mode == :on ? '' : ' [shadow]'}")
          return nil if @mode == :on
        end
      end
      obj = (Marshal.load(bytes) rescue nil)
      mons = obj.is_a?(Array) ? obj : [obj]
      if @mode != :off
        why = nil
        mons.each_with_index do |m, i|
          r = refusal(m)
          next unless r

          why = "Pokemon #{i + 1}: #{r}"
          break
        end
        if why
          PEMK.log("peer: #{what} refused (#{why})#{@mode == :on ? '' : ' [shadow]'}")
          return nil if @mode == :on
        end
      end
      mons.each { |m| clean(m) if m.is_a?(Pokemon) }
      obj
    end

    # -> nil when +pkmn+ has the shape of a Pokemon this game can hold, else why not.
    def refusal(pkmn, fused = false)
      return "not a Pokemon" unless pkmn.instance_of?(Pokemon)

      iv = ->(name) { pkmn.instance_variable_get(name) }
      return "species" unless known?(GameData::Species, iv[:@species])
      return "form" unless int?(iv[:@form], 0, 999)
      return "experience" unless int?(iv[:@exp], 0, 100_000_000)
      return "hit points" unless int?(iv[:@hp], 0, 99_999) && int?(iv[:@totalhp], 0, 99_999)
      return "stats" unless %i[@attack @defense @spatk @spdef @speed].all? { |n| int?(iv[n], 0, 99_999) }
      return "status" unless known?(GameData::Status, iv[:@status]) && int?(iv[:@statusCount], 0, 999)
      return "gender" unless iv[:@gender].nil? || int?(iv[:@gender], 0, 2)
      return "ability" unless iv[:@ability].nil? || known?(GameData::Ability, iv[:@ability])
      return "ability index" unless iv[:@ability_index].nil? || int?(iv[:@ability_index], 0, 9)
      return "nature" unless %i[@nature @nature_for_stats].all? { |n| iv[n].nil? || known?(GameData::Nature, iv[n]) }
      return "held item" unless iv[:@item].nil? || known?(GameData::Item, iv[:@item])
      return "ball" unless known?(GameData::Item, iv[:@poke_ball])
      return "moves" unless moves?(iv[:@moves])
      return "first moves" unless symbols?(iv[:@first_moves])
      return "ribbons" unless symbols?(iv[:@ribbons])
      return "IVs" unless stat_hash?(iv[:@iv], 0, 999)
      return "EVs" unless stat_hash?(iv[:@ev], 0, 999)
      return "IV caps" unless iv[:@ivMaxed].nil? || iv[:@ivMaxed].is_a?(Hash)
      byte_fields = %i[@happiness @cool @beauty @cute @smart @tough @sheen @pokerus]
      return "condition" unless byte_fields.all? { |n| iv[n].nil? || int?(iv[n], 0, 255) }
      return "name" unless text?(iv[:@name])
      return "origin" unless text?(iv[:@obtain_text])
      return "owner" unless owner?(iv[:@owner])
      return "mail" unless iv[:@mail].nil? || mail?(iv[:@mail])
      return "id" unless int?(iv[:@personalID], 0, 0xffffffff)
      stray = NUMBERS.find { |n| !iv[n].nil? && !int?(iv[n], -2**62, 2**62) } ||
              FLAGS.find { |n| ![nil, true, false].include?(iv[n]) }
      return stray.to_s.delete("@") if stray
      return "shadow moves" unless iv[:@shadow_moves].nil? || iv[:@shadow_moves].is_a?(Array)
      return "saved EVs" unless iv[:@saved_ev].nil? || stat_hash?(iv[:@saved_ev], 0, 999)
      fusion = iv[:@fused]
      return "fusion" unless fusion.nil? || (!fused && refusal(fusion, true).nil?)

      nil
    rescue StandardError => e
      "unreadable (#{e.class})"
    end

    # The texts another player wrote, without the codes a message box would run.
    def clean(pkmn)
      set = ->(obj, name, max) { obj.instance_variable_set(name, plain(obj.instance_variable_get(name), max)) }
      set.call(pkmn, :@name, PEMK::NAME_MAX)
      set.call(pkmn, :@obtain_text, TEXT_MAX)
      owner = pkmn.instance_variable_get(:@owner)
      set.call(owner, :@name, PEMK::NAME_MAX) if owner.instance_of?(Pokemon::Owner)
      mail = pkmn.instance_variable_get(:@mail)
      if defined?(Mail) && mail.instance_of?(Mail)
        set.call(mail, :@message, TEXT_MAX)
        set.call(mail, :@sender, PEMK::NAME_MAX)
      end
      fusion = pkmn.instance_variable_get(:@fused)
      clean(fusion) if fusion.instance_of?(Pokemon) && !fusion.equal?(pkmn)
    rescue StandardError => e
      PEMK.log("peer: clean error #{e.class}: #{e.message}")
    end

    def plain(value, max)
      return nil unless value.is_a?(String)

      s = value.dup.force_encoding(Encoding::UTF_8).scrub("")
      s = s.gsub(/[[:cntrl:]\p{Cf}\\<>]/, "").squeeze(" ").strip
      s[0, max].to_s
    end

    # --- shapes ---------------------------------------------------------------

    def int?(v, lo, hi)
      v.is_a?(Integer) && v >= lo && v <= hi
    end

    def known?(data, v)
      v.is_a?(Symbol) && data.exists?(v)
    end

    def symbols?(v)
      v.nil? || (v.is_a?(Array) && v.size <= 100 && v.all? { |e| e.is_a?(Symbol) })
    end

    def text?(v)
      v.nil? || (v.is_a?(String) && v.bytesize <= 1024)
    end

    def stat_hash?(v, lo, hi)
      v.is_a?(Hash) && v.size <= 16 && v.all? { |k, n| k.is_a?(Symbol) && int?(n, lo, hi) }
    end

    def moves?(v)
      max = (Pokemon::MAX_MOVES rescue 4)
      v.is_a?(Array) && v.size <= max && v.all? do |m|
        m.instance_of?(Pokemon::Move) && known?(GameData::Move, m.instance_variable_get(:@id)) &&
          int?(m.instance_variable_get(:@pp), 0, 999) && int?(m.instance_variable_get(:@ppup) || 0, 0, 3)
      end
    end

    def owner?(v)
      v.instance_of?(Pokemon::Owner) && int?(v.instance_variable_get(:@id), 0, 0xffffffff) &&
        text?(v.instance_variable_get(:@name)) &&
        %i[@gender @language].all? { |n| (g = v.instance_variable_get(n)).nil? || int?(g, 0, 99) }
    end

    def mail?(v)
      defined?(Mail) && v.instance_of?(Mail) && known?(GameData::Item, v.instance_variable_get(:@item)) &&
        text?(v.instance_variable_get(:@message)) && text?(v.instance_variable_get(:@sender))
    end
  end
end
