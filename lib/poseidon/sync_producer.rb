module Poseidon
  # Used by +Producer+ for sending messages to the kafka cluster.
  #
  # You should not use this interface directly
  #
  # Fetches metadata at appropriate times.
  # Builds MessagesToSend
  # Handle MessageBatchToSend lifecyle
  #
  # Who is responsible for fetching metadata from broker seed list?
  #   Do we want to be fetching from real live brokers eventually?
  #
  # @api private
  class SyncProducer
    OPTION_DEFAULTS = {
      :compression_codec => nil,
      :compressed_topics => nil,
      :metadata_refresh_interval_ms => 600_000,
      :partitioner => nil,
      :max_send_retries => 3,
      :retry_backoff_ms => 100,
      :required_acks => 0,
      :ack_timeout_ms => 1500,
    }

    attr_reader :client_id, :retry_backoff_ms, :max_send_retries,
      :metadata_refresh_interval_ms, :required_acks, :ack_timeout_ms
    def initialize(client_id, seed_brokers, options = {})
      @client_id = client_id

      handle_options(options.dup)

      @cluster_metadata   = ClusterMetadata.new
      @message_conductor  = MessageConductor.new(@cluster_metadata, @partitioner)
      @broker_pool        = BrokerPool.new(client_id, seed_brokers)
    end

    def send_messages(messages, &callback)
      return if messages.empty?

      messages_to_send = MessagesToSend.new(messages, @cluster_metadata, callback)

      retries_remaining = @max_send_retries
      while retries_remaining >= 0 && messages_to_send.unsent_messages?
        if messages_to_send.needs_metadata? || refresh_interval_elapsed?
          refreshed_metadata = refresh_metadata(messages_to_send.topic_set)

          # Unable to get any metadata fail all messages.
          if !refreshed_metadata
            puts "Failed to refresh metadata"
            messages_to_send.topic_set.each do |topic|
              messages = messages_to_send.remove_for_topic(topic)
              callback.call(ProduceResult.metadata_failure(topic, messages))
            end
          end

=begin
          # Fail any messages we couldn't find topic metadata for if this is
          # the last retry
          if retries_remaining == 0
            metadata_for_topics = @cluster_metadata.metadata_for_topics(messages_to_send.topic_set)

            messages_to_send.topic_set.each do |topic|
              if metadata_for_topics[topic].nil?
                messages = messages_to_send.remove_for_topic(topic)
                callback.call(ProduceResult.metadata_failure(topic, messages))
              end
            end
          end
=end
        end

        messages_to_send.messages_for_brokers(@message_conductor).each do |messages_for_broker|
          if response = send_to_broker(messages_for_broker)
            trigger_callbacks_for_produce_response(response, callback)
          else
            messages_to_send.successfully_sent(messages_for_broker.messages)

            # Need to trigger callback for each partition/topic pair
            trigger_callbacks_for_zero_ack_request(messages_for_broker.messages, callback)
          end
        end

        if !messages_to_send.unsent_messages? || @max_send_retries == 0
          p "Getting out of here"
          break
        else
          Kernel.sleep retry_backoff_ms / 1000.0
          refresh_metadata(messages_to_send.topic_set)
        end

        retries_remaining -= 1
      end

      nil
    end

    def shutdown
      @broker_pool.shutdown
    end
    
    private
    def handle_options(options)
      @ack_timeout_ms    = handle_option(options, :ack_timeout_ms)
      @retry_backoff_ms  = handle_option(options, :retry_backoff_ms)

      @metadata_refresh_interval_ms = 
        handle_option(options, :metadata_refresh_interval_ms)

      @required_acks    = handle_option(options, :required_acks)
      @max_send_retries = handle_option(options, :max_send_retries)

      @compression_config = ProducerCompressionConfig.new(
        handle_option(options, :compression_codec), 
        handle_option(options, :compressed_topics))

      @partitioner = handle_option(options, :partitioner)

      raise ArgumentError, "Unknown options: #{options.keys.inspect}" if options.keys.any?
    end

    def handle_option(options, sym)
      options.delete(sym) || OPTION_DEFAULTS[sym]
    end

    def refresh_interval_elapsed?
      (Time.now - @cluster_metadata.last_refreshed_at) > metadata_refresh_interval_ms
    end

    def refresh_metadata(topics)
      @cluster_metadata.update(@broker_pool.fetch_metadata(topics))
      @broker_pool.update_known_brokers(@cluster_metadata.brokers)
      true
    rescue Errors::UnableToFetchMetadata
      return nil
    end

    def send_to_broker(messages_for_broker, callback)
      return false if messages_for_broker.broker_id == -1
      to_send = messages_for_broker.build_protocol_objects(@compression_config)
      response = @broker_pool.execute_api_call(messages_for_broker.broker_id, :produce,
                                              required_acks, ack_timeout_ms,
                                              to_send)
=begin
      if required_acks != 0
        messages_for_broker.successfully_sent(response, callback)
      else
        # Client requested 0 acks, assume all sends were successful
        messages_for_broker.messages
      end
=end
    rescue Connection::ConnectionFailedError
      false
    end
  end
end
