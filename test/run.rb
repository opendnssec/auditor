require 'lib/kasp_auditor.rb'
include KASPAuditor

path = ARGV[0] + "/"
runner = Runner.new
runner.run(path)