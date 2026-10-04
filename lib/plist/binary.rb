# encoding: utf-8

module Plist
  class UID
    attr_reader :value

    def initialize(value)
      unless value.is_a?(Integer) && value >= 0
        raise ArgumentError, "UID value must be a non-negative integer"
      end

      @value = value
    end

    def ==(other)
      other.is_a?(UID) && other.value == @value
    end
    alias eql? ==

    def hash
      [UID, @value].hash
    end

    def inspect
      "#<Plist::UID #{@value}>"
    end
  end

  class Reference
    attr_reader :object_index

    def initialize(object_index)
      @object_index = object_index
    end

    def ==(other)
      other.is_a?(Reference) && other.object_index == @object_index
    end
    alias eql? ==

    def hash
      [Reference, @object_index].hash
    end

    def inspect
      "#<Plist::Reference object_index=#{@object_index}>"
    end
  end

  class CyclicReferenceError < Plist::Error
    attr_reader :object_index

    def initialize(message, object_index)
      super(message)
      @object_index = object_index
    end
  end

  module Binary
    MAGIC = "bplist00"
    EPOCH_OFFSET = 978_307_200
    TRAILER_SIZE = 32

    DEFAULT_MAX_OBJECTS = 1_000_000
    DEFAULT_MAX_LENGTH = 100 * 1_024 * 1_024
    DEFAULT_MAX_DATA_LENGTH = 10 * 1_024 * 1_024
    DEFAULT_MAX_STRING_LENGTH = 10 * 1_024 * 1_024

    Node = Struct.new(:kind, :value, :key_refs, :value_refs, :blob) do
      def all_refs
        key_refs.to_a + value_refs.to_a
      end
    end

    def self.parse(filename_or_data, options = {})
      Reader.new(options).parse(read_input(filename_or_data))
    end

    def self.dump(object, options = {})
      Writer.new(options).dump(object)
    end

    def self.read_input(filename_or_data)
      if filename_or_data.respond_to?(:read)
        filename_or_data.read
      elsif filename_or_data.is_a?(String) && file_path?(filename_or_data)
        File.binread(filename_or_data)
      else
        filename_or_data
      end
    end

    def self.file_path?(value)
      File.exist?(value)
    rescue ArgumentError
      false
    end

    class Reader
      def initialize(options = {})
        @shared = options.fetch(:shared, false)
        @cycles = options.fetch(:cycles, :reject)
        @marshal = options.fetch(:marshal, false)
        @max_objects = options.fetch(:max_objects, DEFAULT_MAX_OBJECTS)
        @max_length = options.fetch(:max_length, DEFAULT_MAX_LENGTH)
        @max_data_length = options.fetch(:max_data_length, DEFAULT_MAX_DATA_LENGTH)
        @max_string_length = options.fetch(:max_string_length, DEFAULT_MAX_STRING_LENGTH)
      end

      def parse(data)
        @data = data.to_s.dup.force_encoding(Encoding::BINARY)
        @positions = []

        check_limits!
        read_magic!
        read_trailer!
        read_offset_table!
        parse_objects!
        validate_root!
        materialize(@root_index)
      end

      private

      def check_limits!
        if @data.bytesize > @max_length
          raise Plist::ParseError.new(
            "binary plist is larger than the configured maximum length",
            @data.bytesize
          )
        end
      end

      def read_magic!
        if @data.bytesize < MAGIC.bytesize || @data.byteslice(0, MAGIC.bytesize) != MAGIC
          raise Plist::ParseError.new("invalid or missing binary plist header", 0)
        end
      end

      def read_trailer!
        if @data.bytesize < MAGIC.bytesize + TRAILER_SIZE
          raise Plist::ParseError.new("binary plist trailer is truncated", @data.bytesize)
        end

        trailer = @data.byteslice(-TRAILER_SIZE, TRAILER_SIZE)
        @offset_size = trailer.getbyte(6)
        @reference_size = trailer.getbyte(7)
        @object_count = read_integer_bytes(trailer.byteslice(8, 8), 8, false)
        @root_index = read_integer_bytes(trailer.byteslice(16, 8), 8, false)
        @offset_table_offset = read_integer_bytes(trailer.byteslice(24, 8), 8, false)

        unless @offset_size.between?(1, 8)
          raise Plist::ParseError.new("invalid offset table entry width", @data.bytesize - 26)
        end
        unless @reference_size.between?(1, 8)
          raise Plist::ParseError.new("invalid object reference width", @data.bytesize - 25)
        end
        if @object_count > @max_objects
          raise Plist::ParseError.new("object count exceeds configured maximum", @data.bytesize - 24)
        end
        if @offset_table_offset < MAGIC.bytesize
          raise Plist::ParseError.new("offset table overlaps the plist header", @data.bytesize - 8)
        end
        if @offset_table_offset + (@object_count * @offset_size) > @data.bytesize - TRAILER_SIZE
          raise Plist::ParseError.new("offset table is truncated", @offset_table_offset)
        end
      end

      def read_offset_table!
        @offsets = Array.new(@object_count) do |index|
          position = @offset_table_offset + (index * @offset_size)
          offset = read_integer_bytes(@data.byteslice(position, @offset_size), @offset_size, false)
          if offset < MAGIC.bytesize || offset >= @offset_table_offset
            raise Plist::ParseError.new("object offset is outside the object table", position)
          end
          offset
        end
      end

      def parse_objects!
        @objects = Array.new(@object_count)
        @ordered_offsets = @offsets.each_with_index.sort_by(&:first)
        @offsets.each_with_index do |offset, index|
          @positions[index] = offset
          @objects[index] = parse_object(offset, index)
        end
      end

      def validate_root!
        if @root_index >= @object_count
          raise Plist::ParseError.new("root object reference is out of bounds", @data.bytesize - 16)
        end
      end

      def parse_object(start, index)
        @current_object_start = start
        marker = byte_at!(start)
        type = marker >> 4
        info = marker & 0x0f

        case type
        when 0 then parse_singleton(marker, start)
        when 1
          size = 1 << info
          unless [1, 2, 4, 8, 16].include?(size)
            raise Plist::ParseError.new("unsupported integer width", start)
          end
          signed_integer = size == 16
          Node.new(:integer, parse_integer(start + 1, size, start, signed_integer), [], [])
        when 2 then Node.new(:real, parse_real(start + 1, 1 << info, start), [], [])
        when 3 then Node.new(:date, parse_date(start + 1, 1 << info, start), [], [])
        when 4 then length_value(start, info, @max_data_length, :data)
        when 5 then length_value(start, info, @max_string_length, :ascii)
        when 6 then length_value(start, info, @max_string_length, :utf16)
        when 7 then length_value(start, info, @max_string_length, :utf8)
        when 8
          uid_size = info + 1
          unless uid_size.between?(1, 8)
            raise Plist::ParseError.new("unsupported UID width", start)
          end
          Node.new(:uid, parse_uid(start + 1, uid_size, start), [], [])
        when 10 then parse_reference_collection(start, info, :array)
        when 13 then parse_dictionary(start, info)
        else
          raise Plist::ParseError.new("unsupported binary plist object type 0x#{type.to_s(16)}", start)
        end
      rescue Plist::ParseError
        raise
      end

      def parse_singleton(marker, position)
        value = case marker
                when 0x00 then nil
                when 0x08 then false
                when 0x09 then true
                else
                  raise Plist::ParseError.new("unsupported singleton marker 0x#{marker.to_s(16)}", position)
                end
        Node.new(:singleton, value, [], [])
      end

      def length_value(start, info, maximum, kind)
        position = start + 1
        length = info
        if info == 15
          length, position = read_extended_length(position, start)
        end
        if length > maximum
          raise Plist::ParseError.new("object length exceeds configured maximum", position)
        end
        parse_length_value(kind, length, position, object_end(start))
      end

      def read_extended_length(position, object_start)
        marker = byte_at!(position)
        type = marker >> 4
        info = marker & 0x0f
        unless type == 1
          raise Plist::ParseError.new("invalid extended length marker", position)
        end
        size = 1 << info
        unless [1, 2, 4, 8, 16].include?(size)
          raise Plist::ParseError.new("unsupported extended integer width", position)
        end
        bytes = bytes_at!(position + 1, size, object_start, size)
        [read_integer_bytes(bytes, size, false), position + 1 + size]
      end

      def parse_length_value(kind, length, position, object_end)
        byte_length = kind == :utf16 ? length * 2 : length
        if object_end && position + byte_length > object_end
          raise Plist::ParseError.new("object length extends past its offset entry", object_end)
        end
        bytes = bytes_at!(position, byte_length, position, byte_length)
        value = case kind
                when :data then parse_data(bytes)
                when :ascii then parse_ascii(bytes)
                when :utf16 then parse_utf16(bytes, length, position, object_end)
                when :utf8 then parse_utf8(bytes)
        end
        Node.new(kind, value, [], [])
      end

      def object_end(start)
        later = @ordered_offsets.find do |offset, _index|
          offset > start
        end
        later ? later.first : @offset_table_offset
      end

      def parse_data(bytes)
        if @marshal
          begin
            return Marshal.load(bytes)
          rescue Exception
          end
        end
        StringIO.new(bytes)
      end

      def parse_ascii(bytes)
        unless bytes.bytes.all? { |byte| byte < 0x80 }
          raise Plist::ParseError.new("invalid ASCII string", @current_object_start)
        end
        bytes.dup.force_encoding(Encoding::US_ASCII)
      end

      def parse_utf8(bytes)
        result = bytes.dup.force_encoding(Encoding::UTF_8)
        unless result.valid_encoding?
          raise Plist::ParseError.new("invalid UTF-8 string", @current_object_start)
        end
        result
      end

      def parse_utf16(bytes, units, position, object_end)
        if bytes.bytesize < units * 2
          raise Plist::ParseError.new("truncated UTF-16 character", position + bytes.bytesize)
        end
        if bytes.bytesize.odd?
          raise Plist::ParseError.new("truncated UTF-16 character", position + bytes.bytesize - 1)
        end
        if object_end && position + bytes.bytesize > object_end
          raise Plist::ParseError.new("truncated UTF-16 character", object_end)
        end

        result = String.new.force_encoding(Encoding::UTF_8)
        index = 0
        while index < units
          value = (bytes.getbyte(index * 2) << 8) | bytes.getbyte(index * 2 + 1)
          if value >= 0xD800 && value <= 0xDBFF
            if index + 1 >= units
              raise Plist::ParseError.new("truncated UTF-16 character", position + (index * 2))
            end
            low = (bytes.getbyte((index + 1) * 2) << 8) | bytes.getbyte((index + 1) * 2 + 1)
            unless low >= 0xDC00 && low <= 0xDFFF
              raise Plist::ParseError.new("invalid UTF-16 surrogate pair", position + (index * 2))
            end
            codepoint = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
            result << codepoint
            index += 2
          elsif value >= 0xDC00 && value <= 0xDFFF
            raise Plist::ParseError.new("invalid UTF-16 surrogate", position + (index * 2))
          else
            result << value
            index += 1
          end
        end
        result.force_encoding(Encoding::UTF_8)
      end

      def parse_integer(position, size, object_start, signed_integer = false)
        bytes = bytes_at!(position, size, object_start, size)
        read_integer_bytes(bytes, size, signed_integer)
      end

      def parse_real(position, size, object_start)
        bytes = bytes_at!(position, size, object_start, size)
        case size
        when 4 then bytes.unpack('g').first
        when 8 then bytes.unpack('G').first
        else
          raise Plist::ParseError.new("unsupported real width", position - 1)
        end
      end

      def parse_date(position, size, object_start)
        bytes = bytes_at!(position, size, object_start, size)
        unless size == 4 || size == 8
          raise Plist::ParseError.new("unsupported date width", position - 1)
        end
        seconds = parse_real_value(bytes, size) + EPOCH_OFFSET
        Time.at(seconds).utc
      end

      def parse_real_value(bytes, size)
        size == 4 ? bytes.unpack('g').first : bytes.unpack('G').first
      end

      def parse_uid(position, size, object_start)
        bytes = bytes_at!(position, size, object_start, size)
        UID.new(read_integer_bytes(bytes, size, false))
      end

      def parse_reference_collection(start, info, kind)
        count, position = reference_count(start, info)
        ensure_object_bytes!(start, position, count * @reference_size)
        refs = Array.new(count) do |index|
          read_reference(position + (index * @reference_size), start)
        end
        Node.new(kind, nil, [], refs)
      end

      def parse_dictionary(start, info)
        count, position = reference_count(start, info)
        ensure_object_bytes!(start, position, count * @reference_size * 2)
        key_refs = Array.new(count) do |index|
          read_reference(position + (index * @reference_size), start)
        end
        value_start = position + (count * @reference_size)
        value_refs = Array.new(count) do |index|
          read_reference(value_start + (index * @reference_size), start)
        end
        Node.new(:dictionary, nil, key_refs, value_refs)
      end

      def reference_count(start, info)
        if info != 15
          return [info, start + 1]
        end
        count, position = read_extended_length(start + 1, start)
        [count, position]
      end

      def read_reference(position, object_start)
        bytes = bytes_at!(position, @reference_size, object_start, @reference_size)
        reference = read_integer_bytes(bytes, @reference_size, false)
        if reference >= @object_count
          raise Plist::ParseError.new("object reference is out of bounds", position)
        end
        reference
      end

      def ensure_object_bytes!(start, position, size)
        ending = object_end(start)
        if position + size > ending
          raise Plist::ParseError.new("object references extend past their object", ending)
        end
      end

      def materialize(index, active = {}, cache = {})
        return cache[index] if cache.key?(index)
        if active.key?(index)
          return handle_cycle(index)
        end

        node = @objects.fetch(index)
        active[index] = true
        value = materialize_node(node, index, active, cache)
        active.delete(index)
        if @shared
          cache[index] = value
        end
        value
      end

      def handle_cycle(index)
        case @cycles
        when :reference
          Reference.new(index)
        when :reject, :raise
          raise CyclicReferenceError.new("cyclic reference to object #{index}", index)
        else
          raise ArgumentError, "unknown cycle strategy #{@cycles.inspect}"
        end
      end

      def materialize_node(node, index, active, cache)
        case node.kind
        when :singleton
          node.value
        when :integer, :real, :date, :ascii, :utf16, :utf8, :uid
          node.value
        when :data
          node.value
        when :array
          node.value_refs.map { |reference| materialize(reference, active, cache) }
        when :dictionary
          result = {}
          node.key_refs.each_with_index do |key_reference, pair_index|
            key = materialize(key_reference, active, cache)
            value = materialize(node.value_refs[pair_index], active, cache)
            result[key] = value
          end
          result
        else
          raise Plist::ParseError.new("unsupported object kind #{node.kind}", @positions[index])
        end
      end

      def byte_at!(position)
        bytes_at!(position, 1, position, 1).getbyte(0)
      end

      def bytes_at!(position, size, error_position = position, needed = size)
        if position < 0 || position + size > @data.bytesize
          raise Plist::ParseError.new("binary plist object is truncated", error_position + needed)
        end
        @data.byteslice(position, size)
      end

      def read_integer_bytes(bytes, size, signed)
        value = 0
        bytes.each_byte { |byte| value = (value << 8) | byte }
        if signed && size > 0 && (bytes.getbyte(0) & 0x80) != 0
          value -= (1 << (size * 8))
        end
        value
      end
    end

    class Writer
      def initialize(options = {})
        @nodes = []
        @object_map = {}
      end

      def dump(object)
        root_index = encode(object)
        object_count = @nodes.length
        reference_size = integer_width(object_count - 1)

        @nodes.each { |node| patch_blob(node, reference_size) }
        blobs = @nodes.map(&:blob)

        offset = MAGIC.bytesize
        offsets = blobs.map do |blob|
          current = offset
          offset += blob.bytesize
          current
        end

        offset_table_offset = offset
        offset_size = integer_width(offset_table_offset)

        output = MAGIC.dup.force_encoding(Encoding::BINARY)
        blobs.each { |blob| output << blob }
        offsets.each { |object_offset| output << pack_integer(object_offset, offset_size, false) }
        output << ("\0" * 6) + [
          offset_size,
          reference_size,
          object_count,
          root_index,
          offset_table_offset
        ].pack("CC" + "Q>" * 3)
        output
      end

      private

      def encode(object)
        case object
        when nil then singleton_index(object, "\x00")
        when true then singleton_index(object, "\x09")
        when false then singleton_index(object, "\x08")
        else
          identity = object_identity(object)
          return @object_map[identity] if @object_map.key?(identity)

          node = Node.new(nil, nil, [], [])
          index = @nodes.length
          @nodes << node
          @object_map[identity] = index
          node.kind, node.blob = render(object, node)
          index
        end
      end

      def singleton_index(object, blob)
        identity = object_identity(object)
        unless @object_map.key?(identity)
          @nodes << Node.new(:singleton, nil, [], [], blob.dup.force_encoding(Encoding::BINARY))
          @object_map[identity] = @nodes.length - 1
        end
        @object_map[identity]
      end

      def object_identity(object)
        case object
        when Integer, Float, Symbol, true, false, nil
          [:value, object]
        else
          [:object, object.object_id]
        end
      end

      def render(object, node)
        case object
        when UID
          [:uid, render_uid(object)]
        when Integer
          [:integer, render_integer(object)]
        when Float
          [:real, render_real(object)]
        when Time, DateTime, Date
          [:date, render_date(object)]
        when String, Symbol
          render_string(object.to_s)
        when IO, StringIO
          data = read_io(object)
          [:data, token(0x4, data.bytesize) + data]
        when Array
          object.each { |item| node.value_refs << encode(item) }
          [:array, nil]
        when Hash
          object.each do |key, value|
            node.key_refs << encode(key)
            node.value_refs << encode(value)
          end
          [:dictionary, nil]
        else
          data = Marshal.dump(object)
          [:data, token(0x4, data.bytesize) + data]
        end
      end

      def patch_blob(node, reference_size)
        return unless node.blob.nil?

        case node.kind
        when :array
          node.blob = token(0xA0 >> 4, node.value_refs.length) +
            pack_references(node.value_refs, reference_size)
        when :dictionary
          node.blob = token(0xD, node.key_refs.length) +
            pack_references(node.key_refs, reference_size) +
            pack_references(node.value_refs, reference_size)
        end
      end

      def pack_references(references, reference_size)
        references.map { |reference| pack_integer(reference, reference_size, false) }.join
      end

      def render_integer(value)
        size = integer_storage_width(value)
        (0x10 | Math.log2(size).to_i).chr + pack_integer(value, size, true)
      end

      def render_real(value)
        "\x23" + [value].pack('G')
      end

      def render_date(value)
        "\x33" + [time_value(value) - EPOCH_OFFSET].pack('G')
      end

      def time_value(value)
        case value
        when Time then value.to_r
        when DateTime then date_time_epoch_rational(value)
        when Date then date_time_epoch_rational(value.to_datetime)
        end
      end

      def date_time_epoch_rational(value)
        utc = value.offset == 0 ? value : value.new_offset(0)
        (utc.ajd - DateTime.new(1970, 1, 1).ajd) * 86_400
      end

      def render_string(value)
        if value.encoding == Encoding::BINARY
          bytes = value.dup.force_encoding(Encoding::BINARY)
          [ :data, token(0x4, bytes.bytesize) + bytes ]
        elsif ascii?(value)
          bytes = value.dup.force_encoding(Encoding::BINARY)
          [ :ascii, token(0x5, bytes.bytesize) + bytes ]
        else
          bytes = utf16_bytes(value)
          [ :utf16, token(0x6, bytes.bytesize / 2) + bytes ]
        end
      end

      def ascii?(string)
        string.bytes.all? { |byte| byte < 0x80 }
      end

      def utf16_bytes(string)
        units = []
        string.encode(Encoding::UTF_8).each_codepoint do |codepoint|
          if codepoint > 0xFFFF
            offset = codepoint - 0x10000
            units << 0xD800 + (offset >> 10)
            units << 0xDC00 + (offset & 0x3FF)
          else
            units << codepoint
          end
        end
        units.map { |unit| [unit].pack('n') }.join.force_encoding(Encoding::BINARY)
      end

      def render_uid(uid)
        size = unsigned_integer_width(uid.value)
        if size > 8
          raise Plist::Error.new("UID values larger than 64 bits are not supported")
        end
        (0x80 | (size - 1)).chr + pack_integer(uid.value, size, false)
      end

      def read_io(io)
        io.rewind rescue nil
        value = io.read || String.new
        value.dup.force_encoding(Encoding::BINARY)
      end

      def token(type, length)
        if length < 15
          ((type << 4) | length).chr
        else
          storage = power_of_two_width(unsigned_integer_width(length))
          ((type << 4) | 0x0F).chr +
            (0x10 | Math.log2(storage).to_i).chr +
            pack_integer(length, storage, false)
        end
      end

      def pack_integer(value, size, signed)
        value += (1 << (size * 8)) if signed && value < 0
        Array.new(size) do |index|
          shift = (size - index - 1) * 8
          ((value >> shift) & 0xFF).chr
        end.join.force_encoding(Encoding::BINARY)
      end

      def integer_width(value)
        value <= 0 ? 1 : unsigned_integer_width(value)
      end

      def unsigned_integer_width(value)
        width = 1
        while value >= (1 << (width * 8))
          width *= 2
        end
        width
      end

      def power_of_two_width(width)
        [1, 2, 4, 8, 16].find { |candidate| candidate >= width }
      end

      def integer_storage_width(value)
        if value >= 0
          storage = power_of_two_width(unsigned_integer_width(value))
          if storage > 16 || value >= (1 << 127)
            raise Plist::Error.new("binary plist integer is outside the supported range")
          end
          return storage
        end

        if value < -(1 << 127)
          raise Plist::Error.new("binary plist integer is outside the supported range")
        end
        16
      end
    end
  end
end
