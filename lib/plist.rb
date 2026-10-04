# encoding: utf-8

# = plist
#
# This is the main file for plist. Everything interesting happens in
# Plist and Plist::Emit.
#
# Copyright 2006-2010 Ben Bleything and Patrick May
# Distributed under the MIT License
#

require 'cgi'
require 'date'
require 'stringio'
require 'time'

require_relative 'plist/generator'
require_relative 'plist/parser'
require_relative 'plist/version'

module Plist
  class Error < StandardError; end
  class ParseError < Error
    attr_reader :offset

    def initialize(message, offset = nil)
      super(message)
      @offset = offset
    end
  end

  def self.parse(filename_or_data, options = {})
    options = options.dup
    format = options.delete(:format) { :xml }
    case format
    when :xml then parse_xml(filename_or_data, options)
    when :binary, :bplist then Binary.parse(filename_or_data, options)
    else
      raise ArgumentError, "unknown plist format #{format.inspect}"
    end
  end

  def self.dump(object, options = {})
    options = options.dup
    format = options.delete(:format) { :xml }
    envelope = options.delete(:envelope) { true }
    case format
    when :xml
      Emit.dump(object, envelope, options)
    when :binary, :bplist
      if envelope == false
        raise ArgumentError, "binary plists cannot be emitted without an envelope"
      end
      Binary.dump(object, options)
    else
      raise ArgumentError, "unknown plist format #{format.inspect}"
    end
  end
end

require_relative 'plist/binary'
