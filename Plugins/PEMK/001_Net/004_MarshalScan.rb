#===============================================================================
# PEMK :: MarshalScan  (client side — read a peer's Marshal before loading it)
#-------------------------------------------------------------------------------
# The same reader as protocol/pemk_marshal_scan.rb, which the server runs on every
# body it relays (mkxp-z cannot require it from there): it walks Marshal bytes
# without loading them - no constant looked up, no object built, no _load run - and
# names every class they refer to. PeerPokemon loads a peer's Pokemon only when every
# name is on PEMK::Config::PEER_CLASSES. server/test/marshal_scan_plugin_test.rb runs
# the same vectors through both copies.
#===============================================================================
module PEMK
  module MarshalScan
    MAX_DEPTH   = 64
    MAX_OBJECTS = 100_000

    class Error < StandardError; end

    # -> [:ok, [class names]] | [:bad, reason]
    def self.classes(bytes)
      r = Reader.new(bytes)
      r.header
      r.object(0)
      raise Error, "trailing bytes" unless r.eof?

      [:ok, r.names.keys]
    rescue Error => e
      [:bad, e.message]
    end

    # -> nil when +bytes+ is well formed and names only classes in +allow+, else why not.
    def self.refusal(bytes, allow)
      verdict, detail = classes(bytes)
      return detail unless verdict == :ok

      stray = detail.reject { |name| allow.include?(name) }
      stray.empty? ? nil : "class #{stray.first}"
    end

    class Reader
      attr_reader :names

      def initialize(bytes)
        raise Error, "not a byte string" unless bytes.is_a?(String)

        @b     = bytes.b
        @pos   = 0
        @syms  = []   # the symbol table, in the order Marshal numbers it
        @objs  = 0    # the object table's size (links point into it)
        @names = {}
      end

      def eof?
        @pos == @b.bytesize
      end

      def header
        raise Error, "not Marshal 4.8" unless byte == 4 && byte == 8
      end

      def object(depth)
        raise Error, "nested too deep" if depth > MAX_DEPTH

        type = byte
        case type
        when 0x30, 0x54, 0x46 then nil                  # 0 T F
        when 0x69 then int                              # i  Fixnum
        when 0x3a, 0x3b then back; symbol               # : ;
        when 0x40 then link                             # @
        when 0x49 then ivar_wrapped(depth)              # I
        when 0x22, 0x66 then entry; bytes               # " f  String, Float
        when 0x6c then entry; byte; take(count * 2)     # l  Bignum: sign, 16-bit words
        when 0x2f then entry; bytes; byte; name("Regexp")
        when 0x5b then entry; count.times { object(depth + 1) }
        when 0x7b, 0x7d                                 # { }  Hash (with default)
          entry
          count.times { object(depth + 1); object(depth + 1) }
          object(depth + 1) if type == 0x7d
        when 0x6f then name(symbol); entry; ivars(depth)                                       # o
        when 0x53 then name(symbol); entry; count.times { symbol; object(depth + 1) }         # S
        when 0x75 then name(symbol); bytes; entry                                              # u  _load
        when 0x55, 0x64 then name(symbol); entry; object(depth + 1)                            # U d
        when 0x65, 0x43 then name(symbol); object(depth + 1)                                   # e C
        when 0x63, 0x6d, 0x4d then entry; name(bytes)                                          # c m M
        else raise Error, format("unknown type 0x%02x", type)
        end
      end

      private

      def byte
        raise Error, "truncated" if @pos >= @b.bytesize

        v = @b.getbyte(@pos)
        @pos += 1
        v
      end

      def back
        @pos -= 1
      end

      def take(n)
        raise Error, "length past the end" if n.negative? || n > @b.bytesize - @pos

        s = @b.byteslice(@pos, n)
        @pos += n
        s
      end

      def bytes
        take(int)
      end

      # Marshal's packed integer.
      def int
        c = byte
        c -= 256 if c > 127
        return 0 if c.zero?
        return c - 5 if c > 4
        return c + 5 if c < -4

        x = c.positive? ? 0 : -1
        c.abs.times do |i|
          x &= ~(0xff << (8 * i))
          x |= byte << (8 * i)
        end
        x
      end

      # An element count: every element takes at least one byte.
      def count
        n = int
        raise Error, "count past the end" if n.negative? || n > @b.bytesize - @pos

        n
      end

      def entry
        @objs += 1
        raise Error, "too many objects" if @objs > MAX_OBJECTS
      end

      def link
        i = int
        raise Error, "dangling link" unless i >= 0 && i < @objs
      end

      def name(n)
        raise Error, "bad class name" if n.empty? || n.bytesize > 256

        @names[n.dup.force_encoding(Encoding::UTF_8)] = true
      end

      # A symbol where the format requires one (a class name, an ivar name).
      def symbol
        case byte
        when 0x3a then real_symbol(false)
        when 0x3b
          i = int
          raise Error, "dangling symbol link" unless i >= 0 && i < @syms.size

          @syms[i]
        when 0x49
          raise Error, "expected a symbol" unless byte == 0x3a

          real_symbol(true)
        else raise Error, "expected a symbol"
        end
      end

      def real_symbol(with_ivars)
        s = bytes
        @syms << s
        count.times { symbol; object(MAX_DEPTH) } if with_ivars   # its encoding
        s
      end

      # "I": an object followed by its instance variables (a String's encoding). A
      # symbol reads its own.
      def ivar_wrapped(depth)
        if byte == 0x3a
          real_symbol(true)
        else
          back
          object(depth + 1)
          ivars(depth)
        end
      end

      def ivars(depth)
        count.times do
          symbol
          object(depth + 1)
        end
      end
    end
  end
end
