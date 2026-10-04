# encoding: utf-8

require 'time'

module Plist
  module NSKeyedArchiver
    APPLE_EPOCH = Time.utc(2001, 1, 1)

    STRING_CLASSES = %w[
      NSString NSMutableString __NSCFString __NSCFConstantString NSTaggedPointerString
    ].freeze
    NUMBER_CLASSES = %w[NSNumber __NSCFBoolean __NSCFNumber].freeze
    DATA_CLASSES = %w[NSData NSMutableData __NSCFData].freeze
    DATE_CLASSES = %w[NSDate __NSCFDate].freeze
    ARRAY_CLASSES = %w[
      NSArray NSMutableArray __NSArrayI __NSArrayM __NSSingleObjectArrayI
    ].freeze
    DICTIONARY_CLASSES = %w[
      NSDictionary NSMutableDictionary __NSDictionaryI __NSDictionaryM
    ].freeze

    def self.decode(archive)
      Decoder.new(archive).decode
    end

    class ArchiveNode
      attr_reader :object_index, :raw, :errors

      def initialize(object_index, raw, errors = [])
        @object_index = object_index
        @raw = raw
        @errors = errors.dup
      end
    end

    class InvalidObject < ArchiveNode
    end

    class ClassDescription < ArchiveNode
      attr_reader :class_name, :classes

      def initialize(object_index, raw, class_name, classes, errors = [])
        super(object_index, raw, errors)
        @class_name = class_name
        @classes = classes
      end
    end

    class UnknownObject < ArchiveNode
      attr_reader :class_name

      def initialize(object_index, raw, class_name, decoder)
        super(object_index, raw)
        @class_name = class_name
        @decoder = decoder
      end

      def properties
        @properties ||= @decoder.lazy_properties(raw)
      end

      def value
        @value
      end

      def decode
        @value = yield(properties)
        self
      end

      def inspect
        "#<#{self.class.name} index=#{object_index.inspect} class=#{class_name.inspect}>"
      end
    end

    class DecodedArchive
      attr_reader :root, :top, :objects, :errors, :class_descriptions

      def initialize(root, top, objects, errors, class_descriptions)
        @root = root
        @top = top
        @objects = objects
        @errors = errors
        @class_descriptions = class_descriptions
      end

      def valid?
        errors.empty?
      end

      def object_at(index)
        objects[index]
      end
    end

    class Decoder
      def initialize(archive)
        unless archive.is_a?(Hash)
          raise ArgumentError, 'NSKeyedArchiver input must be a Hash'
        end

        @raw_objects = fetch_key(archive, '$objects')
        @raw_top = fetch_key(archive, '$top')
        @archiver = fetch_key(archive, '$archiver')
        unless @raw_objects.is_a?(Array)
          raise ArgumentError, 'NSKeyedArchiver archive must contain an $objects Array'
        end
        unless @raw_top.is_a?(Hash)
          raise ArgumentError, 'NSKeyedArchiver archive must contain a $top Hash'
        end

        @values = Array.new(@raw_objects.length)
        @decoded = {}
        @class_descriptors = Array.new(@raw_objects.length)
        @descriptor_indices = {}
        @reference_errors = Hash.new { |hash, key| hash[key] = [] }
        @top_errors = []
      end

      def decode
        scan_class_descriptions
        decode_all_objects
        top = decode_top

        objects = @values.each_with_index.map do |value, index|
          value.nil? && raw_at(index).nil? ? nil : value
        end

        errors = {}
        @reference_errors.each do |index, messages|
          errors[index] = messages unless messages.empty?
        end
        @class_descriptors.each_with_index do |descriptor, index|
          next if descriptor.nil?
          add_errors(errors, index, descriptor.errors)
        end
        objects.each_with_index do |object, index|
          next if object.is_a?(ClassDescription)
          add_errors(errors, index, node_errors(object))
        end
        unless @top_errors.empty?
          errors['$top'] = @top_errors
        end
        unless valid_archiver?
          errors['$archiver'] = ['$archiver is not NSKeyedArchiver']
        end

        descriptions = {}
        @class_descriptors.each_with_index do |descriptor, index|
          descriptions[index] = descriptor unless descriptor.nil?
        end

        DecodedArchive.new(top['root'], top, objects, errors, descriptions)
      end

      def lazy_properties(raw)
        properties = {}
        raw.each do |key, value|
          normalized_key = key.to_s
          next if normalized_key == '$class'
          properties[normalized_key] = decode_lazy_value(value)
        end
        properties
      end

      private

      def decode_lazy_value(value)
        if uid?(value)
          resolve_reference(nil, value)
        elsif value.is_a?(Hash)
          result = {}
          value.each do |key, child|
            result[decode_lazy_value(key)] = decode_lazy_value(child)
          end
          result
        elsif value.is_a?(Array)
          value.map { |child| decode_lazy_value(child) }
        else
          value
        end
      end

      def scan_class_descriptions
        @raw_objects.each_with_index do |raw, index|
          next unless raw.is_a?(Hash) && present_key?(raw, '$classname')

          class_name = fetch_key(raw, '$classname')
          classes = fetch_key(raw, '$classes')
          errors = []

          unless class_name.is_a?(String)
            errors << '$classname must be a String'
          end
          unless classes.is_a?(Array) && !classes.empty? && classes.all? { |name| name.is_a?(String) }
            errors << '$classes must be a non-empty Array of Strings'
          end
          if classes.is_a?(Array) && !classes.empty? && classes.all? { |name| name.is_a?(String) } && class_name != classes.first
            errors << '$classes does not describe $classname'
          end

          if class_name.is_a?(String)
            previous_index = @descriptor_indices[class_name]
            if previous_index
              previous_classes = @class_descriptors[previous_index].classes
              if previous_classes == classes
                errors << "duplicate class description for #{class_name}"
              else
                errors << "conflicting class description for #{class_name}"
              end
            else
              @descriptor_indices[class_name] = index
            end
          end

          descriptor = ClassDescription.new(index, raw, class_name, classes, errors)
          @class_descriptors[index] = descriptor
          @values[index] = descriptor
        end
      end

      def decode_all_objects
        @raw_objects.each_index do |index|
          object_at(index) unless @class_descriptors[index]
        end
      end

      def object_at(index)
        return @values[index] if @decoded[index]

        raw = @raw_objects[index]
        if @class_descriptors[index]
          @decoded[index] = true
          @values[index] = @class_descriptors[index]
          return @values[index]
        end

        if raw == '$null'
          @decoded[index] = true
          @values[index] = nil
          return nil
        end

        unless raw.is_a?(Hash) && present_key?(raw, '$class')
          return invalid_object(index, raw, ['object is not a keyed archive object'])
        end

        class_uid = fetch_key(raw, '$class')
        unless uid?(class_uid)
          return invalid_object(index, raw, ['$class must refer to a class description UID'])
        end

        class_index = uid_index(class_uid)
        if class_index.nil? || class_index >= @raw_objects.length
          return invalid_object(index, raw, ['$class UID is outside $objects'])
        end

        descriptor = @class_descriptors[class_index]
        if descriptor.nil?
          return invalid_object(index, raw, ["object #{class_index} is not a class description"])
        end

        class_name = descriptor.class_name
        unless class_name.is_a?(String)
          return invalid_object(index, raw, ['class description has no valid $classname'])
        end

        value = decode_classed_object(index, raw, class_name)
        @decoded[index] = true
        value
      end

      def decode_classed_object(index, raw, class_name)
        if STRING_CLASSES.include?(class_name)
          decode_string(index, raw)
        elsif NUMBER_CLASSES.include?(class_name)
          decode_number(index, raw)
        elsif DATA_CLASSES.include?(class_name)
          decode_data(index, raw)
        elsif DATE_CLASSES.include?(class_name)
          decode_date(index, raw)
        elsif ARRAY_CLASSES.include?(class_name)
          decode_array(index, raw)
        elsif DICTIONARY_CLASSES.include?(class_name)
          decode_dictionary(index, raw)
        else
          @values[index] = UnknownObject.new(index, raw, class_name, self)
        end
      end

      def decode_string(index, raw)
        value = fetch_key(raw, 'NS.string')
        unless value.is_a?(String)
          return invalid_object(index, raw, 'NS.string must be a String')
        end
        @values[index] = value
      end

      def decode_number(index, raw)
        if present_key?(raw, 'NS.boolval')
          value = fetch_key(raw, 'NS.boolval')
          unless value == true || value == false
            return invalid_object(index, raw, 'NS.boolval must be true or false')
          end
          @values[index] = value
        elsif present_key?(raw, 'NS.intval')
          value = fetch_key(raw, 'NS.intval')
          unless value.is_a?(Integer)
            return invalid_object(index, raw, 'NS.intval must be an Integer')
          end
          @values[index] = value
        elsif present_key?(raw, 'NS.dblval')
          value = fetch_key(raw, 'NS.dblval')
          unless value.is_a?(Numeric)
            return invalid_object(index, raw, 'NS.dblval must be Numeric')
          end
          @values[index] = value.to_f
        else
          invalid_object(index, raw, 'NSNumber is missing its numeric value')
        end
      end

      def decode_data(index, raw)
        value = fetch_key(raw, 'NS.data')
        if value.respond_to?(:read)
          value.rewind if value.respond_to?(:rewind)
          value = value.read
          value.force_encoding(Encoding::BINARY) if value.respond_to?(:force_encoding)
        elsif value.is_a?(String)
          value = value.dup
          value.force_encoding(Encoding::BINARY) if value.respond_to?(:force_encoding)
        else
          return invalid_object(index, raw, 'NS.data must be binary data')
        end
        @values[index] = value
      end

      def decode_date(index, raw)
        value = fetch_key(raw, 'NS.time')
        unless value.is_a?(Numeric)
          return invalid_object(index, raw, 'NS.time must be Numeric')
        end
        @values[index] = Time.at(APPLE_EPOCH.to_f + value.to_f).utc
      end

      def decode_array(index, raw)
        members = fetch_key(raw, 'NS.objects')
        unless members.is_a?(Array)
          return invalid_object(index, raw, 'NS.objects must be an Array')
        end

        result = []
        @values[index] = result
        @decoded[index] = true
        members.each do |uid|
          result << resolve_reference(index, uid)
        end
        result
      end

      def decode_dictionary(index, raw)
        keys = fetch_key(raw, 'NS.keys')
        values = fetch_key(raw, 'NS.objects')
        unless keys.is_a?(Array) && values.is_a?(Array) && keys.length == values.length
          return invalid_object(index, raw, 'NS.keys and NS.objects must be equal-length Arrays')
        end

        result = {}
        @values[index] = result
        @decoded[index] = true
        keys.each_with_index do |key_uid, member_index|
          key = resolve_reference(index, key_uid)
          value = resolve_reference(index, values[member_index])
          if result.key?(key)
            add_reference_error(index, "dictionary key at #{member_index} is duplicated")
          else
            result[key] = value
          end
        end
        result
      end

      def decode_top
        result = {}
        @raw_top.each do |key, uid|
          name = key.to_s
          unless uid?(uid)
            @top_errors << "$top[#{name}] must be a UID"
            result[name] = InvalidObject.new(nil, uid, ['$top entry is not a UID'])
            next
          end
          result[name] = resolve_reference('$top', uid)
        end
        unless result.key?('root')
          @top_errors << '$top must contain a root UID'
        end
        result
      end

      def resolve_reference(source, uid)
        unless uid?(uid)
          message = 'UID reference is not a UID'
          add_reference_error(source, message)
          return InvalidObject.new(nil, uid, [message])
        end

        index = uid_index(uid)
        if index.nil? || index >= @raw_objects.length
          message = "UID #{uid_inspect(uid)} is outside $objects"
          add_reference_error(source, message)
          return InvalidObject.new(index, uid, [message])
        end

        if @class_descriptors[index]
          message = "UID #{index} refers to a class description"
          add_reference_error(source, message)
          return InvalidObject.new(index, @raw_objects[index], [message])
        end

        object_at(index)
      end

      def invalid_object(index, raw, errors)
        @decoded[index] = true
        @values[index] = InvalidObject.new(index, raw, Array(errors))
      end

      def add_reference_error(index, message)
        return if index.nil?
        @reference_errors[index] << message
      end

      def add_errors(errors, index, messages)
        return if messages.nil? || messages.empty?
        errors[index] = (errors[index] || []) + messages
      end

      def node_errors(object)
        object.respond_to?(:errors) ? object.errors : []
      end

      def raw_at(index)
        @raw_objects[index]
      end

      def valid_archiver?
        @archiver.nil? || @archiver == 'NSKeyedArchiver'
      end

      def uid?(value)
        if value.is_a?(Hash) && (value.key?('CF$UID'.freeze) || value.key?(:'CF$UID'))
          uid = fetch_key(value, 'CF$UID')
          return uid.is_a?(Integer) && uid >= 0
        end
        value.respond_to?(:uid)
      end

      def uid_index(value)
        if value.is_a?(Hash) && (value.key?('CF$UID'.freeze) || value.key?(:'CF$UID'))
          value = fetch_key(value, 'CF$UID')
        elsif value.respond_to?(:uid)
          value = value.uid
        end
        return unless value.is_a?(Integer) && value >= 0
        value
      end

      def uid_inspect(value)
        index = uid_index(value)
        index.nil? ? value.inspect : index.to_s
      end

      def present_key?(hash, key)
        hash.key?(key) || hash.key?(key.to_sym)
      end

      def fetch_key(hash, key)
        if hash.key?(key)
          hash[key]
        else
          hash[key.to_sym]
        end
      end
    end
  end
end
