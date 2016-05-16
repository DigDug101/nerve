require 'nerve/service_watcher/base'


module Nerve
  module ServiceCheck
    class ShellServiceCheck < BaseServiceCheck
      require 'open3'

      def initialize(opts={})
        super

        raise ArgumentError, "missing required argument 'command' in shell check" unless opts['command']

        @command = opts['command']
        @expected_exit_statuses = opts['expected_exit_statuses'] || [0]
      end

      def check
        log.debug "nerve: running shell health check #{@name}"
        _, _, status = Open3.capture3(@command)
        log.debug "nerve: shell check exited with status #{status}"

        return @expected_exit_statuses.include?(status)
      end
    end

    CHECKS ||= {}
    CHECKS['shell'] = ShellServiceCheck
  end
end
