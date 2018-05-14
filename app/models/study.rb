class Study

  ###
  #
  # Study: main object class for portal; stores information regarding study objects and references to FireCloud workspaces,
  # access controls to viewing study objects, and also used as main parsing class for uploaded study files.
  #
  ###

  include Mongoid::Document
  include Mongoid::Timestamps

  ###
  #
  # FIRECLOUD METHODS
  #
  ###

  # prefix for FireCloud workspaces, defaults to blank in production
  WORKSPACE_NAME_PREFIX = Rails.env != 'production' ? Rails.env + '-' : ''

  # instantiate one FireCloudClient to avoid creating too many tokens
  @@firecloud_client = FireCloudClient.new

  # getter for FireCloudClient instance
  def self.firecloud_client
    @@firecloud_client
  end

  # method to renew firecloud client (forces new access token for API and reinitializes storage driver)
  def self.refresh_firecloud_client
    begin
      @@firecloud_client = FireCloudClient.new
      true
    rescue => e
      Rails.logger.error "#{Time.now}: unable to refresh FireCloud client: #{e.message}"
      e.message
    end
  end

  ###
  #
  # SETTINGS, ASSOCIATIONS AND SCOPES
  #
  ###

  # pagination
  def self.per_page
    5
  end

  # associations and scopes
  belongs_to :user
  belongs_to :branding_group
  has_many :study_files, dependent: :delete do
    def by_type(file_type)
      if file_type.is_a?(Array)
        where(queued_for_deletion: false, :file_type.in => file_type).to_a
      else
        where(queued_for_deletion: false, file_type: file_type).to_a
      end
    end

    def non_primary_data
      where(queued_for_deletion: false).not_in(file_type: 'Fastq').to_a
    end

    def valid
      where(queued_for_deletion: false, :generation.ne => nil).to_a
    end
  end

  has_many :expression_scores, dependent: :delete do
    def by_gene(gene, study_file_ids)
      found_scores = any_of({gene: gene, :study_file_id.in => study_file_ids}, {searchable_gene: gene.downcase, :study_file_id.in => study_file_ids})
      if found_scores.empty?
        return []
      else
        # since we can have duplicate genes but not cells, merge into one object for rendering
        merged_scores = {'searchable_gene' => gene.downcase, 'gene' => gene, 'scores' => {}}
        found_scores.each do |score|
          merged_scores['scores'].merge!(score.scores)
        end
        return [merged_scores]
      end
    end

    def unique_genes
      pluck(:gene).uniq
    end
  end

  has_many :genes, dependent: :delete do
    def by_name(gene_name, study_file_ids)
      found_scores = any_of({name: gene_name, :study_file_id.in => study_file_ids}, {searchable_name: gene_name.downcase, :study_file_id.in => study_file_ids})
      if found_scores.empty?
        return []
      else
        # since we can have duplicate genes but not cells, merge into one object for rendering
        merged_scores = {'searchable_name' => gene_name.downcase, 'name' => gene_name, 'scores' => {}}
        found_scores.each do |score|
          merged_scores['scores'].merge!(score.scores)
        end
        return [merged_scores]
      end
    end

    def unique_genes
      pluck(:name).uniq
    end
  end

  has_many :precomputed_scores, dependent: :delete do
    def by_name(name)
      where(name: name).first
    end
  end

  has_many :study_shares, dependent: :destroy do
    def can_edit
      where(permission: 'Edit').map(&:email)
    end

    def can_view
      all.to_a.map(&:email)
    end

    def non_reviewers
      where(:permission.nin => %w(Reviewer)).map(&:email)
    end

    def reviewers
      where(permission: 'Reviewer').map(&:email)
    end
  end

  has_many :cluster_groups, dependent: :delete do
    def by_name(name)
      find_by(name: name)
    end
  end

  has_many :data_arrays, as: :linear_data, dependent: :delete do
    def by_name_and_type(name, type)
      where(name: name, array_type: type).order_by(&:array_index)
    end
  end

  has_many :study_metadata, dependent: :delete do
    def by_name_and_type(name, type)
      where(name: name, annotation_type: type).to_a
    end
  end

  has_many :cell_metadata, dependent: :delete do
    def by_name_and_type(name, type)
      where(name: name, annotation_type: type).first
    end
  end

  has_many :directory_listings, dependent: :delete do
    def unsynced
      where(sync_status: false).to_a
    end

    # all synced directories, regardless of type
    def are_synced
      where(sync_status: true).to_a
    end

    # synced directories of a specific type
    def synced_by_type(file_type)
      where(sync_status: true, file_type: file_type).to_a
    end

    # primary data directories
    def primary_data
      where(sync_status: true, :file_type.in => DirectoryListing::PRIMARY_DATA_TYPES).to_a
    end

    # non-primary data directories
    def non_primary_data
      where(sync_status: true, :file_type.nin => DirectoryListing::PRIMARY_DATA_TYPES).to_a
    end
  end

  # User annotations are per study
  has_many :user_annotations, dependent: :delete
  has_many :user_data_arrays, dependent: :delete

  # HCA metadata object
  has_many :analysis_metadata, dependent: :delete do
    def public
      where(published: true)
    end
  end

  # field definitions
  field :name, type: String
  field :embargo, type: Date
  field :url_safe_name, type: String
  field :description, type: String
  field :firecloud_workspace, type: String
  field :firecloud_project, type: String, default: FireCloudClient::PORTAL_NAMESPACE
  field :bucket_id, type: String
  field :data_dir, type: String
  field :public, type: Boolean, default: true
  field :queued_for_deletion, type: Boolean, default: false
  field :initialized, type: Boolean, default: false
  field :view_count, type: Integer, default: 0
  field :cell_count, type: Integer, default: 0
  field :gene_count, type: Integer, default: 0
  field :view_order, type: Float, default: 100.0
  field :use_existing_workspace, type: Boolean, default: false
  field :default_options, type: Hash, default: {} # extensible hash where we can put arbitrary values as 'defaults'

  accepts_nested_attributes_for :study_files, allow_destroy: true
  accepts_nested_attributes_for :study_shares, allow_destroy: true, reject_if: proc { |attributes| attributes['email'].blank? }

  ###
  #
  # VALIDATIONS & CALLBACKS
  #
  ###

  # custom validator since we need everything to pass in a specific order (otherwise we get orphaned FireCloud workspaces)
  validate :initialize_with_new_workspace, on: :create, if: Proc.new {|study| !study.use_existing_workspace}
  validate :initialize_with_existing_workspace, on: :create, if: Proc.new {|study| study.use_existing_workspace}

  # populate specific errors for study shares since they share the same form
  validate do |study|
    study.study_shares.each do |study_share|
      next if study_share.valid?
      study_share.errors.full_messages.each do |msg|
        errors.add(:base, "Share Error - #{msg}")
      end
    end
  end

  # update validators
  validates_uniqueness_of :name, on: :update, message: ": %{value} has already been taken.  Please choose another name."
  validates_presence_of   :name, on: :update
  validates_uniqueness_of :url_safe_name, on: :update, message: ": The name you provided tried to create a public URL (%{value}) that is already assigned.  Please rename your study to a different value."

  # callbacks
  before_validation :set_url_safe_name
  before_validation :set_data_dir, :set_firecloud_workspace_name, on: :create
  # before_save       :verify_default_options
  after_create      :make_data_dir, :set_default_participant
  after_destroy     :remove_data_dir

  # search definitions
  index({"name" => "text", "description" => "text"}, {background: true})

  ###
  #
  # ACCESS CONTROL METHODS
  #
  ###

  # return all studies that are editable by a given user
  def self.editable(user)
    if user.admin?
      self.where(queued_for_deletion: false)
    else
      studies = self.where(queued_for_deletion: false, user_id: user._id)
      shares = StudyShare.where(email: user.email, permission: 'Edit').map(&:study).select {|s| !s.queued_for_deletion }
      [studies + shares].flatten.uniq
    end
  end

  # return all studies that are viewable by a given user as a Mongoid criterion
  def self.viewable(user)
    if user.admin?
      self.where(queued_for_deletion: false)
    else
      public = self.where(public: true, queued_for_deletion: false).map(&:_id)
      owned = self.where(user_id: user._id, public: false, queued_for_deletion: false).map(&:_id)
      shares = StudyShare.where(email: user.email).map(&:study).select {|s| !s.queued_for_deletion }.map(&:_id)
      intersection = public + owned + shares
      # return Mongoid criterion object to use with pagination
      Study.in(:_id => intersection)
    end
  end

  # return all studies either owned by or shared with a given user as a Mongoid criterion
  def self.accessible(user)
    if user.admin?
      self.where(queued_for_deletion: false)
    else
      owned = self.where(user_id: user._id, queued_for_deletion: false).map(&:_id)
      shares = StudyShare.where(email: user.email).map(&:study).select {|s| !s.queued_for_deletion }.map(&:_id)
      intersection = owned + shares
      Study.in(:_id => intersection)
    end
  end

  # check if a give use can edit study
  def can_edit?(user)
    user.nil? ? false : self.admins.include?(user.email)
  end

  # check if a given user can view study by share (does not take public into account - use Study.viewable(user) instead)
  def can_view?(user)
    if user.nil?
      false
    else
      self.can_edit?(user) || self.study_shares.can_view.include?(user.email)
    end
  end

  # check if a user can download data directly from the bucket
  def can_direct_download?(user)
    if user.nil?
      false
    else
      self.user.email == user.email || self.study_shares.can_view.include?(user.email)
    end
  end

  # check if a user can download data through the portal
  def can_download?(user)
    if user.nil?
      false
    else
      self.public? || self.can_edit?(user) || self.study_shares.non_reviewers.include?(user.email)
    end
  end

  # check if user can delete a study - only owners can
  def can_delete?(user)
    self.user_id == user.id || user.admin?
  end

  # check if a user can run workflows on the given study
  def can_compute?(user)
    if user.nil?
      false
    else
      workspace_acl = Study.firecloud_client.get_workspace_acl(self.firecloud_project, self.firecloud_workspace)
      workspace_acl['acl'][user.email].nil? ? false : workspace_acl['acl'][user.email]['canCompute']
    end
  end

  # list of emails for accounts that can edit this study
  def admins
    [self.user.email, self.study_shares.can_edit, User.where(admin: true).pluck(:email)].flatten.uniq
  end

  # check if study is still under embargo or whether given user can bypass embargo
  def embargoed?(user)
    if user.nil?
      self.check_embargo?
    else
      # must not be viewable by current user & embargoed to be true
      !self.can_view?(user) && self.check_embargo?
    end
  end

  # helper method to check embargo status
  def check_embargo?
    self.embargo.nil? || self.embargo.blank? ? false : Date.today <= self.embargo
  end

  # label for study visibility
  def visibility
    self.public? ? "<span class='sc-badge bg-success text-success'>Public</span>".html_safe : "<span class='sc-badge bg-danger text-danger'>Private</span>".html_safe
  end

  # helper method to return key-value pairs of sharing permissions local to portal (not what is persisted in FireCloud)
  # primarily used when syncing study with FireCloud workspace
  def local_acl
    acl = {
        "#{self.user.email}" => (Rails.env == 'production' && FireCloudClient::COMPUTE_BLACKLIST.include?(self.firecloud_project)) ? 'Edit' : 'Owner'
    }
    self.study_shares.each do |share|
      acl["#{share.email}"] = share.permission
    end
    acl
  end

  ###
  #
  # DATA PATHS & URLS
  #
  ###

  # file path to study public folder
  def data_public_path
    Rails.root.join('public', 'single_cell', 'data', self.url_safe_name)
  end

  # file path to upload storage directory
  def data_store_path
    Rails.root.join('data', self.data_dir)
  end

  # helper to generate a URL to a study's FireCloud workspace
  def workspace_url
    "https://portal.firecloud.org/#workspaces/#{self.firecloud_project}/#{self.firecloud_workspace}"
  end

  # helper to generate a URL to a study's GCP bucket
  def google_bucket_url
    "https://console.cloud.google.com/storage/browser/#{self.bucket_id}"
  end

  # helper to generate a URL to a specific FireCloud submission inside a study's GCP bucket
  def submission_url(submission_id)
    self.google_bucket_url + "/#{submission_id}"
  end

  ###
  #
  # DEFAULT OPTIONS METHODS
  #
  ###

  # helper to return default cluster to load, will fall back to first cluster if no preference has been set
  # or default cluster cannot be loaded
  def default_cluster
    default = self.cluster_groups.first
    unless self.default_options[:cluster].nil?
      new_default = self.cluster_groups.by_name(self.default_options[:cluster])
      unless new_default.nil?
        default = new_default
      end
    end
    default
  end

  # helper to return default annotation to load, will fall back to first available annotation if no preference has been set
  # or default annotation cannot be loaded
  def default_annotation
    default_cluster = self.default_cluster
    default_annot = self.default_options[:annotation]
    # in case default has not been set
    if default_annot.nil?
      if !default_cluster.nil? && default_cluster.cell_annotations.any?
        annot = default_cluster.cell_annotations.first
        default_annot = "#{annot[:name]}--#{annot[:type]}--cluster"
      elsif self.cell_metadata.any?
        metadatum = self.cell_metadata.first
        default_annot = "#{metadatum.name}--#{metadatum.annotation_type}--study"
      else
        # annotation won't be set yet if a user is parsing metadata without clusters, or vice versa
        default_annot = nil
      end
    end
    default_annot
  end

  # helper to return default annotation type (group or numeric)
  def default_annotation_type
    if self.default_options[:annotation].nil?
      nil
    else
      # middle part of the annotation string is the type, e.g. Label--group--study
      self.default_options[:annotation].split('--')[1]
    end
  end

  # return color profile value, converting blanks to nils
  def default_color_profile
    self.default_options[:color_profile].presence
  end

  # return the value of the expression axis label
  def default_expression_label
    label = self.default_options[:expression_label].presence
    label.nil? ? 'Expression' : label
  end

  # determine if a user has supplied an expression label
  def has_expression_label?
    !self.default_options[:expression_label].blank?
  end

  # determine whether or not the study owner wants to receive update emails
  def deliver_emails?
    if self.default_options[:deliver_emails].nil?
      true
    else
      self.default_options[:deliver_emails]
    end
  end

  # default size for cluster points
  def default_cluster_point_size
    if self.default_options[:cluster_point_size].blank?
      6
    else
      self.default_options[:cluster_point_size].to_i
    end
  end

  # default size for cluster points
  def show_cluster_point_borders?
    if self.default_options[:cluster_point_border].blank?
      true
    else
      self.default_options[:cluster_point_border] == 'true'
    end
  end

  def default_cluster_point_alpha
    if self.default_options[:cluster_point_alpha].blank?
      1.0
    else
      self.default_options[:cluster_point_alpha].to_f
    end
  end

  ###
  #
  # INSTANCE VALUE SETTERS & GETTERS
  #
  ###

  # helper method to get number of unique single cells
  def set_cell_count
    @cell_count = self.all_cells_array.size
    self.update!(cell_count: @cell_count)
    Rails.logger.info "#{Time.now}: Setting cell count in #{self.name} to #{@cell_count}"
  end

  # helper method to set the number of unique genes in this study
  def set_gene_count
    gene_count = self.genes.pluck(:name).uniq.count
    Rails.logger.info "#{Time.now}: setting gene count in #{self.name} to #{gene_count}"
    self.update!(gene_count: gene_count)
  end

  # return a count of the number of fastq files both uploaded and referenced via directory_listings for a study
  def primary_data_file_count
    study_file_count = self.study_files.by_type('Fastq').size
    directory_listing_count = self.directory_listings.primary_data.map {|d| d.files.size}.reduce(0, :+)
    study_file_count + directory_listing_count
  end

  # count of all files in a study, regardless of type
  def total_file_count
    self.study_files.non_primary_data.count + self.primary_data_file_count
  end

  # return a count of the number of miscellanous files both uploaded and referenced via directory_listings for a study
  def misc_directory_file_count
    self.directory_listings.non_primary_data.map {|d| d.files.size}.reduce(0, :+)
  end

  # count the number of cluster-based annotations in a study
  def cluster_annotation_count
    self.cluster_groups.map {|c| c.cell_annotations.size}.reduce(0, :+)
  end

  ###
  #
  # METADATA METHODS
  #
  ###

  # return an array of all single cell names in study
  def all_cells
    annot = self.study_metadata.first
    if annot.present?
      annot.cell_annotations.keys
    else
      []
    end
  end

  # return an array of all single cell names in study, will check for master list of cells or concatenate all
  # cell lists from individual expression matrices
  def all_cells_array
    vals = []
    arrays = DataArray.where(study_id: self.id, linear_data_type: 'Study', linear_data_id: self.id, name: 'All Cells').order_by(&:array_index)
    if arrays.any?
      arrays.each do |array|
        vals += array.values
      end
    else
      vals = self.all_expression_matrix_cells
    end
    vals
  end

  # return an array of all cell names that have been used in expression matrices (does not get cells from cell metadata file)
  def all_expression_matrix_cells
    vals = []
    self.expression_matrix_files.each do |file|
      arrays = DataArray.where(name: "#{file.name} Cells", array_type: 'cells', linear_data_type: 'Study',
                               linear_data_id: self.id).order_by(&:array_index)
      arrays.each do |array|
        vals += array.values
      end
    end
    vals
  end

  # return a hash keyed by cell name of the requested study_metadata values
  def cell_metadata_values(metadata_name, metadata_type)
    cell_metadatum = self.cell_metadata.by_name_and_type(metadata_name, metadata_type)
    if cell_metadatum.present?
      cell_metadatum.cell_annotations
    else
      {}
    end
  end

  # return array of possible values for a given study_metadata annotation (valid only for group-based)
  def cell_metadata_keys(metadata_name, metadata_type)
    cell_metadatum = self.cell_metadata.by_name_and_type(metadata_name, metadata_type)
    if cell_metadatum.present?
      cell_metadatum.values
    else
      []
    end
  end

  ###
  #
  # STUDYFILE GETTERS
  #
  ###


  # helper to build a study file of the requested type
  def build_study_file(attributes)
    self.study_files.build(attributes)
  end

  # helper method to access all cluster definitions files
  def cluster_ordinations_files
    self.study_files.by_type('Cluster')
  end

  # helper method to access cluster definitions file by name
  def cluster_ordinations_file(name)
    self.study_files.find_by(file_type: 'Cluster', name: name)
  end

  # helper method to directly access expression matrix files
  def expression_matrix_files
    self.study_files.by_type(['Expression Matrix', 'MM Coordinate Matrix'])
  end

  # helper method to directly access expression matrix file file by name
  def expression_matrix_file(name)
    self.study_files.find_by(:file_type.in => ['Expression Matrix', 'MM Coordinate Matrix'], name: name)
  end
  # helper method to directly access metadata file
  def metadata_file
    self.study_files.by_type('Metadata').first
  end

  ###
  #
  # DELETE METHODS
  #
  ###

  # nightly cron to delete any studies that are 'queued for deletion'
  # will run after database is re-indexed to make performance better
  # calls delete_all on collections to minimize memory usage
  def self.delete_queued_studies
    studies = self.where(queued_for_deletion: true)
    studies.each do |study|
      Rails.logger.info "#{Time.now}: deleting queued study #{study.name}"
      Gene.where(study_id: study.id).delete_all
      DataArray.where(study_id: study.id).delete_all
      CellMetadatum.where(study_id: study.id).delete_all
      PrecomputedScore.where(study_id: study.id).delete_all
      ClusterGroup.where(study_id: study.id).delete_all
      StudyFile.where(study_id: study.id).delete_all
      DirectoryListing.where(study_id: study.id).delete_all
      UserAnnotation.where(study_id: study.id).delete_all
      UserAnnotationShare.where(study_id: study.id).delete_all
      UserDataArray.where(study_id: study.id).delete_all
      AnalysisMetadatum.where(study_id: study.id).delete_all
      # now destroy study to ensure everything is removed
      study.destroy
      Rails.logger.info "#{Time.now}: delete of #{study.name} completed"
    end
    true
  end

  ###
  #
  # MISCELLANOUS METHODS
  #
  ###

  # transform expression data from db into mtx format
  def expression_to_matrix_market(expression_file)
    puts "Generating Matrix Market coordinate (mm) file for #{self.name} expression data"
    puts 'Reading source data...'
    genes = Gene.where(study_id: self.id, study_file_id: expression_file.id)
    puts 'Assembling counts...'
    score_count = genes.size
    all_cells = self.all_cells_array
    cell_count = all_cells.size
    significant_values = score_count + cell_count + 1 # extra value is for GENE header
    score_file = File.new(self.data_store_path.to_s + "/#{expression_file.name}.tmp", 'w+')
    counter = 0
    puts 'Writing gene-level scores...'
    genes.each_with_index do |gene, gene_index|
      gene_name = gene.name
      score_file.write "#{gene_index + 2}\t1\t#{gene_name}\n"
      gene.scores.each do |cell, score|
        cell_index = all_cells.index(cell)
        score_file.write "#{gene_index + 2}\t#{cell_index + 2}\t#{score}\n"
        significant_values += 1
      end
      counter += 1
      if counter % 1000 == 0
        puts "#{counter} genes written out of #{score_count}"
      end
    end
    puts 'Finished writing scores, updating significant score count...'
    score_file.close
    output_file = File.new(self.data_store_path.to_s + "/#{expression_file.name}.mm", 'w+')
    reopened_file = File.open(self.data_store_path.to_s + "/#{expression_file.name}.tmp", 'r')
    puts 'Creating final output file and writing headers...'
    output_file.write "%%MatrixMarket matrix coordinate double symmetric\n"
    output_file.write "#{score_count + 1}\t#{cell_count + 1}\t#{significant_values}\n"
    puts 'Headers successfully written!'
    puts 'Writing cell list...'
    output_file.write "1\t1\tGENE\n"
    all_cells.each_with_index do |cell, index|
      output_file.write "1\t#{index + 2}\t#{cell}\n"
    end
    puts 'Cell list successfully written!'
    puts 'Concatenating files...'
    while !reopened_file.eof?
      output_file.write reopened_file.readline
    end
    puts 'Finished!'
    puts "Output file: #{File.absolute_path(output_file)}"
    reopened_file.close
    File.delete(reopened_file.path)
    output_file.close
  end

  # regenerate an expression matrix from database records
  def regenerate_expression_matrix(expression_study_file)
    puts "regenerating #{expression_study_file.upload_file_name} expression matrix"

    # load cell arrays to create headers
    expression_file_cells = DataArray.where(study_id: self.id, linear_data_type: 'Study', linear_data_id: self.id,
                                            array_type: 'cells', study_file_id: expression_study_file.id).order(:array_index => 'asc')
    all_cells = expression_file_cells.map(&:values).flatten

    # create new file and write headers
    if expression_study_file.upload_content_type == 'application/gzip'
      @new_expression_file = Zlib::GzipWriter.open(File.join(self.data_store_path, expression_study_file.upload_file_name))
    else
      @new_expression_file = File.new(File.join(self.data_store_path, expression_study_file.upload_file_name), 'w')
    end
    headers = ['GENE', all_cells].flatten.join("\t")
    @new_expression_file.write headers + "\n"

    # load expression scores for requested file and write
    puts "loading expression data from #{self.name}"
    genes = Gene.where(study_id: self.id, study_file_id: expression_study_file.id)
    genes.each do |gene|
      puts "writing #{gene.name} expression values"
      @new_expression_file.write "#{gene.name}\t"
      vals = []
      scores = gene.scores
      all_cells.each do |cell|
        vals << scores[cell].to_f
      end
      @new_expression_file.write vals.join("\t") + "\n"
    end
    puts "all scores complete"

    # return filepath
    filepath = @new_expression_file.path
    @new_expression_file.close
    filepath
  end

  # perform a sanity check to look for any missing files in remote storage
  def self.storage_sanity_check
    puts 'Performing global storage sanity check for all studies'
    start_time = Time.now
    @missing_files = []
    self.where(queued_for_deletion: false).each do |study|
      puts "Performing check for '#{study.name}'"
      puts "Beginning with study_files"
      # begin with study_files
      files = study.study_files.where(queued_for_deletion: false, human_data: false, :parse_status.ne => 'parsing', status: 'uploaded')
      study_remotes = []
      # get all remotes at once, rather than individually to save time & memory
      begin
        remotes = Study.firecloud_client.get_workspace_files(study.firecloud_project, study.firecloud_workspace)
        study_remotes += remotes
        while remotes.next?
          remotes = remotes.next
          study_remotes += remotes
        end
        files.each do |file|
          file_location = file.bucket_location
          puts "Checking file: #{file_location}"
          # if file has no generation tag, then we know the upload failed
          if file.generation.blank?
            puts "#{file_location} was never uploaded to #{study.bucket_id} (no generation tag)"
            @missing_files << {filename: file_location, study: study.name, owner: study.user.email, reason: "File was never uploaded to #{study.bucket_id} (no generation tag)"}
          else
            match = study_remotes.detect {|remote| remote.name == file_location}
            if match.nil?
              puts "#{file_location} not found in #{study.bucket_id}"
              @missing_files << {filename: file_location, study: study.name, owner: study.user.email, reason: "File missing from bucket: #{study.bucket_id}"}
            elsif match.generation.to_s != file.generation.to_s
              puts "#{file_location} generation tag mismatch - local: #{file.generation}, remote: #{match.generation}"
              @missing_files << {filename: file_location, study: study.name, owner: study.user.email, reason: "generation tag mismatch - local: #{file.generation}, remote: #{match.generation}"}
            end
          end
        end
        # next check directory_listings
        directories = study.directory_listings.are_synced
        directories.each do |directory|
          puts "Checking directory: #{directory.name}"
          directory.files.each do |file|
            file_location = file['name']
            puts "Checking directory file: #{file_location}"
            match = study_remotes.detect {|remote| remote.name == file_location}
            if match.nil?
              puts "#{file_location} not found in #{study.bucket_id}"
              @missing_files << {filename: file_location, study: study.name, owner: study.user.email, reason: "File missing from bucket: #{study.bucket_id}"}
            elsif match.generation.to_s != file[:generation].to_s
              puts "#{file_location} generation tag mismatch - local: #{file[:generation]}, remote: #{match.generation}"
              @missing_files << {filename: file_location, study: study.name, owner: study.user.email, reason: "generation tag mismatch - local: #{file[:generation]}, remote: #{match.generation}"}
            end
          end
        end
      rescue => e
        puts "#{Time.now}: error in retrieving remotes for #{study.name}: #{e.message}"
        @missing_files << {filename: 'N/A', study: study.name, owner: study.user.email, reason: "Error retrieving remotes: #{e.message}"}
      end
    end
    end_time = Time.now
    seconds_diff = (start_time - end_time).to_i.abs
    hours = seconds_diff / 3600
    seconds_diff -= hours * 3600
    minutes = seconds_diff / 60
    seconds_diff -= minutes * 60
    seconds = seconds_diff
    puts "Sanity check complete! elapsed time: #{hours} hours, #{minutes} minutes, #{seconds} seconds"
    puts "Missing files found: #{@missing_files.size}"
    if @missing_files.any?
      SingleCellMailer.sanity_check(@missing_files).deliver_now
    else
      SingleCellMailer.admin_notification('Sanity check results: All files accounted for', nil, '<p>No missing files found!</p>').deliver_now
    end
  end

  ###
  #
  # PARSERS
  #
  ###

  # helper method to sanitize arrays of data for use as keys or names (removes quotes, can transform . into _)
  def sanitize_input_array(array, replace_periods=false)
    output = []
    array.each do |entry|
      value = entry.gsub(/(\"|\')/, '')
      output << (replace_periods ? value.gsub(/\./, '_') : value)
    end
    output
  end

  # method to parse master expression scores file for study and populate collection
  # this parser assumes the data is a non-sparse square matrix
  def initialize_gene_expression_data(expression_file, user, opts={local: true})
    begin
      @count = 0
      @child_count = 0
      @message = []
      @last_line = ""
      start_time = Time.now
      @validation_error = false
      @file_location = expression_file.upload.path
      @shift_headers = true

      # before anything starts, check if file has been uploaded locally or needs to be pulled down from FireCloud first
      if !opts[:local]
        # make sure data dir exists first
        self.make_data_dir
        Study.firecloud_client.execute_gcloud_method(:download_workspace_file, self.firecloud_project, self.firecloud_workspace, expression_file.remote_location, self.data_store_path, verify: :none)
        @file_location = File.join(self.data_store_path, expression_file.remote_location)
      end

      # next, check if this is a re-parse job, in which case we need to remove all existing entries first
      if opts[:reparse]
        self.genes.where(study_file_id: expression_file.id).delete_all
        DataArray.where(study_id: self.id, study_file_id: expression_file.id).delete_all
        expression_file.invalidate_cache_by_file_type
      end

      # determine content type from file contents, not from upload_content_type
      content_type = expression_file.determine_content_type
      # validate headers
      if content_type == 'application/gzip'
        Rails.logger.info "#{Time.now}: Parsing #{expression_file.name}:#{expression_file.id} as application/gzip"
        file = Zlib::GzipReader.open(@file_location)
      else
        Rails.logger.info "#{Time.now}: Parsing #{expression_file.name}:#{expression_file.id} as text/plain"
        file = File.open(@file_location, 'rb')
      end
      # first determine if this is a MM coordinate file or not
      cells = file.readline.split(/[\t,]/).map(&:strip)
      @last_line = "#{expression_file.name}, line 1"
      if !['gene', ''].include?(cells.first.downcase) || cells.size <= 1
        # file did not have correct header information, but may be an export from R which will have one less column
        next_line_size = file.readline.split(/[\t,]/).size
        if cells.size == next_line_size - 1
          # don't shift the headers later as they are beginning with the names of cells (doesn't start with GENE or blank)
          @shift_headers = false
        else
          expression_file.update(parse_status: 'failed')
          @validation_error = true
          @validation_error_message = 'file header validation failed: first header should be GENE or blank followed by cell names'
        end
      end

      file.close
    rescue => e
      error_message = "Unexpected error: #{e.message}"
      filename = expression_file.name
      expression_file.remove_local_copy
      expression_file.destroy
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Expression file: '#{filename}' parse has failed", error_message).deliver_now
      raise StandardError, error_message
    end

    # raise validation error if needed
    if @validation_error
      filename = expression_file.name
      expression_file.remove_local_copy
      expression_file.destroy
      Rails.logger.info Time.now.to_s + ': ' + @validation_error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Expression file: '#{filename}' parse has failed", @validation_error_message).deliver_now
      raise StandardError, error_message
    end

    # begin parse
    begin
      Rails.logger.info "#{Time.now}: Beginning expression matrix parse from #{expression_file.name}:#{expression_file.id} for #{self.name}"
      expression_file.update(parse_status: 'parsing')
      # open data file and grab header row with name of all cells, deleting 'GENE' at start
      # determine proper reader
      if content_type == 'application/gzip'
        expression_data = Zlib::GzipReader.open(@file_location)
      else
        expression_data = File.open(@file_location, 'rb')
      end
      raw_cells = expression_data.readline.rstrip.split(/[\t,]/).map(&:strip)
      cells = self.sanitize_input_array(raw_cells)
      @last_line = "#{expression_file.name}, line 1"

      # shift headers if first cell is blank or GENE
      if @shift_headers
        cells.shift
      end

      # validate that new expression matrix does not have repeated cells, raise error if repeats found
      existing_cells = self.all_expression_matrix_cells
      uniques = cells - existing_cells

      unless uniques.size == cells.size
        repeats = cells - uniques
        raise StandardError, "You have re-used the following cell names that were found in another expression matrix in your study (cell names must be unique across all expression matrices): #{repeats.join(', ')}"
      end

      # store study id for later to save memory
      study_id = self._id
      @records = []
      @child_records = []
      # keep a running record of genes already parsed to catch validation errors before they happen
      # this is needed since we're creating records in batch and won't know which gene was responsible
      @genes_parsed = []
      Rails.logger.info "#{Time.now}: Expression data loaded, starting record creation for #{self.name}"
      while !expression_data.eof?
        # grab single row of scores, parse out gene name at beginning
        line = expression_data.readline.strip.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
        if line.strip.blank?
          next
        else
          raw_row = line.split(/[\t,]/).map(&:strip)
          row = self.sanitize_input_array(raw_row)
          @last_line = "#{expression_file.name}, line #{expression_data.lineno}"

          gene_name = row.shift
          # check for duplicate genes
          if @genes_parsed.include?(gene_name)
            user_error_message = "You have a duplicate gene entry (#{gene_name}) in your gene list.  Please check your file and try again."
            error_message = "Duplicate gene #{gene_name} in #{expression_file.name} (#{expression_file._id}) for study: #{self.name}"
            Rails.logger.info error_message
            raise StandardError, user_error_message
          else
            @genes_parsed << gene_name
          end

          new_gene = Gene.new(name: gene_name, searchable_name: gene_name.downcase, study_file_id: expression_file._id,
                              study_id: self.id)
          @records << new_gene.attributes

          # convert all remaining strings to floats, then store only significant values (!= 0)
          scores = row.map(&:to_f)
          significant_scores = {}
          scores.each_with_index do |score, index|
            unless score == 0.0
              significant_scores[cells[index]] = score
            end
          end
          significant_cells = significant_scores.keys
          significant_exp_values = significant_scores.values

          # chunk cells & values into pieces as necessary
          significant_cells.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
            # create array of all cells for study, send the object attributes rather than the object for bulk insertion
            cell_array = DataArray.new(name: new_gene.cell_key, cluster_name: expression_file.name, array_type: 'cells',
                                       array_index: index + 1, study_file_id: expression_file._id, values: slice,
                                       linear_data_type: 'Gene', linear_data_id: new_gene.id, study_id: self.id)
            @child_records << cell_array.attributes
          end

          significant_exp_values.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
            # create array of all cells for study, sending the object attributes rather than the object for bulk insertion
            score_array = DataArray.new(name: new_gene.score_key, cluster_name: expression_file.name, array_type: 'expression',
                                        array_index: index + 1, study_file_id: expression_file._id, values: slice,
                                        linear_data_type: 'Gene', linear_data_id: new_gene.id, study_id: self.id)
            @child_records << score_array.attributes
          end

          # batch insert records in groups of 1000
          if @records.size % 1000 == 0
            Gene.create(@records)
            @count += @records.size
            Rails.logger.info "#{Time.now}: Processed #{@count} genes from #{expression_file.name}:#{expression_file.id} for #{self.name}"
            @records = []
          end

          if @child_records.size >= 1000
            DataArray.create!(@child_records)
            @child_count += @child_records.size
            Rails.logger.info "#{Time.now}: Processed #{@child_count} child data arrays from #{expression_file.name}:#{expression_file.id} for #{self.name}"
            @child_records = []
          end
        end
      end
      # process last few records
      Gene.create(@records)
      @count += @records.size
      Rails.logger.info "#{Time.now}: Processed #{@count} genes from #{expression_file.name}:#{expression_file.id} for #{self.name}"
      @records = nil

      DataArray.create(@child_records)
      @child_count += @child_records.size
      Rails.logger.info "#{Time.now}: Processed #{@child_count} child data arrays from #{expression_file.name}:#{expression_file.id} for #{self.name}"
      @child_records = nil

      # add processed cells to known cells
      cells.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
        Rails.logger.info "#{Time.now}: Create known cells array ##{index + 1} for #{expression_file.name}:#{expression_file.id} in #{self.name}"
        known_cells = self.data_arrays.build(name: "#{expression_file.name} Cells", cluster_name: expression_file.name,
                                             array_type: 'cells', array_index: index + 1, values: slice,
                                             study_file_id: expression_file.id, study_id: self.id)
        known_cells.save
      end

      self.set_gene_count

      # set the default expression label if the user supplied one
      if !self.has_expression_label? && !expression_file.y_axis_label.blank?
        Rails.logger.info "#{Time.now}: Setting default expression label in #{self.name} to '#{expression_file.y_axis_label}'"
        opts = self.default_options
        self.update!(default_options: opts.merge(expression_label: expression_file.y_axis_label))
      end

      # clean up, print stats
      expression_data.close
      expression_file.update(parse_status: 'parsed')

      end_time = Time.now
      time = (end_time - start_time).divmod 60.0
      @message << "#{Time.now}: #{expression_file.name} parse completed!"
      @message << "Gene-level entries created: #{@count}"
      @message << "Total Time: #{time.first} minutes, #{time.last} seconds"
      Rails.logger.info @message.join("\n")
      # set initialized to true if possible
      if self.cluster_groups.any? && self.cell_metadata.any? && !self.initialized?
        Rails.logger.info "#{Time.now}: initializing #{self.name}"
        self.update!(initialized: true)
        Rails.logger.info "#{Time.now}: #{self.name} successfully initialized"
      end

      begin
        SingleCellMailer.notify_user_parse_complete(user.email, "Expression file: '#{expression_file.name}' has completed parsing", @message).deliver_now
      rescue => e
        Rails.logger.error "#{Time.now}: Unable to deliver email: #{e.message}"
      end

      Rails.logger.info "#{Time.now}: determining upload status of expression file: #{expression_file.upload_file_name}:#{expression_file.id}"
      # now that parsing is complete, we can move file into storage bucket and delete local (unless we downloaded from FireCloud to begin with)
      # rather than relying on opts[:local], actually check if the file is already in the GCS bucket
      destination = expression_file.remote_location.blank? ? expression_file.upload_file_name : expression_file.remote_location
      remote = Study.firecloud_client.get_workspace_file(self.firecloud_project, self.firecloud_workspace, destination)
      if remote.nil?
        begin
          Rails.logger.info "#{Time.now}: preparing to upload expression file: #{expression_file.upload_file_name}:#{expression_file.id} to FireCloud"
          self.send_to_firecloud(expression_file)
        rescue => e
          Rails.logger.info "#{Time.now}: Expression file: #{expression_file.upload_file_name}:#{expression_file.id} failed to upload to FireCloud due to #{e.message}"
          SingleCellMailer.notify_admin_upload_fail(expression_file, e.message).deliver_now
        end
      else
        # we have the file in FireCloud already, so just delete it
        begin
          Rails.logger.info "#{Time.now}: found remote version of #{expression_file.upload_file_name}: #{remote.name} (#{remote.generation})"
          run_at = 15.seconds.from_now
          Delayed::Job.enqueue(UploadCleanupJob.new(self, expression_file), run_at: run_at)
          Rails.logger.info "#{Time.now}: cleanup job for #{expression_file.upload_file_name}:#{expression_file.id} scheduled for #{run_at}"
        rescue => e
          # we don't really care if the delete fails, we can always manually remove it later as the file is in FireCloud already
          Rails.logger.error "#{Time.now}: Could not delete #{expression_file.name}:#{expression_file.id} in study #{self.name}; aborting"
          SingleCellMailer.admin_notification('Local file deletion failed', nil, "The file at #{@file_location} failed to clean up after parsing, please remove.").deliver_now
        end
      end
    rescue => e
      # error has occurred, so clean up records and remove file
      Gene.where(study_id: self.id, study_file_id: expression_file.id).delete_all
      DataArray.where(study_id: self.id, study_file_id: expression_file.id).delete_all
      filename = expression_file.name
      expression_file.remove_local_copy
      expression_file.destroy
      error_message = "#{@last_line}: #{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Gene Expression matrix: '#{filename}' parse has failed", error_message).deliver_now
    end
    true
  end

  # parse single cluster coordinate & metadata file (name, x, y, z, metadata_cols* format)
  # uses cluster_group model instead of single clusters; group membership now defined by metadata
  # stores point data in cluster_group_data_arrays instead of single_cells and cluster_points
  def initialize_cluster_group_and_data_arrays(ordinations_file, user, opts={local: true})
    begin
      @file_location = ordinations_file.upload.path
      # before anything starts, check if file has been uploaded locally or needs to be pulled down from FireCloud first
      if !opts[:local]
        # make sure data dir exists first
        self.make_data_dir
        Study.firecloud_client.execute_gcloud_method(:download_workspace_file, self.firecloud_project, self.firecloud_workspace, ordinations_file.remote_location, self.data_store_path, verify: :none)
        @file_location = File.join(self.data_store_path, ordinations_file.remote_location)
      end

      # next, check if this is a re-parse job, in which case we need to remove all existing entries first
      if opts[:reparse]
        self.cluster_groups.where(study_file_id: ordinations_file.id).delete_all
        self.data_arrays.where(study_file_id: ordinations_file.id).delete_all
        ordinations_file.invalidate_cache_by_file_type
      end

      # determine content type from file contents, not from upload_content_type
      content_type = ordinations_file.determine_content_type
      # validate headers
      if content_type == 'application/gzip'
        Rails.logger.info "#{Time.now}: Parsing #{ordinations_file.name}:#{ordinations_file.id} as application/gzip"
        d_file = Zlib::GzipReader.open(@file_location)
      else
        Rails.logger.info "#{Time.now}: Parsing #{ordinations_file.name}:#{ordinations_file.id} as text/plain"
        d_file = File.open(@file_location, 'rb')
      end

      # validate headers of cluster file
      @validation_error = false
      start_time = Time.now
      headers = d_file.readline.split(/[\t,]/).map(&:strip)
      second_header = d_file.readline.split(/[\t,]/).map(&:strip)
      @last_line = "#{ordinations_file.name}, line 1"
      # must have at least NAME, X and Y fields
      unless (headers & %w(NAME X Y)).size == 3 && second_header.include?('TYPE')
        ordinations_file.update(parse_status: 'failed')
        @validation_error = true
      end
      d_file.close
    rescue => e
      ordinations_file.update(parse_status: 'failed')
      error_message = "#{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      filename = ordinations_file.upload_file_name
      ordinations_file.remove_local_copy
      ordinations_file.destroy
      SingleCellMailer.notify_user_parse_fail(user.email, "Cluster file: '#{filename}' parse has failed", error_message).deliver_now
      raise StandardError, error_message
    end

    # raise validation error if needed
    if @validation_error
      error_message = "file header validation failed: should be at least NAME, X, Y with second line starting with TYPE"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      filename = ordinations_file.upload_file_name
      ordinations_file.remove_local_copy
      ordinations_file.destroy
      SingleCellMailer.notify_user_parse_fail(user.email, "Cluster file: '#{filename}' parse has failed", error_message).deliver_now
      raise StandardError, error_message
    end

    @message = []
    @cluster_metadata = []
    @point_count = 0
    # begin parse
    begin
      cluster_name = ordinations_file.name
      Rails.logger.info "#{Time.now}: Beginning cluster initialization using #{ordinations_file.upload_file_name}:#{ordinations_file.id} for cluster: #{cluster_name} in #{self.name}"
      ordinations_file.update(parse_status: 'parsing')

      if content_type == 'application/gzip'
        cluster_data = Zlib::GzipReader.open(@file_location)
      else
        cluster_data = File.open(@file_location, 'rb')
      end

      raw_header_data = cluster_data.readline.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').split(/[\t,]/).map(&:strip)
      raw_type_data = cluster_data.readline.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').split(/[\t,]/).map(&:strip)
      header_data = self.sanitize_input_array(raw_header_data)
      type_data = self.sanitize_input_array(raw_type_data)

      # determine if 3d coordinates have been provided
      is_3d = header_data.include?('Z')
      cluster_type = is_3d ? '3d' : '2d'

      # grad header indices, z index will be nil if no 3d data
      name_index = header_data.index('NAME')
      x_index = header_data.index('X')
      y_index = header_data.index('Y')
      z_index = header_data.index('Z')

      # determine what extra metadata has been provided
      metadata_headers = header_data - %w(NAME X Y Z)
      metadata_headers.each do |metadata|
        idx = header_data.index(metadata)
        # store temporary object with metadata name, index location and data type (group or numeric)
        point_metadata = {
            name: metadata,
            index: idx,
            type: type_data[idx].downcase # downcase type to avoid case matching issues later
        }
        @cluster_metadata << point_metadata
      end

      # create cluster object for use later
      Rails.logger.info "#{Time.now}: Creating cluster group object: #{cluster_name} in study: #{self.name}"
      @domain_ranges = {
          x: [ordinations_file.x_axis_min, ordinations_file.x_axis_max],
          y: [ordinations_file.y_axis_min, ordinations_file.y_axis_max]
      }
      required_values = 4
      if is_3d
        @domain_ranges[:z] = [ordinations_file.z_axis_min, ordinations_file.z_axis_max]
        required_values = 6
      end

      # check if ranges are valid
      unless @domain_ranges.values.flatten.compact.size == required_values
        @domain_ranges = nil
      end

      @cluster_group = self.cluster_groups.build(name: cluster_name,
                                                 study_file_id: ordinations_file._id,
                                                 cluster_type: cluster_type,
                                                 domain_ranges: @domain_ranges
      )

      # add cell-level annotation definitions and save (will be used to populate dropdown menu)
      # this object will not be saved until after parse is done as we need to collect all possible values
      # for group annotations (not needed for numeric)
      cell_annotations = []
      @cluster_metadata.each do |metadata|
        cell_annotations << {
            name: metadata[:name],
            type: metadata[:type],
            header_index: metadata[:index],
            values: []
        }
      end
      @cluster_group.save

      # container to store temporary data arrays until ready to save
      @data_arrays = []
      # create required data_arrays (name, x, y)
      @data_arrays[name_index] = @cluster_group.data_arrays.build(name: 'text', cluster_name: cluster_name, array_type: 'cells',
                                                                  array_index: 1, study_file_id: ordinations_file._id,
                                                                  study_id: self.id, values: [])
      @data_arrays[x_index] = @cluster_group.data_arrays.build(name: 'x', cluster_name: cluster_name, array_type: 'coordinates',
                                                               array_index: 1, study_file_id: ordinations_file._id,
                                                               study_id: self.id, values: [])
      @data_arrays[y_index] = @cluster_group.data_arrays.build(name: 'y', cluster_name: cluster_name, array_type: 'coordinates',
                                                               array_index: 1, study_file_id: ordinations_file._id,
                                                               study_id: self.id, values: [])

      # add optional data arrays (z, metadata)
      if is_3d
        @data_arrays[z_index] = @cluster_group.data_arrays.build(name: 'z', cluster_name: cluster_name, array_type: 'coordinates',
                                                               array_index: 1, study_file_id: ordinations_file._id,
                                                               study_id: self.id, values: [])
      end
      @cluster_metadata.each do |metadata|
        @data_arrays[metadata[:index]] = @cluster_group.data_arrays.build(name: metadata[:name], cluster_name: cluster_name,
                                                                          array_type: 'annotations', array_index: 1,
                                                                          study_file_id: ordinations_file._id,
                                                                          study_id: self.id, values: [])
      end

      Rails.logger.info "#{Time.now}: Headers/Metadata loaded for cluster initialization using #{ordinations_file.upload_file_name} for cluster: #{cluster_name} in #{self.name}"
      # begin reading data
      while !cluster_data.eof?
        line = cluster_data.readline.strip.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
        if line.strip.blank?
          next
        else
          @point_count += 1
          @last_line = "#{ordinations_file.name}, line #{cluster_data.lineno}"
          raw_vals = line.split(/[\t,]/).map(&:strip)
          vals = self.sanitize_input_array(raw_vals)
          # assign value to corresponding data_array by column index
          vals.each_with_index do |val, index|
            if @data_arrays[index].values.size >= DataArray::MAX_ENTRIES
              # array already has max number of values, so save it and replace it with a new data array
              # of same name & type with array_index incremented by 1
              current_data_array_index = @data_arrays[index].array_index
              data_array = @data_arrays[index]
              Rails.logger.info "#{Time.now}: Saving data array: #{data_array.name}-#{data_array.array_type}-#{data_array.array_index} using #{ordinations_file.upload_file_name}:#{ordinations_file.id} for cluster: #{cluster_name} in #{self.name}"
              data_array.save
              new_data_array = @cluster_group.data_arrays.build(name: data_array.name, cluster_name: data_array.cluster_name,
                                                                array_type: data_array.array_type, array_index: current_data_array_index + 1,
                                                                study_file_id: ordinations_file._id, study_id: self.id, values: [])
              @data_arrays[index] = new_data_array
            end
            # determine whether or not value needs to be cast as a float or not
            if type_data[index] == 'numeric'
              @data_arrays[index].values << val.to_f
            else
              @data_arrays[index].values << val
              # check if this is a group annotation, and if so store its value in the cluster_group.cell_annotations
              # hash if the value is not already present
              if type_data[index] == 'group'
                existing_vals = cell_annotations.find {|annot| annot[:name] == header_data[index]}
                metadata_idx = cell_annotations.index(existing_vals)
                unless existing_vals[:values].include?(val)
                  cell_annotations[metadata_idx][:values] << val
                  Rails.logger.info "#{Time.now}: Adding #{val} to #{@cluster_group.name} list of group values for #{header_data[index]}"
                end
              end
            end
          end
        end

      end
      # clean up
      @data_arrays.each do |data_array|
        Rails.logger.info "#{Time.now}: Saving data array: #{data_array.name}-#{data_array.array_type}-#{data_array.array_index} using #{ordinations_file.upload_file_name}:#{ordinations_file.id} for cluster: #{cluster_name} in #{self.name}"
        data_array.save
      end
      cluster_data.close

      # save cell_annotations to cluster_group object
      @cluster_group.update_attributes(cell_annotations: cell_annotations)
      # reload cluster_group to use in messaging
      @cluster_group = ClusterGroup.find_by(study_id: self.id, study_file_id: ordinations_file.id, name: ordinations_file.name)
      ordinations_file.update(parse_status: 'parsed')
      end_time = Time.now
      time = (end_time - start_time).divmod 60.0
      # assemble email message parts
      @message << "#{ordinations_file.upload_file_name} parse completed!"
      @message << "Cluster created: #{@cluster_group.name}, type: #{@cluster_group.cluster_type}"
      if @cluster_group.cell_annotations.any?
        @message << "Annotations:"
        @cluster_group.cell_annotations.each do |annot|
          @message << "#{annot['name']}: #{annot['type']}#{annot['type'] == 'group' ? ' (' + annot['values'].join(',') + ')' : nil}"
        end
      end
      @message << "Total points in cluster: #{@point_count}"
      @message << "Total Time: #{time.first} minutes, #{time.last} seconds"
      # set initialized to true if possible
      if self.genes.any? && self.cell_metadata.any? && !self.initialized?
        Rails.logger.info "#{Time.now}: initializing #{self.name}"
        self.update!(initialized: true)
        Rails.logger.info "#{Time.now}: #{self.name} successfully initialized"
      end

      # check to see if a default cluster & annotation have been set yet
      # must load reference to self into a local variable as we cannot call self.save to update attributes
      study_obj = Study.find(self.id)
      if study_obj.default_options[:cluster].nil?
        study_obj.default_options[:cluster] = @cluster_group.name
      end

      if study_obj.default_options[:annotation].nil?
        if @cluster_group.cell_annotations.any?
          cell_annot = @cluster_group.cell_annotations.first
          study_obj.default_options[:annotation] = "#{cell_annot[:name]}--#{cell_annot[:type]}--cluster"
          if cell_annot[:type] == 'numeric'
            # set a default color profile if this is a numeric annotation
            study_obj.default_options[:color_profile] = 'Reds'
          end
        elsif study_obj.cell_metadata.any?
          metadatum = study_obj.cell_metadata.first
          study_obj.default_options[:annotation] = "#{metadatum.name}--#{metadatum.annotation_type}--study"
          if metadatum.annotation_type == 'numeric'
            # set a default color profile if this is a numeric annotation
            study_obj.default_options[:color_profile] = 'Reds'
          end
        else
          # no possible annotations to set, but enter annotation key into default_options
          study_obj.default_options[:annotation] = nil
        end
      end

      # update study.default_options
      study_obj.save

      # create subsampled data_arrays for visualization
      cell_metadata = CellMetadatum.where(study_id: self.id)
      # determine how many levels to subsample based on size of cluster_group
      required_subsamples = ClusterGroup::SUBSAMPLE_THRESHOLDS.select {|sample| sample < @cluster_group.points}
      required_subsamples.each do |sample_size|
        # create cluster-based annotation subsamples first
        if @cluster_group.cell_annotations.any?
          @cluster_group.cell_annotations.each do |cell_annot|
            @cluster_group.delay.generate_subsample_arrays(sample_size, cell_annot[:name], cell_annot[:type], 'cluster')
          end
        end
        # create study-based annotation subsamples
        cell_metadata.each do |metadata|
          @cluster_group.delay.generate_subsample_arrays(sample_size, metadata.name, metadata.annotation_type, 'study')
        end
      end

      begin
        SingleCellMailer.notify_user_parse_complete(user.email, "Cluster file: '#{ordinations_file.upload_file_name}' has completed parsing", @message).deliver_now
      rescue => e
        Rails.logger.error "#{Time.now}: Unable to deliver email: #{e.message}"
      end

      Rails.logger.info "#{Time.now}: determining upload status of ordinations file: #{ordinations_file.upload_file_name}:#{ordinations_file.id}"

      # now that parsing is complete, we can move file into storage bucket and delete local (unless we downloaded from FireCloud to begin with)
      destination = ordinations_file.remote_location.blank? ? ordinations_file.upload_file_name : ordinations_file.remote_location
      remote = Study.firecloud_client.get_workspace_file(self.firecloud_project, self.firecloud_workspace, destination)
      if remote.nil?
        begin
          Rails.logger.info "#{Time.now}: preparing to upload ordinations file: #{ordinations_file.upload_file_name}:#{ordinations_file.id} to FireCloud"
          self.send_to_firecloud(ordinations_file)
        rescue => e
          Rails.logger.info "#{Time.now}: Cluster file: #{ordinations_file.upload_file_name}:#{ordinations_file.id} failed to upload to FireCloud due to #{e.message}"
          SingleCellMailer.notify_admin_upload_fail(ordinations_file, e.message).deliver_now
        end
      else
        # we have the file in FireCloud already, so just delete it
        begin
          Rails.logger.info "#{Time.now}: found remote version of #{ordinations_file.upload_file_name}: #{remote.name} (#{remote.generation})"
          run_at = 15.seconds.from_now
          Delayed::Job.enqueue(UploadCleanupJob.new(self, ordinations_file), run_at: run_at)
          Rails.logger.info "#{Time.now}: cleanup job for #{ordinations_file.upload_file_name}:#{ordinations_file.id} scheduled for #{run_at}"
        rescue => e
          # we don't really care if the delete fails, we can always manually remove it later as the file is in FireCloud already
          Rails.logger.error "#{Time.now}: Could not delete #{ordinations_file.name}:#{ordinations_file.id} in study #{self.name}; aborting"
          SingleCellMailer.admin_notification('Local file deletion failed', nil, "The file at #{@file_location} failed to clean up after parsing, please remove.").deliver_now
        end
      end
    rescue => e
      # error has occurred, so clean up records and remove file
      ClusterGroup.where(study_file_id: ordinations_file.id).delete_all
      DataArray.where(study_file_id: ordinations_file.id).delete_all
      filename = ordinations_file.upload_file_name
      ordinations_file.remove_local_copy
      ordinations_file.destroy
      error_message = "#{@last_line} ERROR: #{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Cluster file: '#{filename}' parse has failed", error_message).deliver_now
    end
    true
  end

  # parse a coordinate labels file and create necessary data_array objects
  # coordinate labels are specific to a cluster_group
  def initialize_coordinate_label_data_arrays(coordinate_file, use, opts={local: true})
    begin
      @file_location = coordinate_file.upload.path
      # before anything starts, check if file has been uploaded locally or needs to be pulled down from FireCloud first
      if !opts[:local]
        # make sure data dir exists first
        self.make_data_dir
        Study.firecloud_client.execute_gcloud_method(:download_workspace_file, self.firecloud_project, self.firecloud_workspace, coordinate_file.remote_location, self.data_store_path, verify: :none)
        @file_location = File.join(self.data_store_path, coordinate_file.remote_location)
      end

      # next, check if this is a re-parse job, in which case we need to remove all existing entries first
      if opts[:reparse]
        self.data_arrays.where(study_file_id: coordinate_file.id).delete_all
        coordinate_file.invalidate_cache_by_file_type
      end

      # determine content type from file contents, not from upload_content_type
      content_type = coordinate_file.determine_content_type
      # validate headers
      if content_type == 'application/gzip'
        Rails.logger.info "#{Time.now}: Parsing #{coordinate_file.name}:#{coordinate_file.id} as application/gzip"
        c_file = Zlib::GzipReader.open(@file_location)
      else
        Rails.logger.info "#{Time.now}: Parsing #{coordinate_file.name}:#{coordinate_file.id} as text/plain"
        c_file = File.open(@file_location, 'rb')
      end

      # validate headers of coordinate file
      @validation_error = false
      start_time = Time.now
      headers = c_file.readline.split(/[\t,]/).map(&:strip)
      @last_line = "#{coordinate_file.name}, line 1"
      # must have at least NAME, X and Y fields
      unless (headers & %w(X Y LABELS)).size == 3
        coordinate_file.update(parse_status: 'failed')
        @validation_error = true
      end
      c_file.close
    rescue => e
      coordinate_file.update(parse_status: 'failed')
      error_message = "#{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      filename = coordinate_file.upload_file_name
      coordinate_file.remove_local_copy
      coordinate_file.destroy
      SingleCellMailer.notify_user_parse_fail(user.email, "Coordinate Labels file: '#{filename}' parse has failed", error_message).deliver_now
      raise StandardError, error_message
    end

    # raise validation error if needed
    if @validation_error
      error_message = "file header validation failed: should be at least NAME, X, Y, LABELS"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      filename = coordinate_file.upload_file_name
      if File.exist?(@file_location)
        File.delete(@file_location)
        if Dir.exist?(File.join(self.data_store_path, coordinate_file.id))
          Dir.chdir(self.data_store_path)
          Dir.rmdir(coordinate_file.id)
        end
      end
      coordinate_file.destroy
      SingleCellMailer.notify_user_parse_fail(user.email, "Coordinate Labels file: '#{filename}' parse has failed", error_message).deliver_now
      raise StandardError, error_message
    end

    # set up containers
    @labels_created = []
    @message = []
    begin
      # load target cluster
      cluster = coordinate_file.coordinate_labels_target

      Rails.logger.info "#{Time.now}: Beginning coordinate label initialization using #{coordinate_file.upload_file_name}:#{coordinate_file.id} for cluster: #{cluster.name} in #{self.name}"
      coordinate_file.update(parse_status: 'parsing')

      if content_type == 'application/gzip'
        coordinate_data = Zlib::GzipReader.open(@file_location)
      else
        coordinate_data = File.open(@file_location, 'rb')
      end

      raw_header_data = coordinate_data.readline.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').split(/[\t,]/).map(&:strip)
      header_data = self.sanitize_input_array(raw_header_data)

      # determine if 3d coordinates have been provided
      is_3d = header_data.include?('Z')

      # grad header indices, z index will be nil if no 3d data
      x_index = header_data.index('X')
      y_index = header_data.index('Y')
      z_index = header_data.index('Z')
      label_index = header_data.index('LABELS')

      # container to store temporary data arrays until ready to save
      @data_arrays = []
      # create required data_arrays (name, x, y)
      @data_arrays[x_index] = cluster.data_arrays.build(name: 'x', cluster_name: cluster.name, array_type: 'labels',
                                                        array_index: 1, study_file_id: coordinate_file._id,
                                                        study_id: self.id, values: [])
      @data_arrays[y_index] = cluster.data_arrays.build(name: 'y', cluster_name: cluster.name, array_type: 'labels',
                                                        array_index: 1, study_file_id: coordinate_file._id,
                                                        study_id: self.id, values: [])
      @data_arrays[label_index] = cluster.data_arrays.build(name: 'text', cluster_name: cluster.name, array_type: 'labels',
                                                            array_index: 1, study_file_id: coordinate_file._id,
                                                            study_id: self.id, values: [])

      # add optional data arrays (z, metadata)
      if is_3d
        @data_arrays[z_index] = cluster.data_arrays.build(name: 'z', cluster_name: cluster.name, array_type: 'labels',
                                                       array_index: 1, study_file_id: coordinate_file._id, study_id: self.id,
                                                       values: [])
      end

      Rails.logger.info "#{Time.now}: Headers/Metadata loaded for coordinate file initialization using #{coordinate_file.upload_file_name}:#{coordinate_file.id} for cluster: #{cluster.name} in #{self.name}"
      # begin reading data
      while !coordinate_data.eof?
        line = coordinate_data.readline.strip.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
        if line.strip.blank?
          next
        else
          @last_line = "#{coordinate_file.name}, line #{coordinate_data.lineno}"
          raw_vals = line.split(/[\t,]/).map(&:strip)
          vals = self.sanitize_input_array(raw_vals)
          # assign value to corresponding data_array by column index
          vals.each_with_index do |val, index|
            if @data_arrays[index].values.size >= DataArray::MAX_ENTRIES
              # array already has max number of values, so save it and replace it with a new data array
              # of same name & type with array_index incremented by 1
              current_data_array_index = @data_arrays[index].array_index
              data_array = @data_arrays[index]
              Rails.logger.info "#{Time.now}: Saving full-lenght data array: #{data_array.name}-#{data_array.array_type}-#{data_array.array_index} using #{coordinate_file.upload_file_name}:#{coordinate_file.id} for cluster: #{cluster.name} in #{self.name}; initializing new array index #{current_data_array_index + 1}"
              data_array.save
              new_data_array = cluster.data_arrays.build(name: data_array.name, cluster_name: data_array.cluster_name,
                                                         array_type: data_array.array_type, array_index: current_data_array_index + 1,
                                                         study_file_id: coordinate_file._id, study_id: self.id, values: [])
              @data_arrays[index] = new_data_array
            end
            # determine whether or not value needs to be cast as a float or not (only values at label index stay as a string)
            if index == label_index
              @data_arrays[index].values << val
            else
              @data_arrays[index].values << val.to_f
            end
          end
        end

      end

      # clean up
      @data_arrays.each do |data_array|
        Rails.logger.info "#{Time.now}: Saving data array: #{data_array.name}-#{data_array.array_type}-#{data_array.array_index} using #{coordinate_file.upload_file_name}:#{coordinate_file.id} for cluster: #{cluster.name} in #{self.name}"
        data_array.save
      end
      coordinate_data.close
      coordinate_file.update(parse_status: 'parsed')
      end_time = Time.now
      time = (end_time - start_time).divmod 60.0
      # assemble email message parts
      @message << "#{coordinate_file.upload_file_name} parse completed!"
      @message << "Labels created (#{@labels_created.size}: #{@labels_created.join(', ')}"
      @message << "Total Time: #{time.first} minutes, #{time.last} seconds"

      # expire cluster caches to load label data on render
      cluster_study_file = cluster.study_file
      cluster_study_file.invalidate_cache_by_file_type

      begin
        SingleCellMailer.notify_user_parse_complete(user.email, "Coordinate Label file: '#{coordinate_file.upload_file_name}' has completed parsing", @message).deliver_now
      rescue => e
        Rails.logger.error "#{Time.now}: Unable to deliver email: #{e.message}"
      end

      Rails.logger.info "#{Time.now}: determining upload status of coordinate labels file: #{coordinate_file.upload_file_name}:#{coordinate_file.id}"

      # now that parsing is complete, we can move file into storage bucket and delete local (unless we downloaded from FireCloud to begin with)
      destination = coordinate_file.remote_location.blank? ? coordinate_file.upload_file_name : coordinate_file.remote_location
      remote = Study.firecloud_client.get_workspace_file(self.firecloud_project, self.firecloud_workspace, destination)
      if remote.nil?
        begin
          Rails.logger.info "#{Time.now}: preparing to upload ordinations file: #{coordinate_file.upload_file_name}:#{coordinate_file.id} to FireCloud"
          self.send_to_firecloud(coordinate_file)
        rescue => e
          Rails.logger.info "#{Time.now}: Cluster file: #{coordinate_file.upload_file_name}:#{coordinate_file.id} failed to upload to FireCloud due to #{e.message}"
          SingleCellMailer.notify_admin_upload_fail(coordinate_file, e.message).deliver_now
        end
      else
        # we have the file in FireCloud already, so just delete it
        begin
          Rails.logger.info "#{Time.now}: found remote version of #{coordinate_file.upload_file_name}: #{remote.name} (#{remote.generation})"
          run_at = 15.seconds.from_now
          Delayed::Job.enqueue(UploadCleanupJob.new(self, coordinate_file), run_at: run_at)
          Rails.logger.info "#{Time.now}: cleanup job for #{coordinate_file.upload_file_name}:#{coordinate_file.id} scheduled for #{run_at}"
        rescue => e
          # we don't really care if the delete fails, we can always manually remove it later as the file is in FireCloud already
          Rails.logger.error "#{Time.now}: Could not delete #{coordinate_file.name}:#{coordinate_file.id} in study #{self.name}; aborting"
          SingleCellMailer.admin_notification('Local file deletion failed', nil, "The file at #{@file_location} failed to clean up after parsing, please remove.").deliver_now
        end
      end
    rescue => e
      # error has occurred, so clean up records and remove file
      DataArray.where(study_file_id: coordinate_file.id).delete_all
      filename = coordinate_file.upload_file_name
      coordinate_file.remove_local_copy
      coordinate_file.destroy
      error_message = "#{@last_line} ERROR: #{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Coordinate Labels file: '#{filename}' parse has failed", error_message).deliver_now

    end
  end

  # parse a study metadata file and create necessary cell_metadatum objects
  def initialize_cell_metadata(metadata_file, user, opts={local: true})
    begin
      @file_location = metadata_file.upload.path
      # before anything starts, check if file has been uploaded locally or needs to be pulled down from FireCloud first
      if !opts[:local]
        # make sure data dir exists first
        self.make_data_dir
        Study.firecloud_client.execute_gcloud_method(:download_workspace_file, self.firecloud_project, self.firecloud_workspace, metadata_file.remote_location, self.data_store_path, verify: :none)
        @file_location = File.join(self.data_store_path, metadata_file.remote_location)
      end

      # next, check if this is a re-parse job, in which case we need to remove all existing entries first
      if opts[:reparse]
        self.cell_metadata.delete_all
        metadata_file.invalidate_cache_by_file_type
      end

      # determine content type from file contents, not from upload_content_type
      content_type = metadata_file.determine_content_type
      # validate headers
      if content_type == 'application/gzip'
        Rails.logger.info "#{Time.now}: Parsing #{metadata_file.name}:#{metadata_file.id} as application/gzip"
        m_file = Zlib::GzipReader.open(@file_location)
      else
        Rails.logger.info "#{Time.now}: Parsing #{metadata_file.name}:#{metadata_file.id} as text/plain"
        m_file = File.open(@file_location, 'rb')
      end

      # validate headers of metadata file
      @validation_error = false
      start_time = Time.now
      Rails.logger.info "#{Time.now}: Validating metadata file headers for #{metadata_file.name}:#{metadata_file.id} in #{self.name}"
      headers = m_file.readline.split(/[\t,]/).map(&:strip)
      @last_line = "#{metadata_file.name}, line 1"
      second_header = m_file.readline.split(/[\t,]/).map(&:strip)
      @last_line = "#{metadata_file.name}, line 2"
      # must have at least NAME and one column, plus TYPE and one value of group or numeric in second line
      unless headers.include?('NAME') && headers.size > 1 && (second_header.uniq.sort - %w(group numeric TYPE)).size == 0 && second_header.size > 1
        metadata_file.update(parse_status: 'failed')
        @validation_error = true
      end
      m_file.close
    rescue => e
      filename = metadata_file.upload_file_name
      metadata_file.remove_local_copy
      metadata_file.destroy
      error_message = "#{@last_line} ERROR: #{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Metadata file: '#{filename}' parse has failed", error_message).deliver_now
      raise StandardError, error_message
    end

    # raise validation error if needed
    if @validation_error
      error_message = "file header validation failed: should be at least NAME and one other column with second line starting with TYPE followed by either 'group' or 'numeric'"
      filename = metadata_file.upload_file_name
      metadata_file.destroy
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Metadata file: '#{filename}' parse has failed", error_message).deliver_now
      raise StandardError, error_message
    end

    @metadata_records = []
    @metadata_data_arrays = []
    @message = []
    # begin parse
    begin
      Rails.logger.info "#{Time.now}: Beginning metadata initialization using #{metadata_file.upload_file_name}:#{metadata_file.id} in #{self.name}"
      metadata_file.update(parse_status: 'parsing')
      # open files for parsing and grab header & type data
      if content_type == 'application/gzip'
        metadata_data = Zlib::GzipReader.open(@file_location)
      else
        metadata_data = File.open(@file_location, 'rb')
      end
      raw_header_data = metadata_data.readline.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').split(/[\t,]/).map(&:strip)
      raw_type_data = metadata_data.readline.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').split(/[\t,]/).map(&:strip)
      header_data = self.sanitize_input_array(raw_header_data)
      type_data = self.sanitize_input_array(raw_type_data)
      name_index = header_data.index('NAME')

      # build study_metadata objects for use later
      header_data.each_with_index do |header, index|
        # don't need an object for the cell names, only metadata values
        unless index == name_index
          m_obj = self.cell_metadata.build(name: header, annotation_type: type_data[index], study_file_id: metadata_file._id, values: [])
          @metadata_records[index] = m_obj
          @metadata_data_arrays[index] = m_obj.data_arrays.build(name: m_obj.name, cluster_name: metadata_file.name,
                                                                      array_type: 'annotations', array_index: 1,
                                                                      study_id: self.id, study_file_id: metadata_file.id,
                                                                      values: [])
        end
      end

      # array to hold all cell names
      all_cells = []

      Rails.logger.info "#{Time.now}: Study metadata objects initialized using: #{metadata_file.name}:#{metadata_file.id} for #{self.name}; beginning parse"
      # read file data
      while !metadata_data.eof?
        line = metadata_data.readline.strip.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
        if line.strip.blank?
          next
        else
          @last_line = "#{metadata_file.name}, line #{metadata_data.lineno}"
          raw_vals = line.split(/[\t,]/).map(&:strip)
          vals = self.sanitize_input_array(raw_vals)

          # assign values to correct cell_metadata object
          vals.each_with_index do |val, index|
            unless index == name_index
              if @metadata_data_arrays[index].values.size >= DataArray::MAX_ENTRIES
                # data array already has max number of values, so save it and replace it with a new data_array of same name & type
                metadata = @metadata_records[index]
                array = @metadata_data_arrays[index]
                Rails.logger.info "#{Time.now}: Saving cell metadata data array: #{array.name}-#{array.array_index} using #{metadata_file.upload_file_name}:#{metadata_file.id} in #{self.name}"
                array.save
                new_array = metadata.data_arrays.build(name: metadata.name, array_type: 'annotations', cluster_name: metadata_file.name,
                                                       array_index: array.array_index + 1, study_file_id: metadata_file._id,
                                                       study_id: self.id, values: [])
                @metadata_data_arrays[index] = new_array
              end
              # determine whether or not value needs to be cast as a float or not
              if type_data[index] == 'numeric'
                @metadata_data_arrays[index].values << val.to_f
              else
                @metadata_data_arrays[index].values << val
                # determine if a new unique value needs to be stored in values array
                if type_data[index] == 'group' && !@metadata_records[index].values.include?(val)
                  @metadata_records[index].values << val
                  Rails.logger.info "#{Time.now}: Adding #{val} to #{@metadata_records[index].name} list of group values for #{header_data[index]}"
                end
              end
            else
              # store the cell name for use later
              all_cells << val
            end
          end
        end
      end

      # create all cells arrays
      all_cells.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
        Rails.logger.info "#{Time.now}: Create all cells array ##{index + 1} for #{metadata_file.name}:#{metadata_file.id} in #{self.name}"
        array = self.data_arrays.build(name: "All Cells", cluster_name: metadata_file.name,
                                             array_type: 'cells', array_index: index + 1, values: slice,
                                             study_file_id: metadata_file.id, study_id: self.id)
        array.save
      end

      # clean up and save records
      @metadata_records.each do |metadata|
        # since first element is nil to preserve index order from file...
        unless metadata.nil?
          Rails.logger.info "#{Time.now}: Saving cell metadata: #{metadata.name}-#{metadata.annotation_type} using #{metadata_file.upload_file_name}:#{metadata_file.id} in #{self.name}"
          metadata.save
        end
      end

      @metadata_data_arrays.each do |array|
        unless array.nil?
          Rails.logger.info "Saving cell metadata data array: #{array.name}-#{array.array_index} using #{metadata_file.upload_file_name}:#{metadata_file.id} in #{self.name}"
          array.save
        end
      end
      metadata_data.close
      metadata_file.update(parse_status: 'parsed')

      # set initialized to true if possible
      if self.genes.any? && self.cluster_groups.any? && !self.initialized?
        Rails.logger.info "#{Time.now}: initializing #{self.name}"
        self.update!(initialized: true)
        Rails.logger.info "#{Time.now}: #{self.name} successfully initialized"
      end

      # assemble message
      end_time = Time.now
      time = (end_time - start_time).divmod 60.0
      # assemble email message parts
      @message << "#{Time.now}: #{metadata_file.upload_file_name} parse completed!"
      @message << "Entries created:"
      @metadata_records.each do |metadata|
        unless metadata.nil?
          @message << "#{metadata.name}: #{metadata.annotation_type}#{metadata.values.any? ? ' (' + metadata.values.join(', ') + ')' : nil}"
        end
      end
      @message << "Total Time: #{time.first} minutes, #{time.last} seconds"

      # load newly parsed data
      new_metadata = CellMetadatum.where(study_id: self.id, study_file_id: metadata_file.id)

      # check to make sure that all the necessary metadata-based subsample arrays exist for this study
      # if parsing first before clusters, will simply exit without performing any action and will be created when clusters are parsed
      self.cluster_groups.each do |cluster_group|
        new_metadata.each do |metadatum|
          # determine necessary subsamples
          required_subsamples = ClusterGroup::SUBSAMPLE_THRESHOLDS.select {|sample| sample < cluster_group.points}
          # for each subsample size, cluster & metadata combination, remove any existing entries and re-create
          # the delete call is necessary as we may be reparsing the file in which case the old entries need to be removed
          # if we are not reparsing, the delete call does nothing
          required_subsamples.each do |sample_size|
            DataArray.where(study_id: self.id, subsample_theshold: sample_size, subsample_annotation: "#{metadatum.name}--#{metadatum.annotation_type}--study").delete_all
            cluster_group.delay.generate_subsample_arrays(sample_size, metadatum.name, metadatum.annotation_type, 'study')
          end
        end
      end

      # check to see if default annotation has been set
      study_obj = Study.find(self.id)
      if study_obj.default_options[:annotation].nil?
        metadatum = new_metadata.first
        study_obj.default_options[:annotation] = "#{metadatum.name}--#{metadatum.annotation_type}--study"
        if metadatum.annotation_type == 'numeric'
          # set a default color profile if this is a numeric annotation
          study_obj.default_options[:color_profile] = 'Reds'
        end

        # update study.default_options
        study_obj.save
      end

      # send email on completion
      begin
        SingleCellMailer.notify_user_parse_complete(user.email, "Metadata file: '#{metadata_file.upload_file_name}' has completed parsing", @message).deliver_now
      rescue => e
        Rails.logger.error "#{Time.now}: Unable to deliver email: #{e.message}"
      end

      # set the cell count
      self.set_cell_count

      Rails.logger.info "#{Time.now}: determining upload status of metadata file: #{metadata_file.upload_file_name}:#{metadata_file.id}"

      # now that parsing is complete, we can move file into storage bucket and delete local (unless we downloaded from FireCloud to begin with)
      destination = metadata_file.remote_location.blank? ? metadata_file.upload_file_name : metadata_file.remote_location
      remote = Study.firecloud_client.get_workspace_file(self.firecloud_project, self.firecloud_workspace, destination)
      if remote.nil?
        begin
          Rails.logger.info "#{Time.now}: preparing to upload metadata file: #{metadata_file.upload_file_name}:#{metadata_file.id} to FireCloud"
          self.send_to_firecloud(metadata_file)
        rescue => e
          Rails.logger.info "#{Time.now}: Metadata file: #{metadata_file.upload_file_name}:#{metadata_file.id} failed to upload to FireCloud due to #{e.message}"
          SingleCellMailer.notify_admin_upload_fail(metadata_file, e.message).deliver_now
        end
      else
        # we have the file in FireCloud already, so just delete it
        begin
          Rails.logger.info "#{Time.now}: found remote version of #{metadata_file.upload_file_name}: #{remote.name} (#{remote.generation})"
          run_at = 15.seconds.from_now
          Delayed::Job.enqueue(UploadCleanupJob.new(self, metadata_file), run_at: run_at)
          Rails.logger.info "#{Time.now}: cleanup job for #{metadata_file.upload_file_name}:#{metadata_file.id} scheduled for #{run_at}"
        rescue => e
          # we don't really care if the delete fails, we can always manually remove it later as the file is in FireCloud already
          Rails.logger.error "#{Time.now}: Could not delete #{metadata_file.name} in study #{self.name}; aborting"
          SingleCellMailer.admin_notification('Local file deletion failed', nil, "The file at #{@file_location} failed to clean up after parsing, please remove.").deliver_now
        end
      end
    rescue => e
      # parse has failed, so clean up records and remove file
      CellMetadatum.where(study_id: self.id).delete_all
      DataArray.where(study_file_id: metadata_file.id).delete_all
      filename = metadata_file.upload_file_name
      metadata_file.remove_local_copy
      metadata_file.destroy
      error_message = "#{@last_line} ERROR: #{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Metadata file: '#{filename}' parse has failed", error_message).deliver_now
    end
    true
  end

  # parse precomputed marker gene files and create documents to render in Morpheus
  def initialize_precomputed_scores(marker_file, user, opts={local: true})
    begin
      @file_location = marker_file.upload.path
      # before anything starts, check if file has been uploaded locally or needs to be pulled down from FireCloud first
      if !opts[:local]
        # make sure data dir exists first
        self.make_data_dir
        Study.firecloud_client.execute_gcloud_method(:download_workspace_file, self.firecloud_project, self.firecloud_workspace, marker_file.remote_location, self.data_store_path, verify: :none)
        @file_location = File.join(self.data_store_path, marker_file.remote_location)
      end

      # next, check if this is a re-parse job, in which case we need to remove all existing entries first
      if opts[:reparse]
        self.precomputed_scores.where(study_file_id: marker_file.id).delete_all
        marker_file.invalidate_cache_by_file_type
      end

      @count = 0
      @message = []
      start_time = Time.now
      @last_line = ""
      @validation_error = false

      # determine content type from file contents, not from upload_content_type
      content_type = marker_file.determine_content_type
      # validate headers
      if content_type == 'application/gzip'
        Rails.logger.info "#{Time.now}: Parsing #{marker_file.name}:#{marker_file.id} as application/gzip"
        file = Zlib::GzipReader.open(@file_location)
      else
        Rails.logger.info "#{Time.now}: Parsing #{marker_file.name}:#{marker_file.id} as text/plain"
        file = File.open(@file_location, 'rb')
      end

      # validate headers
      headers = file.readline.split(/[\t,]/).map(&:strip)
      @last_line = "#{marker_file.name}, line 1"
      if headers.first != 'GENE NAMES' || headers.size <= 1
        marker_file.update(parse_status: 'failed')
        @validation_error = true
      end
      file.close
    rescue => e
      filename = marker_file.upload_file_name
      marker_file.remove_local_copy
      marker_file.destroy
      error_message = "#{@last_line} ERROR: #{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Gene List file: '#{filename}' parse has failed", error_message).deliver_now
      # raise standard error to halt execution
      raise StandardError, error_message
    end

    # raise validation error if needed
    if @validation_error
      error_message = "file header validation failed: #{@last_line}: first header must be 'GENE NAMES' followed by clusters"
      filename = marker_file.upload_file_name
      marker_file.destroy
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Gene List file: '#{filename}' parse has failed", error_message).deliver_now
      raise StandardError, error_message
    end

    # begin parse
    begin
      Rails.logger.info "#{Time.now}: Beginning precomputed score parse using #{marker_file.name}:#{marker_file.id} for #{self.name}"
      marker_file.update(parse_status: 'parsing')
      list_name = marker_file.name
      if list_name.nil? || list_name.blank?
        list_name = marker_file.upload_file_name.gsub(/(-|_)+/, ' ')
      end
      precomputed_score = self.precomputed_scores.build(name: list_name, study_file_id: marker_file._id)

      if content_type == 'application/gzip'
        marker_scores = Zlib::GzipReader.open(@file_location).readlines.map(&:strip).delete_if {|line| line.blank? }
      else
        marker_scores = File.open(@file_location, 'rb').readlines.map(&:strip).delete_if {|line| line.blank? }
      end

      raw_clusters = marker_scores.shift.split(/[\t,]/).map(&:strip)
      clusters = self.sanitize_input_array(raw_clusters, true)
      @last_line = "#{marker_file.name}, line 1"

      clusters.shift # remove 'Gene Name' at start
      precomputed_score.clusters = clusters
      rows = []
      # keep a running record of genes already parsed; same as expression_scores except precomputed_scores
      # have no built-in validations due to structure of gene_scores array
      @genes_parsed = []
      marker_scores.each_with_index do |line, i|
        @last_line = "#{marker_file.name}, line #{i + 2}"
        raw_vals = line.split(/[\t,]/).map(&:strip)
        vals = self.sanitize_input_array(raw_vals)
        gene = vals.shift.gsub(/\./, '_')
        if @genes_parsed.include?(gene)
          marker_file.update(parse_status: 'failed')
          user_error_message = "You have a duplicate gene entry (#{gene}) in your gene list.  Please check your file and try again."
          error_message = "Duplicate gene #{gene} in #{marker_file.name} (#{marker_file._id}) for study: #{self.name}"
          Rails.logger.info Time.now.to_s + ': ' + error_message
          raise StandardError, user_error_message
        else
          # gene is unique so far so add to list
          @genes_parsed << gene
        end

        row = {"#{gene}" => {}}
        clusters.each_with_index do |cluster, index|
          row[gene][cluster] = vals[index].to_f
        end
        rows << row
        @count += 1
      end
      precomputed_score.gene_scores = rows
      precomputed_score.save
      marker_file.update(parse_status: 'parsed')

      # assemble message
      end_time = Time.now
      time = (end_time - start_time).divmod 60.0
      @message << "#{Time.now}: #{marker_file.name} parse completed!"
      @message << "Total gene list entries created: #{@count}"
      @message << "Total Time: #{time.first} minutes, #{time.last} seconds"
      Rails.logger.info @message.join("\n")

      # send email
      begin
        SingleCellMailer.notify_user_parse_complete(user.email, "Gene list file: '#{marker_file.name}' has completed parsing", @message).deliver_now
      rescue => e
        Rails.logger.error "#{Time.now}: Unable to deliver email: #{e.message}"
      end

      Rails.logger.info "#{Time.now}: determining upload status of gene list file: #{marker_file.upload_file_name}"

      # now that parsing is complete, we can move file into storage bucket and delete local (unless we downloaded from FireCloud to begin with)
      destination = marker_file.remote_location.blank? ? marker_file.upload_file_name : marker_file.remote_location
      remote = Study.firecloud_client.get_workspace_file(self.firecloud_project, self.firecloud_workspace, destination)
      if remote.nil?
        begin
          Rails.logger.info "#{Time.now}: preparing to upload gene list file: #{marker_file.upload_file_name}:#{marker_file.id} to FireCloud"
          self.send_to_firecloud(marker_file)
        rescue => e
          Rails.logger.info "#{Time.now}: Gene List file: #{marker_file.upload_file_name}:#{marker_file.id} failed to upload to FireCloud due to #{e.message}"
          SingleCellMailer.notify_admin_upload_fail(marker_file, e.message).deliver_now
        end
      else
        # we have the file in FireCloud already, so just delete it
        begin
          Rails.logger.info "#{Time.now}: found remote version of #{marker_file.upload_file_name}: #{remote.name} (#{remote.generation})"
          run_at = 15.seconds.from_now
          Delayed::Job.enqueue(UploadCleanupJob.new(self, metadata_file), run_at: run_at)
          Rails.logger.info "#{Time.now}: cleanup job for #{marker_file.upload_file_name}:#{marker_file.id} scheduled for #{run_at}"
        rescue => e
          # we don't really care if the delete fails, we can always manually remove it later as the file is in FireCloud already
          Rails.logger.error "#{Time.now}: Could not delete #{marker_file.name} in study #{self.name}; aborting"
          SingleCellMailer.admin_notification('Local file deletion failed', nil, "The file at #{@file_location} failed to clean up after parsing, please remove.").deliver_now
        end
      end
    rescue => e
      # parse has failed, so clean up records and remove file
      PrecomputedScore.where(study_file_id: marker_file.id).delete_all
      filename = marker_file.upload_file_name
      marker_file.remove_local_copy
      marker_file.destroy
      error_message = "#{@last_line} ERROR: #{e.message}"
      Rails.logger.info Time.now.to_s + ': ' + error_message
      SingleCellMailer.notify_user_parse_fail(user.email, "Gene List file: '#{filename}' parse has failed", error_message).deliver_now
    end
    true
  end

  ###
  #
  # FIRECLOUD FILE METHODS
  #
  ###

  # shortcut method to send an uploaded file straight to firecloud from parser
  # will compress plain text files before uploading to reduce storage/egress charges
  def send_to_firecloud(file)
    begin
      Rails.logger.info "#{Time.now}: Uploading #{file.upload_file_name}:#{file.id} to FireCloud workspace: #{self.firecloud_workspace}"
      file_location = file.remote_location.blank? ? file.upload.path : File.join(self.data_store_path, file.remote_location)
      # determine if file needs to be compressed
      first_two_bytes = File.open(file_location).read(2)
      gzip_signature = StudyFile::GZIP_MAGIC_NUMBER # per IETF
      file_is_gzipped = (first_two_bytes == gzip_signature)
      opts = {}
      if file_is_gzipped or file.upload_file_name.last(4) == '.bam' or file.upload_file_name.last(5) == '.cram'
        # log that file is already compressed
        Rails.logger.info "#{Time.now}: #{file.upload_file_name}:#{file.id} is already compressed, direct uploading"
      else
        Rails.logger.info "#{Time.now}: Performing gzip on #{file.upload_file_name}:#{file.id}"
        # Compress all uncompressed files before upload.
        # This saves time on upload and download, and money on egress and storage.
        gzip_filepath = file_location + '.tmp.gz'
        Zlib::GzipWriter.open(gzip_filepath) do |gz|
          File.open(file_location, 'rb').each do |line|
            gz.write line
          end
          gz.close
        end
        File.rename gzip_filepath, file_location
        opts.merge!(content_encoding: 'gzip')
      end
      remote_file = Study.firecloud_client.execute_gcloud_method(:create_workspace_file, self.firecloud_project, self.firecloud_workspace, file.upload.path, file.upload_file_name, opts)
      # store generation tag to know whether a file has been updated in GCP
      Rails.logger.info "#{Time.now}: Updating #{file.upload_file_name}:#{file.id} with generation tag: #{remote_file.generation} after successful upload"
      file.update(generation: remote_file.generation)
      file.update(upload_file_size: remote_file.size)
      Rails.logger.info "#{Time.now}: Upload of #{file.upload_file_name}:#{file.id} complete, scheduling cleanup job"
      # schedule the upload cleanup job to run in two minutes
      run_at = 15.seconds.from_now
      Delayed::Job.enqueue(UploadCleanupJob.new(file.study, file), run_at: run_at)
      Rails.logger.info "#{Time.now}: cleanup job for #{file.upload_file_name}:#{file.id} scheduled for #{run_at}"
    rescue RuntimeError => e
      Rails.logger.error "#{Time.now}: unable to upload '#{file.upload_file_name}:#{file.id} to FireCloud; #{e.message}"
      # check if file still exists
      file_location = file.remote_location.blank? ? file.upload.path : File.join(self.data_store_path, file.remote_location)
      exists = File.exists?(file_location)
      Rails.logger.info "#{Time.now} local copy of #{file.upload_file_name}:#{file.id} still in #{self.data_store_path}? #{exists}"
      SingleCellMailer.notify_admin_upload_fail(file, e.message).deliver_now
    end
  end

  ###
  #
  # PUBLIC CALLBACK SETTERS
  # These are methods that are called as a part of callbacks, but need to be public as they are also referenced elsewhere
  #
  ###

  # make data directory after study creation is successful
  # this is now a public method so that we can use it whenever remote files are downloaded to validate that the directory exists
  def make_data_dir
    unless Dir.exists?(self.data_store_path)
      FileUtils.mkdir_p(self.data_store_path)
    end
  end

  # set the 'default_participant' entity in workspace data to allow users to upload sample information
  def set_default_participant
    begin
      path = Rails.root.join('data', self.data_dir, 'default_participant.tsv')
      entity_file = File.new(path, 'w+')
      entity_file.write "entity:participant_id\ndefault_participant"
      entity_file.close
      upload = File.open(entity_file.path)
      Study.firecloud_client.import_workspace_entities_file(self.firecloud_project, self.firecloud_workspace, upload)
      Rails.logger.info "#{Time.now}: created default_participant for #{self.firecloud_workspace}"
      File.delete(path)
    rescue => e
      Rails.logger.error "#{Time.now}: Unable to set default participant: #{e.message}"
    end
  end

  private

  ###
  #
  # SETTERS
  #
  ###

  # sets a url-safe version of study name (for linking)
  def set_url_safe_name
    self.url_safe_name = self.name.downcase.gsub(/[^a-zA-Z0-9]+/, '-').chomp('-')
  end

  # set the FireCloud workspace name to be used when creating study
  # will only set the first time, and will not set if user is initializing from an existing workspace
  def set_firecloud_workspace_name
    unless self.use_existing_workspace
      self.firecloud_workspace = "#{WORKSPACE_NAME_PREFIX}#{self.url_safe_name}"
    end
  end

  # set the data directory to a random value to use as a temp location for uploads while parsing
  # this is useful as study deletes will happen asynchronously, so while the study is marked for deletion we can allow
  # other users to re-use the old name & url_safe_name
  # will only set the first time
  def set_data_dir
    @dir_val = SecureRandom.hex(32)
    while Study.where(data_dir: @dir_val).exists?
      @dir_val = SecureRandom.hex(32)
    end
    self.data_dir = @dir_val
  end

  ###
  #
  # CUSTOM VALIDATIONS
  #
  ###

  # automatically create a FireCloud workspace on study creation after validating name & url_safe_name
  # will raise validation errors if creation, bucket or ACL assignment fail for any reason and deletes workspace on validation fail
  def initialize_with_new_workspace
    unless Rails.env == 'test' # testing for this is handled through ui_test_suite.rb which runs against development database

      Rails.logger.info "#{Time.now}: Study: #{self.name} creating FireCloud workspace"
      validate_name_and_url

      Rails.logger.info "#{Time.now}: Study: #{self.name} checking FireCloud project permissions"
      has_access = set_firecloud_project_permissions
      if !has_access
        errors.add(:firecloud_project, " is not accessible to the portal service account.  Please choose another project.")
      end
      Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud project permissions ok"
      unless self.errors.any?
        begin
          # create workspace
          workspace = Study.firecloud_client.create_workspace(self.firecloud_project, self.firecloud_workspace)
          Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud workspace creation successful"
          ws_name = workspace['name']
          # validate creation
          unless ws_name == self.firecloud_workspace
            # delete workspace on validation fail
            Study.firecloud_client.delete_workspace(self.firecloud_project, self.firecloud_workspace)
            errors.add(:firecloud_workspace, ' was not created properly (workspace name did not match or was not created).  Please try again later.')
            return false
          end
          Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud workspace validation successful"
          # set bucket_id
          bucket = workspace['bucketName']
          self.bucket_id = bucket
          if self.bucket_id.nil?
            # delete workspace on validation fail
            Study.firecloud_client.delete_workspace(self.firecloud_project, self.firecloud_workspace)
            errors.add(:firecloud_workspace, ' was not created properly (storage bucket was not set).  Please try again later.')
            return false
          end
          Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud bucket assignment successful"
          # set workspace acl
          study_owner = self.user.email
          workspace_permission = 'WRITER'
          can_compute = true
          # if study project is in the compute blacklist, revoke compute permission
          if Rails.env == 'production' && FireCloudClient::COMPUTE_BLACKLIST.include?(self.firecloud_project)
            can_compute = false
          end
          # check project acls to see if user is project member
          project_acl = Study.firecloud_client.get_billing_project_members(self.firecloud_project)
          user_project_acl = project_acl.find {|acl| acl['email'] == study_owner}
          # if user has no project acls, then we set specific workspace-level acls
          if user_project_acl.nil?
            acl = Study.firecloud_client.create_workspace_acl(study_owner, workspace_permission, true, can_compute)
            Study.firecloud_client.update_workspace_acl(self.firecloud_project, self.firecloud_workspace, acl)
            # validate acl
            ws_acl = Study.firecloud_client.get_workspace_acl(self.firecloud_project, ws_name)
            unless ws_acl['acl'][study_owner]['accessLevel'] == workspace_permission && ws_acl['acl'][study_owner]['canCompute'] == can_compute
              # delete workspace on validation fail
              Study.firecloud_client.delete_workspace(self.firecloud_project, self.firecloud_workspace)
              errors.add(:firecloud_workspace, ' was not created properly (permissions do not match).  Please try again later.')
              return false
            end
          end
          Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud workspace acl assignment successful"
          if self.study_shares.any?
            Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud workspace acl assignment for shares starting"
            self.study_shares.each do |share|
              begin
                acl = Study.firecloud_client.create_workspace_acl(share.email, StudyShare::FIRECLOUD_ACL_MAP[share.permission], true, false)
                Study.firecloud_client.update_workspace_acl(self.firecloud_project, self.firecloud_workspace, acl)
                Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud workspace acl assignment for shares #{share.email} successful"
              rescue RuntimeError => e
                errors.add(:study_shares, "Could not create a share for #{share.email} to workspace #{self.firecloud_workspace} due to: #{e.message}")
                return false
              end
            end
          end
        rescue => e
          # delete workspace on any fail as this amounts to a validation fail
          Rails.logger.info "#{Time.now}: Error creating workspace: #{e.message}"
          # delete firecloud workspace unless error is 409 Conflict (workspace already taken)
          if e.message != '409 Conflict'
            Study.firecloud_client.delete_workspace(self.firecloud_project, self.firecloud_workspace)
            errors.add(:firecloud_workspace, " creation failed: #{e.message}; Please try again.")
          else
            errors.add(:firecloud_workspace, ' - there is already an existing workspace using this name.  Please choose another name for your study.')
            errors.add(:name, ' - you must choose a different name for your study.')
            self.firecloud_workspace = nil
          end
          return false
        end
      end
    end
  end

  # validator to use existing FireCloud workspace
  def initialize_with_existing_workspace
    unless Rails.env == 'test'

      Rails.logger.info "#{Time.now}: Study: #{self.name} using FireCloud workspace: #{self.firecloud_workspace}"
      validate_name_and_url
      # check if workspace is already being used
      if Study.where(firecloud_workspace: self.firecloud_workspace).exists?
        errors.add(:firecloud_workspace, ': The workspace you provided is already in use by another study.  Please use another workspace.')
        return false
      end

      Rails.logger.info "#{Time.now}: Study: #{self.name} checking FireCloud project permissions"
      has_access = set_firecloud_project_permissions
      if !has_access
        errors.add(:firecloud_project, " is not accessible to the portal service account.  Please choose another project.")
      end
      Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud project permissions ok"

      unless self.errors.any?
        begin
          workspace = Study.firecloud_client.get_workspace(self.firecloud_project, self.firecloud_workspace)
          study_owner = self.user.email
          # check project acls to see if user is project member
          project_acl = Study.firecloud_client.get_billing_project_members(self.firecloud_project)
          user_project_acl = project_acl.find {|acl| acl['email'] == study_owner}
          # if user has no project acls, then we set specific workspace-level acls
          if user_project_acl.nil?
            workspace_permission = 'WRITER'
            can_compute = true
            # if study project is in the compute blacklist, revoke compute permission
            if Rails.env == 'production' && FireCloudClient::COMPUTE_BLACKLIST.include?(self.firecloud_project)
              can_compute = false
              Rails.logger.info "#{Time.now}: Study: #{self.name} removing compute permissions"
              compute_acl = Study.firecloud_client.create_workspace_acl(self.user.email, workspace_permission, true, can_compute)
              Study.firecloud_client.update_workspace_acl(self.firecloud_project, self.firecloud_workspace, compute_acl)
            end
            acl = Study.firecloud_client.get_workspace_acl(self.firecloud_project, self.firecloud_workspace)
            # first check workspace authorization domain
            auth_domain = workspace['workspace']['authorizationDomain']
            unless auth_domain.empty?
              errors.add(:firecloud_workspace, ': The workspace you provided is restricted.  We currently do not allow use of restricted workspaces.  Please use another workspace.')
              return false
            end
            # check permissions
            if acl['acl'][study_owner].nil? || acl['acl'][study_owner]['accessLevel'] == 'READER'
              errors.add(:firecloud_workspace, ': You do not have write permission for the workspace you provided.  Please use another workspace.')
              return false
            end
            # check compute permissions
            if acl['acl'][study_owner]['canCompute'] != can_compute
              errors.add(:firecloud_workspace, ': There was an error setting the permissions on your workspace (compute permissions were not set correctly).  Please try again.')
              return false
            end
            Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud workspace acl check successful"
            # set bucket_id, it is nested lower since we had to get an existing workspace
          end

          bucket = workspace['workspace']['bucketName']
          self.bucket_id = bucket
          if self.bucket_id.nil?
            # delete workspace on validation fail
            errors.add(:firecloud_workspace, ' was not created properly (storage bucket was not set).  Please try again later.')
            return false
          end
          Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud bucket assignment successful"
          if self.study_shares.any?
            Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud workspace acl assignment for shares starting"
            self.study_shares.each do |share|
              begin
                acl = Study.firecloud_client.create_workspace_acl(share.email, StudyShare::FIRECLOUD_ACL_MAP[share.permission], true, false)
                Study.firecloud_client.update_workspace_acl(self.firecloud_project, self.firecloud_workspace, acl)
                Rails.logger.info "#{Time.now}: Study: #{self.name} FireCloud workspace acl assignment for shares #{share.email} successful"
              rescue RuntimeError => e
                errors.add(:study_shares, "Could not create a share for #{share.email} to workspace #{self.firecloud_workspace} due to: #{e.message}")
                return false
              end
            end
          end
        rescue => e
          # delete workspace on any fail as this amounts to a validation fail
          Rails.logger.info "#{Time.now}: Error assigning workspace: #{e.message}"
          errors.add(:firecloud_workspace, " assignment failed: #{e.message}; Please check the workspace in question and try again.")
          return false
        end
      end
    end
  end

  # sub-validation used on create
  def validate_name_and_url
    # check name and url_safe_name first and set validation error
    if self.name.blank? || self.name.nil?
      errors.add(:name, " cannot be blank - please provide a name for your study.")
    end
    if Study.where(name: self.name).any?
      errors.add(:name, ": #{self.name} has already been taken.  Please choose another name.")
    end
    if Study.where(url_safe_name: self.url_safe_name).any?
      errors.add(:url_safe_name, ": The name you provided (#{self.name}) tried to create a public URL (#{self.url_safe_name}) that is already assigned.  Please rename your study to a different value.")
    end
  end

  ###
  #
  # CUSTOM CALLBACKS
  #
  ###

  # remove data directory on delete
  def remove_data_dir
    if Dir.exists?(self.data_store_path)
      FileUtils.rm_rf(self.data_store_path)
    end
  end

  # remove firecloud workspace on delete
  def delete_firecloud_workspace
    begin
      Study.firecloud_client.delete_workspace(self.firecloud_project, self.firecloud_workspace)
    rescue RuntimeError => e
      # workspace was not found, most likely deleted already
      Rails.logger.error "#{Time.now}: #{e.message}"
    end
  end

  # set permissions in projects that were created outside of SCP to allow the service account access
  def set_firecloud_project_permissions
    # only perform check if this is not the default portal project
    if self.firecloud_project != FireCloudClient::PORTAL_NAMESPACE
      begin
        client = FireCloudClient.new(self.user, FireCloudClient::PORTAL_NAMESPACE)
        project_members = client.get_billing_project_members(self.firecloud_project)
        if project_members.detect {|member| member['email'] == client.storage_issuer && member['role'] == 'owner'}.nil?
          added = client.add_user_to_billing_project(self.firecloud_project, 'owner', client.storage_issuer)
          return added == 'OK'
        end
      rescue RuntimeError => e
        Rails.logger.error "#{Time.now}: unable to add portal service account to #{self.firecloud_project}: #{e.message}"
        false
      end
    else
      true
    end
  end
end
