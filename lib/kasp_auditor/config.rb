#
# $Id$
#
# Copyright (c) 2009 Nominet UK. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
# GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
# IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
# IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

require 'xsd/datatypes'
module KASPAuditor
  # Represents KASP configuration file
  # Also loads salt in from <zone_config>.xml SignerConfiguration file.
  class Config
    class ConfigLoadError < Exception
    end

    attr_reader :err
    attr_accessor :changed_config
    
    # Should the PartialAuditor be used instead of the full Auditor?
    attr_reader :partial_audit
    def initialize(zone_name, kasp_file_loc, policy, config_file_loc, syslog)
      return if !zone_name
      #      @zones = []
      #      print "Opening config file : #{config_file_loc}\n"
      # Read the kasp.xml file
      @name = (zone_name.to_s+"").untaint
      @err = 0
      @partial_audit = false
      begin
        File.open((kasp_file_loc+"").untaint, 'r') {|file|
          doc = REXML::Document.new(file)


          # Now find the appropiate policy
          found_policy = false
          doc.elements.each('KASP/Policy') {|p|
            if (p.attributes['name'] == policy)
              found_policy = true
              # Now load the policy in!
          
              # @TODO@ Check out Zone.SOA - should be able to monitor SOA with that

              #        # Fill out new zone
              @audit_tag_present = false
              p.elements.each('Audit') {|a|
                # Read the information present in the Audit element, and
                # figure out what sort of auditor to use - full or partial
                @audit_tag_present = true
                a.elements.each('Partial') {|partial|
                  @partial_audit = true
                }
              }
              begin
                @signatures = Signatures.new(p.elements['Signatures'])
                @denial = Denial.new(p.elements['Denial'])
                @keys = Keys.new(p.elements['Keys'])
                @soa = SOA.new(p.elements['Zone/SOA'])
              rescue Exception => e
                raise ConfigLoadError.new("ERROR - Configuration file #{kasp_file_loc} can't be loaded. Try running ods-kaspcheck to check the configuration.")
              end
            end
          }
          if (!found_policy)
            raise ConfigLoadError.new("ERROR - Can't find policy #{policy.inspect} in KASP Policy.")
          end
        }
      rescue Exception => e
        raise ConfigLoadError.new("ERROR - Can't find KASP file : #{kasp_file_loc.inspect} : #{e}")
      end
      #
      # Read the salt ONLY from the SignerConfiguration
      if (@denial.nsec3)
        conf_f = (config_file_loc.to_s+"").untaint
        begin
          File.open(conf_f, 'r') {|file|
            doc = REXML::Document.new(file)
            e = doc.elements['SignerConfiguration/Zone/Denial/NSEC3/Hash/']
            if (e)
              @denial.nsec3.hash.salt = e.elements['Salt'].text
              decoded_salt = Dnsruby::RR::NSEC3.decode_salt(@denial.nsec3.hash.salt)
              if (decoded_salt.length.to_i != @denial.nsec3.hash.salt_length.to_i)
                # @TODO@ Only log this if this is a zone of interest!
                msg = "ERROR : SALT LENGTH IS #{decoded_salt.length}, but should be #{@denial.nsec3.hash.salt_length}"
                print "#{Syslog::LOG_ERR}: #{msg}\n"
                begin
                  syslog.log(Syslog::LOG_ERR, msg)
                rescue ArgumentError # Make sure we continue no matter what
                end
                @err = Syslog::LOG_ERR
              end
            else
              raise ConfigLoadError.new("ERROR - can't read salt from SignerConfiguration file : #{conf_f}")
            end
          }
        rescue Errno::ENOENT
          raise ConfigLoadError.new("ERROR - Can't find SignerConfiguration file : #{conf_f}")
        end
      end
    end
    # Check the defined hash algorithm against the denial type. If NSEC3 is
    # being used, then make sure that the key algorithm is consistent with NSEC3.
    # Return true if an inconsistent key algorithm is used with NSEC3.
    # Return false otherwise.
    def inconsistent_nsec3_algorithm?
      if (@denial.nsec3)
        @keys.keys.each {|key|
          if ((key.algorithm != Dnsruby::Algorithms.DSA_NSEC3_SHA1) &&
                (key.algorithm != Dnsruby::Algorithms.RSASHA1_NSEC3_SHA1) &&
                (key.algorithm != Dnsruby::Algorithms.RSASHA256) &&
                (key.algorithm != Dnsruby::Algorithms.RSASHA512))
            return true
          end
        }
      end
      return false
    end
    
    def self.xsd_duration_to_seconds xsd_duration
      # XSDDuration hack
      xsd_duration = "P0DT#{$1}" if xsd_duration =~ /^PT(.*)$/
      xsd_duration = "-P0DT#{$1}" if xsd_duration =~ /^-PT(.*)$/
      a = XSD::XSDDuration.new xsd_duration
      from_min = 0 | a.min * 60
      from_hour = 0 | a.hour * 60 * 60
      from_day = 0 | a.day * 60 * 60 * 24
      from_month = 0 | a.month * 60 * 60 * 24 * 31
      from_year = 0 | a.year * 60 * 60 * 24 * 365
      # XSD::XSDDuration seconds hack.
      x = a.sec.to_s.to_i + from_min + from_hour + from_day + from_month + from_year
      return x
    end

    attr_accessor :name, :signatures, :keys, :denial, :soa, :audit_tag_present
        
    class Signatures
      attr_accessor :resign, :refresh, :jitter, :inception_offset, :validity
      def initialize(e)
        resign_text = e.elements['Resign'].text
        @resign = Config.xsd_duration_to_seconds(resign_text)
        refresh_text = e.elements['Refresh'].text
        @refresh = Config.xsd_duration_to_seconds(refresh_text)
        jitter_text = e.elements['Jitter'].text
        @jitter = Config.xsd_duration_to_seconds(jitter_text)
        inception_offset_text = e.elements['InceptionOffset'].text
        @inception_offset = Config.xsd_duration_to_seconds(inception_offset_text)

        @validity = Validity.new(e.elements['Validity'])
      end
      class Validity
        attr_accessor :default, :denial
        def initialize(e)
          default_text = e.elements['Default'].text
          @default = Config.xsd_duration_to_seconds(default_text)
          denial_text = e.elements['Denial'].text
          @denial = Config.xsd_duration_to_seconds(denial_text)
        end
      end
    end
    class Denial
      attr_accessor :nsec, :nsec3
      def initialize(e)
        if (e.elements['NSEC'])
          @nsec = Nsec.new() # e.elements['NSEC'])
        else
          @nsec3 = Nsec3.new(e.elements['NSEC3'])
        end
      end
      class Nsec
      end
      class Nsec3
        attr_accessor :optout, :hash
        def initialize(e)
          @optout = false
          if (e.elements['OptOut'])
            @optout = true
          end
          @hash = Hash.new(e.elements['Hash'])
        end
        class Hash
          attr_accessor :algorithm, :iterations, :salt, :salt_length
          def initialize(e)
            @algorithm = e.elements['Algorithm'].text.to_i
            @iterations = e.elements['Iterations'].text.to_i
            e.elements.each('Salt') {|s|
              @salt_length = s.attributes['length']
            }
          end
        end
      end
    end
    class SOA
      UNIXTIME = "unixtime"
      COUNTER = "counter"
      DATECOUNTER = "datecounter"
      KEEP = "keep"
      attr_accessor :ttl, :minimum, :serial
      def initialize(e)
        ttl_text = e.elements['TTL'].text
        @ttl = Config.xsd_duration_to_seconds(ttl_text)
        min_text = e.elements['Minimum'].text
        @minimum = Config.xsd_duration_to_seconds(min_text)
        @serial = e.elements['Serial'].text
        if (!([UNIXTIME, COUNTER, DATECOUNTER, KEEP].include?@serial))
          # @TODO@ Log errors encountered in config?
          # Leave to policy configuration auditor
          print "ERROR : zone serial type incorrect! (#{@serial} found)\n"
        end
      end
    end
    class Keys
      attr_accessor :ttl, :ksks, :zsks
      def keys
        return @ksks + @zsks
      end
      def initialize(e)
        ttl_text = e.elements['TTL'].text
        @ttl = Config.xsd_duration_to_seconds(ttl_text)
        @ksks = []
        e.get_elements('KSK').each {|k|
          key = AnyKey.new(k)
          @ksks.push(key)
        }
        @zsks = []
        e.get_elements('ZSK').each {|k|
          key = AnyKey.new(k)
          @zsks.push(key)
        }
      end
      class AnyKey
        attr_accessor :algorithm, :alg_length, :standby, :lifetime
        def initialize(e)
          # Algorithm length and value
          @algorithm = Dnsruby::Algorithms.new(e.elements['Algorithm'].text.to_i)
          begin
            @standby = e.elements['Standby'].text.to_i
          rescue Exception
            @standby = 0
          end
          lifetime_text = e.elements['Lifetime'].text
          @lifetime = Config.xsd_duration_to_seconds(lifetime_text)
          if (@lifetime == 0)
            @lifetime = 999999999999
          end
          e.elements.each('Algorithm') {|s|
            @alg_length = s.attributes['length'].to_i
          }
        end
      end
    end
  end
end
