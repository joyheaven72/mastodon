# frozen_string_literal: true

class StreamingServerManager
  @running_thread = nil

  def initialize
    at_exit { stop }
  end

  def start(port: 4020)
    return if @running_thread

    queue = Queue.new

    @queue = queue

    @running_thread = Thread.new do
      Open3.popen2e(
        {
          'REDIS_NAMESPACE' => ENV.fetch('REDIS_NAMESPACE'),
          'DB_NAME' => "#{ENV.fetch('DB_NAME', 'mastodon')}_test#{ENV.fetch('TEST_ENV_NUMBER', '')}",
          'RAILS_ENV' => ENV.fetch('RAILS_ENV', 'test'),
          'NODE_ENV' => ENV.fetch('STREAMING_NODE_ENV', 'development'),
          'PORT' => port.to_s,
        },
        'node index.js', # must not call yarn here, otherwise it will fail because yarn does not send signals to its child process
        chdir: Rails.root.join('streaming')
      ) do |_stdin, stdout_err, process_thread|
        status = :starting

        # Spawn a thread to listen on streaming server output
        output_thread = Thread.new do
          stdout_err.each_line do |line|
            Rails.logger.info "Streaming server: #{line}"

            if status == :starting && line.match('Streaming API now listening on')
              status = :started
              @queue.enq 'started'
            end
          end
        end

        # And another thread to listen on commands from the main thread
        loop do
          msg = queue.pop

          case msg
          when 'stop'
            # we need to properly stop the reading thread
            output_thread.kill

            # Then stop the node process
            Process.kill('KILL', process_thread.pid)

            # And we stop ourselves
            @running_thread.kill
          end
        end
      end
    end

    # wait for 10 seconds for the streaming server to start
    Timeout.timeout(10) do
      loop do
        break if @queue.pop == 'started'
      end
    end
  end

  def stop
    return unless @running_thread

    @queue.enq 'stop'

    # Wait for the thread to end
    @running_thread.join
  end
end
