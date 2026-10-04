require 'test/unit'
require 'plist'

class TestNSKeyedArchiver < Test::Unit::TestCase
  def test_decodes_supported_classes_and_mutable_variants
    objects = [
      '$null',
      class_description('NSString'),
      class_description('NSMutableString'),
      class_description('NSNumber'),
      class_description('NSData'),
      class_description('NSDate'),
      class_description('NSMutableArray'),
      class_description('NSMutableDictionary'),
      keyed_object(1, 'NS.string' => 'immutable'),
      keyed_object(2, 'NS.string' => 'mutable'),
      keyed_object(3, 'NS.boolval' => true),
      keyed_object(3, 'NS.intval' => 42),
      keyed_object(3, 'NS.dblval' => 1.5),
      keyed_object(4, 'NS.data' => 'abc'),
      keyed_object(5, 'NS.time' => 600),
      keyed_object(1, 'NS.string' => 'items'),
      keyed_object(6, 'NS.objects' => [uid(10), uid(11), uid(12), uid(13), uid(14)]),
      keyed_object(7, 'NS.keys' => [uid(15)], 'NS.objects' => [uid(16)]),
      keyed_object(6, 'NS.objects' => [uid(17)])
    ]

    archive = decode(objects, uid(17))
    items = archive.root['items']

    assert_equal(true, items[0])
    assert_equal(42, items[1])
    assert_in_delta(1.5, items[2], 0.0001)
    assert_equal('abc'.dup.force_encoding(Encoding::BINARY), items[3])
    assert_equal(Encoding::ASCII_8BIT, items[3].encoding)
    assert_equal(Time.utc(2001, 1, 1, 0, 10), items[4])
    assert_kind_of(Hash, archive.root)
    assert_kind_of(Array, archive.object_at(18))
    assert_equal(['immutable', 'mutable'], archive.objects.values_at(8, 9))
  end

  def test_shared_container_identity_and_cycles_are_preserved
    objects = [
      '$null',
      class_description('NSString'),
      class_description('NSDictionary'),
      class_description('NSArray'),
      keyed_object(1, 'NS.string' => 'name'),
      keyed_object(1, 'NS.string' => 'left'),
      keyed_object(1, 'NS.string' => 'right'),
      keyed_object(2,
        'NS.keys' => [uid(4), uid(5), uid(6)],
        'NS.objects' => [uid(8), uid(9), uid(10)]),
      keyed_object(1, 'NS.string' => 'shared'),
      keyed_object(3, 'NS.objects' => [uid(7)]),
      keyed_object(3, 'NS.objects' => [uid(7)]),
      keyed_object(3, 'NS.objects' => [uid(9), uid(10)])
    ]

    archive = decode(objects, uid(11))
    left_array = archive.root[0]
    right_array = archive.root[1]
    dictionary = left_array[0]

    assert_same(dictionary, right_array[0])
    assert_same(left_array, dictionary['left'])
    assert_same(right_array, dictionary['right'])
    assert_equal('shared', dictionary['name'])
    assert_same(archive.object_at(7), dictionary)
  end

  def test_unknown_class_is_lazy_and_can_be_interpreted_by_caller
    objects = [
      '$null',
      class_description('Widget', ['Widget', 'NSObject']),
      class_description('NSString'),
      class_description('NSArray'),
      keyed_object(2, 'NS.string' => 'widget-name'),
      keyed_object(1, 'label' => uid(4), 'answer' => 7),
      keyed_object(2, 'NS.string' => 'ignored-by-widget'),
      keyed_object(3, 'NS.objects' => [uid(5)])
    ]

    archive = decode(objects, uid(7))
    widget = archive.root[0]

    assert_kind_of(Plist::NSKeyedArchiver::UnknownObject, widget)
    assert_equal('Widget', widget.class_name)
    assert_equal('widget-name', widget.properties['label'])
    assert_equal(7, widget.properties['answer'])
    assert_nil(widget.value)

    widget.decode { |properties| properties['label'].upcase }

    assert_equal('WIDGET-NAME', widget.value)
    assert_same(widget, archive.object_at(5))
  end

  def test_invalid_uids_and_class_descriptions_are_reported_by_object_number
    objects = [
      '$null',
      { '$classname' => 123, '$classes' => ['Wrong'] },
      class_description('NSString'),
      class_description('NSString'),
      keyed_object(3, 'NS.string' => 'still decoded'),
      class_description('NSDictionary'),
      class_description('NSDictionary', ['NSDictionary', 'NSMutableDictionary']),
      class_description('NSArray'),
      keyed_object(7, 'NS.objects' => [uid(99), uid(2), 'not-a-uid', uid(10)]),
      'plain content without a keyed class',
      keyed_object(9),
      keyed_object(7)
    ]
    top = { 'root' => uid(8), 'broken' => 'not-a-uid' }

    archive = decode(objects, top, false)

    assert(!archive.valid?)
    assert_kind_of(Plist::NSKeyedArchiver::InvalidObject, archive.root[0])
    assert_equal(99, archive.root[0].object_index)
    assert_equal(2, archive.root[1].object_index)
    assert_nil(archive.root[2].object_index)
    assert_kind_of(Plist::NSKeyedArchiver::InvalidObject, archive.root[3])
    assert_same(archive.object_at(10), archive.root[3])

    assert_kind_of(Plist::NSKeyedArchiver::ClassDescription, archive.object_at(1))
    assert_equal(['$classname must be a String', '$classes does not describe $classname'], archive.errors[1])
    assert_match(/duplicate class description/, archive.errors[3].first)
    assert_match(/conflicting class description/, archive.errors[6].first)
    assert_kind_of(Plist::NSKeyedArchiver::InvalidObject, archive.object_at(9))
    assert_kind_of(Plist::NSKeyedArchiver::InvalidObject, archive.object_at(10))
    assert_kind_of(Plist::NSKeyedArchiver::InvalidObject, archive.object_at(11))
    assert_equal('still decoded', archive.object_at(4))
    assert_kind_of(Plist::NSKeyedArchiver::InvalidObject, archive.top['broken'])
    assert_equal(['$top[broken] must be a UID'], archive.errors['$top'])
  end

  private

  def decode(objects, top, valid_archiver = true)
    top = { 'root' => top } if top.is_a?(Hash) && top.key?('CF$UID')
    archive = {
      '$archiver' => valid_archiver ? 'NSKeyedArchiver' : 'something-else',
      '$objects' => objects,
      '$top' => top
    }
    Plist::NSKeyedArchiver.decode(archive)
  end

  def uid(index)
    { 'CF$UID' => index }
  end

  def class_description(name, classes = [name])
    { '$classname' => name, '$classes' => classes }
  end

  def keyed_object(class_index, fields = {})
    { '$class' => uid(class_index) }.merge(fields)
  end
end
