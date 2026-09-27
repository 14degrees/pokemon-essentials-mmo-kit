#===============================================================================
# PEMK :: Session
#-------------------------------------------------------------------------------
# Owns the connection lifecycle for this game instance and exposes the singletons
# the rest of the SDK talks to (client / relay / self_id). Started lazily the
# first time we're in the overworld (see Pump), so $game_player / $game_map exist.
#
# ROLE :auto makes local testing trivial: the first instance to launch binds the
# port and hosts; the second finds the port busy and joins as a client — no
# config changes needed to test with two windows on one PC.
#===============================================================================
module PEMK
  @client  = nil
  @relay   = nil
  @self_id = nil
  @started = false

  def self.client;   @client;   end
  def self.relay;    @relay;    end
  def self.self_id;  @self_id;  end
  def self.started?; @started;  end

  # Phase 2: once the server issues a stable account/trainer id at login, it
  # becomes our presence id too (so a player's presence and account align).
  def self.set_self_id(v)
    @self_id = v
  end

  # PEMK_INSTANCE=<name> runs this window as a fully separate player on the same PC:
  # its own config, account, session token, log and local save file, all suffixed
  # with the name. Automated tests launch several of these side by side; unlike the
  # older PEMK_GUEST, two instances never share a save file (a checkpoint pushes the
  # file it just wrote, so a shared file can carry one account's save into another).
  # -> the validated name, or nil when unset.
  def self.instance
    return @instance if defined?(@instance)

    raw = ENV["PEMK_INSTANCE"].to_s.strip
    @instance = raw.match?(/\A[A-Za-z0-9_-]{1,32}\z/) ? raw : nil
  end

  # "base.ext" -> "base_<instance>.ext" for per-instance files; unchanged otherwise.
  def self.instance_file(name)
    return name unless instance

    ext = File.extname(name)
    "#{File.basename(name, ext)}_#{instance}#{ext}"
  end

  # Effective connection settings: Config defaults, overridden by an optional
  # plain-text mmo_config.txt in the game folder (so friends can set up LAN play
  # without touching Ruby). Resolved once, on first use.
  def self.settings
    @settings ||= resolve_settings
  end

  def self.resolve_settings
    s = { :role => Config::ROLE, :host => Config::HOST, :port => Config::PORT,
          :bind => Config::BIND_HOST, :email => nil, :password => nil }
    # A guest instance (PEMK_GUEST) reads its OWN config so two windows on one PC
    # can log in as distinct accounts. A named instance (PEMK_INSTANCE) does too.
    file = if instance
             instance_file(Config::CONFIG_FILE)
           elsif !ENV["PEMK_GUEST"].to_s.strip.empty?
             "mmo_config_guest.txt"
           else
             Config::CONFIG_FILE
           end
    path = File.expand_path(file)
    if File.exist?(path)
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        k, v = line.split("=", 2)
        next unless k && v
        k = k.strip.downcase
        v = v.strip
        case k
        when "role"     then s[:role] = v.downcase.to_sym
        when "host"     then s[:host] = v
        when "port"     then s[:port] = v.to_i if v.to_i > 0
        when "bind"     then s[:bind] = v
        when "email"    then s[:email] = v
        when "password" then s[:password] = v   # never logged
        end
      end
      log("config: #{file} -> host=#{s[:host]} port=#{s[:port]} email=#{s[:email].inspect}")
    end
    s
  rescue => e
    log("config: error reading #{Config::CONFIG_FILE}: #{e.class}: #{e.message}")
    { :role => Config::ROLE, :host => Config::HOST, :port => Config::PORT,
      :bind => Config::BIND_HOST, :username => nil, :password => nil }
  end

  def self.enabled?
    Config::ENABLED && settings[:role] != :off
  end

  # Lightweight file logger (no reliable console at all stages under mkxp-z).
  def self.log(msg)
    File.open(File.expand_path(instance_file("mmo.log")), "a") { |f| f.write("#{msg}\n") }
  rescue
    nil
  end

  def self.send_message(hash, body = nil)
    c = @client
    return false unless c && c.connected?
    c.send_message(hash, body)
  end

  # Idempotent: opens the client connection to the DEDICATED server (there is no
  # in-process relay any more — the authoritative Ruby+Postgres server owns data).
  # Sets @started up front so a failure isn't retried every frame. self_id stays
  # nil until Auth logs in and the server issues the account id.
  def self.ensure_started
    return if @started || !enabled?
    @started = true
    st = settings
    begin
      @client = NetClient.new(st[:host], st[:port])
      if @client.connect
        log("client: connected to dedicated server #{st[:host]}:#{st[:port]}")
      else
        log("client: FAILED to connect to #{st[:host]}:#{st[:port]}")
      end
    rescue => e
      log("start error: #{e.class}: #{e.message}")
    end
  end

  def self.shutdown
    (@client.close if @client) rescue nil
    (@relay.stop  if @relay)  rescue nil
    @client = nil
    @relay = nil
    @started = false
  end
end

# A named instance keeps its own local save beside the default one. The engine reads
# SaveData::FILE_PATH at call time everywhere (load screen, Game.save, checkpoints,
# the .bak sibling), and plugins load before Game.initialize, so redefining it here
# moves every path at once.
if PEMK.instance && defined?(SaveData) && SaveData.const_defined?(:FILE_PATH)
  pemk_instance_save = File.join(File.dirname(SaveData::FILE_PATH),
                                 PEMK.instance_file(File.basename(SaveData::FILE_PATH)))
  SaveData.send(:remove_const, :FILE_PATH)
  SaveData.const_set(:FILE_PATH, pemk_instance_save)
  PEMK.log("instance #{PEMK.instance}: save file #{pemk_instance_save}")
end
