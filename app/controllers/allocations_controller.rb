class AllocationsController < ApplicationController
  
  before_filter :get_drop_down_data, :only => [:new, :edit]
  before_filter :require_admin_user, :except => [:index, :edit]
  
  def index
    @allocations = Allocation.includes(:project, :provider, :override).order('providers.name, allocations.name')
    respond_to do |format|
      format.html do
        @allocations = @allocations.paginate :page => params[:page]
        @grouped_allocations = @allocations.group_by(&:provider_name)
      end
      format.csv do
        @filename = 'allocations.csv'
      end
    end
  end

  def trimet_report_groups
    allocations = Allocation.includes(:trimet_report_group,:trimet_program,:trimet_provider).where('trimet_report_group_id IS NOT NULL AND trimet_program_id IS NOT NULL AND trimet_provider_id IS NOT NULL')

    @trimet_groups = {}
    allocations.each do |a|
      @trimet_groups[[a.trimet_report_group,a.trimet_program,a.trimet_provider]] ||= []
      @trimet_groups[[a.trimet_report_group,a.trimet_program,a.trimet_provider]] << a
    end
    respond_to do |format|
      format.csv do
        @filename = '"TriMet Groupings.csv"'
      end
    end
  end
  
  def new
    @allocation = Allocation.new
  end
  
  def create
    @allocation = Allocation.new params[:allocation]

    if @allocation.save
      redirect_to(allocations_path, :notice => 'Allocation was successfully created.')
    else
      get_drop_down_data
      render :action => "new"
    end
  end

  def edit
    @allocation = Allocation.find params[:id]
  end

  def update
    @allocation = Allocation.find(params[:id])

    if @allocation.update_attributes(params[:allocation])
      redirect_to(edit_allocation_path(@allocation), :notice => 'Allocation was successfully updated.')
    else
      get_drop_down_data
      render :action => "edit"
    end
  end
  
  def destroy
    @allocation = Allocation.find params[:id]
    @allocation.destroy if current_user.is_admin && !(@allocation.trips.exists? || @allocation.summaries.exists?)
    
    redirect_to allocations_url
  end

  private
  
  def get_drop_down_data
    @trip_collection_methods   = TRIP_COLLECTION_METHODS
    @run_collection_methods    = RUN_COLLECTION_METHODS 
    @cost_collection_methods   = COST_COLLECTION_METHODS
    @trimet_providers          = TrimetProvider.default_order
    @trimet_programs           = TrimetProgram.default_order
    @trimet_report_group       = TrimetReportGroup.default_order
  end
end
