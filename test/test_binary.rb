require 'test/unit'
require 'date'
require 'stringio'
require 'plist'

class TestBinary < Test::Unit::TestCase
  BINARY_HEADER_SIZE = 8

  def test_roundtrips_supported_scalar_types
    time = DateTime.civil(2020, 1, 2, 3, 4, 5)
    source = {
      'integer' => 42,
      'large_integer' => 2 ** 100,
      'negative_integer' => -(2 ** 70),
      'real' => 1.25,
      'date' => time,
      'data' => StringIO.new("".dup.force_encoding(Encoding::BINARY)),
      'ascii' => 'abc',
      'utf16' => "\u00E9\u{1F600}",
      'uid' => Plist::UID.new(4294967295),
      'null' => nil,
      'true' => true,
      'false' => false
    }

    result = Plist.parse_binary(Plist.dump_binary(source))

    assert_equal(42, result['integer'])
    assert_equal(2 ** 100, result['large_integer'])
    assert_equal(-(2 ** 70), result['negative_integer'])
    assert_in_delta(1.25, result['real'], 0.000001)
    assert_equal(time, result['date'])
    data = result['data'].read
    assert_equal(Encoding::BINARY, data.encoding)
    assert_equal(0, data.bytesize)
    assert_equal('abc', result['ascii'])
    assert_equal("\u00E9\u{1F600}", result['utf16'])
    assert_kind_of(Plist::UID, result['uid'])
    assert_equal(4294967295, result['uid'].value)
    assert_not_kind_of(Integer, result['uid'])
    assert_nil(result['null'])
    assert_equal(true, result['true'])
    assert_equal(false, result['false'])
  end

  def test_binary_format_is_selected_explicitly
    source = [1, 'two']

    binary = Plist.dump(source, true, format: :binary)
    assert_equal('bplist00', binary[0, 8])
    assert_equal(source, Plist.parse(binary, format: :binary))
    assert_equal(source, Plist.parse_binary(Plist.dump_binary(source)))
  end

  def test_xml_interface_remains_the_default
    xml = Plist.dump([1])
    assert(xml.start_with?('<?xml'))
    assert_equal([1], Plist.parse(xml))
  end

  def test_preserves_shared_container_references
    shared = [1, 2]
    source = { 'a' => shared, 'b' => shared }

    result = Plist.parse_binary(Plist.dump_binary(source))

    assert_same(result['a'], result['b'])
  end

  def test_preserves_shared_uid_references
    uid = Plist::UID.new(9)
    source = { 'a' => uid, 'b' => uid }

    result = Plist.parse_binary(Plist.dump_binary(source))

    assert_same(result['a'], result['b'])
    assert_equal(uid.value, result['a'].value)
  end

  def test_reads_binary_data_from_io
    source = { 'answer' => 42 }
    encoded = Plist.dump_binary(source)

    assert_equal(source, Plist.parse_binary(StringIO.new(encoded)))
  end

  def test_shared_references_can_be_copied
    shared = [1, 2]
    source = { 'a' => shared, 'b' => shared }

    result = Plist.parse_binary(Plist.dump_binary(source), preserve_shared_references: false)

    assert_not_same(result['a'], result['b'])
    assert_equal(result['a'], result['b'])
  end

  def test_shared_leaf_objects_are_copied_when_requested
    string = 'same'
    uid = Plist::UID.new(3)
    source = { 'a' => string, 'b' => string, 'u1' => uid, 'u2' => uid }

    shared = Plist.parse_binary(Plist.dump_binary(source))
    copied = Plist.parse_binary(Plist.dump_binary(source), preserve_shared_references: false)

    assert_same(shared['a'], shared['b'])
    assert_same(shared['u1'], shared['u2'])
    assert_not_same(copied['a'], copied['b'])
    assert_not_same(copied['u1'], copied['u2'])
    assert_equal(3, copied['u1'].value)
  end

  def test_cycles_are_rejected_by_default_when_writing_and_reading
    cyclic = []
    cyclic << cyclic

    assert_raise(Plist::CyclicReferenceError) { Plist.dump_binary(cyclic) }

    encoded = Plist.dump_binary(cyclic, on_cycle: :reference)
    assert_raise(Plist::CyclicReferenceError) { Plist.parse_binary(encoded) }
  end

  def test_cycles_can_be_returned_as_references
    cyclic = []
    cyclic << cyclic

    encoded = Plist.dump_binary(cyclic, on_cycle: :reference)
    result = Plist.parse_binary(encoded, on_cycle: :reference)

    assert_kind_of(Plist::Reference, result[0])
    assert_equal(0, result[0].object_index)
  end

  def test_uses_two_byte_references_and_offsets
    source = (0...260).to_a
    encoded = Plist.dump_binary(source)

    assert_equal(2, encoded[-26].unpack('C')[0])
    assert_equal(2, encoded[-25].unpack('C')[0])
    assert_equal(source, Plist.parse_binary(encoded))
  end

  def test_parses_each_reference_and_offset_width
    [1, 2, 4, 8].each do |width|
      directive = { 1 => 'C', 2 => 'n', 4 => 'N', 8 => 'Q>' }.fetch(width)
      body = [0x10, 1, 0xa1].pack('C3') + [0].pack(directive)
      offset_table_position = BINARY_HEADER_SIZE + body.bytesize
      encoded = Plist::BINARY_MAGIC + body + [8, 10].pack(directive + '2') +
        [0, 0, 0, 0, 0, 0, width, width, 2, 1, offset_table_position].pack('C6CCQ>3')

      assert_equal([1], Plist.parse_binary(encoded))
    end
  end

  def test_object_count_limit_is_configurable
    source = [1, 2]
    encoded = Plist.dump_binary(source)

    error = assert_raise(Plist::LimitExceededError) do
      Plist.parse_binary(encoded, max_objects: 1)
    end
    assert_match(/object count/, error.message)
  end

  def test_object_length_limit_is_configurable
    source = 'x' * 16
    encoded = Plist.dump_binary(source)

    assert_raise(Plist::LimitExceededError) do
      Plist.parse_binary(encoded, max_object_length: 15)
    end
  end

  def test_damaged_trailer_reports_trailer_position
    encoded = 'bplist00' +
      [0x10, 1].pack('CC') +
      [8].pack('C') +
      [0, 0, 0, 0, 0, 0, 9, 1, 1, 0, 10].pack('C6CCQ>3')

    error = assert_raise(Plist::BinaryParseError) { Plist.parse_binary(encoded) }
    assert_equal(encoded.bytesize - 32 + 6, error.position)
  end

  def test_out_of_bounds_reference_reports_reference_position
    encoded = Plist.dump_binary([1])
    trailer = encoded[-32..-1].unpack('C6CCQ>3')
    array_offset = encoded[trailer[10], trailer[6]].unpack('C')[0]
    integer_offset = encoded[trailer[10] + trailer[6], trailer[6]].unpack('C')[0]
    reference_position = array_offset + 1
    encoded[reference_position] = [255].pack('C')

    error = assert_raise(Plist::BinaryParseError) { Plist.parse_binary(encoded) }
    assert_equal(reference_position, error.position)
    assert_match(/outside the object table/, error.message)
    assert_equal(10, integer_offset)
  end

  def test_half_utf16_character_reports_object_position
    object_offset = 8
    encoded = 'bplist00' +
      [0x6f, 0x10, 0x01].pack('C3') +
      [object_offset].pack('C') +
      [0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 11].pack('C6CCQ>3')

    error = assert_raise(Plist::BinaryParseError) { Plist.parse_binary(encoded) }
    assert_equal(object_offset, error.position)
    assert_match(/partial character/, error.message)
  end
end
