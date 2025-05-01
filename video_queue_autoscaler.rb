#!/usr/bin/env ruby
require 'redis'
require 'json'
require 'logger'
require 'optparse'
require 'socket'
require 'thread'

class VideoQueueAutoscaler
  def initialize(options = {})
    @redis_url = options[:redis_url] || ENV['REDIS_URL'] || 'redis://localhost:6379/0'
    @app_name = options[:app_name] || ENV['TARGET_APP_NAME'] || 'listingai-backend'
    @target_queue = options[:target_queue] || ENV['TARGET_QUEUE'] || 'video'
    @process_group = options[:process_group] || ENV['PROCESS_GROUP'] || 'video_worker'
    @check_interval = (options[:check_interval] || ENV['CHECK_INTERVAL'] || 5).to_i
    @quiet_period = (options[:quiet_period] || ENV['QUIET_PERIOD'] || 30).to_i
    @max_instances = (options[:max_instances] || ENV['MAX_INSTANCES'] || 2).to_i
    @health_port = (options[:health_port] || ENV['HEALTH_PORT'] || 8080).to_i
    @debug = options[:debug] || (ENV['DEBUG'] == 'true')
    @logger = Logger.new(options[:log_path] || STDOUT)
    @logger.level = @debug ? Logger::DEBUG : Logger::INFO
    
    @empty_queue_since = nil
    
    @logger.info "Starting autoscaler. Target app: #{@app_name}"
    @logger.info "Monitoring queue: #{@target_queue} for auto-scaling"
    @logger.info "Process group to scale: #{@process_group}"
    @logger.info "Debug mode: #{@debug}"
    
    # Start health check server in a background thread
    start_health_server
  end
  
  def start_health_server
    Thread.new do
      begin
        @logger.info "Starting health check server on port #{@health_port}"
        server = TCPServer.new(@health_port)
        loop do
          client = server.accept
          client.puts "OK"
          client.close
        end
      rescue StandardError => e
        @logger.error "Health server error: #{e.message}"
        sleep 5
        retry # Try to restart the server if it fails
      end
    end
  end
  
  def run
    @logger.info "Starting Video Queue Autoscaler for #{@app_name}"
    @logger.info "Check interval: #{@check_interval}s, Quiet period: #{@quiet_period}s"
    
    loop do
      begin
        if video_queue_empty?
          handle_empty_queue
        else
          handle_active_queue
        end
      rescue StandardError => e
        @logger.error "Error in main loop: #{e.message}"
        @logger.debug e.backtrace.join("\n")
      end
      
      sleep @check_interval
    end
  end
  
  private
  
  def video_queue_empty?
    redis = Redis.new(url: @redis_url)
    
    # Check video queue size
    queue_size = redis.llen("queue:#{@target_queue}")
    @logger.debug "Queue #{@target_queue} size: #{queue_size}"
    return false if queue_size > 0

    # Check Sidekiq's busy workers
    processes = redis.smembers('processes')
    @logger.debug "Found #{processes.length} Sidekiq processes"
    
    processes.each do |process|
      process_info = redis.hgetall(process)
      @logger.debug "Raw process info for #{process}: #{process_info.inspect}"
      next if process_info.empty?

      begin
        busy_workers = process_info['busy'].to_i
        
        # Parse the nested info JSON
        info = JSON.parse(process_info['info']) if process_info['info']
        queues = info&.fetch('queues', []) || []
        
        if queues.include?(@target_queue)
          @logger.info "Found video worker #{process} - Busy workers: #{busy_workers}"
        else
          @logger.debug "Process #{process} - Busy workers: #{busy_workers}, Queues: #{queues.join(',')}"
        end
        
        # Only consider processes that handle our target queue
        if queues.include?(@target_queue) && busy_workers > 0
          @logger.info "Active video job found on worker #{process}"
          return false
        end
      rescue JSON::ParserError => e
        @logger.error "Failed to parse info for #{process}: #{e.message}"
        @logger.debug "Raw info: #{process_info['info']}"
      end
    end

    @logger.debug "No active jobs found for #{@target_queue}"
    true
  rescue StandardError => e
    @logger.error "Redis error checking queue state: #{e.message}"
    @logger.debug e.backtrace.join("\n") if @debug
    false
  end
  
  def handle_empty_queue
    if @empty_queue_since.nil?
      @empty_queue_since = Time.now
      @logger.info "Video queue is empty, starting #{@quiet_period}s quiet period"
    else
      elapsed = Time.now - @empty_queue_since
      
      if elapsed >= @quiet_period
        current_count = get_current_instances
        if current_count > 0
          @logger.info "Queue empty for #{elapsed.to_i}s, initiating scale down"
          scale_down
        else
          @logger.debug "Queue empty for #{elapsed.to_i}s but no workers to scale down"
        end
      else
        @logger.debug "Queue empty for #{elapsed.to_i}s (waiting for #{@quiet_period}s)"
      end
    end
  end
  
  def handle_active_queue
    if @empty_queue_since
      @logger.info "Video queue active, resetting quiet period"
      @empty_queue_since = nil
    end
    
    scale_up_if_needed
  end
  
  def get_current_instances
    cmd = "fly machines list --app #{@app_name} --json"
    @logger.debug "Executing: #{cmd}"
    output = `#{cmd}`
    
    if $?.success?
      begin
        machines = JSON.parse(output)
        # Count only machines that are started and have the correct process group
        count = machines.count do |m| 
          m['state'] == 'started' && 
          m['config'] && 
          m['config']['env'] && 
          m['config']['env']['FLY_PROCESS_GROUP'] == @process_group
        end
        @logger.info "Current #{@process_group} instances: #{count}"
        count
      rescue JSON::ParserError => e
        @logger.error "Failed to parse machines list: #{e.message}"
        0
      end
    else
      @logger.error "Machines list command exit status: #{$?.exitstatus}"
      0
    end
  end
  
  def scale_down
    current_count = get_current_instances
    return if current_count == 0
    
    @logger.info "Scaling down video workers from #{current_count}"
    
    if current_count == 1
      list_cmd = "fly machines list --app #{@app_name} --json"
      @logger.debug "Running command: #{list_cmd}"
      output = `#{list_cmd}`
      
      if $?.success?
        machines = JSON.parse(output)
        running_machines = machines.select do |m|
          m['state'] == 'started' && 
          m['config'] && 
          m['config']['env'] && 
          m['config']['env']['FLY_PROCESS_GROUP'] == @process_group
        end
        
        running_machines.each do |machine|
          stop_cmd = "fly machines stop #{machine['id']} --app #{@app_name}"
          @logger.debug "Running command: #{stop_cmd}"
          result = system(stop_cmd)
          @logger.info "Stopped machine #{machine['id']}"
        end
      else
        @logger.error "Failed to list machines: #{$?.exitstatus}"
      end
    else
      cmd = "fly scale count #{current_count - 1} --app #{@app_name} --process-group #{@process_group} --yes"
      @logger.debug "Running command: #{cmd}"
      result = system(cmd)
      @logger.info "Scaled down to #{current_count - 1} workers"
    end
  end
  
  def should_scale_up?
    redis = Redis.new(url: @redis_url)
    
    # Get video queue size
    queue_size = redis.llen("queue:#{@target_queue}")
    current_count = get_current_instances
    
    # Scale up if there are jobs and no instances
    if queue_size > 0 && current_count == 0
      @logger.info "Queue has jobs (#{queue_size}) but no workers, should scale up"
      return true
      
    # Scale up if there are more than 5 jobs per worker and we're below max
    elsif queue_size > current_count * 5 && current_count < @max_instances
      @logger.info "Queue has #{queue_size} jobs (> 5 per worker), should scale up"
      return true
    end
    
    false
  rescue StandardError => e
    @logger.error "Error checking if scale up needed: #{e.message}"
    false
  end
  
  def scale_up_if_needed
    if should_scale_up?
      # First check for suspended machines
      list_cmd = "fly machines list --app #{@app_name} --json"
      @logger.debug "Checking for suspended machines: #{list_cmd}"
      output = `#{list_cmd}`
      
      if $?.success?
        begin
          machines = JSON.parse(output)
          suspended_machines = machines.select do |m|
            m['state'] == 'stopped' && 
            m['config'] && 
            m['config']['env'] && 
            m['config']['env']['FLY_PROCESS_GROUP'] == @process_group
          end
          
          if suspended_machines.any?
            machine = suspended_machines.first
            @logger.info "Starting suspended machine #{machine['id']}"
            start_cmd = "fly machines start #{machine['id']} --app #{@app_name}"
            @logger.debug "Running command: #{start_cmd}"
            start_result = system(start_cmd)
            
            @logger.info "Started suspended machine #{machine['id']}"
            return if start_result
          end
        rescue JSON::ParserError => e
          @logger.error "Failed to parse machines list: #{e.message}"
        end
      end

      # If no suspended machines or start failed, proceed with normal scale up
      current_count = get_current_instances
      new_count = [current_count + 1, @max_instances].min
      @logger.info "Scaling up video workers from #{current_count} to #{new_count}"
      
      cmd = "fly scale count #{new_count} --app #{@app_name} --process-group #{@process_group} --yes"
      @logger.debug "Running command: #{cmd}"
      result = system(cmd)
      @logger.info "Scale up complete"
    end
  end
