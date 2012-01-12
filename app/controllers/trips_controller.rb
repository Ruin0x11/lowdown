require 'csv'

class TripQuery
  extend ActiveModel::Naming
  include ActiveModel::Conversion

  attr_accessor :start_date, :end_date, :provider, :allocation, :dest_allocation, :commit

  def initialize(params, commit = nil)
    params ||= {}
    @commit          = commit
    @end_date        = params["end_date"] ? Date.parse(params["end_date"]) : Date.today
    @start_date      = params["start_date"] ? Date.parse(params["start_date"]) : @end_date - 5
    @provider        = params[:provider]          
    @allocation      = params[:allocation]
    @dest_allocation = params[:dest_allocation]
  end

  def persisted?
    false
  end

  def conditions
    d = {}
    d[:date]                     = start_date..end_date if start_date
    d["allocations.provider_id"] = provider if provider.present?
    d[:allocation_id]            = allocation if allocation.present?
    d
  end
  
  def update_allocation?
    @commit.try(:downcase) == "transfer trips" && @dest_allocation.present? && @dest_allocation != @allocation
  end

  def format
    return if @commit.blank?
    if @commit.downcase.include?("bpa")
      "bpa"
    elsif @commit.downcase.include?("csv")
      "general"
    end
  end
end

class TripsController < ApplicationController
  before_filter :require_admin_user, :only=>[:import]

  def index
    redirect_to :action=>:list
  end

  def list
    @query       = TripQuery.new params[:trip_query], params[:commit]
    @providers   = Provider.all
    @allocations = Allocation.order(:name)

    @trips = Trip.current_versions.includes(:pickup_address, :dropoff_address, :run, :customer, :allocation => [:provider,:project]).joins(:allocation).where(@query.conditions).order(:date,:trip_import_id)

    if @query.format == 'general'
      unused_columns = ["id", "base_id", "trip_import_id", "allocation_id", 
                        "home_address_id", "pickup_address_id", 
                        "dropoff_address_id", "customer_id", "run_id"] 

      good_columns = Trip.column_names.find_all {|x| ! unused_columns.member? x}

      csv = ""
      CSV.generate(csv) do |csv|
        csv << good_columns.map(&:titlecase) + %w{Customer Allocation Run
          Home\ Name Home\ Building Home\ Address\ 1 Home\ Address\ 2 Home\ City Home\ State Home\ Postal\ Code
          Pickup\ Name Pickup\ Building Pickup\ Address\ 1 Pickup\ Address\ 2 Pickup\ City Pickup\ State Pickup\ Postal\ Code
          Dropoff\ Name Dropoff\ Building Dropoff\ Address\ 1 Dropoff\ Address\ 2 Dropoff\ City Dropoff\ State Dropoff\ Postal\ Code}

        for trip in @trips.includes(:home_address)
          csv << good_columns.map {|x| trip.send(x)} + [trip.customer.name, trip.allocation.name, trip.run.try(:name)] + address_fields(trip.home_address) + address_fields(trip.pickup_address) + address_fields(trip.dropoff_address)
        end
      end
      return send_data csv, :type => "text/csv", :filename => "trips.csv", :disposition => 'attachment'
    elsif @query.format == 'bpa'
      csv = ""
      CSV.generate(csv) do |csv|
        csv << %w{Trip\ Date First\ Name Last\ Name StartTime EndTime Minutes Share\ ID Ride\ Type Miles Cust\ Type Billed\ Amount Invoice\ Amount Apportioned\ Amount Difference Funding\ Source Fare In/Out Guest Attendant Mobility\ Type Completed Customer\ ID Project\ # Override Trip\ Purpose Program SPD\ Billing\ Miles Customer Total\ Trips Provider Service\ End\ Date}
        for trip in @trips
          csv << [
            trip.date, 
            trip.customer.first_name,
            trip.customer.last_name,
            trip.start_at.strftime("%I:%M %p"),
            trip.end_at.strftime("%I:%M %p"),
            trip.apportioned_duration,
            trip.routematch_share_id,
            trip.shared? ? 'Shared' : 'Indiv',
            trip.apportioned_mileage,
            trip.customer.customer_type,
            trip.fare,
            trip.calculated_bpa_fare,
            trip.apportioned_fare,
            (trip.calculated_bpa_fare - trip.fare),
            trip.allocation.routematch_override.try(:split,'::').try(:slice,0),
            trip.customer_pay,
            trip.in_trimet_district ? 'TRUE' : 'FALSE',
            trip.guest_count,
            trip.attendant_count,
            trip.mobility,
            trip.result_code,
            trip.customer.routematch_customer_id,
            trip.allocation.project.project_number,
            trip.allocation.routematch_override,
            trip.purpose_type,
            trip.allocation.program,
            trip.estimated_trip_distance_in_miles,
            1,
            trip.guest_count + trip.attendant_count + 1,
            trip.allocation.provider.name,
            service_end_date(trip.date)
          ]
        end
      end
      return send_data csv, :type => "text/csv", :filename => "bpa_data.csv", :disposition => 'attachment'
    else
      @trips = @trips.paginate :page => params[:page], :per_page => 30
    end
  end
  
  def update_allocation
    @query       = TripQuery.new params[:trip_query], params[:commit]
    @providers   = Provider.with_trip_data
    
    if @query.update_allocation?
      @completed_trips_count = Trip.select("SUM(guest_count) AS g, SUM(attendant_count) AS a, COUNT(*) AS c").current_versions.where( @query.conditions ).completed.first.attributes.values.inject(0) {|sum,x| sum + x.to_i }
      if @completed_trips_count > 0
        @completed_transfer_count = params[:transfer_count].try(:to_i) || 0
        ratio = @completed_transfer_count/@completed_trips_count.to_f
        @trips_transferred = {}
        now = Trip.new.now_rounded
        
        Trip.transaction do
          Trip::RESULT_CODES.values.each do |rc|
            if rc == 'COMP'
              this_transfer_count = @completed_transfer_count
            else
              this_transfer_count = ((Trip.select("SUM(guest_count) AS g, SUM(attendant_count) AS a, COUNT(*) AS c").current_versions.where(@query.conditions).where(:result_code => rc).first.attributes.values.inject(0) {|sum,x| sum + x.to_i }) * ratio).to_i
            end

            trips_remaining = this_transfer_count
            @trips_transferred[rc] = 0
            # This is the maximum number of trips we'll need, if there are no guest or attendants. 
            # It may be fewer when guests & attendants are counted below
            trips = Trip.where(:result_code => rc).current_versions.where( @query.conditions ).limit(this_transfer_count)
            if trips.present?
              for trip in trips
                passengers = (trip.guest_count || 0) + (trip.attendant_count || 0) + 1
                if trips_remaining > 0 && passengers <= trips_remaining
                  trip.allocation_id = @query.dest_allocation 
                  trip.version_switchover_time = now
                  trip.save!
                  trips_remaining -= passengers
                  @trips_transferred[rc] += passengers
                end
              end
            end
          end
        end
        
        @allocation = Allocation.find @query.dest_allocation
      end
    end
    @trip_count = {}
    Trip::RESULT_CODES.values.each do |rc|
      @trip_count[rc] = Trip.select("SUM(guest_count) AS g, SUM(attendant_count) AS a, COUNT(*) AS c").current_versions.where(@query.conditions).where(:result_code => rc).first.attributes.values.inject(0) {|sum,x| sum + x.to_i }
    end
  end

  def share
    @trips = Trip.current_versions.paginate :page => params[:page], :per_page => 30, :conditions => {:routematch_share_id=>params[:id]}
  end

  def run
    id = params[:id]
    @trips = Trip.current_versions.paginate :page => params[:page], :per_page => 30, :conditions => {:run_id=>id}
    @run = Run.find(id)
  end
  
  def import_trips
    id = params[:id]
    @trips = Trip.current_versions.paginate :page => params[:page], :per_page => 30, :conditions => {:trip_import_id=>id}
    @import = TripImport.find(id)
  end

  def show_import
  end

  def import
    if ! params['file-import']
      redirect_to :action=>:show_import and return
    end
    file = params['file-import'].tempfile
    processed = TripImport.new(:file_path=>file)
    if processed.save
      flash[:notice] = "Import complete - #{processed.record_count} records processed.</div>"
      render 'show_import'
    else
#     TODO: make into a flash error
      flash[:notice] = "Import aborted due to the following error(s):<br/>#{processed.problems}"
      render 'show_import'
    end
  end

  def show
    @trip = Trip.find(params[:id])
    @customer = @trip.customer
    @home_address = @trip.home_address
    @pickup_address = @trip.pickup_address
    @dropoff_address = @trip.dropoff_address
    @updated_by_user = @trip.updated_by_user
    @allocations = Allocation.order(:name)
  end
  
  def update
    old_trip = Trip.find(params[:trip][:id])
    @trip = old_trip.current_version
    # clean_new_row # needed for Trips?
    @trip.update_attributes(params[:trip]) ?
      redirect_to(:action=>:show, :id=>@trip) : render(:action => :show)
  end

  def show_bulk_update

  end

  def bulk_update

    start_date = Date.parse(params[:start_date])
    end_date = Date.parse(params[:end_date])

    updated_runs = Run.current_versions.where(:complete => false, :date => start_date..end_date).update_all(:complete => true)
    updated_trips = Trip.current_versions.where(:complete => false, :date => start_date..end_date).update_all(:complete => true)
    flash[:notice] = "Updated #{updated_trips} trips records and #{updated_runs} run records"

    redirect_to :action=>:show_bulk_update
  end

  private

  def address_fields(address)
    [address.common_name, address.building_name, address.address_1, address.address_2, address.city, address.state, address.postal_code]
  end

  def service_end_date(date)
    return date if date.blank? || !date.acts_like?(:date)
    if date.day < 16
      Date.new(date.year, date.month, 15)
    else
      d = date + 1.month
      Date.new(d.year, d.month, 1) - 1.day   
    end
  end
end
