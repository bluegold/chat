# frozen_string_literal: true

module ChatBackend
  class Status
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @expecting_response = false
      @responding = false
    end

    def expect_response
      @mutex.synchronize do
        @expecting_response = true
        @responding = false
      end
    end

    def start_response
      @mutex.synchronize do
        @responding = true
        @condition.broadcast
      end
    end

    def end_response
      @mutex.synchronize do
        @responding = false
        @expecting_response = false
        @condition.broadcast
      end
    end

    def pending?
      @mutex.synchronize { @expecting_response }
    end

    def streaming?
      @mutex.synchronize { @responding }
    end
  end

  ResponseSync = Status
end
