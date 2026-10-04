require 'test/unit'
require 'stringio'
require 'plist'

class TestBinaryPlist < Test::Unit::TestCase
  def roundtrip(value, options = {})
    binary = Plist.dump(value, format: :binary)
    [binary, Plist.parse(binary, options.merge(format: :binary))]
  end

  def test_explicit_binary_format
    binary = Plist::Emit.dump(1, true, format: :binary)

    assert_equal('bplist00', binary.byteslice(0, 8))
    assert_equal(1, Plist.parse_binary(binary))
    assert_equal(1, Plist.parse(binary, format: :binary))
    assert_equal(binary, Plist::Emit.dump(1, true, format: :binary))
  end

  def test_xml_remains_the_default
    xml = Plist.dump(1)
    result = Plist.parse(xml)

    assert(xml.start_with?('<?xml'))
    assert_equal(1, result)
  end

  def test_scalar_roundtrip
    time = Time.utc(2020, 1, 2, 3, 4, 5)
    value = {
      'true' => true,
      'false' => false,
      'null' => nil,
      'positive big integer' => (1 << 100) + 42,
      'negative big integer' => -(1 << 100) - 7,
      'largest signed 128 bit integer' => (1 << 127) - 1,
      'negative small integer' => -8,
      'real' => 3.14159,
      'date' => time,
      'uid' => Plist::UID.new(12345)
    }

    _binary, result = roundtrip(value)

    assert_equal(true, result['true'])
    assert_equal(false, result['false'])
    assert_nil(result['null'])
    assert_equal((1 << 100) + 42, result['positive big integer'])
    assert_equal(-(1 << 100) - 7, result['negative big integer'])
    assert_equal((1 << 127) - 1, result['largest signed 128 bit integer'])
    assert_equal(-8, result['negative small integer'])
    assert_in_delta(3.14159, result['real'], 0.0000001)
    assert_kind_of(Time, result['date'])
    assert_in_delta(time.to_f, result['date'].to_f, 0.001)
    assert_instance_of(Plist::UID, result['uid'])
    assert_equal(12345, result['uid'].value)
    assert_not_kind_of(Integer, result['uid'])
  end

  def test_ascii_utf16_data_and_empty_data_roundtrip
    value = {
      'ascii' => 'hello',
      'utf16' => "hello \u{4E2D}\u{1F600}",
      'data' => StringIO.new("\x00\x80\xff".b),
      'empty data' => StringIO.new(''.b)
    }

    _binary, result = roundtrip(value)

    assert_equal('hello', result['ascii'])
    assert_equal("hello \u{4E2D}\u{1F600}", result['utf16'])
    assert_kind_of(StringIO, result['data'])
    assert_equal("\x00\x80\xff".b, result['data'].read)
    assert_kind_of(StringIO, result['empty data'])
    assert_equal(''.b, result['empty data'].read)
  end

  def test_shared_references_are_preserved_when_requested
    shared = ['value']
    value = [shared, shared]

    _binary, result = roundtrip(value, shared: true)

    assert_same(result[0], result[1])
  end

  def test_shared_references_are_expanded_by_default
    shared = ['value']
    value = [shared, shared]

    _binary, result = roundtrip(value)

    assert_equal(result[0], result[1])
    assert_not_same(result[0], result[1])
  end

  def test_cycle_can_be_returned_as_reference
    value = []
    value << value
    binary = Plist.dump(value, format: :binary)

    result = Plist.parse(binary, format: :binary, shared: true, cycles: :reference)

    assert_instance_of(Plist::Reference, result[0])
    assert_equal(0, result[0].object_index)
  end

  def test_cycle_is_rejected_by_default_in_shared_mode
    value = []
    value << value
    binary = Plist.dump(value, format: :binary)

    error = assert_raise(Plist::CyclicReferenceError) do
      Plist.parse(binary, format: :binary, shared: true)
    end
    assert_equal(0, error.object_index)
  end

  def test_cycle_can_be_explicitly_rejected
    value = {}
    value['self'] = value
    binary = Plist.dump(value, format: :binary)

    assert_raise(Plist::CyclicReferenceError) do
      Plist.parse(binary, format: :binary, shared: true, cycles: :reject)
    end
  end

  def test_corrupt_trailer_reports_error_offset
    binary = Plist.dump(1, format: :binary).dup
    binary.setbyte(binary.bytesize - 26, 0)

    error = assert_raise(Plist::ParseError) do
      Plist.parse(binary, format: :binary)
    end
    assert_equal(binary.bytesize - 26, error.offset)
  end

  def test_out_of_bounds_reference_reports_error_offset
    binary = Plist.dump([1], format: :binary).dup
    binary.setbyte(9, 0xff)

    error = assert_raise(Plist::ParseError) do
      Plist.parse(binary, format: :binary)
    end
    assert_equal(9, error.offset)
  end

  def test_half_utf16_character_reports_error_offset
    binary = Plist.dump(['A', ''], format: :binary).dup
    binary.setbyte(13, 0x61)

    error = assert_raise(Plist::ParseError) do
      Plist.parse(binary, format: :binary)
    end
    assert_equal(14, error.offset)
  end

  def test_object_count_limit_is_configurable
    binary = Plist.dump([1], format: :binary)

    assert_raise(Plist::ParseError) do
      Plist.parse(binary, format: :binary, max_objects: 1)
    end
  end

  def test_data_length_limit_is_configurable
    binary = Plist.dump(StringIO.new('abc'.b), format: :binary)

    assert_raise(Plist::ParseError) do
      Plist.parse(binary, format: :binary, max_data_length: 2)
    end
  end

  def test_total_length_limit_is_configurable
    binary = Plist.dump('abc', format: :binary)

    assert_raise(Plist::ParseError) do
      Plist.parse(binary, format: :binary, max_length: binary.bytesize - 1)
    end
  end

  def test_variable_offset_and_reference_widths
    values = 257.times.map { |index| index * 37 }
    long_ascii = Plist.dump(values, format: :binary)

    assert_equal(2, long_ascii.getbyte(long_ascii.bytesize - 25))
    assert_equal(2, long_ascii.getbyte(long_ascii.bytesize - 26))
    result = Plist.parse(long_ascii, format: :binary)
    assert_equal(values, result)

    long_data = Plist.dump(StringIO.new('a'.b * 257), format: :binary)
    data_result = Plist.parse(long_data, format: :binary)
    assert_equal(257, data_result.read.bytesize)
  end

  def test_writer_and_parser_options_are_not_mutated
    parse_options = { format: :binary, shared: true }
    dump_options = { format: :binary }
    binary = Plist.dump([1, 2], dump_options)
    Plist.parse(binary, parse_options)

    assert_equal(:binary, parse_options[:format])
    assert_equal(:binary, dump_options[:format])
  end
end
