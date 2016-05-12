# Long running class that determines if, and in how much detail a potentially
# slow transaction should be recorded in
#
# Rules:
#   - Runtime must be slower than a threshold

module ScoutApm
  class SlowRequestPolicy
    CAPTURE_TYPES = [
      CAPTURE_DETAIL  = "capture_detail",
      CAPTURE_NONE    = "capture_none",
    ]

    # Adjust speed points. See the function
    POINT_MULTIPLIER_SPEED = 0.25

    # For each minute we haven't seen an endpoint
    POINT_MULTIPLIER_AGE = 0.25

    # Outliers are worth up to "1000ms" of weight
    POINT_MULTIPLIER_PERCENTILE = 1.0

    # A hash of Endpoint Name to the last time we stored a slow transaction for it.
    #
    # Defaults to a start time that is pretty close to application boot time.
    # So the "age" of an endpoint we've never seen is the time the application
    # has been running.
    attr_reader :last_seen


    def initialize
      zero_time = Time.now
      @last_seen = Hash.new { |h, k| h[k] = zero_time }
    end

    def stored!(request)
      last_seen[unique_name_for(request)] = Time.now
    end

    # Determine if this request trace should be fully analyzed by scoring it
    # across several metrics, and then determining if that's good enough to
    # make it into this minute's payload.
    #
    # Due to the combining nature of the agent & layaway file, there's no
    # guarantee that a high scoring local champion will still be a winner when
    # they go up to "regionals" and are compared against the other processes
    # running on a node.
    def score(request)
      unique_name = request.unique_name
      if unique_name == :unknown
        return -1 # A negative score, should never be good enough to store.
      end

      total_time = request.root_layer.total_call_time

      # How long has it been since we've seen this?
      age = Time.now - last_seen[unique_name]

      # What approximate percentile was this request?
      percentile = ScoutApm::Agent.instance.request_histograms.approximate_quantile_of_value(unique_name, total_time)

      return speed_points(total_time) + percentile_points(percentile) + age_points(age)
    end

    private

    def unique_name_for(request)
      scope_layer = LayerConverters::ConverterBase.new(request).scope_layer
      if scope_layer
        scope_layer.legacy_metric_name
      else
        :unknown
      end
    end

    # Time in seconds
    # Logarithm keeps huge times from swamping the other metrics.
    # 1+ is necessary to keep the log function in positive territory.
    def speed_points(time)
      Math.log(1 + time) * POINT_MULTIPLIER_SPEED
    end

    def percentile_points(percentile)
      percentile * POINT_MULTIPLIER_PERCENTILE
    end

    def age_points(age)
      age / 60.0 * POINT_MULTIPLIER_AGE
    end
  end
end
