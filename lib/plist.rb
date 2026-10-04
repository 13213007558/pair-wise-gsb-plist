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
require_relative 'plist/keyed_archiver'
require_relative 'plist/parser'
require_relative 'plist/version'

module Plist
  def self.decode_keyed_archive(data)
    KeyedArchiver.decode(data)
  end
end
