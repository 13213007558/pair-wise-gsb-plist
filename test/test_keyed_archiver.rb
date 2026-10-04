# encoding: utf-8

require 'stringio'
require 'test/unit'
require 'plist'

class TestKeyedArchiver < Test::Unit::TestCase
  def uid(index)
    { 'CF$UID' => index }
  end

  def class_description(name, classes = [name, 'NSObject'])
    { '$classname' => name, '$classes' => classes }
  end

  def archive(objects, root_index = nil)
    top = root_index.nil? ? {} : { 'root' => uid(root_index) }
    Plist.decode_keyed_archive(
      '$archiver' => 'NSKeyedArchiver',
      '$objects' => objects,
      '$top' => top
    )
  end

  def test_decodes_supported_mutable_and_immutable_classes
    objects = [
      '$null',
      class_description('NSString'),
      class_description('NSMutableString'),
      { '$class' => uid(2), 'NS.string' => 'value' },
      class_description('NSNumber'),
      { '$class' => uid(4), 'NS.intval' => 42 },
      { '$class' => uid(4), 'NS.boolval' => true },
      { '$class' => uid(4), 'NS.realval' => 1.5 },
      class_description('NSMutableData'),
      { '$class' => uid(8), 'NS.data' => StringIO.new('abc') },
      class_description('NSDate'),
      { '$class' => uid(10), 'NS.time' => 0 },
      class_description('NSMutableArray'),
      { '$class' => uid(12), 'NS.objects' => [uid(3)] },
      class_description('NSMutableDictionary'),
      {
        '$class' => uid(14),
        'NS.keys' => [uid(3)],
        'NS.objects' => [uid(6)]
      }
    ]

    decoded = archive(objects, 15)

    assert_equal('value', decoded.objects[3])
    assert_equal(42, decoded.objects[5])
    assert_equal(true, decoded.objects[6])
    assert_in_delta(1.5, decoded.objects[7])
    assert_equal(Encoding::BINARY, decoded.objects[9].encoding)
    assert_equal('abc', decoded.objects[9])
    assert_equal(Time.utc(2001, 1, 1), decoded.objects[11])
    assert_equal(['value'], decoded.objects[13])
    assert_equal({ 'value' => true }, decoded.objects[15])
    assert_equal(decoded.objects[15], decoded.root)
  end

  def test_shared_containers_and_cycles_keep_one_object_identity
    objects = [
      '$null',
      class_description('NSArray'),
      class_description('NSDictionary'),
      { '$class' => uid(1), 'NS.objects' => [uid(5)] },
      { '$class' => uid(1), 'NS.objects' => [uid(5)] },
      {
        '$class' => uid(2),
        'NS.keys' => [uid(7)],
        'NS.objects' => [uid(3)]
      },
      { '$class' => uid(1), 'NS.objects' => [uid(3), uid(4)] },
      'group'
    ]

    decoded = archive(objects, 6)
    first_array = decoded.root[0]
    second_array = decoded.root[1]
    shared_dictionary = first_array[0]

    assert_same(shared_dictionary, second_array[0])
    assert_same(first_array, shared_dictionary['group'])
    assert_same(decoded.objects[5], shared_dictionary)
  end

  def test_unknown_classes_become_lazy_nodes
    objects = [
      '$null',
      class_description('Waffle', ['Waffle', 'NSObject']),
      { '$class' => uid(1), 'NS.objects' => [uid(3)] },
      { '$class' => uid(1), 'topping' => 'maple', 'pair' => uid(2) }
    ]

    decoded = archive(objects, 3)
    unknown = decoded.objects[3]

    assert_kind_of(Plist::KeyedArchiver::LazyObject, unknown)
    assert_equal(3, unknown.object_index)
    assert_equal('Waffle', unknown.class_name)
    assert_equal(['Waffle', 'NSObject'], unknown.classes)
    assert_equal('maple', unknown.field('topping'))
    assert_same(decoded.objects[2], unknown.field('pair'))
    assert(decoded.errors.empty?)
  end

  def test_unkeyed_primitive_records_remain_plain_values
    objects = [
      '$null',
      'plain string',
      7,
      true,
      StringIO.new("\x00\x01".b)
    ]

    decoded = archive(objects, 1)

    assert_equal('plain string', decoded.objects[1])
    assert_equal(7, decoded.objects[2])
    assert_equal(true, decoded.objects[3])
    assert_equal("\x00\x01".b, decoded.objects[4])
    assert(decoded.errors.empty?)
  end

  def test_invalid_uids_and_class_descriptions_are_reported_by_object_number
    objects = [
      '$null',
      class_description('NSArray', ['NSDictionary', 'NSObject']),
      { '$class' => uid(1), 'NS.objects' => [uid(99)] },
      class_description('NSArray', ['NSArray', 'NSObject']),
      { '$class' => uid(99), 'NS.objects' => [] },
      class_description('NSArray'),
      {
        '$class' => uid(5),
        'NS.objects' => [
          { 'CF$UID' => 'bad' },
          uid(99)
        ]
      },
      class_description('Waffle', ['Waffle', 'NSObject']),
      { '$class' => uid(7), 'topping' => 'maple' }
    ]

    decoded = archive(objects, 2)

    assert(error_codes(decoded, 1).include?(:class_name_mismatch))
    assert(error_codes(decoded, 3).include?(:duplicate_class_description))
    assert(error_codes(decoded, 4).include?(:uid_out_of_range))
    assert(error_codes(decoded, 6).include?(:invalid_uid))
    assert(error_codes(decoded, 6).include?(:uid_out_of_range))

    assert_kind_of(Array, decoded.objects[2])
    assert_kind_of(Plist::KeyedArchiver::InvalidReference, decoded.objects[2][0])
    assert_equal(2, decoded.objects[2][0].object_index)
    assert_kind_of(Plist::KeyedArchiver::MalformedObject, decoded.objects[4])
    assert_equal(4, decoded.objects[4].object_index)
    assert_kind_of(Plist::KeyedArchiver::LazyObject, decoded.objects[8])
  end

  def test_incorrect_class_description_reports_its_own_object_number
    objects = [
      '$null',
      {
        '$classname' => 'NSArray',
        '$classes' => ['NSArray', 'NSObject'],
        '$class' => uid(0)
      },
      { '$class' => uid(1), 'NS.objects' => [] }
    ]

    decoded = archive(objects, 2)

    assert(error_codes(decoded, 1).include?(:invalid_class_descriptor))
    assert(error_codes(decoded, 2).include?(:invalid_class_description))
    assert_kind_of(Array, decoded.objects[2])
  end

  def test_rejects_input_that_is_not_a_keyed_archive
    assert_raise(ArgumentError) do
      Plist.decode_keyed_archive({})
    end
  end

  private

  def error_codes(decoded, object_number)
    decoded.errors[object_number].map(&:code)
  end
end
