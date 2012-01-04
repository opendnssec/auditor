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

module KASPAuditor
  # This class manages the caches that are used to track the lifecycle
  # of keys used to sign the zone.
  # We need to store all the keys that we see for each zone that we audit.
  # We need the following states : pre-published, in-use, retired, and dead.
  # REVOKED will indicate retired for RFC5011 keys, but non-5011 keys may
  # go through a "present, but not used" retirement phase. Keys may also move
  # straight to dead. Once dead, keys are no longer tracked.
  # As we start to track a non-RFC5011 zone, we may have problems differentiating
  # between pre-published and retired keys. Thus some keys may go directly from
  # pre-published to dead.
  #
  # FILE : have one file cache for each zone which is tracked :
  #  (<workingdirectory>/tracking/<zone_name>
  # The file will consist of a list of [key, status, timestamp] tuples,
  # where status is one of :
  #   PREPUBLISHED, INUSE, RETIRED, DEAD
  # DEAD keys may be purged from the file (and may indeed never appear).
  # The key_tag will be the PRE-REVOKED key_tag (even for revoked keys).
  # The timestamp field records the time the key first entered the new state.
  # The file starts with two records - one for the timestamp at which the file
  # was originally created, and one for the last SOA serial that was seen.
  #
  class KeyTracker
    class Status < Dnsruby::CodeMapper
      PREPUBLISHED = 1
      INUSE = 2
      RETIRED = 4
      update
    end

    SEPARATOR = "\0\0$~$~$~\0\0"

    # The Cache holds the data for each of the Status levels.
    # It is dynamically generated from the Status levels.
    # The dynamic methods created here will not show up in RDoc,
    # but consist of methods to add, remove and find keys in
    # different states. Timestamps are also held here.
    class Cache
      # Set up add_inuse_key, etc.
      Status.strings.each {|s| eval "attr_reader :#{s.downcase}"}
      Status.strings.each {|s| eval "def add_#{s.downcase}_key(key)
                          if (!include_#{s.downcase}_key?key)
                                new_key = key.clone
                                new_key.public_key
                                @#{s.downcase}[new_key]=[Time.now.to_i, Time.now.to_i]
                          end
          end"}
      # Set up add_inuse_key_with_time, etc.
      Status.strings.each {|s| eval "def add_#{s.downcase}_key_with_time(key, time, first_time)
                          if (!include_#{s.downcase}_key?key)
                                new_key = key.clone
                                new_key.public_key
                                @#{s.downcase}[new_key]=[time, first_time]
                          end
          end"}
      # Set up include_inuse_key?, etc.
      Status.strings.each {|s| eval "def include_#{s.downcase}_key?(key)
                   key.public_key
                   @#{s.downcase}.each {|k,v|
                      if ((k == key) || (k.key_tag_pre_revoked ==
                              key.key_tag_pre_revoked))
                         return v
                      end
                   }
                   return false
          end"}
      # Set up delete_inuse_key, etc.
      Status.strings.each {|s| eval "def delete_#{s.downcase}_key(key)
                                     key.public_key
                                     @#{s.downcase}.delete_if {|k, temp|
             ((k==key) || (k.key_tag_pre_revoked == key.key_tag_pre_revoked))
                                     }
          end"}
      def include_key?(key)
        Status.strings.each {|s| eval "return true if include_#{s.downcase}_key?(key)"}
        return false
      end
      def initialize
        Status.strings.each {|s| eval "@#{s.downcase} = {}"}
      end
    end

    attr_reader :cache
    attr_accessor :last_soa_serial

    # Each run, the auditor needs to load the key caches for the zone, then
    # audit the zone, keeping track of which keys are used. The key caches are
    # then updated. The auditor needs to run the lifetime, numStandby checks
    # on the keys as well.
    #
    # If the key caches can't be found, then create new ones.
    #
    # These files, once started for a zone, will never be deleted.
    def initialize(working_directory, zone_name, parent, config, enforcer_interval, validity)
      @working = working_directory
      @zone = zone_name
      @parent  = parent
      @config = config
      @enforcer_interval = enforcer_interval
      @last_soa_serial = nil
      @initial_timestamp = Time.now.to_i
      @validity = validity
      @cache = load_tracker_cache()
    end

    # Load the cache for the zone from the workingdirectory. Create a new
    # cache if one can't be found. Also defaults to reloading the SOA serial
    # for the zone.
    def load_tracker_cache(load_soa_serial = true)
      # Need to store the time that the state change was first noticed.
      # Need to load this from file, store in cache, add to new cache values,
      # and write back to file.
      cache = Cache.new
      filename = get_tracker_filename
      dir = File.dirname(filename)
      begin
        Dir.mkdir(dir) unless File.directory?(dir)
      rescue Errno::ENOENT
        @parent.log(LOG_ERR, "Can't create working folder : #{dir}")
        KASPAuditor.exit("Can't create working folder : #{dir}", 1)
      end
      File.open(filename, File::CREAT) { |f|
        # Now load the cache
        # Is there an initial timestamp and a current SOA serial to load?
        count = 0
        while (line = f.gets)
          count += 1
          if (count == 1)
            @initial_timestamp = line.chomp.to_i
            next
          elsif (count == 2)
            if (load_soa_serial)
              @last_soa_serial = line.chomp.to_i
            end
            next
          end
          key_string, status_string, time, first_time  = line.split(SEPARATOR)
          if (!first_time)
            first_time = time
          end
          key = RR.create(key_string)
          eval "cache.add_#{status_string.downcase}_key_with_time(key, time.to_i, first_time.to_i)".untaint
        end
      }
      return cache
    end

    # Store the data back to the file
    def save_tracker_cache
      # These values should only be written if the audit has been successful!!
      # Best to write it back to a new file - then move the new file to the
      # original location (overwriting the original)
      return if @parent.ret_val == 3
      tracker_file = get_tracker_filename
      File.open(tracker_file + ".temp", 'w') { |f|
        # First, save the initial timestamp and the current SOA serial
        f.puts(@initial_timestamp.to_s)
        f.puts(@last_soa_serial.to_s)
        # Now save the cache!!
        Status.strings.each {|s|
          status = s.downcase
          eval "@cache.#{status}.each {|key, time|
              write_key_to_file(f, key.to_s, status, time[0], time[1])
            }".untaint
        }

      }
      # Now move the .temp file over the original
      File.delete(tracker_file)
      File.rename(tracker_file+".temp", tracker_file)
    end

    def write_key_to_file(f, key, status, time, first_time)
      f.puts("#{key}#{SEPARATOR}#{status}#{SEPARATOR}#{time}#{SEPARATOR}#{first_time}")
    end

    def get_tracker_filename
      zone = @zone
      if ((zone.to_s == ".") || (zone.to_s==""))
        zone = "root.zone"
      end
      return @working + "#{File::SEPARATOR}tracker#{File::SEPARATOR}" + zone
    end

    #Compare two serials according to RFC 1982. Return 0 if equal,
    #-1 if s1 is bigger, 1 if s1 is smaller.
    def compare_serial(s1, s2)
      if s1 == s2
        return 0
      end
      if s1 < s2 and (s2 - s1) < (2**31)
        return 1
      end
      if s1 > s2 and (s1 - s2) > (2**31)
        return 1
      end
      if s1 < s2 and (s2 - s1) > (2**31)
        return -1
      end
      if s1 > s2 and (s1 - s2) < (2**31)
        return -1
      end
      return 0
    end

    # The auditor calls this method at the end of the auditing run.
    # This is the only public method in this class.
    # It passes in all the keys it has seen, and the keys it has seen used.
    # keys is a list of DNSKeys, and keys_used is a list of the key_tags
    # used to sign RRSIGs in the zone.
    # The data is then used to track the lifecycle of zone keys, and perform
    # associated auditing checks
    def process_key_data(keys, keys_used, soa_serial, key_ttl)
      update_cache(keys, keys_used)
      if (@last_soa_serial)
        if (compare_serial(soa_serial, @last_soa_serial) == 1)
          @parent.log(LOG_ERR, "SOA serial has decreased - used to be #{@last_soa_serial} but is now #{soa_serial}")
        end
      else
        @last_soa_serial = soa_serial
      end
      @last_soa_serial = soa_serial
      run_checks(key_ttl)
      # Then we need to save the data
      save_tracker_cache
    end

    # run the checks on the new zone data - called internally
    def run_checks(key_ttl)
      # We also need to perform the auditing checks against the config
      # Checks to be performed :
      #   b) Warn if number of prepublished ZSKs < ZSK:Standby
      # Do this by [alg, alg_length] - so only select those keys which match the config
      @config.keys.zsks.each {|zsk|
        prepublished_zsk_count = @cache.prepublished.keys.select {|k|
          k.zone_key? && !k.sep_key? && (k.algorithm == zsk.algorithm) &&
            (k.key_length == zsk.alg_length)
        }.length
        if (prepublished_zsk_count < zsk.standby)
          msg = "Not enough prepublished ZSKs! Should be #{zsk.standby} but have #{prepublished_zsk_count}"
          @parent.log(LOG_WARNING, msg)
        end
      }
      @cache.inuse.each {|key, time|
        timestamp = time[0]
        first_timestamp = time[1]
        # Ignore this check if the key was already in use at the time at which the lifetime policy was changed.
        # How do we know to which AnyKey group this key belongs? Can only take a guess by [algorithm, alg_length] tuple
        # Also going to have to put checks in place where key protocol/algorithm is checked against policy :-(
        #   - no we don't! These are only checked when we are loading a new key - not one we've seen before.
        #     and of course, a new key should be created with the correct values!
        key_group_policy_changed = false
        # First, find all the key groups which this key could belong to
        keys = @config.changed_config.zsks
        if (key.sep_key?)
          keys = @config.changed_config.ksks
        end
        possible_groups = keys.select{|k|             (k.algorithm == key.algorithm) &&
            (k.alg_length == key.key_length)}
        # Then, find the latest timestamp (other than 0)
        key_group_policy_changed_time = 0
        if (possible_groups.length == 0)
          # Can't find the group this key belongs to
          if (@config.changed_config.kasp_timestamp < first_timestamp)
            #    @TODO@ o if there has been no change in any of the configured keys then error (the key shouldn't exist)
            # Shouldn't this be caught by something else?
          end
          #   o if there has been a change since the key was first seen,  then don't raise any errors for this key
        else
          possible_groups.each {|g|
            if (g.timestamp > key_group_policy_changed_time)
              key_group_policy_changed_time = g.timestamp
              key_group_policy_changed = true
            end
          }
          next if (key_group_policy_changed && (first_timestamp < key_group_policy_changed_time))
        end

        if (key.zone_key? && !key.sep_key?)
          #   d) Warn if ZSK inuse longer than ZSK:Lifetime + Enforcer:Interval
          # Get the ZSK lifetime for this type of key from the config
          zsks = @config.keys.zsks.select{|zsk|
            (zsk.algorithm == key.algorithm) &&
              (zsk.alg_length == key.key_length)}
          next if (zsks.length == 0)
          # Take the "safest" value - i.e. the longest one in this case
          zsk_lifetime = 0
          zsks.each {|z|
            zsk_lifetime = z.lifetime if (z.lifetime > zsk_lifetime)
          }
          lifetime = zsk_lifetime + @enforcer_interval + @validity
          if timestamp < (Time.now.to_i - lifetime)
            msg = "ZSK #{key.key_tag} in use too long - should be max #{lifetime} seconds but has been #{Time.now.to_i-timestamp} seconds"
            @parent.log(LOG_WARNING, msg)
          end
        else
          #   c) Warn if KSK inuse longer than KSK:Lifetime + Enforcer:Interval
          # Get the KSK lifetime for this type of key from the config
          ksks = @config.keys.ksks.select{|ksk| (ksk.algorithm == key.algorithm) &&
              (ksk.alg_length == key.key_length)}
          next if (ksks.length == 0)
          # Take the "safest" value - i.e. the longest one in this case
          ksk_lifetime = 0
          ksks.each {|k|
            ksk_lifetime = k.lifetime if (k.lifetime > ksk_lifetime)
          }
          lifetime = ksk_lifetime + @enforcer_interval + @validity
          if timestamp < (Time.now.to_i - lifetime)
#            msg = "KSK #{key.key_tag} in use too long - should be max #{lifetime} seconds but has been #{Time.now.to_i-timestamp} seconds"
            msg = "KSK #{key.key_tag} reaching end of lifetime - should be max #{lifetime} seconds but has been #{Time.now.to_i-timestamp} seconds, not including time taken for DS to be seen"
            @parent.log(LOG_WARNING, msg)
          end
        end
      }
      if (@config.audit_tag_present)
        check_inuse_keys_history(key_ttl)
      end
    end
    
    def check_inuse_keys_history(key_ttl)
      # Error if a key is seen in use without having first been seen in prepublished for at least the zone key TTL
      # Remember not to warn if we haven't been running as long as the zone key TTL...
      if (Time.now.to_i >= (@initial_timestamp + key_ttl))
        # Has a key jumped to in-use without having gone through prepublished for at least key_ttl?
        # Just load the cache from disk again - then we could compare the two
        old_cache = load_tracker_cache(false)
        @cache.inuse.keys.each {|new_inuse_key|
          next if old_cache.include_inuse_key?new_inuse_key
          next if (new_inuse_key.sep_key?) # KSKs aren't prepublished any more
          old_key_timestamp, old_key_first_timestamp = old_cache.include_prepublished_key?new_inuse_key
          if (!old_key_timestamp)
            @parent.log(LOG_ERR, "Key (#{new_inuse_key.key_tag}) has gone straight to active use without a prepublished phase")
            next
          end

          if ((Time.now.to_i - old_key_timestamp) < key_ttl)
            @parent.log(LOG_ERR, "Key (#{new_inuse_key.key_tag}) has gone to active use, but has only been prepublished for" +
                " #{(Time.now.to_i - old_key_timestamp)} seconds. Zone DNSKEY ttl is #{key_ttl}")
          end
        }
      end
    end

    def update_cache(keys, keys_used)
      # We need to update the cache with this new information.
      # We can obviously add any revoked keys to retired.
      # Any keys in the cache that aren't in the zone are moved to dead
      # Any new keys are added to the appropriate state
      # All continuing keys are updated
      # This means :
      #   a) All keys in keys_used should be in inuse
      #   b) inuse should contain no other keys (than those in keys_usd)
      #   c) only keys in keys should be in prepublished or retired
      #   d) All keys with REVOKED should be retired
      #   e) If not previously seen, keys in keys but not keys_used should be in prepublished
      #   f) Keys which are not inuse, but still in zone, and which were previously known, should be retired
      keys.each {|key|
        #        print "Checking published key #{key.key_tag_pre_revoked}\n"
        if !@cache.include_inuse_key?(key)
          #          print "Unseen key #{key.key_tag_pre_revoked}\n"
          if !keys_used.include?(key.key_tag_pre_revoked)
            #            print "Unseen key #{key.key_tag_pre_revoked} not in use - adding to prepublished\n"
            @cache.add_prepublished_key(key)
          end
        else
          if key.revoked?
            #            print "Handling revoked key #{key.key_tag_pre_revoked}\n"
            @cache.add_retired_key(key)
            @cache.delete_prepublished_key(key)
          elsif !keys_used.include?(key.key_tag_pre_revoked)
            #            print "Previously seen non-revoked key #{key.key_tag} still published but not in use - adding to retired\n"
            @cache.add_retired_key(key)
            @cache.delete_prepublished_key(key)
          end
        end
      }
      keys_used.each {|key|
        # Now find the key with that tag
        keys.each {|k|
          if (key == k.key_tag)
            # print "Taking inuse key #{key} and removing from prepublished\n"
            @cache.add_inuse_key(k)
            @cache.delete_prepublished_key(k)
          end
        }
      }
      @cache.inuse.keys.each {|key|
        if !keys_used.include?key.key_tag_pre_revoked
          #          print "Deleting key #{key.key_tag_pre_revoked} from inuse\n"
          @cache.delete_inuse_key(key)
        end
      }
      @cache.prepublished.keys.each  {|key|
        found = false
        keys.each {|k|
          if ((key == k) || (k.key_tag_pre_revoked == key.key_tag_pre_revoked))
            found = true
          end
        }
        #        print "Deleting missing #{key.key_tag_pre_revoked} key from prepublished\n" if !found
        @cache.delete_prepublished_key(key) if !found
      }
      @cache.retired.keys.each {|key|
        found = false
        keys.each {|k|
          if ((key == k) || (k.key_tag_pre_revoked == key.key_tag_pre_revoked))
            found = true
          end
        }
        #        print "Deleting missing #{key.key_tag_pre_revoked} key from retired\n" if !found
        @cache.delete_retired_key(key) if !found
      }
    end

  end

end
