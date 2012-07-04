class FlexReport < ActiveRecord::Base
  validates :name, :presence => true, :uniqueness => true
  validates :adjustment_start_date, :presence => true, :if => :adjustment?
  validates :adjustment_end_date, :presence => true, :if => :adjustment?

  validates_date :start_date, :end_date, :adjustment_start_date, :adjustment_end_date, :allow_blank => true

  attr_accessor :is_new
  attr_reader   :results, :results_fields
  
  default_scope :order => 'position ASC'

  TimePeriods = [ "year", "quarter", "month" ]
  
  GroupBys = %w{county,quarter funding_source,quarter funding_source,funding_subsource,quarter project_number,quarter funding_source,county,provider_name,program}

  GroupMappings = {
    "agency"            => "providers.agency",
    "county"            => "allocations.county",
    "funding_source"    => "projects.funding_source",
    "funding_subsource" => "projects.funding_subsource",
    "allocation_name"   => "allocations.name",
    "program"           => "allocations.program",
    "project_name"      => "projects.name",
    "project_number"    => "projects.project_number",
    "provider_name"     => "providers.name",
    "subcontractor"     => "providers.subcontractor",
    "quarter"           => "quarter",
    "month"             => "month",
    "year"              => "year"
  }


  def self.new_from_params(params)
    report = self.new(params[:flex_report])

    report.field_list      ||= ''
    report.allocation_list ||= ''

    report
  end

  def funding_subsource_names
    if funding_subsource_name_list.blank?
      [""]
    else
      funding_subsource_name_list.split("|")
    end
  end

  def funding_subsource_names=(list)
    if list.blank? 
      self.funding_subsource_name_list = nil
    else
      self.funding_subsource_name_list = list.reject {|x| x == ""}.sort.map(&:to_s).join("|")
    end
  end

  def program_names
    if program_name_list.blank?
      [""]
    else
      program_name_list.split("|")
    end
  end

  def program_names=(list)
    if list.blank? 
      self.program_name_list = nil
    else
      self.program_name_list = list.reject {|x| x == ""}.sort.map(&:to_s).join("|")
    end
  end

  def subcontractor_names
    if subcontractor_name_list.blank?
      [""]
    else
      subcontractor_name_list.split("|")
    end
  end

  def subcontractor_names=(list)
    if list.blank? 
      self.subcontractor_name_list = nil
    else
      self.subcontractor_name_list = list.reject {|x| x == ""}.sort.map(&:to_s).join("|")
    end
  end

  def county_names
    if county_name_list.blank?
      [""]
    else
      county_name_list.split("|")
    end
  end

  def county_names=(list)
    if list.blank? 
      self.county_name_list = nil
    else
      self.county_name_list = list.reject {|x| x == ""}.sort.map(&:to_s).join("|")
    end
  end

  def providers
    provider_list.blank? ? [] : Provider.find(provider_list.split(",").map(&:to_i))
  end

  def provider_ids
    provider_list.blank? ? [""] : provider_list.split(",").map(&:to_i)
  end

  def providers=(list)
    if list.blank?
      self.provider_list = nil
    else
      self.provider_list = list.sort.map(&:to_s).join(",")
    end
  end

  def allocations
    allocation_list.blank? ? [] : Allocation.find_all_by_id(allocation_list.split(",").map(&:to_i))
  end

  def allocation_ids
    allocation_list.blank? ? [] : allocation_list.split(",").map(&:to_i)
  end

  def allocations=(list)
    if list.blank?
      self.allocation_list = ''
    else
      debugger
      self.allocation_list = list.sort.map(&:to_s).join(",")
    end
  end

  def fields
    if field_list
      return field_list.split(",")
    else
      return []
    end
  end

  def fields=(list)    
    return self.field_list = '' if list.to_s.empty?

    list = list.keys if list.respond_to?(:keys)
    self.field_list = list.sort.map(&:to_s).join(",")
  end

  def query_end_date
    Date.new(end_date.year, end_date.month, 1) + 1.months
  end
  
  def query_adjustment_end_date
    Date.new(adjustment_end_date.year, adjustment_end_date.month, 1) + 1.months if adjustment_end_date.present?
  end

  def group_fields
    group_by.split(",")
  end

  def groups
    group_fields.map { |f| GroupMappings[f] }
  end

  # Collect all data, and summarize it grouped according to the groups provided.
  # groups: the names of groupings, in order from coarsest to finest (i.e. project_name, quarter)
  # group_fields: the names of groupings with table names (i.e. projects.name, quarter)
  # allocation: an list of allocations to restrict the report to
  # fields: a list of fields to display

  def populate_results!(filters=nil)
    group_select = []

    for group,field in groups.split(",").zip group_fields
      group_select << "#{group} as #{field}"
    end

    group_select = group_select.join(",")

    results = Allocation
    where_strings = []
    where_params = []
    if funding_subsource_name_list.present?
      results = results.joins(:project)
      where_strings << "COALESCE(projects.funding_source,'') || ': ' || COALESCE(projects.funding_subsource) IN (?)"
      where_params << funding_subsource_names
    end
    if provider_list.present? 
      where_strings << "provider_id IN (?)"
      where_params << provider_ids
    end
    if subcontractor_name_list.present?
      results = results.joins(:provider)
      where_strings << "providers.subcontractor IN (?)"
      where_params << subcontractor_names
    end
    if program_name_list.present?
      where_strings << "program IN (?)"
      where_params << program_names
    end
    if county_name_list.present?
      where_strings << "county IN (?)"
      where_params << county_names
    end

    if where_strings.present?
      where_string = where_strings.join(" AND ")
      if allocations.present?
        where_string = "(#{where_string}) OR allocations.id IN (?)"
        where_params << allocations
      end
    elsif allocations.present?
        where_string = "allocations.id IN (?)"
        where_params << allocations
    end
    results = results.where(where_string, *where_params)
     
    for period in TimePeriods
      if group_fields.member? period
        results = PeriodAllocation.apply_periods(results, start_date, query_end_date, period)
      end
    end

    allocations = group(group_fields, results)
    apply_to_leaves! allocations, group_fields.size do | allocationset |
      row = ReportRow.new fields

      for allocation in allocationset
        if allocation.respond_to? :period_start_date 
          collection_start_date = allocation.period_start_date
          collection_end_date = allocation.period_end_date
        else
          collection_start_date = start_date
          collection_end_date = query_end_date
          # collection_start_date = adjustment ? adjustment_start_date : start_date
          # collection_end_date   = adjustment ? query_adustment_end_date : query_end_date
        end

        if allocation.trip_collection_method == 'trips'
          row.collect_trips_by_trip(allocation, collection_start_date, collection_end_date, pending, adjustment)
        else
          row.collect_trips_by_summary(allocation, collection_start_date, collection_end_date, pending, adjustment)
        end

        if allocation.run_collection_method == 'trips' 
          row.collect_runs_by_trip(allocation, collection_start_date, collection_end_date, pending, adjustment)
        elsif allocation.run_collection_method == 'runs'
          row.collect_runs_by_run(allocation, collection_start_date, collection_end_date, pending, adjustment)
        else
          row.collect_runs_by_summary(allocation, collection_start_date, collection_end_date, pending, adjustment)
        end

        if allocation.cost_collection_method == 'summary'
          row.collect_costs_by_summary(allocation, collection_start_date, collection_end_date, pending, adjustment)
        end
        row.collect_costs_by_trip(allocation, collection_start_date, collection_end_date, pending, adjustment)

        row.collect_operation_data_by_summary(allocation, collection_start_date, collection_end_date, pending, adjustment)

      end
      row.allocation = allocationset[0]
      row
    end

    # @levels = group_fields.size
    @results = allocations
    @results_fields = {}
    if fields.nil? or fields.empty?
      ReportRow.fields.each do |field| 
        @results_fields[field] = 1
      end
    else
      fields.each do |field| 
        @results_fields[field] = 1
      end
    end

    @results_fields['driver_hours'] = 0
    ['driver_volunteer_hours', 'driver_paid_hours', 'driver_total_hours'].each do |field| 
      if @results_fields.member? field
        @results_fields['driver_hours'] += 1
      end
    end
    @results_fields['volunteer_hours'] = 0
    ['escort_volunteer_hours', 'admin_volunteer_hours', 'total_volunteer_hours'].each do |field|
      if @results_fields.member? field
        @results_fields['volunteer_hours'] += 1
      end
    end
  end

  private
  # group a set of records by a list of fields.  
  # groups is a list of fields to group by
  # records is a list of records
  # the output is a nested hash, with one level for each element of groups
  # for example,

  # groups = [kingdom, edible]
  # records = [platypus, cow, oak, apple, orange, shiitake]
  # output = {'animal' => { 'no' => ['platypus'], 
  #                         'yes' => ['cow'] 
  #                       }, 
  #           'plant' => { 'no' => 'oak'], 
  #                        'yes' => ['apple', 'orange']
  #                       }
  #           'fungus' => { 'yes' => ['shiitake'] }
  #          }
  def group(groups, records)
    out = {}
    last_group = groups[-1]

    for record in records
      cur_group = out
      for group in groups
        group_value = record.send(group)
        if group == last_group
          if !cur_group.member? group_value
            cur_group[group_value] = []
          end
        else
          if ! cur_group.member? group_value
            cur_group[group_value] = {}
          end
        end
        cur_group = cur_group[group_value]
      end
      cur_group << record
    end
    return out
  end


  # Apply the specified block to the leaves of a nested hash (leaves
  # are defined as elements {depth} levels deep, so that hashes
  # can be leaves)
  def apply_to_leaves!(group, depth, &block) 
    if depth == 0
      return block.call group
    else
      group.each do |k, v|
        group[k] = apply_to_leaves! v, depth - 1, &block
      end
      return group
    end
  end

  def get_by_key(groups, hash, keysrc)
    for group in groups
      val = keysrc.instance_variable_get "@#{group}"
      if hash.nil? 
        return nil
      end
      hash = hash[val]
    end
    return hash
  end

end