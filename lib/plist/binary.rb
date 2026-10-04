# encoding: utf-8

require 'date'
require 'stringio'

module Plist
  class BinaryPlistError < StandardError; end

  class BinaryParseError < BinaryPlistError
    attr_reader :position

    def initialize(message, position = nil)
      super(position.nil? ? message : "#{message} at byte #{position}")
      @position = position
    end
  end

  class CyclicReferenceError < BinaryPlistError; end
  class LimitExceededError < BinaryParseError; end

  UID = Struct.new(:value)
  Reference = Struct.new(:object_index) do
    alias index object_index
  end

  BINARY_MAGIC = 'bplist00'.freeze
  BINARY_EPOCH = DateTime.civil(2001, 1, 1)

  def self.parse_binary(filename_or_data, options = {})
    BinaryReader.new(options).parse(read_input(filename_or_data))
  end

  def self.dump_binary(obj, options = {})
    BinaryWriter.new(options).dump(obj)
  end

  def self.read_input(filename_or_data)
    if filename_or_data.respond_to?(:read)
      filename_or_data.read
    elsif file_input?(filename_or_data)
      File.binread(filename_or_data)
    else
      filename_or_data
    end
  end

  def self.file_input?(value)
    value.is_a?(String) && File.exist?(value)
  rescue ArgumentError
    false
  end

  class BinaryReader
    RawObject = Struct.new(:kind, :value, :references, :position, :end_position)

    DEFAULT_MAX_OBJECTS = 100_000
    DEFAULT_MAX_OBJECT_LENGTH = 16 * 1024 * 1024

    def initialize(options = {})
      @max_objects = options.fetch(:max_objects, DEFAULT_MAX_OBJECTS)
      @max_object_length = options.fetch(:max_object_length,
        options.fetch(:max_length, DEFAULT_MAX_OBJECT_LENGTH))
      @shared = options.fetch(:preserve_shared_references,
        options.fetch(:shared, true))
      @cycle_strategy = options.fetch(:on_cycle,
        options.fetch(:cycle_strategy, options.fetch(:cyclic, :raise)))
      @marshal = options.fetch(:marshal, false)

      unless [:raise, :reference].include?(@cycle_strategy)
        raise ArgumentError, 'on_cycle must be :raise or :reference'
      end
    end

    def parse(input)
      raise BinaryParseError.new('binary plist is empty', 0) if input.nil?

      @data = input.dup.force_encoding(Encoding::BINARY)
      parse_trailer
      parse_offset_table
      parse_object_table
      materialize(@root_index)
    end

    private

    def parse_trailer
      @trailer_position = @data.bytesize - 32
      if @data.bytesize < 40
        raise BinaryParseError.new('binary plist must contain an 8 byte header and 32 byte trailer', 0)
      end
      unless @data.byteslice(0, 8) == BINARY_MAGIC
        raise BinaryParseError.new('invalid binary plist header', 0)
      end

      trailer = @data.byteslice(@trailer_position, 32).unpack('C6CCQ>3')
      @offset_size = trailer[6]
      @reference_size = trailer[7]
      @object_count = trailer[8]
      @root_index = trailer[9]
      @offset_table_position = trailer[10]

      unless [1, 2, 4, 8].include?(@offset_size)
        raise BinaryParseError.new('trailer offset size must be 1, 2, 4, or 8', @trailer_position + 6)
      end
      unless [1, 2, 4, 8].include?(@reference_size)
        raise BinaryParseError.new('trailer reference size must be 1, 2, 4, or 8', @trailer_position + 7)
      end
      if @object_count < 1 || @object_count > @max_objects
        raise LimitExceededError, "object count #{@object_count} exceeds limit #{@max_objects}"
      end
      if @root_index >= @object_count
        raise BinaryParseError.new('root object index is outside the object table', @trailer_position + 16)
      end
      if @offset_table_position < 8 || @offset_table_position > @trailer_position
        raise BinaryParseError.new('offset table position is outside the plist', @trailer_position + 24)
      end

      offset_table_length = multiply_count(@object_count, @offset_size, 'offset table')
      if @offset_table_position + offset_table_length > @trailer_position
        raise BinaryParseError.new('offset table overlaps the trailer', @trailer_position + 24)
      end
    end

    def multiply_count(count, width, label)
      length = count * width
      if length > @max_object_length || length / width != count
        raise LimitExceededError, "#{label} length exceeds limit #{@max_object_length}"
      end
      length
    end

    def parse_offset_table
      @offsets = Array.new(@object_count)
      @object_count.times do |index|
        position = @offset_table_position + index * @offset_size
        offset = read_integer(position, @offset_size, false, 'offset')
        if offset < 8 || offset >= @offset_table_position
          raise BinaryParseError.new("object #{index} offset is outside the object table", position)
        end
        @offsets[index] = offset
      end

      if @offsets != @offsets.sort || @offsets.uniq.size != @offsets.size
        raise BinaryParseError.new('object offsets must be unique and ordered', @offset_table_position)
      end
    end

    def parse_object_table
      @objects = Array.new(@object_count)
      @object_count.times do |index|
        @objects[index] = parse_object(@offsets[index], index)
        object_end = index + 1 < @object_count ? @offsets[index + 1] : @offset_table_position
        if @objects[index].end_position > object_end
          raise BinaryParseError.new("object #{index} overlaps another object", @objects[index].position)
        end
      end
    end

    def parse_object(position, index)
      marker = read_byte(position, "object #{index} marker")
      high = marker >> 4
      low = marker & 0x0f

      case marker
      when 0x00 then return RawObject.new(:null, nil, [], position, position + 1)
      when 0x08 then return RawObject.new(:boolean, false, [], position, position + 1)
      when 0x09 then return RawObject.new(:boolean, true, [], position, position + 1)
      when 0x0f then raise BinaryParseError.new('filler objects cannot be referenced', position)
      end

      case high
      when 1 then parse_integer(low, position)
      when 2 then parse_real(low, position)
      when 3 then parse_date(low, position)
      when 4 then parse_data(low, position)
      when 5 then parse_ascii_string(low, position)
      when 6 then parse_utf16_string(low, position)
      when 10 then parse_array(low, position)
      when 13 then parse_dictionary(low, position)
      when 8 then parse_uid(low, position)
      else raise BinaryParseError.new("unsupported object type 0x#{marker.to_s(16).rjust(2, '0')}", position)
      end
    end

    def parse_integer(low, position)
      unless (0..4).include?(low)
        raise BinaryParseError.new('invalid integer width', position)
      end
      width = 1 << low
      RawObject.new(:integer, read_integer(position + 1, width, true, 'integer'),
        [], position, position + 1 + width)
    end

    def parse_real(low, position)
      case low
      when 2
        value = read_bytes(position + 1, 4, 'float').unpack('g')[0]
        width = 4
      when 3
        value = read_bytes(position + 1, 8, 'double').unpack('G')[0]
        width = 8
      else
        raise BinaryParseError.new('invalid real width', position)
      end
      RawObject.new(:real, value, [], position, position + 1 + width)
    end

    def parse_date(low, position)
      unless low == 3
        raise BinaryParseError.new('invalid date width', position)
      end
      seconds = read_bytes(position + 1, 8, 'date').unpack('G')[0]
      RawObject.new(:date, BINARY_EPOCH + Rational(seconds) / 86_400,
        [], position, position + 9)
    end

    def parse_uid(low, position)
      width = low + 1
      unless (1..16).include?(width)
        raise BinaryParseError.new('invalid UID width', position)
      end
      value = read_integer(position + 1, width, false, 'UID')
      RawObject.new(:uid, UID.new(value), [], position, position + 1 + width)
    end

    def parse_data(low, position)
      length, payload_position = read_length(low, position + 1, 'data')
      value = read_bounded_bytes(payload_position, length, 'data')
      RawObject.new(:data, value, [], position, payload_position + length)
    end

    def parse_ascii_string(low, position)
      length, payload_position = read_length(low, position + 1, 'string')
      value = read_bounded_bytes(payload_position, length, 'ASCII string')
      unless value.bytes.all? { |byte| byte < 0x80 }
        raise BinaryParseError.new('ASCII string contains a non-ASCII byte', position)
      end
      RawObject.new(:string, value.force_encoding(Encoding::UTF_8),
        [], position, payload_position + length)
    end

    def parse_utf16_string(low, position)
      length, payload_position = read_length(low, position + 1, 'string')
      available = @offset_table_position - payload_position
      if available < length * 2
        raise BinaryParseError.new('UTF-16 string contains a partial character', position)
      end
      value = read_bytes(payload_position, length * 2, 'UTF-16 string')
      begin
        value = value.encode(Encoding::UTF_8, Encoding::UTF_16BE)
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise BinaryParseError.new('UTF-16 string contains invalid data', position)
      end
      RawObject.new(:string, value, [], position, payload_position + length * 2)
    end

    def parse_array(low, position)
      count, payload_position = read_length(low, position + 1, 'array')
      check_length(count, 'array', position)
      ensure_payload_bounds(payload_position, count * @reference_size, 'array')
      references = read_references(payload_position, count)
      RawObject.new(:array, nil, references, position,
        payload_position + count * @reference_size)
    end

    def parse_dictionary(low, position)
      count, payload_position = read_length(low, position + 1, 'dictionary')
      check_length(count, 'dictionary', position)
      ensure_payload_bounds(payload_position, count * @reference_size * 2, 'dictionary')
      keys = read_references(payload_position, count)
      values_start = payload_position + count * @reference_size
      values = read_references(values_start, count)
      RawObject.new(:dictionary, keys.zip(values), keys + values, position,
        values_start + count * @reference_size)
    end

    def read_length(low, length_position, label)
      if low != 15
        check_length(low, label, length_position - 1)
        [low, length_position]
      else
        marker = read_byte(length_position, "#{label} length marker")
        unless marker >> 4 == 1 && (0..4).include?(marker & 0x0f)
          raise BinaryParseError.new("invalid #{label} length encoding", length_position)
        end
        width = 1 << (marker & 0x0f)
        if length_position + 1 + width > @offset_table_position
          raise BinaryParseError.new("invalid #{label} length encoding", length_position)
        end
        length = read_integer(length_position + 1, width, false, 'length')
        check_length(length, label, length_position)
        [length, length_position + 1 + width]
      end
    end

    def check_length(length, label, position)
      if length > @max_object_length
        raise LimitExceededError, "#{label} length #{length} exceeds limit #{@max_object_length}"
      end
    end

    def read_references(position, count)
      multiply_count(count, @reference_size, 'collection')
      Array.new(count) do |index|
        reference_position = position + index * @reference_size
        reference = read_integer(reference_position, @reference_size, false, 'reference')
        if reference >= @object_count
          raise BinaryParseError.new(
            "object reference #{reference} is outside the object table",
            reference_position)
        end
        reference
      end
    end

    def ensure_payload_bounds(position, length, label)
      multiply_count(length, 1, label)
      if position < 8 || position + length > @offset_table_position
        raise BinaryParseError.new("#{label} references overlap the offset table", position)
      end
    end

    def materialize(index, path = [])
      if @shared
        materialize_shared(index)
      else
        materialize_copy(index, path)
      end
    end

    def materialize_shared(index)
      @materialized ||= {}
      @active ||= {}
      return @materialized[index] if @materialized.key?(index)
      return cycle_reference(index) if @active.key?(index)

      raw = @objects[index]
      leaf = materialize_leaf(raw)
      return @materialized[index] = leaf unless leaf.nil? && container?(raw)

      @active[index] = true
      @materialized[index] = case raw.kind
      when :array
        raw.references.map { |child| materialize_shared(child) }
      when :dictionary
        raw.value.each_with_object({}) do |(key, value), result|
          result[materialize_shared(key)] = materialize_shared(value)
        end
      end
      @active.delete(index)
      @materialized[index]
    end

    def materialize_copy(index, path)
      return cycle_reference(index) if path.include?(index)

      raw = @objects[index]
      leaf = materialize_leaf(raw, true)
      return leaf unless leaf.nil? && container?(raw)

      next_path = path + [index]
      case raw.kind
      when :array
        raw.references.map { |child| materialize_copy(child, next_path) }
      when :dictionary
        raw.value.each_with_object({}) do |(key, value), result|
          result[materialize_copy(key, next_path)] = materialize_copy(value, next_path)
        end
      end
    end

    def container?(raw)
      raw.kind == :array || raw.kind == :dictionary
    end

    def materialize_leaf(raw, independent_copy = false)
      case raw.kind
      when :null then nil
      when :boolean, :integer, :real then raw.value
      when :string then independent_copy ? raw.value.dup : raw.value
      when :uid then independent_copy ? UID.new(raw.value.value) : raw.value
      when :date then independent_copy ? raw.value.dup : raw.value
      when :data then materialize_data(raw.value)
      end
    end

    def materialize_data(bytes)
      if @marshal
        begin
          return Marshal.load(bytes)
        rescue Exception
        end
      end
      io = StringIO.new
      io.binmode
      io.write(bytes)
      io.rewind
      io
    end

    def cycle_reference(index)
      unless @cycle_strategy == :reference
        raise CyclicReferenceError, "cyclic reference to object #{index}"
      end
      Reference.new(index)
    end

    def read_byte(position, label)
      read_integer(position, 1, false, label)
    end

    def read_integer(position, width, signed, label)
      bytes = read_bytes(position, width, label)
      value = bytes.each_byte.inject(0) { |result, byte| (result << 8) | byte }
      if signed && value >= (1 << ((width * 8) - 1))
        value -= (1 << (width * 8))
      end
      value
    end

    def read_bounded_bytes(position, length, label)
      if position + length > @offset_table_position
        raise BinaryParseError.new("#{label} extends past the object table", position)
      end
      read_bytes(position, length, label)
    end

    def read_bytes(position, length, label)
      if position < 0 || length < 0 || position > @data.bytesize
        raise BinaryParseError.new("#{label} starts outside the plist", position)
      end
      value = @data.byteslice(position, length)
      if value.nil? || value.bytesize != length
        raise BinaryParseError.new("unexpected end of plist while reading #{label}", position)
      end
      value
    end
  end

  class BinaryWriter
    Node = Struct.new(:kind, :value, :references) do
      def container?
        kind == :array || kind == :dictionary
      end
    end

    def initialize(options = {})
      @cycle_strategy = options.fetch(:on_cycle,
        options.fetch(:cycle_strategy, options.fetch(:cyclic, :raise)))
      unless [:raise, :reference].include?(@cycle_strategy)
        raise ArgumentError, 'on_cycle must be :raise or :reference'
      end
    end

    def dump(root)
      @nodes = []
      @identity = {}
      @active = {}
      root_index = register(root)
      @reference_size = reference_width(@nodes.size - 1)

      body = @nodes.map { |node| encode_node(node) }.join.force_encoding(Encoding::BINARY)
      offsets = []
      position = BINARY_MAGIC.bytesize
      @nodes.each do |node|
        offsets << position
        position += encoded_node_size(node)
      end

      offset_table_position = BINARY_MAGIC.bytesize + body.bytesize
      offset_size = [1, 2, 4, 8].find { |width| offsets.last <= unsigned_maximum(width) }
      raise BinaryPlistError, 'binary plist is too large to encode' if offset_size.nil?

      output = BINARY_MAGIC.dup.force_encoding(Encoding::BINARY)
      output << body
      offsets.each { |offset| output << encode_unsigned_integer(offset, offset_size) }
      output << encode_trailer(offset_size, @reference_size, @nodes.size,
        root_index, offset_table_position)
      output
    end

    private

    def register(value)
      if identity_key?(value)
        key = [value.class, value.object_id]
        return handle_cycle(value) if @active.key?(key)
        return @identity[key] if @identity.key?(key)
      end

      index = @nodes.size
      if identity_key?(value)
        key = [value.class, value.object_id]
        @identity[key] = index
        @active[key] = true
      end

      node = build_node(value)
      @nodes << node
      register_references(node)
      @active.delete([value.class, value.object_id]) if identity_key?(value)
      index
    end

    def identity_key?(value)
      value.is_a?(UID) || value.is_a?(Array) || value.is_a?(Hash) ||
        value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(Date) ||
        value.is_a?(IO) || value.is_a?(StringIO)
    end

    def handle_cycle(value)
      raise CyclicReferenceError, "cyclic reference to #{value.class}" unless @cycle_strategy == :reference
      @identity[[value.class, value.object_id]]
    end

    def build_node(value)
      case value
      when nil then Node.new(:null, nil, [])
      when true, false then Node.new(:boolean, value, [])
      when UID then Node.new(:uid, value.value, [])
      when Integer then Node.new(:integer, value, [])
      when Float then Node.new(:real, value, [])
      when Time, Date then Node.new(:date, value, [])
      when String then build_string_node(value)
      when Symbol then build_string_node(value.to_s)
      when IO, StringIO then Node.new(:data, read_io(value), [])
      when Array then Node.new(:array, value, [])
      when Hash then Node.new(:dictionary, value, [])
      else
        Node.new(:data, Marshal.dump(value), [])
      end
    end

    def build_string_node(value)
      string = value.dup
      if string.encoding == Encoding::ASCII_8BIT
        utf8 = string.dup.force_encoding(Encoding::UTF_8)
        string = utf8 if utf8.valid_encoding?
      end

      if string.encoding == Encoding::ASCII_8BIT || !string.valid_encoding?
        raise BinaryPlistError, 'binary strings must be wrapped in an IO object'
      end

      if string.ascii_only?
        Node.new(:ascii, string.dup.force_encoding(Encoding::BINARY), [])
      else
        Node.new(:utf16, string.encode(Encoding::UTF_16BE).force_encoding(Encoding::BINARY), [])
      end
    end

    def read_io(io)
      position = io.pos rescue nil
      io.rewind
      io.binmode if io.respond_to?(:binmode)
      io.read.force_encoding(Encoding::BINARY)
    ensure
      io.seek(position) if position && io.respond_to?(:seek)
    end

    def register_references(node)
      return unless node.container?

      if node.kind == :array
        node.references.replace(node.value.map { |item| register(item) })
      else
        node.references.replace(node.value.flat_map do |key, value|
          [register(key), register(value)]
        end)
      end
    end

    def encode_node(node)
      case node.kind
      when :null then "\x00"
      when :boolean then node.value ? "\x09" : "\x08"
      when :integer then encode_integer(node.value)
      when :real then [0x23, node.value].pack('CG')
      when :date then [0x33, date_seconds(node.value)].pack('CG')
      when :uid then encode_uid(node.value)
      when :data then encode_blob(0x40, node.value)
      when :ascii then encode_blob(0x50, node.value)
      when :utf16 then encode_blob(0x60, node.value, node.value.bytesize / 2)
      when :array then encode_container(0xa0, node)
      when :dictionary then encode_container(0xd0, node)
      end.dup.force_encoding(Encoding::BINARY)
    end

    def encoded_node_size(node)
      encode_node(node).bytesize
    end

    def encode_integer(value)
      width = signed_integer_width(value)
      marker = 0x10 | Math.log2(width).to_i
      [marker].pack('C') + encode_signed_integer(value, width)
    end

    def encode_uid(value)
      width = unsigned_integer_width(value)
      [0x80 | (width - 1)].pack('C') + encode_unsigned_integer(value, width)
    end

    def encode_blob(marker, bytes, logical_length = bytes.bytesize)
      [marker_with_length(marker, logical_length)].pack('C') +
        length_suffix(logical_length) + bytes
    end

    def encode_container(marker, node)
      count = node.kind == :array ? node.references.size : node.references.size / 2
      output = [marker_with_length(marker, count)].pack('C') + length_suffix(count)
      references = node.kind == :dictionary ? node.references.each_slice(2).to_a.transpose.flatten : node.references
      references.each { |reference| output << encode_unsigned_integer(reference, @reference_size) }
      output
    end

    def marker_with_length(marker, length)
      length < 15 ? marker | length : marker | 15
    end

    def length_suffix(length)
      return ''.dup.force_encoding(Encoding::BINARY) if length < 15
      width = unsigned_integer_width(length)
      [0x10 | Math.log2(width).to_i].pack('C') + encode_unsigned_integer(length, width)
    end

    def date_seconds(value)
      date = value.is_a?(Time) ? value.to_datetime : value
      ((date - BINARY_EPOCH) * 86_400).to_f
    end

    def encode_trailer(offset_size, reference_size, count, root_index, offset_table_position)
      [0, 0, 0, 0, 0, 0, offset_size, reference_size, count, root_index,
       offset_table_position].pack('C6CCQ>3')
    end

    def encode_signed_integer(value, width)
      value += (1 << (width * 8)) if value < 0
      encode_unsigned_integer(value, width)
    end

    def encode_unsigned_integer(value, width)
      bytes = Array.new(width) do |index|
        (value >> ((width - 1 - index) * 8)) & 0xff
      end
      bytes.pack('C*')
    end

    def integer_width(value)
      [1, 2, 4, 8].find { |width| value <= unsigned_maximum(width) } ||
        raise(BinaryPlistError, 'object reference is too large')
    end

    alias reference_width integer_width

    def unsigned_integer_width(value)
      raise BinaryPlistError, 'integer must not be negative' if value < 0
      [1, 2, 4, 8, 16].find { |width| value <= unsigned_maximum(width) } ||
        raise(BinaryPlistError, 'integer is too large')
    end

    def signed_integer_width(value)
      [1, 2, 4, 8, 16].find { |width| value >= -signed_limit(width) && value <= signed_limit(width) - 1 } ||
        raise(BinaryPlistError, 'integer is too large')
    end

    def unsigned_maximum(width)
      (1 << (width * 8)) - 1
    end

    def signed_limit(width)
      1 << ((width * 8) - 1)
    end
  end
end
