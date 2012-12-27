class PeriodAllocation
  attr_accessor :quarter, :year, :month, :period_start_date, :period_end_date, :collection_start_date, :collection_end_date

  def self.apply_periods(allocations, start_date, end_date, period)
    # enumerate periods between start_date and end_date.
    # collection_*_date variables represent the date range we're going to collect data for.
    # period_*_date variables represent the entire period range (e.g. the full 12 months of the year).
    # collection date ranges will be a subset of the period range when the period range extends
    # before and/or after the date range requested by the user.
    year = start_date.year
    if period == 'year'
      period_start_date = Date.new(year, 1, 1)
      advance = 12
    elsif period == 'quarter'
      zero_based_month = start_date.month - 1
      quarter_start = (zero_based_month / 3) * 3 + 1
      period_start_date = Date.new(year, quarter_start, 1)
      advance = 3
    elsif period == 'month'
      period_start_date = Date.new(year, start_date.month, 1)
      advance = 1
    end
    period_end_date = period_start_date.advance(:months=>advance)

    periods = []
    begin
      collection_start_date = (start_date > period_start_date ? start_date : period_start_date)
      collection_end_date = (end_date < period_end_date ? end_date : period_end_date)

      periods += allocations.map do |allocation|
        PeriodAllocation.new allocation, period_start_date, period_end_date, collection_start_date, collection_end_date
      end

      period_start_date = period_start_date.advance(:months=>advance)
      period_end_date = period_end_date.advance(:months=>advance)
    end while period_end_date <= end_date

    periods
  end

  def initialize(allocation, period_start_date, period_end_date, collection_start_date, collection_end_date)
    @allocation = allocation
    @period_start_date = period_start_date
    @period_end_date = period_end_date
    @collection_start_date = collection_start_date
    @collection_end_date = collection_end_date
    @quarter = period_start_date.year * 10 + (period_start_date.month - 1) / 3 + 1
    @year = period_start_date.year
    @month = period_start_date.year * 100 + period_start_date.month
  end

  def method_missing(method_name, *args, &block)
    @allocation.send method_name, *args, &block
  end

  def respond_to?(method)
    if instance_variables.member? "@#{method.to_s}".to_sym
      return true
    end
    return @allocation.respond_to? method
  end
end
