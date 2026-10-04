# encoding: utf-8

require 'date'

module Plist
  module KeyedArchiver
    APPLE_EPOCH = Time.utc(2001, 1, 1)

    KNOWN_CLASSES = {
      'NSString' => :string,
      'NSMutableString' => :string,
      'NSNumber' => :number,
      'NSData' => :data,
      'NSMutableData' => :data,
      'NSDate' => :date,
      'NSArray' => :array,
      'NSMutableArray' => :array,
      'NSDictionary' => :dictionary,
      'NSMutableDictionary' => :dictionary
    }

    def self.decode(archive)
      Decoder.new(archive).decode
    end

    class KeyedArchive
      attr_reader :root, :top, :objects, :class_descriptions, :errors

      def initialize(top, objects, class_descriptions, errors)
        @top = top
        @root = top['root']
        @objects = objects
        @class_descriptions = class_descriptions
        @errors = errors
      end
    end

    class ClassDescription
      attr_reader :object_index, :class_name, :classes
      attr_accessor :valid

      def initialize(object_index, class_name, classes)
        @object_index = object_index
        @class_name = class_name
        @classes = classes
        @valid = true
      end

      def valid?
        valid
      end
    end

    class LazyObject
      attr_reader :object_index, :class_name, :classes, :raw

      def initialize(object_index, description, raw, decoder)
        @object_index = object_index
        @class_name = description.class_name
        @classes = description.classes
        @raw = raw
        @decoder = decoder
      end

      def field?(name)
        raw.key?(name)
      end

      def field(name)
        @decoder.decode_lazy_value(raw[name], object_index, name)
      end

      def [](name)
        field(name)
      end
    end

    class MalformedObject
      attr_reader :object_index, :message, :raw

      def initialize(object_index, message, raw)
        @object_index = object_index
        @message = message
        @raw = raw
      end

      def inspect
        "#<#{self.class} object_index=#{object_index.inspect} #{message}>"
      end
    end

    class InvalidReference < MalformedObject
      attr_reader :target, :path

      def initialize(object_index, target, path, message, raw = nil)
        super(object_index, message, raw)
        @target = target
        @path = path
      end
    end

    class DecodeError
      attr_reader :object_index, :code, :message, :path, :target

      def initialize(object_index, code, message, path = nil, target = nil)
        @object_index = object_index
        @code = code
        @message = message
        @path = path
        @target = target
      end
    end

    class Decoder
      def initialize(archive)
        unless archive.is_a?(Hash)
          raise ArgumentError, 'NSKeyedArchiver input must be a Hash'
        end

        unless archive['$archiver'] == 'NSKeyedArchiver'
          raise ArgumentError, '$archiver must be NSKeyedArchiver'
        end
        unless archive['$objects'].is_a?(Array)
          raise ArgumentError, '$objects must be an Array'
        end
        unless archive['$top'].is_a?(Hash)
          raise ArgumentError, '$top must be a Hash'
        end

        @archive = archive
        @records = archive['$objects']
        @values = Array.new(@records.length)
        @class_descriptions = {}
        @errors = {}
        @container_jobs = []
      end

      def decode
        build_class_descriptions
        build_objects
        fill_containers
        decode_top

        KeyedArchive.new(@decoded_top, @values, @class_descriptions, @errors)
      end

      def decode_lazy_value(value, source_id, path)
        if uid?(value)
          resolve_reference(source_id, path, value)
        else
          value
        end
      end

      private

      def build_class_descriptions
        seen_names = {}

        @records.each_with_index do |record, index|
          next unless class_description?(record)

          name = record['$classname']
          classes = record['$classes']
          valid = true

          if record.key?('$class')
            add_error(index, :invalid_class_descriptor, 'class descriptions must not contain $class', '$class')
            valid = false
          end

          unless name.is_a?(String)
            add_error(index, :invalid_class_name, '$classname must be a String', '$classname')
            valid = false
          end

          unless classes.is_a?(Array) && !classes.empty? && classes.all? { |item| item.is_a?(String) }
            add_error(index, :invalid_class_hierarchy, '$classes must be a non-empty Array of Strings', '$classes')
            valid = false
            classes = []
          end

          if name.is_a?(String) && !classes.empty? && classes.first != name
            add_error(index, :class_name_mismatch, '$classes.first must equal $classname', '$classes')
            valid = false
          end

          resolved_name = name.is_a?(String) ? name : classes.first
          description = ClassDescription.new(index, resolved_name, classes)
          description.valid = valid
          @values[index] = description
          @class_descriptions[index] = description

          next unless resolved_name

          if seen_names.key?(resolved_name)
            add_error(index, :duplicate_class_description, "duplicate class description for #{resolved_name}")
          else
            seen_names[resolved_name] = index
          end
        end
      end

      def build_objects
        @records.each_with_index do |record, index|
          next if @class_descriptions.key?(index)
          @values[index] = build_object(record, index)
        end
      end

      def build_object(record, index)
        return nil if record == '$null'

        if uid?(record)
          return malformed(index, 'a UID cannot be a standalone $objects entry', record)
        end

        if record.is_a?(Hash)
          return build_keyed_object(record, index) if record.key?('$class')
          return malformed(index, 'object content must have a $class UID', record)
        end

        if record.is_a?(Array)
          return malformed(index, 'a raw Array cannot be an archive object', record)
        end

        if record.is_a?(String)
          return record.dup
        end

        if binary_data?(record)
          return read_binary(record)
        end

        if record.is_a?(Numeric) || record == true || record == false || record.nil?
          return record
        end

        if record.respond_to?(:to_time)
          time = record.to_time
          return time.respond_to?(:utc) ? time.utc : time
        end

        malformed(index, "unsupported object content #{record.class}", record)
      end

      def build_keyed_object(record, index)
        description = resolve_class_description(index, record['$class'])
        return malformed(index, 'object has an invalid $class reference', record) unless description

        unless description.valid?
          message = '$class references an invalid class description'
          add_error(index, :invalid_class_description, message, '$class', description.object_index)
        end

        type = KNOWN_CLASSES[description.class_name]
        return LazyObject.new(index, description, record, self) unless type

        send("build_#{type}", record, index)
      end

      def build_string(record, index)
        value = record['NS.string']
        return malformed(index, 'NSString requires NS.string', record) unless value.is_a?(String)
        value.dup
      end

      def build_number(record, index)
        if record.key?('NS.boolval')
          value = record['NS.boolval']
          case value
          when true then true
          when false then false
          when 0 then false
          when 1 then true
          else malformed_number(index, record)
          end
        elsif record.key?('NS.intval')
          value = record['NS.intval']
          value.is_a?(Integer) ? value : malformed_number(index, record)
        elsif record.key?('NS.realval')
          value = record['NS.realval']
          value.is_a?(Numeric) ? Float(value) : malformed_number(index, record)
        else
          malformed_number(index, record)
        end
      end

      def build_data(record, index)
        value = record['NS.data']
        return malformed(index, 'NSData requires NS.data', record) unless binary_data?(value)
        read_binary(value)
      end

      def build_date(record, index)
        value = record['NS.time']
        unless value.is_a?(Numeric)
          return malformed(index, 'NSDate requires a numeric NS.time', record)
        end
        Time.at(APPLE_EPOCH.to_f + value.to_f).utc
      end

      def build_array(record, index)
        members = record['NS.objects']
        unless members.is_a?(Array)
          return malformed(index, 'NSArray requires NS.objects', record)
        end

        value = []
        @container_jobs << [:array, index, value, members]
        value
      end

      def build_dictionary(record, index)
        keys = record['NS.keys']
        members = record['NS.objects']
        unless keys.is_a?(Array) && members.is_a?(Array)
          return malformed(index, 'NSDictionary requires NS.keys and NS.objects', record)
        end

        value = {}
        @container_jobs << [:dictionary, index, value, keys, members]
        value
      end

      def fill_containers
        @container_jobs.each do |job|
          if job.first == :array
            _, source_id, value, members = job
            members.each_with_index do |member, member_index|
              value << resolve_reference(source_id, "NS.objects[#{member_index}]", member)
            end
          else
            _, source_id, value, keys, members = job
            if keys.length != members.length
              add_error(source_id, :key_value_count_mismatch, 'NS.keys and NS.objects must have the same length')
            end

            paired_length = [keys.length, members.length].min
            paired_length.times do |member_index|
              key = resolve_reference(source_id, "NS.keys[#{member_index}]", keys[member_index])
              member = resolve_reference(source_id, "NS.objects[#{member_index}]", members[member_index])
              if value.key?(key)
                message = 'duplicate key in decoded NSDictionary'
                add_error(source_id, :duplicate_dictionary_key, message, "NS.keys[#{member_index}]")
              end
              value[key] = member
            end
          end
        end
      end

      def decode_top
        @decoded_top = {}
        @archive['$top'].each do |name, reference|
          @decoded_top[name] = resolve_reference(:$top, name.to_s, reference)
        end
      end

      def resolve_class_description(source_id, reference)
        target = uid_target(source_id, '$class', reference)
        return unless target

        description = @class_descriptions[target]
        unless description
          message = '$class does not reference a class description'
          add_error(source_id, :invalid_class_reference, message, '$class', target)
          return
        end
        description
      end

      def resolve_reference(source_id, path, reference)
        target = uid_target(source_id, path, reference)
        return invalid_reference(source_id, nil, path, 'invalid UID reference', reference) unless target

        value = @values[target]
        if value.is_a?(ClassDescription)
          add_error(source_id, :invalid_object_reference, 'UID references a class description', path, target)
          return invalid_reference(source_id, target, path, 'reference points to a class description', reference)
        end
        value
      end

      def uid_target(source_id, path, reference)
        unless uid?(reference)
          add_error(source_id, :invalid_uid, 'expected a CF$UID reference', path)
          return
        end

        target = reference['CF$UID']
        unless target.is_a?(Integer)
          add_error(source_id, :invalid_uid, 'CF$UID must be an Integer', path)
          return
        end

        if target < 0 || target >= @records.length
          add_error(source_id, :uid_out_of_range, "UID #{target} is outside $objects", path, target)
          return
        end

        target
      end

      def class_description?(record)
        record.is_a?(Hash) &&
          (record.key?('$classname') || record.key?('$classes'))
      end

      def uid?(value)
        value.is_a?(Hash) && value.key?('CF$UID')
      end

      def binary_data?(value)
        value.is_a?(String) || value.respond_to?(:read)
      end

      def read_binary(value)
        return value.dup.force_encoding(Encoding::BINARY) if value.is_a?(String)

        value.rewind if value.respond_to?(:rewind)
        value.read.force_encoding(Encoding::BINARY)
      end

      def malformed_number(index, record)
        malformed(index, 'NSNumber has an invalid numeric value', record)
      end

      def malformed(index, message, raw)
        add_error(index, :malformed_object, message)
        MalformedObject.new(index, message, raw)
      end

      def invalid_reference(source_id, target, path, message, raw)
        InvalidReference.new(source_id, target, path, message, raw)
      end

      def add_error(object_id, code, message, path = nil, target = nil)
        @errors[object_id] ||= []
        @errors[object_id] << DecodeError.new(object_id, code, message, path, target)
      end
    end
  end
end
