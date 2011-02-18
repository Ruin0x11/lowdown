class Allocation < ActiveRecord::Base
  has_many :trips
  belongs_to :provider
  belongs_to :project

  def to_s
    name
  end

  def agency
    return provider.agency
  end

  def funding_source
    return project.funding_source
  end

  def funding_subsource
    return project.funding_subsource
  end

  def project_number
    return project.project_number
  end

  def project_name
    project.name
  end

end
