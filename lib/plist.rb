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
require 'stringio'

require_relative 'plist/generator'
require_relative 'plist/parser'
require_relative 'plist/binary'
require_relative 'plist/version'

module Plist
  def self.dump(obj, envelope = true, options = {})
    Plist::Emit.dump(obj, envelope, options)
  end

  def self.parse(filename_or_data, options = {})
    options = options.dup
    format = options.delete(:format) || :xml

    case format
    when :xml then parse_xml(filename_or_data, options)
    when :binary then parse_binary(filename_or_data, options)
    else raise ArgumentError, "unsupported plist format: #{format.inspect}"
    end
  end
end
