# encoding ascii-8bit

require 'openssl'

module MoneyTree
  class Key
    include OpenSSL
    include Support
    extend Support
    class KeyInvalid < Exception; end
    class KeyGenerationFailure < Exception; end
    class KeyImportFailure < Exception; end
    class KeyFormatNotFound < Exception; end
    class InvalidWIFFormat < Exception; end
    class InvalidBase64Format < Exception; end
    
    attr_reader :options, :key, :raw_key, :network, :network_key
    attr_accessor :ec_key
    
    GROUP_NAME = 'secp256k1'
    ORDER = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141".to_i(16)

    def valid?(eckey = nil)
      eckey ||= ec_key
      eckey.nil? ? false : eckey.check_key
    end
    
    def to_bytes
      hex_to_bytes to_hex
    end
    
    def to_i
      bytes_to_int to_bytes
    end
  end
  
  class PrivateKey < Key
        
    def initialize(opts = {})
      @options = opts
      @ec_key = PKey::EC.new GROUP_NAME
      @network_key = options[:network] || :bitcoin
      @network = MoneyTree::NETWORKS[network_key]
      if @options[:key]
        @raw_key = @options[:key]
        @key = parse_raw_key
        import
      else
        generate
        @key = to_hex
      end
    end
    
    def generate
      ec_key.generate_key
    end
    
    def import
      ec_key.private_key = BN.new(key, 16)
      set_public_key
    end
    
    def calculate_public_key(opts = {})
      opts[:compressed] = true unless opts[:compressed] == false
      group = ec_key.group
      group.point_conversion_form = opts[:compressed] ? :compressed : :uncompressed
      point = group.generator.mul ec_key.private_key
    end
    
    def set_public_key(opts = {})
      ec_key.public_key = calculate_public_key(opts)
    end
    
    def parse_raw_key
      result = if raw_key.is_a?(Bignum) then from_bignum
      elsif hex_format? then from_hex
      elsif base64_format? then from_base64
      elsif compressed_wif_format? then from_wif
      elsif uncompressed_wif_format? then from_wif
      else 
        raise KeyFormatNotFound
      end
      result.downcase
    end

    def from_bignum(bignum = raw_key)
      int_to_hex(bignum)
    end

    def from_hex(hex = raw_key)
      hex
    end
    
    def from_wif(wif = raw_key)
      compressed = wif.length == 52
      parse_network_from_wif(wif, compressed: compressed)
      validate_wif(wif)
      hex = decode_base58(wif)
      last_char = compressed ? -11 : -9
      hex.slice(2..last_char)
    end

    def parse_network_from_wif(wif, opts = {})
      networks = MoneyTree::NETWORKS
      chars_key = opts[:compressed] ? :compressed_wif_chars : :uncompressed_wif_chars
      @network_key = networks.keys.select do |k|
        networks[k][chars_key].include?(wif.slice(0))
      end.first
      @network = networks[network_key]
    end
    
    def from_base64(base64_key = raw_key)
      raise InvalidBase64Format unless base64_format?(base64_key)
      decode_base64(base64_key)
    end

    def compressed_wif_format?
      wif_format?(:compressed)
    end
    
    def uncompressed_wif_format?
      wif_format?(:uncompressed)
    end

    def wif_format?(compression)
      length = compression == :compressed ? 52 : 51
      wif_prefixes = MoneyTree::NETWORKS.map {|k, v| v["#{compression}_wif_chars".to_sym]}.flatten
      raw_key.length == length && wif_prefixes.include?(raw_key.slice(0))
    end

    def base64_format?(base64_key = raw_key)
      base64_key.length == 44 && base64_key =~ /^(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?$/
    end
    
    def hex_format?
      raw_key.length == 64 && !raw_key[/\H/]
    end
    
    def to_hex
      int_to_hex @ec_key.private_key
    end
    
    def to_wif(opts = {})
      opts[:compressed] = true unless opts[:compressed] == false
      source = network[:privkey_version] + to_hex
      source += network[:privkey_compression_flag] if opts[:compressed]
      hash = sha256(source)
      hash = sha256(hash)
      checksum = hash.slice(0..7)
      source_with_checksum = source + checksum
      encode_base58(source_with_checksum)
    end

    def wif_valid?(wif)
      hex = decode_base58(wif)
      return false unless hex.slice(0..1) == network[:privkey_version]
      checksum = hex.chars.to_a.pop(8).join
      source = hex.slice(0..-9)
      hash = sha256(source)
      hash = sha256(hash)
      hash_checksum = hash.slice(0..7)
      checksum == hash_checksum
    end
    
    def validate_wif(wif)
      raise InvalidWIFFormat unless wif_valid?(wif)
    end
    
    def to_base64
      encode_base64(to_hex)
    end
    
    def to_s
      to_wif
    end
    
  end
  
  class PublicKey < Key
    attr_reader :private_key, :point, :group, :key_int
    
    def initialize(p_key, opts = {})
      @options = opts
      @options[:compressed] = true if @options[:compressed].nil?
      
      if p_key.is_a?(PrivateKey)
        @private_key = p_key
        @network_key = private_key.network_key
        @network = MoneyTree::NETWORKS[network_key]
        @point = @private_key.calculate_public_key(@options)
        @group = @point.group
        @key = @raw_key = to_hex
      else
        @network_key = @options[:network] || :bitcoin
        @network = MoneyTree::NETWORKS[network_key]
        @raw_key = p_key
        @group = PKey::EC::Group.new GROUP_NAME
        @key = parse_raw_key
      end
      raise ArgumentError, "Must initialize with a MoneyTree::PrivateKey or a public key value" if @key.nil?
    end
    
    def compression
      @group.point_conversion_form
    end
    
    def compression=(compression_type = :compressed)
      @group.point_conversion_form = compression_type
    end
    
    def compressed
      compressed_key = self.class.new raw_key, options # deep clone
      compressed_key.set_point to_i, compressed: true
      compressed_key
    end
    
    def uncompressed
      uncompressed_key = self.class.new raw_key, options # deep clone
      uncompressed_key.set_point to_i, compressed: false
      uncompressed_key
    end
    
    def set_point(int = to_i, opts = {})
      opts = options.merge(opts)
      opts[:compressed] = true if opts[:compressed].nil?
      self.compression = opts[:compressed] ? :compressed : :uncompressed
      bn = BN.new int_to_hex(int), 16
      @point = PKey::EC::Point.new group, bn
      raise KeyInvalid, 'point is not on the curve' unless @point.on_curve?
    end
    
    def parse_raw_key
      result = if raw_key.is_a?(Bignum)
        set_point raw_key
      elsif hex_format?
        set_point hex_to_int(raw_key), compressed: false
      elsif compressed_hex_format?
        set_point hex_to_int(raw_key), compressed: true
      else 
        raise KeyFormatNotFound
      end
      to_hex
    end
    
    def hex_format?
      raw_key.length == 130 && !raw_key[/\H/]
    end
    
    def compressed_hex_format?
      raw_key.length == 66 && !raw_key[/\H/]
    end
    
    def to_hex
      int_to_hex to_i
    end
    
    def to_i
      point.to_bn.to_i
    end
    
    def to_ripemd160
      hash = sha256 to_hex
      ripemd160 hash
    end
    
    def to_address
      hash = to_ripemd160
      address = network[:address_version] + hash
      to_serialized_base58 address
    end
    alias :to_s :to_address
    
    def to_fingerprint
      hash = to_ripemd160
      hash.slice(0..7)
    end
    
    def to_bytes
      int_to_bytes to_i
    end
  end
end
