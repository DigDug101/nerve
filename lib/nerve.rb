require 'fileutils'
require 'logger'
require 'json'
require 'timeout'

require 'nerve/version'
require 'nerve/utils'
require 'nerve/log'
require 'nerve/ring_buffer'
require 'nerve/reporter'
require 'nerve/service_watcher'

module Nerve
  class Nerve

    include Logging

    def initialize(config_manager)
      log.info 'nerve: starting up!'
      @config_manager = config_manager

      # set global variable for exit signal
      $EXIT = false

      @watchers = {}
      @watcher_versions = {}

      # Flag to indicate a config reload is required by the main loop
      # This decoupling is required for gracefully reloading config on SIGHUP
      # as one should do basically nothing in a signal handler
      @config_to_load = true

      # Will be populated by load_config! in the main loop
      @instance_id = nil
      @services = {}
      @heartbeat_path = nil

      Signal.trap("HUP") do
        @config_to_load = true
      end

     log.debug 'nerve: completed init'
    end

    def load_config!
      log.info 'nerve: loading config'
      @config_to_load = false
      @config_manager.reload!
      config = @config_manager.config

      # required options
      log.debug 'nerve: checking for required inputs'
      %w{instance_id services}.each do |required|
        raise ArgumentError, "you need to specify required argument #{required}" unless config[required]
      end
      @instance_id = config['instance_id']
      @services = config['services']
      @heartbeat_path = config['heartbeat_path']
    end

    def run
      log.info 'nerve: starting run'
      begin
        loop do
          # Check if configuration needs to be reloaded and reconcile any new
          # configuration of watchers with old configuration
          if @config_to_load
            load_config!

            services_to_launch, services_to_reap = [], []

            # Determine which watchers have changed their configuration
            (@services.keys | @watchers.keys).each do |name|
              if @services.has_key?(name)
                new_watcher_config = merged_config(@services[name], name)
                # Service managed by nerve and has differing configuration
                if new_watcher_config.hash != @watcher_versions[name]
                  log.info "nerve: detected new config for #{name}"
                  services_to_launch << name
                  unless @watcher_versions[name].nil?
                    # Keep the old watcher running until replacement is launched
                    # This keeps the service registered while we change it over
                    # This also keeps connection pools active across diffs
                    new_name = "#{name}_#{@watcher_versions[name]}"
                    @watchers[new_name] = @watchers.delete(name)
                    @watcher_versions[new_name] = @watcher_versions.delete(name)
                    services_to_reap << new_name
                  end
                end
              else
                # Service no longer managed by nerve
                services_to_reap << name
              end
            end

            log.info "nerve: launching new watchers: #{services_to_launch}"
            services_to_launch.each do |name|
              launch_watcher(name, @services[name])
            end

            log.info "nerve: reaping old watchers: #{services_to_reap}"
            services_to_reap.each do |name|
                reap_watcher(name) rescue "nerve: could not cleanly reap #{name}"
            end
          end

          # If this was a configuration check, bail out now
          if @config_manager.options[:check_config]
            log.info 'nerve: configuration check succeeded, exiting'
            break
          end

          # Check that watcher threads are still alive, auto-remediate if they
          # are not. Sometimes zookeeper flakes out or connections are lost to
          # remote datacenter zookeeper clusters, failing is not an option
          relaunch = []
          @watchers.each do |name, watcher_thread|
            unless watcher_thread.alive?
              relaunch << name
            end
          end

          relaunch.each do |name|
            begin
              log.warn "nerve: watcher #{name} not alive; reaping and relaunching"
              reap_watcher(name)
            rescue => e
              log.warn "nerve: could not reap #{name}, got #{e.inspect}"
            end
            launch_watcher(name, @services[name])
          end

          unless @heartbeat_path.nil?
            FileUtils.touch(@heartbeat_path)
          end

          # "Responsive" sleep 10
          nap_time = 10
          while nap_time > 0
            break if @config_to_load
            sleep [nap_time, 1].min
            nap_time -= 1
          end
        end
      rescue => e
        log.error "nerve: encountered unexpected exception #{e.inspect} in main thread"
        raise e
      ensure
        $EXIT = true
        log.warn 'nerve: reaping all watchers'
        @watchers.each do |name, watcher_thread|
          reap_watcher(name) rescue "nerve: watcher #{name} could not be immediately reaped; skippping"
        end
      end

      log.info 'nerve: exiting'
    ensure
      $EXIT = true
    end

    def merged_config(config, name)
      return config.merge({'instance_id' => @instance_id, 'name' => name})
    end

    def launch_watcher(name, config)
      log.debug "nerve: launching service watcher #{name}"
      watcher_config = merged_config(config, name)
      # The ServiceWatcher may mutate the configs, so record the version before
      # passing the config to the ServiceWatcher
      @watcher_versions[name] = watcher_config.hash

      watcher = ServiceWatcher.new(watcher_config)
      unless @config_manager.options[:check_config]
        @watchers[name] = Thread.new{watcher.run}
      end
    end

    def reap_watcher(name)
      watcher_thread = @watchers.delete(name)
      @watcher_versions.delete(name)
      # Signal the watcher thread to exit
      watcher_thread[:finish] = true

      unclean_shutdown = watcher_thread.join(10).nil?
      if unclean_shutdown
        log.error "nerve: unclean shutdown of #{name}, killing thread"
        Thread.kill(watcher_thread)
        raise "Could not join #{watcher_thread}"
      end

      !unclean_shutdown
    end
  end
end