end

# Parse command line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: video_queue_autoscaler.rb [options]"
  
  opts.on("-r", "--redis-url URL", "Redis URL") do |url|
    options[:redis_url] = url
  end
  
  opts.on("-a", "--app-name NAME", "Fly.io App Name") do |name|
    options[:app_name] = name
  end
  
  opts.on("-q", "--target-queue QUEUE", "Target queue name") do |queue|
    options[:target_queue] = queue
  end
  
  opts.on("-g", "--process-group NAME", "Process group to scale") do |group|
    options[:process_group] = group
  end
  
  opts.on("-i", "--interval SECONDS", Integer, "Check interval in seconds") do |interval|
    options[:check_interval] = interval
  end
  
  opts.on("-p", "--quiet-period SECONDS", Integer, "Time to wait before scaling down") do |period|
    options[:quiet_period] = period
  end
  
  opts.on("-m", "--max-instances COUNT", Integer, "Maximum number of instances") do |count|
    options[:max_instances] = count
  end
  
  opts.on("-h", "--health-port PORT", Integer, "Health check port") do |port|
    options[:health_port] = port
  end
  
  opts.on("-l", "--log PATH", "Log file path") do |path|
    options[:log_path] = path
  end
  
  opts.on("-d", "--debug", "Enable debug logging") do
    options[:debug] = true
  end
  
  opts.on("--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

autoscaler = VideoQueueAutoscaler.new(options)
autoscaler.run