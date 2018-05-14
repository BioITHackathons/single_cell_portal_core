class SiteController < ApplicationController

  ###
  #
  # This is the main public controller for the portal.  All data viewing/rendering is handled here, including creating
  # UserAnnotations and submitting workflows.
  #
  ###

  ###
  #
  # FILTERS & SETTINGS
  #
  ###

  respond_to :html, :js, :json

  before_action :set_study, except: [:index, :search, :privacy_policy, :view_workflow_wdl, :create_totat, :log_action,
                                     :get_workflow_options, :get_analysis_metadata, :search_analysis_metadata]
  before_action :set_cluster_group, only: [:study, :render_cluster, :render_gene_expression_plots, :render_gene_set_expression_plots,
                                           :view_gene_expression, :view_gene_set_expression, :view_gene_expression_heatmap,
                                           :view_precomputed_gene_expression_heatmap, :expression_query, :annotation_query,
                                           :get_new_annotations, :annotation_values, :show_user_annotations_form]
  before_action :set_selected_annotation, only: [:render_cluster, :render_gene_expression_plots, :render_gene_set_expression_plots,
                                                 :view_gene_expression, :view_gene_set_expression, :view_gene_expression_heatmap,
                                                 :view_precomputed_gene_expression_heatmap, :annotation_query, :annotation_values,
                                                 :show_user_annotations_form]
  before_action :load_precomputed_options, only: [:study, :update_study_settings, :render_cluster, :render_gene_expression_plots,
                                                  :render_gene_set_expression_plots, :view_gene_expression, :view_gene_set_expression,
                                                  :view_gene_expression_heatmap, :view_precomputed_gene_expression_heatmap]
  before_action :check_view_permissions, except: [:index, :privacy_policy, :search, :precomputed_results, :expression_query,
                                                  :view_workflow_wdl, :log_action, :get_workspace_samples, :update_workspace_samples,
                                                  :create_totat, :get_workflow_options, :get_analysis_metadata, :search_analysis_metadata]
  before_action :check_compute_permissions, only: [:get_fastq_files, :get_workspace_samples, :update_workspace_samples,
                                                   :delete_workspace_samples, :get_workspace_submissions, :create_workspace_submission,
                                                   :get_submission_workflow, :abort_submission_workflow, :get_submission_errors,
                                                   :get_submission_outputs, :delete_submission_files, :get_submission_metadata]

  # caching
  caches_action :render_cluster, :render_gene_expression_plots, :render_gene_set_expression_plots,
                :expression_query, :annotation_query, :precomputed_results,
                cache_path: :set_cache_path

  COLORSCALE_THEMES = %w(Blackbody Bluered Blues Earth Electric Greens Hot Jet Picnic Portland Rainbow RdBu Reds Viridis YlGnBu YlOrRd)

  ###
  #
  # HOME & SEARCH METHODS
  #
  ###

  # view study overviews/descriptions
  def index
    # set study order
    case params[:order]
      when 'recent'
        @order = :created_at.desc
      when 'popular'
        @order = :view_count.desc
      else
        @order = [:view_order.asc, :name.asc]
    end

    # load viewable studies in requested order
    if user_signed_in?
      @viewable = Study.viewable(current_user).order_by(@order)
    else
      @viewable = Study.where(public: true).order_by(@order)
    end

    # filter list if in branding group mode
    if @selected_branding_group.present?
      @viewable = @viewable.where(branding_group_id: @selected_branding_group.id)
    end

    # if search params are present, filter accordingly
    if !params[:search_terms].blank?
      @studies = @viewable.where({:$text => {:$search => params[:search_terms]}}).paginate(page: params[:page], per_page: Study.per_page)
    else
      @studies = @viewable.paginate(page: params[:page], per_page: Study.per_page)
    end

    # determine study/cell count based on viewable to user
    @study_count = @viewable.count
    @cell_count = @viewable.map(&:cell_count).inject(&:+)

    if @cell_count.nil?
      @cell_count = 0
    end
  end

  # search for matching studies
  def search
    # use built-in MongoDB text index (supports quoting terms & case sensitivity)
    @studies = Study.where({'$text' => {'$search' => params[:search_terms]}})

    # restrict to branding group if present
    if @selected_branding_group.present?
      @studies = @studies.where(branding_group_id: @selected_branding_group.id)
    end

    render 'index'
  end

  def privacy_policy

  end

  # search for one or more genes to view expression information
  # will redirect to appropriate method as needed
  def search_genes
    @terms = parse_search_terms(:genes)
    # grab saved params for loaded cluster, boxpoints mode, annotations, consensus and other view settings
    cluster = params[:search][:cluster]
    annotation = params[:search][:annotation]
    boxpoints = params[:search][:boxpoints]
    consensus = params[:search][:consensus]
    subsample = params[:search][:subsample]
    plot_type = params[:search][:plot_type]
    kernel_type = params[:search][:kernel_type]
    band_type = params[:search][:band_type]
    heatmap_row_centering = params[:search][:heatmap_row_centering]
    heatmap_size = params[:search][:heatmap_size]

    # if only one gene was searched for, make an attempt to load it and redirect to correct page
    if @terms.size == 1
      @gene = load_best_gene_match(@study.genes.by_name(@terms.first, @study.expression_matrix_files.map(&:id)), @terms.first)
      if @gene.empty?
        redirect_to merge_default_redirect_params(request.referrer, scpbr: params[:scpbr]),
                    alert: "No matches found for: #{@terms.first}." and return
      else
        redirect_to merge_default_redirect_params(view_gene_expression_path(study_name: params[:study_name], gene: @gene['name'],
                                                                            cluster: cluster, annotation: annotation, consensus: consensus,
                                                                            subsample: subsample, plot_type: plot_type,
                                                                            kernel_type: kernel_type, band_type: band_type,
                                                                            boxpoints: boxpoints, heatmap_row_centering: heatmap_row_centering,
                                                                            heatmap_size: heatmap_size),
                                                  scpbr: params[:scpbr])  and return
      end
    end

    # else, determine which view to load (heatmaps vs. violin/scatter)
    if !consensus.blank?
      redirect_to merge_default_redirect_params(view_gene_set_expression_path(study_name: params[:study_name], search: {genes: @terms.join(' ')},
                                                                              cluster: cluster, annotation: annotation,
                                                                              consensus: consensus, subsample: subsample,
                                                                              plot_type: plot_type, kernel_type: kernel_type,
                                                                              band_type: band_type, boxpoints: boxpoints,
                                                                              heatmap_row_centering: heatmap_row_centering,
                                                                              heatmap_size: heatmap_size),
                                                scpbr: params[:scpbr])
    else
      redirect_to merge_default_redirect_params(view_gene_expression_heatmap_path(search: {genes: @terms.join(' ')}, cluster: cluster,
                                                                                  annotation: annotation, plot_type: plot_type,
                                                                                  kernel_type: kernel_type, band_type: band_type,
                                                                                  boxpoints: boxpoints, heatmap_row_centering: heatmap_row_centering,
                                                                                  heatmap_size: heatmap_size),
                                                scpbr: params[:scpbr])
    end
  end

  ###
  #
  # STUDY SETTINGS
  #
  ###

  # re-render study description as CKEditor instance
  def edit_study_description

  end

  # update selected attributes via study settings tab
  def update_study_settings
    @spinner_target = '#update-study-settings-spinner'
    @modal_target = '#update-study-settings-modal'
    if !user_signed_in?
      set_study_default_options
      @notice = 'Please sign in before continuing.'
      render action: 'notice'
    else
      if @study.can_edit?(current_user)
        if @study.update(study_params)
          # invalidate caches as needed
          if @study.previous_changes.keys.include?('default_options')
            # invalidate all cluster & expression caches as points sizes/borders may have changed globally
            # start with default cluster then do everything else
            @study.default_cluster.study_file.invalidate_cache_by_file_type
            other_clusters = @study.cluster_groups.keep_if {|cluster_group| cluster_group.name != @study.default_cluster}
            other_clusters.map {|cluster_group| cluster_group.study_file.invalidate_cache_by_file_type}
            @study.expression_matrix_files.map {|matrix_file| matrix_file.invalidate_cache_by_file_type}
          elsif @study.previous_changes.keys.include?('name')
            # if user renames a study, invalidate all caches
            old_name = @study.previous_changes['url_safe_name'].first
            CacheRemovalJob.new(old_name).delay.perform
          end
          set_study_default_options
          if @study.initialized?
            @cluster = @study.default_cluster
            @options = load_cluster_group_options
            @cluster_annotations = load_cluster_group_annotations
            set_selected_annotation
          end

          @study_files = @study.study_files.non_primary_data.sort_by(&:name)
          @primary_study_files = @study.study_files.by_type('Fastq')
          @directories = @study.directory_listings.are_synced
          @primary_data = @study.directory_listings.primary_data
          @other_data = @study.directory_listings.non_primary_data

          # double check on download availability: first, check if administrator has disabled downloads
          # then check if FireCloud is available and disable download links if either is true
          @allow_downloads = AdminConfiguration.firecloud_access_enabled? && Study.firecloud_client.api_available?
        else
          set_study_default_options
        end
      else
        set_study_default_options
        @alert = 'You do not have permission to perform that action.'
        render action: 'notice'
      end
    end
  end

  ###
  #
  # VIEW/RENDER METHODS
  #
  ###

  ## ANALYSIS-BASED

  def search_analysis_metadata
    # only allow searching on public metadata
    matches = AnalysisMetadatum.where(published: true)
    params.each do |param, value|
      case param
        when 'submission_id'
          matches = matches.where(submission_id: params[:submission_id])
        when 'study'
          studies = Study.any_of({name: /#{params[:study]}/},{url_safe_name: /#{params[:study]}/})
          if studies.size > 0
            ids = studies.map(&:id)
            matches = matches.where(:study_id.in => ids)
          end
        when 'name'
          matches = matches.where(name: /#{params[:name]}/)
      end
    end

    logger.info "matches: #{matches.inspect}"

    search_params = params.delete_if {|k, v| k == 'controller' || k == 'action' || k == 'format'}

    @results = {
        search_string: search_params,
        results: matches.map(&:fair_header)
    }
    respond_to do |format|
      format.html {render html: "<html><body><pre>#{JSON.pretty_generate(@results)}</pre></body></html>".html_safe}
      format.json {render json: @results.to_json}
    end
  end

  # download an instance of analysis_metadatum
  def get_analysis_metadata
    @analysis = AnalysisMetadatum.find_by(submission_id: params[:submission_id])
    if @analysis.nil? || !@analysis.published?
      head 404
    else
      respond_to do |format|
        format.html {render html: "<html><body><pre>#{JSON.pretty_generate(@analysis.fair_payload)}</pre></body></html>".html_safe}
        format.json {render json: @analysis.fair_payload.to_json}
      end
    end
  end

  ## CLUSTER-BASED

  # load single study and view top-level clusters
  def study
    @study.update(view_count: @study.view_count + 1)
    @study_files = @study.study_files.non_primary_data.sort_by(&:name)
    @primary_study_files = @study.study_files.by_type('Fastq')
    @directories = @study.directory_listings.are_synced
    @primary_data = @study.directory_listings.primary_data
    @other_data = @study.directory_listings.non_primary_data
    @analyses = @study.analysis_metadata.public

    # double check on download availability: first, check if administrator has disabled downloads
    # then check if FireCloud is available and disable download links if either is true
    @allow_firecloud_access = AdminConfiguration.firecloud_access_enabled?
    @allow_downloads = @allow_firecloud_access && Study.firecloud_client.api_available?
    set_study_default_options
    # load options and annotations
    if @study.initialized?
      @options = load_cluster_group_options
      @cluster_annotations = load_cluster_group_annotations
      # call set_selected_annotation manually
      set_selected_annotation
    end

    # if user has permission to run workflows, load available workflows and current submissions

    if @allow_firecloud_access
      if user_signed_in? && @study.can_compute?(current_user)
        # load list of previous submissions
        workspace = Study.firecloud_client.get_workspace(@study.firecloud_project, @study.firecloud_workspace)
        @submissions = Study.firecloud_client.get_workspace_submissions(@study.firecloud_project, @study.firecloud_workspace)

        # remove deleted submissions from list of runs
        if !workspace['workspace']['attributes']['deleted_submissions'].blank?
          deleted_submissions = workspace['workspace']['attributes']['deleted_submissions']['items']
          @submissions.delete_if {|submission| deleted_submissions.include?(submission['submissionId'])}
        end

        # load samples from workspace
        all_samples = Study.firecloud_client.get_workspace_entities_by_type(@study.firecloud_project, @study.firecloud_workspace, 'sample')
        @samples = Naturally.sort(all_samples.map {|s| s['name']})

        # load locations of primary data (for new sample selection)
        @primary_data_locations = []
        fastq_files = @primary_study_files.select {|f| !f.human_data}
        [fastq_files, @primary_data].flatten.each do |entry|
          @primary_data_locations << ["#{entry.name} (#{entry.description})", "#{entry.class.name.downcase}--#{entry.name}"]
        end

        # load list of available workflows
        @workflows_list = load_available_workflows
      end
    end
  end

  # render a single cluster and its constituent sub-clusters
  def render_cluster
    subsample = params[:subsample].blank? ? nil : params[:subsample].to_i
    @coordinates = load_cluster_group_data_array_points(@selected_annotation, subsample)
    @plot_type = @cluster.cluster_type == '3d' ? 'scatter3d' : 'scattergl'
    @options = load_cluster_group_options
    @cluster_annotations = load_cluster_group_annotations
    if @cluster.has_coordinate_labels?
      @coordinate_labels = load_cluster_group_coordinate_labels
    end
    @range = set_range(@coordinates.values)
    if @cluster.is_3d? && @cluster.has_range?
      @aspect = compute_aspect_ratios(@range)
    end
    @axes = load_axis_labels

    # load default color profile if necessary
    if params[:annotation] == @study.default_annotation && @study.default_annotation_type == 'numeric' && !@study.default_color_profile.nil?
      @coordinates[:all][:marker][:colorscale] = @study.default_color_profile
    end

    respond_to do |format|
      format.js
    end
  end

  ## GENE-BASED

  # render box and scatter plots for parent clusters or a particular sub cluster
  def view_gene_expression
    @options = load_cluster_group_options
    @cluster_annotations = load_cluster_group_annotations
    @top_plot_partial = @selected_annotation[:type] == 'group' ? 'expression_plots_view' : 'expression_annotation_plots_view'
    @y_axis_title = load_expression_axis_title
  end

  # re-renders plots when changing cluster selection
  def render_gene_expression_plots
    matches = @study.genes.by_name(params[:gene], @study.expression_matrix_files.map(&:id))
    subsample = params[:subsample].blank? ? nil : params[:subsample].to_i
    @gene = load_best_gene_match(matches, params[:gene])
    @y_axis_title = load_expression_axis_title
    # depending on annotation type selection, set up necessary partial names to use in rendering
    if @selected_annotation[:type] == 'group'
      @values = load_expression_boxplot_data_array_scores(@selected_annotation, subsample)
      if params[:plot_type] == 'box'
        @values_box_type = 'box'
      else
        @values_box_type = 'violin'
        @values_kernel_type = params[:kernel_type]
        @values_band_type = params[:band_type]
      end
      @top_plot_partial = 'expression_plots_view'
      @top_plot_plotly = 'expression_plots_plotly'
      @top_plot_layout = 'expression_box_layout'
    else
      @values = load_annotation_based_data_array_scatter(@selected_annotation, subsample)
      @top_plot_partial = 'expression_annotation_plots_view'
      @top_plot_plotly = 'expression_annotation_plots_plotly'
      @top_plot_layout = 'expression_annotation_scatter_layout'
      @annotation_scatter_range = set_range(@values.values)
    end
    @expression = load_expression_data_array_points(@selected_annotation, subsample)
    @options = load_cluster_group_options
    @range = set_range([@expression[:all]])
    @coordinates = load_cluster_group_data_array_points(@selected_annotation, subsample)
    if @cluster.has_coordinate_labels?
      @coordinate_labels = load_cluster_group_coordinate_labels
    end
    @static_range = set_range(@coordinates.values)
    if @cluster.is_3d? && @cluster.has_range?
      @expression_aspect = compute_aspect_ratios(@range)
      @static_aspect = compute_aspect_ratios(@static_range)
    end
    @cluster_annotations = load_cluster_group_annotations

    # load default color profile if necessary
    if params[:annotation] == @study.default_annotation && @study.default_annotation_type == 'numeric' && !@study.default_color_profile.nil?
      @expression[:all][:marker][:colorscale] = @study.default_color_profile
      @coordinates[:all][:marker][:colorscale] = @study.default_color_profile
    end
  end

  # view set of genes (scores averaged) as box and scatter plots
  # works for both a precomputed list (study supplied) or a user query
  def view_gene_set_expression
    # first check if there is a user-supplied gene list to view as consensus
    # call search_expression_scores to return values not found

    terms = params[:gene_set].blank? && !params[:consensus].blank? ? parse_search_terms(:genes) : @study.precomputed_scores.by_name(params[:gene_set]).gene_list
    @genes, @not_found = search_expression_scores(terms)

    consensus = params[:consensus].nil? ? 'Mean ' : params[:consensus].capitalize + ' '
    @gene_list = @genes.map{|gene| gene['name']}.join(' ')
    @y_axis_title = consensus + ' ' + load_expression_axis_title
    # depending on annotation type selection, set up necessary partial names to use in rendering
    @options = load_cluster_group_options
    @cluster_annotations = load_cluster_group_annotations
    @top_plot_partial = @selected_annotation[:type] == 'group' ? 'expression_plots_view' : 'expression_annotation_plots_view'

    if @genes.size > 5
      @main_genes, @other_genes = divide_genes_for_header
    end
    # make sure we found genes, otherwise redirect back to base view
    if @genes.empty?
      redirect_to merge_default_redirect_params(view_study_path, scpbr: params[:scpbr]), alert: "None of the requested genes were found: #{terms.join(', ')}"
    else
      render 'view_gene_expression'
    end
  end

  # re-renders plots when changing cluster selection
  def render_gene_set_expression_plots
    # first check if there is a user-supplied gene list to view as consensus
    # call load expression scores since we know genes exist already from view_gene_set_expression

    terms = params[:gene_set].blank? ? parse_search_terms(:genes) : @study.precomputed_scores.by_name(params[:gene_set]).gene_list
    @genes = load_expression_scores(terms)
    subsample = params[:subsample].blank? ? nil : params[:subsample].to_i
    consensus = params[:consensus].nil? ? 'Mean ' : params[:consensus].capitalize + ' '
    @gene_list = @genes.map{|gene| gene['gene']}.join(' ')
    @y_axis_title = consensus + ' ' + load_expression_axis_title
    # depending on annotation type selection, set up necessary partial names to use in rendering
    if @selected_annotation[:type] == 'group'
      @values = load_gene_set_expression_boxplot_scores(@selected_annotation, params[:consensus], subsample)
      if params[:plot_type] == 'box'
        @values_box_type = 'box'
      else
        @values_box_type = 'violin'
        @values_kernel_type = params[:kernel_type]
        @values_band_type = params[:band_type]
      end
      @top_plot_partial = 'expression_plots_view'
      @top_plot_plotly = 'expression_plots_plotly'
      @top_plot_layout = 'expression_box_layout'
    else
      @values = load_gene_set_annotation_based_scatter(@selected_annotation, params[:consensus], subsample)
      @top_plot_partial = 'expression_annotation_plots_view'
      @top_plot_plotly = 'expression_annotation_plots_plotly'
      @top_plot_layout = 'expression_annotation_scatter_layout'
      @annotation_scatter_range = set_range(@values.values)
    end
    # load expression scatter using main gene expression values
    @expression = load_gene_set_expression_data_arrays(@selected_annotation, params[:consensus], subsample)
    color_minmax =  @expression[:all][:marker][:color].minmax
    @expression[:all][:marker][:cmin], @expression[:all][:marker][:cmax] = color_minmax

    # load static cluster reference plot
    @coordinates = load_cluster_group_data_array_points(@selected_annotation, subsample)
    # set up options, annotations and ranges
    @options = load_cluster_group_options
    @range = set_range([@expression[:all]])
    @static_range = set_range(@coordinates.values)

    if @cluster.is_3d? && @cluster.has_range?
      @expression_aspect = compute_aspect_ratios(@range)
      @static_aspect = compute_aspect_ratios(@static_range)
    end

    @cluster_annotations = load_cluster_group_annotations

    if @genes.size > 5
      @main_genes, @other_genes = divide_genes_for_header
    end

    # load default color profile if necessary
    if params[:annotation] == @study.default_annotation && @study.default_annotation_type == 'numeric' && !@study.default_color_profile.nil?
      @expression[:all][:marker][:colorscale] = @study.default_color_profile
      @coordinates[:all][:marker][:colorscale] = @study.default_color_profile
    end

    render 'render_gene_expression_plots'
  end

  # view genes in Morpheus as heatmap
  def view_gene_expression_heatmap
    # parse and divide up genes
    terms = parse_search_terms(:genes)
    @genes, @not_found = search_expression_scores(terms)
    @gene_list = @genes.map{|gene| gene['name']}.join(' ')
    # load dropdown options
    @options = load_cluster_group_options
    @cluster_annotations = load_cluster_group_annotations
    if @genes.size > 5
      @main_genes, @other_genes = divide_genes_for_header
    end
    # make sure we found genes, otherwise redirect back to base view
    if @genes.empty?
      redirect_to merge_default_redirect_params(view_study_path, scpbr: params[:scpbr]), alert: "None of the requested genes were found: #{terms.join(', ')}"
    end
  end

  # load data in gct form to render in Morpheus, preserving query order
  def expression_query
    if check_xhr_view_permissions
      terms = parse_search_terms(:genes)
      @genes = load_expression_scores(terms)
      @headers = ["Name", "Description"]
      @cells = @cluster.concatenate_data_arrays('text', 'cells')
      @cols = @cells.size
      @cells.each do |cell|
        @headers << cell
      end

      @rows = []
      @genes.each do |gene|
        row = [gene['name'], ""]
        case params[:row_centered]
          when 'z-score'
            vals = ExpressionScore.z_score(gene['scores'], @cells)
            row += vals
          when 'robust-z-score'
            vals = ExpressionScore.robust_z_score(gene['scores'], @cells)
            row += vals
          else
            @cells.each do |cell|
              row << gene['scores'][cell].to_f
            end
        end
        @rows << row.join("\t")
      end
      @data = ['#1.2', [@rows.size, @cols].join("\t"), @headers.join("\t"), @rows.join("\n")].join("\n")

      send_data @data, type: 'text/plain'
    else
      head 403
    end
  end

  # load annotations in tsv format for Morpheus
  def annotation_query
    @cells = @cluster.concatenate_data_arrays('text', 'cells')
    if @selected_annotation[:scope] == 'cluster'
      @annotations = @cluster.concatenate_data_arrays(@selected_annotation[:name], 'annotations')
    else
      study_annotations = @study.cell_metadata_values(@selected_annotation[:name], @selected_annotation[:type])
      @annotations = []
      @cells.each do |cell|
        @annotations << study_annotations[cell]
      end
    end
    # assemble rows of data
    @rows = []
    @cells.each_with_index do |cell, index|
      @rows << [cell, @annotations[index]].join("\t")
    end
    @headers = ['NAME', @selected_annotation[:name]]
    @data = [@headers.join("\t"), @rows.join("\n")].join("\n")
    send_data @data, type: 'text/plain'
  end

  # dynamically reload cluster-based annotations list when changing clusters
  def get_new_annotations
    @cluster_annotations = load_cluster_group_annotations
  end

  # return JSON representation of selected annotation
  def annotation_values
    render json: @selected_annotation.to_json
  end

  ## GENELIST-BASED

  # load precomputed data in gct form to render in Morpheus
  def precomputed_results
    if check_xhr_view_permissions
      @precomputed_score = @study.precomputed_scores.by_name(params[:precomputed])

      @headers = ["Name", "Description"]
      @precomputed_score.clusters.each do |cluster|
        @headers << cluster
      end
      @rows = []
      @precomputed_score.gene_scores.each do |score_row|
        score_row.each do |gene, scores|
          row = [gene, ""]
          mean = 0.0
          if params[:row_centered] == '1'
            mean = scores.values.inject(0) {|sum, x| sum += x} / scores.values.size
          end
          @precomputed_score.clusters.each do |cluster|
            row << scores[cluster].to_f - mean
          end
          @rows << row.join("\t")
        end
      end
      @data = ['#1.2', [@rows.size, @precomputed_score.clusters.size].join("\t"), @headers.join("\t"), @rows.join("\n")].join("\n")

      send_data @data, type: 'text/plain', filename: 'query.gct'
    else
      head 403
    end
  end

  # redirect to show precomputed marker gene results
  def search_precomputed_results
    redirect_to merge_default_redirect_params(view_precomputed_gene_expression_heatmap_path(study_name: params[:study_name],
                                                                                            precomputed: params[:expression]),
                                              scpbr: params[:scpbr])
  end

  # view all genes as heatmap in morpheus, will pull from pre-computed gct file
  def view_precomputed_gene_expression_heatmap
    @precomputed_score = @study.precomputed_scores.by_name(params[:precomputed])
    @options = load_cluster_group_options
    @cluster_annotations = load_cluster_group_annotations
  end

  ###
  #
  # DOWNLOAD METHODS
  #
  ###

  # method to download files if study is public
  def download_file
    # make sure user is signed in
    if !user_signed_in?
      redirect_to merge_default_redirect_params(view_study_path(@study.url_safe_name), scpbr: params[:scpbr]),
                  alert: 'You must be signed in to download data.' and return
    elsif @study.embargoed?(current_user)
      redirect_to merge_default_redirect_params(view_study_path(@study.url_safe_name), scpbr: params[:scpbr]),
                  alert: "You may not download any data from this study until #{@study.embargo.to_s(:long)}." and return
    elsif !@study.can_download?(current_user)
      redirect_to merge_default_redirect_params(view_study_path(@study.url_safe_name), scpbr: params[:scpbr]),
                  alert: 'You do not have permission to perform that action.' and return
    end

    # next check if downloads have been disabled by administrator, this will abort the download
    # download links shouldn't be rendered in any case, this just catches someone doing a straight GET on a file
    # also check if FireCloud is unavailable and abort if so as well
    if !AdminConfiguration.firecloud_access_enabled? || !Study.firecloud_client.api_available?
      head 503 and return
    end

    begin
      # get filesize and make sure the user is under their quota
      requested_file = Study.firecloud_client.execute_gcloud_method(:get_workspace_file, @study.firecloud_project, @study.firecloud_workspace, params[:filename])
      if requested_file.present?
        filesize = requested_file.size
        user_quota = current_user.daily_download_quota + filesize
        # check against download quota that is loaded in ApplicationController.get_download_quota
        if user_quota <= @download_quota
          @signed_url = Study.firecloud_client.execute_gcloud_method(:generate_signed_url, @study.firecloud_project, @study.firecloud_workspace, params[:filename], expires: 15)
          current_user.update(daily_download_quota: user_quota)
        else
          redirect_to view_study_path(@study.url_safe_name), alert: 'You have exceeded your current daily download quota.  You must wait until tomorrow to download this file.' and return
        end
        # redirect directly to file to trigger download
        redirect_to @signed_url
      else
        # send notification to the study owner that file is missing (if notifications turned on)
        SingleCellMailer.user_download_fail_notification(@study, params[:filename]).deliver_now
        redirect_to view_study_path, alert: 'The file you requested is currently not available.  Please contact the study owner if you require access to this file.' and return
      end
    rescue RuntimeError => e
      logger.error "#{Time.now}: error generating signed url for #{params[:filename]}; #{e.message}"
      redirect_to merge_default_redirect_params(view_study_path(@study.url_safe_name), scpbr: params[:scpbr]),
                  alert: "We were unable to download the file #{params[:filename]} do to an error: #{view_context.simple_format(e.message)}" and return
    end
  end

  def create_totat
    if !user_signed_in?
      error = {'message': "Forbidden: You must be signed in to do this"}
      render json:  + error, status: 403
    end
    half_hour = 1800 # seconds
    totat_and_ti = current_user.create_totat(time_interval=half_hour)
    render json: totat_and_ti
  end

  # Returns text file listing signed URLs, etc. of files for download via curl.
  # That is, this return 'cfg.txt' used as config (K) argument in 'curl -K cfg.txt'
  def download_bulk_files

    # Ensure study is public
    if !@study.public?
      message = 'Only public studies can be downloaded via curl.'
      render plain: "Forbidden: " + message, status: 403
      return
    end

    # 'all' or the name of a directory, e.g. 'csvs'
    download_object = params[:download_object]

    totat = params[:totat]

    # Time-based one-time access token (totat) is used to track user's download quota
    valid_totat = User.verify_totat(totat)

    if valid_totat == false
      render plain: "Forbidden: Invalid access token " + totat, status: 403
      return
    else
      user = valid_totat
    end

    user_quota = user.daily_download_quota

    # Only check quota at beginning of download, not per file.
    # Studies might be massive, and we want user to be able to download at least
    # one requested download object per day.
    if user_quota >= @download_quota
      message = 'You have exceeded your current daily download quota.  You must wait until tomorrow to download this object.'
      render plain: "Forbidden: " + message, status: 403
      return
    end

    curl_configs = ['--create-dirs', '--compressed']

    curl_files = []

    # Gather all study files, if we're downloading whole study ('all')
    if download_object == 'all'
      files = @study.study_files.valid
      files.each do |study_file|
        unless study_file.human_data?
          curl_files.push(study_file)
        end
      end
    end

    # Gather all files in requested directory listings
    synced_dirs = @study.directory_listings.are_synced
    synced_dirs.each do |synced_dir|
      if download_object != 'all' and synced_dir[:name] != download_object
        next
      end
      synced_dir.files.each do |file|
        curl_files.push(file)
      end
    end

    start_time = Time.now

    # Get signed URLs for all files in the requested download objects, and update user quota
    Parallel.map(curl_files, in_threads: 100) do |file|
      fc_client = FireCloudClient.new
      curl_config, file_size = get_curl_config(file, fc_client)
      curl_configs.push(curl_config)
      user_quota += file_size
    end

    end_time = Time.now
    time = (end_time - start_time).divmod 60.0
    @log_message = ["#{Time.now}: #{@study.url_safe_name} curl configs generated!"]
    @log_message << "Signed URLs generated: #{curl_configs.size}"
    @log_message << "Total time in get_curl_config: #{time.first} minutes, #{time.last} seconds"
    Rails.logger.info @log_message.join("\n")

    curl_configs = curl_configs.join("\n\n")

    user.update(daily_download_quota: user_quota)

    send_data curl_configs, type: 'text/plain', filename: 'cfg.txt'
  end

  ###
  #
  # ANNOTATION METHODS
  #
  ###

  # render the 'Create Annotations' form (must be done via ajax to get around page caching issues)
  def show_user_annotations_form

  end

  # Method to create user annotations from box or lasso selection
  def create_user_annotations

    # Data name is an array of the values of labels
    @data_names = []

    #Error handling block to create annotation
    begin
      # Get the label values and push to data names
      user_annotation_params[:user_data_arrays_attributes].keys.each do |key|
        user_annotation_params[:user_data_arrays_attributes][key][:values] =  user_annotation_params[:user_data_arrays_attributes][key][:values].split(',')
        @data_names.push(user_annotation_params[:user_data_arrays_attributes][key][:name].strip )
      end

      # Create the annotation
      @user_annotation = UserAnnotation.new(user_id: user_annotation_params[:user_id], study_id: user_annotation_params[:study_id], cluster_group_id: user_annotation_params[:cluster_group_id], values: @data_names, name: user_annotation_params[:name])

      # override cluster setter to use the current selected cluster, needed for reloading
      @cluster = @user_annotation.cluster_group

      # Error handling, save the annotation and handle exceptions
      if @user_annotation.save
        # Method call to create the user data arrays for this annotation
        @user_annotation.initialize_user_data_arrays(user_annotation_params[:user_data_arrays_attributes], user_annotation_params[:subsample_annotation],user_annotation_params[:subsample_threshold], user_annotation_params[:loaded_annotation])

        # Reset the annotations in the dropdowns to include this new annotation
        @cluster_annotations = load_cluster_group_annotations
        @options = load_cluster_group_options

        # No need for an alert, only a message saying successfully created
        @alert = nil
        @notice = "User Annotation: '#{@user_annotation.name}' successfully saved. You may now view this annotation via the annotations dropdown."

        # Update the dropdown partial
        render 'update_user_annotations'
      else
        # If there was an error saving, reload and alert the use something broke
        @cluster_annotations = load_cluster_group_annotations
        @options = load_cluster_group_options
        @notice = nil
        @alert = 'The following errors prevented the annotation from being saved: ' + @user_annotation.errors.full_messages.join(',')
        logger.error "#{Time.now}: Creating user annotation of params: #{user_annotation_params}, unable to save user annotation with errors #{@user_annotation.errors.full_messages.join(', ')}"
        render 'update_user_annotations'
      end
        # More error handling, this is if can't save user annotation
    rescue Mongoid::Errors::InvalidValue => e
      # If an invalid value was somehow passed through the form, and couldn't save the annotation
      @cluster_annotations = load_cluster_group_annotations
      @options = load_cluster_group_options
      @notice = nil
      @alert = 'The following errors prevented the annotation from being saved: ' + 'Invalid data type submitted. (' + e.problem + '. ' + e.resolution + ')'
      logger.error "#{Time.now}: Creating user annotation of params: #{user_annotation_params}, invalid value of #{e.message}"
      render 'update_user_annotations'

    rescue NoMethodError => e
      # If something is nil and can't have a method called on it, respond with an alert
      @cluster_annotations = load_cluster_group_annotations
      @options = load_cluster_group_options
      @notice = nil
      @alert = 'The following errors prevented the annotation from being saved: ' + e.message
      logger.error "#{Time.now}: Creating user annotation of params: #{user_annotation_params}, no method error #{e.message}"
      render 'update_user_annotations'

    rescue => e
      # If a generic unexpected error occurred and couldn't save the annotation
      @cluster_annotations = load_cluster_group_annotations
      @options = load_cluster_group_options
      @notice = nil
      @alert = 'An unexpected error prevented the annotation from being saved: ' + e.message
      logger.error "#{Time.now}: Creating user annotation of params: #{user_annotation_params}, unexpected error #{e.message}"
      render 'update_user_annotations'
    end
  end

  ###
  #
  # WORKFLOW METHODS
  #
  ###

  # method to populate an array with entries corresponding to all fastq files for a study (both owner defined as study_files
  # and extra fastq's that happen to be in the bucket)
  def get_fastq_files
    @fastq_files = []
    file_list = []

    #
    selected_entries = params[:selected_entries].split(',').map(&:strip)
    selected_entries.each do |entry|
      class_name, entry_name = entry.split('--')
      case class_name
        when 'directorylisting'
          directory = @study.directory_listings.are_synced.detect {|d| d.name == entry_name}
          if !directory.nil?
            directory.files.each do |file|
              entry = file
              entry[:gs_url] = directory.gs_url(file[:name])
              file_list << entry
            end
          end
        when 'studyfile'
          study_file = @study.study_files.by_type('Fastq').detect {|f| f.name == entry_name}
          if !study_file.nil?
            file_list << {name: study_file.bucket_location, size: study_file.upload_file_size, generation: study_file.generation, gs_url: study_file.gs_url}
          end
        else
          nil # this is called when selection is cleared out
      end
    end
    # now that we have the complete list, populate the table with sample pairs (if present)
    populate_rows(@fastq_files, file_list)

    render json: @fastq_files.to_json
  end

  # view the wdl of a specified workflow
  def view_workflow_wdl
    @workflow_name = params[:workflow]
    @workflow_namespace = params[:namespace]
    @workflow_snapshot = params[:snapshot]
    begin
      # load workflow payload object
      @workflow_wdl = Study.firecloud_client.get_method(@workflow_namespace, @workflow_name, @workflow_snapshot, true)
      if @workflow_wdl.is_a?(Hash)
        @workflow_wdl = @workflow_wdl['payload']
      end
    rescue => e
      @workflow_wdl = "We're sorry, but we could not load the requested workflow object.  Please try again later.\n\nError: #{e.message}"
      logger.error "#{Time.now}: unable to load WDL for #{@workflow_namespace}:#{@workflow_name}:#{@workflow_snapshot}; #{e.message}"
    end
  end

  # get the available entities for a workspace
  def get_workspace_samples
    begin
      requested_samples = params[:samples].split(',')
      # get all samples
      all_samples = Study.firecloud_client.get_workspace_entities_by_type(@study.firecloud_project, @study.firecloud_workspace, 'sample')
      # since we can't query the API (easily) for matching samples, just get all and then filter based on requested samples
      matching_samples = all_samples.keep_if {|sample| requested_samples.include?(sample['name']) }
      @samples = []
      matching_samples.each do |sample|
        @samples << [sample['name'],
                     sample['attributes']['fastq_file_1'],
                     sample['attributes']['fastq_file_2'],
                     sample['attributes']['fastq_file_3'],
                     sample['attributes']['fastq_file_4']
        ]
      end
      render json: @samples.to_json
    rescue => e
      logger.error "#{Time.now}: Error retrieving workspace samples for #{study.name}; #{e.message}"
      render json: []
    end
  end

  # save currently selected sample information back to study workspace
  def update_workspace_samples
    form_payload = params[:samples]

    begin
      # create a 'real' temporary file as we can't pass open tempfiles
      filename = "#{SecureRandom.uuid}-sample-info.tsv"
      temp_tsv = File.new(Rails.root.join('data', @study.data_dir, filename), 'w+')

      # add participant_id to new file as FireCloud data model requires this for samples (all samples get default_participant value)
      headers = %w(entity:sample_id participant_id fastq_file_1 fastq_file_2 fastq_file_3 fastq_file_4)
      temp_tsv.write headers.join("\t") + "\n"

      # get list of samples from form payload
      samples = form_payload.keys
      samples.each do |sample|
        # construct a new line to write to the tsv file
        newline = "#{sample}\tdefault_participant\t"
        vals = []
        headers[2..5].each do |attr|
          # add a value for each parameter, created an empty string if this was not present in the form data
          vals << form_payload[sample][attr].to_s
        end
        # write new line to tsv file
        newline += vals.join("\t")
        temp_tsv.write newline + "\n"
      end
      # close the file to ensure write is completed
      temp_tsv.close

      # now reopen and import into FireCloud
      upload = File.open(temp_tsv.path)
      Study.firecloud_client.import_workspace_entities_file(@study.firecloud_project, @study.firecloud_workspace, upload)

      # upon success, load the newly imported samples from the workspace and update the form
      new_samples = Study.firecloud_client.get_workspace_entities_by_type(@study.firecloud_project, @study.firecloud_workspace, 'sample')
      @samples = Naturally.sort(new_samples.map {|s| s['name']})

      # clean up tempfile
      File.delete(temp_tsv.path)

      # render update notice
      @notice = 'Your sample information has successfully been saved.'
      render action: :update_workspace_samples
    rescue => e
      logger.info "#{Time.now}: Error saving workspace entities: #{e.message}"
      @alert = "An error occurred while trying to save your sample information: #{view_context.simple_format(e.message)}"
      render action: :notice
    end
  end

  # delete selected samples from workspace data entities
  def delete_workspace_samples
    samples = params[:samples]
    begin
      # create a mapping of samples to delete
      delete_payload = Study.firecloud_client.create_entity_map(samples, 'sample')
      Study.firecloud_client.delete_workspace_entities(@study.firecloud_project, @study.firecloud_workspace, delete_payload)

      # upon success, load the newly imported samples from the workspace and update the form
      new_samples = Study.firecloud_client.get_workspace_entities_by_type(@study.firecloud_project, @study.firecloud_workspace, 'sample')
      @samples = Naturally.sort(new_samples.map {|s| s['name']})

      # render update notice
      @notice = 'The requested samples have successfully been deleted.'

      # set flag to empty out the samples table to prevent the user from trying to delete the sample again
      @empty_samples_table = true
      render action: :update_workspace_samples
    rescue => e
      logger.error "#{Time.now}: Error deleting workspace entities: #{e.message}"
      @alert = "An error occurred while trying to delete your sample information: #{view_context.simple_format(e.message)}"
      render action: :notice
    end
  end

  # get all submissions for a study workspace
  def get_workspace_submissions
    workspace = Study.firecloud_client.get_workspace(@study.firecloud_project, @study.firecloud_workspace)
    @submissions = Study.firecloud_client.get_workspace_submissions(@study.firecloud_project, @study.firecloud_workspace)
    # remove deleted submissions from list of runs
    if !workspace['workspace']['attributes']['deleted_submissions'].blank?
      deleted_submissions = workspace['workspace']['attributes']['deleted_submissions']['items']
      @submissions.delete_if {|submission| deleted_submissions.include?(submission['submissionId'])}
    end
  end

  # retrieve any optional parameters for a selected workflow
  def get_workflow_options
    @options = WorkflowConfiguration.get_additional_parameters(params[:workflow_identifier])
  end

  # create a workspace analysis submission for a given sample
  def create_workspace_submission
    begin
      # before creating submission, we need to make sure that the user is on the 'all-portal' user group list if it exists
      user_group_config = AdminConfiguration.find_by(config_type: 'Portal FireCloud User Group')
      if user_group_config.present? && !current_user.registered_for_firecloud
        group_name = user_group_config.value
        logger.info "#{Time.now}: adding #{current_user.email} to #{group_name} user group"
        Study.firecloud_client.add_user_to_group(group_name, 'member', current_user.email)
        logger.info "#{Time.now}: user group registration complete"
        current_user.update(registered_for_firecloud: true)
      end

      # set up parameters
      workflow_namespace, workflow_name, workflow_snapshot = params[:workflow][:identifier].split('--')
      samples = params[:workflow][:samples].keep_if {|s| !s.blank?}
      optional_inputs = params[:workflow][:optional_parameters]

      # either load existing workspace configuration or copy new one into the workspace from the methods repository
      config_namespace, config_name = set_workflow_configuration(workflow_name, workflow_namespace, workflow_snapshot)

      # submission must be done as user, so create a client with current_user and submit
      client = FireCloudClient.new(current_user, @study.firecloud_project)
      @submissions = []
      @failed_submissions = []
      samples.each do |sample|
        logger.info "#{Time.now}: Updating configuration for #{config_namespace}/#{config_name} to run #{workflow_namespace}/#{workflow_name} in #{@study.firecloud_project}/#{@study.firecloud_workspace}"
        # create input hash for submission
        submission_inputs = {sample_name: sample}
        if optional_inputs.present?
          submission_inputs.merge!(optional_inputs)
        end
        # Run any workflow-specific extra configuration steps
        configuration_response = WorkflowConfiguration.new(@study, config_namespace, config_name, workflow_namespace, workflow_name, submission_inputs).perform
        # make sure the configuration step completed without error, otherwise abort submission
        if configuration_response[:complete]
          logger.info "#{Time.now}: Creating submission for #{sample} using #{configuration_response[:configuration_namespace]}/#{configuration_response[:configuration_name]} in #{@study.firecloud_project}/#{@study.firecloud_workspace}"
          @submissions << client.create_workspace_submission(@study.firecloud_project, @study.firecloud_workspace, configuration_response[:configuration_namespace], configuration_response[:configuration_name], 'sample', sample)
        else
          logger.error "#{Time.now}: Unable to submit #{sample} using #{config_namespace}/#{config_name} in #{@study.firecloud_project}/#{@study.firecloud_workspace}; logging error"
          @failed_submissions << configuration_response
        end
      end
    rescue => e
      logger.error "#{Time.now}: unable to submit workflow #{workflow_name} for sample #{samples.join(', ')} in #{@study.firecloud_workspace} due to: #{e.message}"
      @alert = "We were unable to submit your workflow due to an error: #{e.message}"
      render action: :notice
    end
  end

  # get a submission workflow object as JSON
  def get_submission_workflow
    begin
      submission = Study.firecloud_client.get_workspace_submission(@study.firecloud_project, @study.firecloud_workspace, params[:submission_id])
      render json: submission.to_json
    rescue => e
      logger.error "#{Time.now}: unable to load workspace submission #{params[:submission_id]} in #{@study.firecloud_workspace} due to: #{e.message}"
      render js: "alert('We were unable to load the requested submission due to an error: #{e.message}')"
    end
  end

  # abort a pending workflow submission
  def abort_submission_workflow
    @submission_id = params[:submission_id]
    begin
      Study.firecloud_client.abort_workspace_submission(@study.firecloud_project, @study.firecloud_workspace, @submission_id)
      @notice = "Submission #{@submission_id} was successfully aborted."

    rescue => e
      @alert = "Unable to abort submission #{@submission_id} due to an error: #{e.message}"
      render action: :notice
    end
  end

  # get errors for a failed submission
  def get_submission_errors
    begin
      workflow_ids = params[:workflow_ids].split(',')
      errors = []
      # first check workflow messages - if there was an issue with inputs, errors could be here
      submission = Study.firecloud_client.get_workspace_submission(@study.firecloud_project, @study.firecloud_workspace, params[:submission_id])
      submission['workflows'].each do |workflow|
        if workflow['messages'].any?
          workflow['messages'].each {|message| errors << message}
        end
      end
      # now look at each individual workflow object
      workflow_ids.each do |workflow_id|
        workflow = Study.firecloud_client.get_workspace_submission_workflow(@study.firecloud_project, @study.firecloud_workspace, params[:submission_id], workflow_id)
        # failure messages are buried deeply within the workflow object, so we need to go through each to find them
        workflow['failures'].each do |workflow_failure|
          errors << workflow_failure['message']
          # sometimes there are extra errors nested below...
          if workflow_failure['causedBy'].any?
            workflow_failure['causedBy'].each do |failure|
              errors << failure['message']
            end
          end
        end
      end
      @error_message = errors.join("<br />")
    rescue => e
      @alert = "Unable to retrieve submission #{@submission_id} error messages due to: #{e.message}"
      render action: :notice
    end
  end

  # get outputs from a requested submission
  def get_submission_outputs
    begin
      @outputs = []
      submission = Study.firecloud_client.get_workspace_submission(@study.firecloud_project, @study.firecloud_workspace, params[:submission_id])
      submission['workflows'].each do |workflow|
        workflow = Study.firecloud_client.get_workspace_submission_workflow(@study.firecloud_project, @study.firecloud_workspace, params[:submission_id], workflow['workflowId'])
        workflow['outputs'].each do |output, file_url|
          display_name = file_url.split('/').last
          file_location = file_url.gsub(/gs\:\/\/#{@study.bucket_id}\//, '')
          output = {display_name: display_name, file_location: file_location}
          @outputs << output
        end
      end
    rescue => e
      @alert = "Unable to retrieve submission #{@submission_id} outputs due to: #{e.message}"
      render action: :notice
    end
  end

  # retrieve a submission analysis metadata file
  def get_submission_metadata
    begin
      submission = Study.firecloud_client.get_workspace_submission(@study.firecloud_project, @study.firecloud_workspace, params[:submission_id])
      if submission.present?
        # check to see if we already have an analysis_metadatum object
        @metadata = AnalysisMetadatum.find_by(study_id: @study.id, submission_id: params[:submission_id])
        if @metadata.nil?
          metadata_attr = {
              name: submission['methodConfigurationName'],
              submission_id: params[:submission_id],
              study_id: @study.id,
              version: '4.6.1'
          }
          @metadata = AnalysisMetadatum.create!(metadata_attr)
        end
      else
        @alert = "We were unable to locate submission '#{params[:submission_id]}'.  Please check the ID and try again."
        render action: :notice
      end
    rescue => e
      @alert = "An error occurred trying to load submission '#{params[:submission_id]}': #{e.message}"
      render action: :notice
    end
  end

  # export a submission analysis metadata file
  def export_submission_metadata
    @metadata = AnalysisMetadatum.find_by(study_id: @study.id, submission_id: params[:submission_id])
    respond_to do |format|
      format.html {send_data JSON.pretty_generate(@metadata.payload), content_type: :json, filename: 'analysis.json'}
      format.json {render json: @metadata.payload}
    end

  end

  # delete all files from a submission
  def delete_submission_files
    begin
      # first, add submission to list of 'deleted_submissions' in workspace attributes (will hide submission in list)
      workspace = Study.firecloud_client.get_workspace(@study.firecloud_project, @study.firecloud_workspace)
      ws_attributes = workspace['workspace']['attributes']
      if ws_attributes['deleted_submissions'].blank?
        ws_attributes['deleted_submissions'] = [params[:submission_id]]
      else
        ws_attributes['deleted_submissions']['items'] << params[:submission_id]
      end
      logger.info "#{Time.now}: adding #{params[:submission_id]} to workspace delete_submissions attribute in #{@study.firecloud_workspace}"
      Study.firecloud_client.set_workspace_attributes(@study.firecloud_project, @study.firecloud_workspace, ws_attributes)
      logger.info "#{Time.now}: deleting analysis metadata for #{params[:submission_id]} in #{@study.url_safe_name}"
      AnalysisMetadatum.where(submission_id: params[:submission_id]).delete
      logger.info "#{Time.now}: queueing submission #{params[:submission]} deletion in #{@study.firecloud_workspace}"
      submission_files = Study.firecloud_client.execute_gcloud_method(:get_workspace_files, @study.firecloud_project, @study.firecloud_workspace, prefix: params[:submission_id])
      DeleteQueueJob.new(submission_files).perform
    rescue => e
      logger.error "#{Time.now}: unable to remove submission #{params[:submission_id]} files from #{@study.firecloud_workspace} due to: #{e.message}"
      @alert = "Unable to delete the outputs for #{params[:submission_id]} due to the following error: #{e.message}"
      render action: :notice
    end
  end

  ###
  #
  # MISCELLANEOUS METHODS
  #
  ###

  # route that is used to log actions in Google Analytics that would otherwise be ignored due to redirects or response types
  def log_action
    @action_to_log = params[:url_string]
  end

  private

  ###
  #
  # SETTERS
  #
  ###

  def set_study
    @study = Study.find_by(url_safe_name: params[:study_name])
    # redirect if study is not found
    if @study.nil?
      redirect_to merge_default_redirect_params(site_path, scpbr: params[:scpbr]), alert: 'Study not found.  Please check the name and try again.' and return
    end
  end

  def set_cluster_group
    # determine which URL param to use for selection
    selector = params[:cluster].nil? ? params[:gene_set_cluster] : params[:cluster]
    if selector.nil? || selector.empty?
      @cluster = @study.default_cluster
    else
      @cluster = @study.cluster_groups.by_name(selector)
    end
  end

  def set_selected_annotation
    # determine which URL param to use for selection and construct base object
    selector = params[:annotation].nil? ? params[:gene_set_annotation] : params[:annotation]
    annot_name, annot_type, annot_scope = selector.nil? ? @study.default_annotation.split('--') : selector.split('--')
    # construct object based on name, type & scope
    if annot_scope == 'cluster'
      @selected_annotation = @cluster.cell_annotations.find {|ca| ca[:name] == annot_name && ca[:type] == annot_type}
      @selected_annotation[:scope] = annot_scope
    elsif annot_scope == 'user'
      # in the case of user annotations, the 'name' value that gets passed is actually the ID
      user_annotation = UserAnnotation.find(annot_name)
      @selected_annotation = {name: user_annotation.name, type: annot_type, scope: annot_scope, id: annot_name}
      @selected_annotation[:values] = user_annotation.values
    else
      @selected_annotation = {name: annot_name, type: annot_type, scope: annot_scope}
      if annot_type == 'group'
        @selected_annotation[:values] = @study.cell_metadata.by_name_and_type(annot_name, annot_type).values
      else
        @selected_annotation[:values] = []
      end
    end
    @selected_annotation
  end

  # create/retrieve a workflow configuration object in a workspace prior to submitting a workflow
  def set_workflow_configuration(workflow_name, workflow_namespace, workflow_snapshot)
    # create a unique identifier for the configuration (combination of name & snapshot ID)
    ws_config_name = [workflow_name, workflow_snapshot].join('_')
    config_namespace = ""
    config_name = ""
    logger.info "#{Time.now}: checking for existing workspace configurations in #{@study.firecloud_project}/#{@study.firecloud_workspace}"
    workspace_configs = Study.firecloud_client.get_workspace_configurations(@study.firecloud_project, @study.firecloud_workspace)
    matching_ws_config = workspace_configs.find {|config| config['methodRepoMethod']['methodName'] == workflow_name && config['methodRepoMethod']['methodNamespace'] == workflow_namespace && config['methodRepoMethod']['methodVersion'] == workflow_snapshot.to_i}
    if matching_ws_config.present?
      submission_config = Study.firecloud_client.get_workspace_configuration(@study.firecloud_project, @study.firecloud_workspace, matching_ws_config['namespace'], matching_ws_config['name'])
      logger.info "#{Time.now}: found existing configuration #{ws_config_name} in #{@study.firecloud_workspace}"
      config_namespace = submission_config['namespace']
      config_name = submission_config['name']
    else
      logger.info "#{Time.now}: No existing configuration found for #{ws_config_name} in #{@study.firecloud_workspace}; copying from repository"
      # we did not find a configuration, so we must copy the public one from the repository
      # first check for a public configuration in 'scp-pipeline-configurations'
      existing_configs = Study.firecloud_client.get_configurations(namespace: 'scp-pipeline-configurations', name: workflow_name)
      if existing_configs.empty?
        # check for configurations in the workflow namespace next
        existing_configs = Study.firecloud_client.get_configurations(namespace: workflow_namespace, name: workflow_name)
      end
      matching_config = existing_configs.find {|config| config['method']['name'] == workflow_name && config['method']['namespace'] == workflow_namespace && config['method']['snapshotId'] == workflow_snapshot.to_i}
      if matching_config.present?
        logger.info "#{Time.now}: Found matching configuration: #{matching_config['namespace']}/#{matching_config['name']}"
        new_config = Study.firecloud_client.copy_configuration_to_workspace(@study.firecloud_project, @study.firecloud_workspace, matching_config['namespace'], matching_config['name'], matching_config['snapshotId'], @study.firecloud_project, ws_config_name)
        config_namespace = new_config['methodConfiguration']['namespace']
        config_name = new_config['methodConfiguration']['name']
      else
        # no matching configurations were present, so create a blank template and configure later
        logger.info "#{Time.now}: No configurations found, creating blank template for #{workflow_namespace}/#{workflow_name}"
        config_template = Study.firecloud_client.create_configuration_template(workflow_namespace, workflow_name, workflow_snapshot.to_i)
        # configure name, namespace and rootEntityType
        config_template['name'] = ws_config_name
        config_template['namespace'] = workflow_namespace
        config_template['rootEntityType'] = 'sample'
        new_config = Study.firecloud_client.create_workspace_configuration(@study.firecloud_project, @study.firecloud_workspace, config_template)
        config_namespace = new_config['methodConfiguration']['namespace']
        config_name = new_config['methodConfiguration']['name']
      end
    end
    # return new configuration namespace & name
    [config_namespace, config_name]
  end

  # whitelist parameters for updating studies on study settings tab (smaller list than in studies controller)
  def study_params
    params.require(:study).permit(:name, :description, :public, :embargo, :cell_count, :default_options => [:cluster, :annotation, :color_profile, :expression_label, :deliver_emails, :cluster_point_size, :cluster_point_alpha, :cluster_point_border], study_shares_attributes: [:id, :_destroy, :email, :permission])
  end

  # whitelist parameters for creating custom user annotation
  def user_annotation_params
    params.require(:user_annotation).permit(:_id, :name, :study_id, :user_id, :cluster_group_id, :subsample_threshold, :loaded_annotation, :subsample_annotation, user_data_arrays_attributes: [:name, :values])
  end

  # make sure user has view permissions for selected study
  def check_view_permissions
    unless @study.public?
      if (!user_signed_in? && !@study.public?) || (user_signed_in? && !@study.can_view?(current_user))
        alert = 'You do not have permission to view the requested page.'
        respond_to do |format|
          format.js {render js: "alert('#{alert}')" and return}
          format.html {redirect_to merge_default_redirect_params(site_path, scpbr: params[:scpbr]), alert: alert and return}
        end
      end
    end
  end

  # check compute permissions for study
  def check_compute_permissions
    if !user_signed_in? || !@study.can_compute?(current_user)
      @alert ='You do not have permission to perform that action.'
      respond_to do |format|
        format.js {render action: :notice}
        format.html {redirect_to merge_default_redirect_params(site_path, scpbr: params[:scpbr]), alert: @alert and return}
        format.json {head 403}
      end
    end
  end

  # check permissions manually on AJAX call via authentication token
  def check_xhr_view_permissions
    unless @study.public?
      if params[:request_user_token].nil?
        return false
      else
        request_user_id, auth_token = params[:request_user_token].split(':')
        request_user = User.find_by(id: request_user_id, authentication_token: auth_token)
        unless !request_user.nil? && @study.can_view?(request_user)
          return false
        end
      end
      return true
    else
      return true
    end
  end

  ###
  #
  # DATA FORMATTING SUB METHODS
  #
  ###

  # generic method to populate data structure to render a cluster scatter plot
  # uses cluster_group model and loads annotation for both group & numeric plots
  # data values are pulled from associated data_array entries for each axis and annotation/text value
  def load_cluster_group_data_array_points(annotation, subsample_threshold=nil)
    # construct annotation key to load subsample data_arrays if needed, will be identical to params[:annotation]
    subsample_annotation = "#{annotation[:name]}--#{annotation[:type]}--#{annotation[:scope]}"
    # load data - passing nil for subsample_threshold automatically loads all values
    x_array = @cluster.concatenate_data_arrays('x', 'coordinates', subsample_threshold, subsample_annotation)
    y_array = @cluster.concatenate_data_arrays('y', 'coordinates', subsample_threshold, subsample_annotation)
    z_array = @cluster.concatenate_data_arrays('z', 'coordinates', subsample_threshold, subsample_annotation)
    cells = @cluster.concatenate_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    annotation_array = []
    annotation_hash = {}
    # Construct the arrays based on scope
    if annotation[:scope] == 'cluster'
      annotation_array = @cluster.concatenate_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
    elsif annotation[:scope] == 'user'
      # for user annotations, we have to load by id as names may not be unique to clusters
      user_annotation = UserAnnotation.find(annotation[:id])
      subsample_annotation = user_annotation.formatted_annotation_identifier
      annotation_array = user_annotation.concatenate_user_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      x_array = user_annotation.concatenate_user_data_arrays('x', 'coordinates', subsample_threshold, subsample_annotation)
      y_array = user_annotation.concatenate_user_data_arrays('y', 'coordinates', subsample_threshold, subsample_annotation)
      z_array = user_annotation.concatenate_user_data_arrays('z', 'coordinates', subsample_threshold, subsample_annotation)
      cells = user_annotation.concatenate_user_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    else
      # for study-wide annotations, load from study_metadata values instead of cluster-specific annotations
      metadata_obj = @study.cell_metadata.by_name_and_type(annotation[:name], annotation[:type])
      annotation_hash = metadata_obj.cell_annotations
      annotation[:values] = metadata_obj.values
    end
    coordinates = {}
    if annotation[:type] == 'numeric'
      text_array = []
      color_array = []
      # load text & color value from correct object depending on annotation scope
      cells.each_with_index do |cell, index|
        if annotation[:scope] == 'cluster'
          val = annotation_array[index]
          text_array << "#{cell}: (#{val})"
        else
          val = annotation_hash[cell]
          text_array <<  "#{cell}: (#{val})"
          color_array << val
        end
      end
      # if we didn't assign anything to the color array, we know the annotation_array is good to use
      color_array.empty? ? color_array = annotation_array : nil
      coordinates[:all] = {
          x: x_array,
          y: y_array,
          annotations: annotation[:scope] == 'cluster' ? annotation_array : annotation_hash[:values],
          text: text_array,
          cells: cells,
          name: annotation[:name],
          marker: {
              cmax: annotation_array.max,
              cmin: annotation_array.min,
              color: color_array,
              size: color_array.map {|a| @study.default_cluster_point_size},
              line: { color: 'rgb(40,40,40)', width: @study.show_cluster_point_borders? ? 0.5 : 0},
              colorscale: 'Reds',
              showscale: true,
              colorbar: {
                  title: annotation[:name] ,
                  titleside: 'right'
              }
          }
      }
      if @cluster.is_3d?
        coordinates[:all][:z] = z_array
      end
    else
      # assemble containers for each trace
      annotation[:values].each do |value|
        coordinates[value] = {x: [], y: [], text: [], cells: [], annotations: [], name: "#{annotation[:name]}: #{value}", marker_size: []}
        if @cluster.is_3d?
          coordinates[value][:z] = []
        end
      end

      if annotation[:scope] == 'cluster' || annotation[:scope] == 'user'
        annotation_array.each_with_index do |annotation_value, index|
          coordinates[annotation_value][:text] << "<b>#{cells[index]}</b><br>#{annotation[:name]}: #{annotation_value}"
          coordinates[annotation_value][:annotations] << "#{annotation[:name]}: #{annotation_value}"
          coordinates[annotation_value][:cells] << cells[index]
          coordinates[annotation_value][:x] << x_array[index]
          coordinates[annotation_value][:y] << y_array[index]
          if @cluster.cluster_type == '3d'
            coordinates[annotation_value][:z] << z_array[index]
          end
          coordinates[annotation_value][:marker_size] << @study.default_cluster_point_size
        end
        coordinates.each do |key, data|
          data[:name] << " (#{data[:x].size} points)"
        end
      else
        cells.each_with_index do |cell, index|
          if annotation_hash.has_key?(cell)
            annotation_value = annotation_hash[cell]
            coordinates[annotation_value][:text] << "<b>#{cell}</b><br>#{annotation[:name]}: #{annotation_value}"
            coordinates[annotation_value][:annotations] << "#{annotation[:name]}: #{annotation_value}"
            coordinates[annotation_value][:x] << x_array[index]
            coordinates[annotation_value][:y] << y_array[index]
            coordinates[annotation_value][:cells] << cell
            if @cluster.cluster_type == '3d'
              coordinates[annotation_value][:z] << z_array[index]
            end
            coordinates[annotation_value][:marker_size] << @study.default_cluster_point_size
          end
        end
        coordinates.each do |key, data|
          data[:name] << " (#{data[:x].size} points)"
        end

      end

    end
    # gotcha to remove entries in case a particular annotation value comes up blank since this is study-wide
    coordinates.delete_if {|key, data| data[:x].empty?}
    coordinates
  end

  # method to load a 2-d scatter of selected numeric annotation vs. gene expression
  def load_annotation_based_data_array_scatter(annotation, subsample_threshold=nil)
    # construct annotation key to load subsample data_arrays if needed, will be identical to params[:annotation]
    subsample_annotation = "#{annotation[:name]}--#{annotation[:type]}--#{annotation[:scope]}"
    cells = @cluster.concatenate_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    annotation_array = []
    annotation_hash = {}
    if annotation[:scope] == 'cluster'
      annotation_array = @cluster.concatenate_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
    elsif annotation[:scope] == 'user'
      # for user annotations, we have to load by id as names may not be unique to clusters
      user_annotation = UserAnnotation.find(annotation[:id])
      subsample_annotation = user_annotation.formatted_annotation_identifier
      annotation_array = user_annotation.concatenate_user_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      cells = user_annotation.concatenate_user_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    else
      metadata_obj = @study.cell_metadata.by_name_and_type(annotation[:name], annotation[:type])
      annotation_hash = metadata_obj.cell_annotations
    end
    values = {}
    values[:all] = {x: [], y: [], cells: [], annotations: [], text: [], marker_size: []}
    if annotation[:scope] == 'cluster' || annotation[:scope] == 'user'
      annotation_array.each_with_index do |annot, index|
        annotation_value = annot
        cell_name = cells[index]
        expression_value = @gene['scores'][cell_name].to_f.round(4)

        values[:all][:text] << "<b>#{cell_name}</b><br>#{annotation[:name]}: #{annotation_value}<br>#{@y_axis_title}: #{expression_value}"
        values[:all][:annotations] << "#{annotation[:name]}: #{annotation_value}"
        values[:all][:x] << annotation_value
        values[:all][:y] << expression_value
        values[:all][:cells] << cell_name
        values[:all][:marker_size] << @study.default_cluster_point_size
      end
    else
      cells.each do |cell|
        if annotation_hash.has_key?(cell)
          annotation_value = annotation_hash[cell]
          expression_value = @gene['scores'][cell].to_f.round(4)
          values[:all][:text] << "<b>#{cell}</b><br>#{annotation[:name]}: #{annotation_value}<br>#{@y_axis_title}: #{expression_value}"
          values[:all][:annotations] << "#{annotation[:name]}: #{annotation_value}"
          values[:all][:x] << annotation_value
          values[:all][:y] << expression_value
          values[:all][:cells] << cell
          values[:all][:marker_size] << @study.default_cluster_point_size
        end
      end
    end
    values
  end

  # method to load a 2-d scatter of selected numeric annotation vs. gene set expression
  # will support a variety of consensus modes (default is mean)
  def load_gene_set_annotation_based_scatter(annotation, consensus, subsample_threshold=nil)
    # construct annotation key to load subsample data_arrays if needed, will be identical to params[:annotation]
    subsample_annotation = "#{annotation[:name]}--#{annotation[:type]}--#{annotation[:scope]}"
    values = {}
    values[:all] = {x: [], y: [], cells: [], annotations: [], text: [], marker_size: []}
    cells = @cluster.concatenate_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    annotation_array = []
    annotation_hash = {}
    if annotation[:scope] == 'cluster'
      annotation_array = @cluster.concatenate_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
    elsif annotation[:scope] == 'user'
      # for user annotations, we have to load by id as names may not be unique to clusters
      user_annotation = UserAnnotation.find(annotation[:id])
      subsample_annotation = user_annotation.formatted_annotation_identifier
      annotation_array = user_annotation.concatenate_user_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      cells = user_annotation.concatenate_user_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    else
      metadata_obj = @study.cell_metadata.by_name_and_type(annotation[:name], annotation[:type])
      annotation_hash = metadata_obj.cell_annotations
    end
    cells.each_with_index do |cell, index|
      annotation_value = annotation[:scope] == 'cluster' ? annotation_array[index] : annotation_hash[cell]
      if !annotation_value.nil?
        case consensus
          when 'mean'
            expression_value = calculate_mean(@genes, cell)
          when 'median'
            expression_value = calculate_median(@genes, cell)
          else
            expression_value = calculate_mean(@genes, cell)
        end
        values[:all][:text] << "<b>#{cell}</b><br>#{annotation[:name]}: #{annotation_value}<br>#{@y_axis_title}: #{expression_value}"
        values[:all][:annotations] << "#{annotation[:name]}: #{annotation_value}"
        values[:all][:x] << annotation_value
        values[:all][:y] << expression_value
        values[:all][:cells] << cell
        values[:all][:marker_size] << @study.default_cluster_point_size
        end
    end
    values
  end

  # load box plot scores from gene expression values using data array of cell names for given cluster
  def load_expression_boxplot_data_array_scores(annotation, subsample_threshold=nil)
    # construct annotation key to load subsample data_arrays if needed, will be identical to params[:annotation]
    subsample_annotation = "#{annotation[:name]}--#{annotation[:type]}--#{annotation[:scope]}"
    values = initialize_plotly_objects_by_annotation(annotation)

    # grab all cells present in the cluster, and use as keys to load expression scores
    # if a cell is not present for the gene, score gets set as 0.0
    cells = @cluster.concatenate_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    if annotation[:scope] == 'cluster'
      # we can take a subsample of the same size for the annotations since the sort order is non-stochastic (i.e. the indices chosen are the same every time for all arrays)
      annotations = @cluster.concatenate_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      cells.each_with_index do |cell, index|
        values[annotations[index]][:y] << @gene['scores'][cell].to_f.round(4)
      end
    elsif annotation[:scope] == 'user'
      # for user annotations, we have to load by id as names may not be unique to clusters
      user_annotation = UserAnnotation.find(annotation[:id])
      subsample_annotation = user_annotation.formatted_annotation_identifier
      annotations = user_annotation.concatenate_user_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      cells = user_annotation.concatenate_user_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
      cells.each_with_index do |cell, index|
        values[annotations[index]][:y] << @gene['scores'][cell].to_f.round(4)
      end
    else
      # since annotations are in a hash format, subsampling isn't necessary as we're going to retrieve values by key lookup
      annotations =  @study.cell_metadata.by_name_and_type(annotation[:name], annotation[:type]).cell_annotations
      cells.each do |cell|
        val = annotations[cell]
        # must check if key exists
        if values.has_key?(val)
          values[annotations[cell]][:y] << @gene['scores'][cell].to_f.round(4)
          values[annotations[cell]][:cells] << cell
        end
      end
    end
    # remove any empty values as annotations may have created keys that don't exist in cluster
    values.delete_if {|key, data| data[:y].empty?}
    values
  end

  # load cluster_group data_array values, but use expression scores to set numerical color array
  def load_expression_data_array_points(annotation, subsample_threshold=nil)
    # construct annotation key to load subsample data_arrays if needed, will be identical to params[:annotation]
    subsample_annotation = "#{annotation[:name]}--#{annotation[:type]}--#{annotation[:scope]}"
    x_array = @cluster.concatenate_data_arrays('x', 'coordinates', subsample_threshold, subsample_annotation)
    y_array = @cluster.concatenate_data_arrays('y', 'coordinates', subsample_threshold, subsample_annotation)
    z_array = @cluster.concatenate_data_arrays('z', 'coordinates', subsample_threshold, subsample_annotation)
    cells = @cluster.concatenate_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    annotation_array = []
    annotation_hash = {}
    if annotation[:scope] == 'cluster'
      annotation_array = @cluster.concatenate_data_arrays(annotation[:name], 'annotations', subsample_threshold)
    elsif annotation[:scope] == 'user'
      # for user annotations, we have to load by id as names may not be unique to clusters
      user_annotation = UserAnnotation.find(annotation[:id])
      subsample_annotation = user_annotation.formatted_annotation_identifier
      annotation_array = user_annotation.concatenate_user_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      x_array = user_annotation.concatenate_user_data_arrays('x', 'coordinates', subsample_threshold, subsample_annotation)
      y_array = user_annotation.concatenate_user_data_arrays('y', 'coordinates', subsample_threshold, subsample_annotation)
      z_array = user_annotation.concatenate_user_data_arrays('z', 'coordinates', subsample_threshold, subsample_annotation)
      cells = user_annotation.concatenate_user_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    else
      # for study-wide annotations, load from cell_metadata values instead of cluster-specific annotations
      metadata_obj = @study.cell_metadata.by_name_and_type(annotation[:name], annotation[:type])
      annotation_hash = metadata_obj.cell_annotations
    end
    expression = {}
    expression[:all] = {
        x: x_array,
        y: y_array,
        annotations: [],
        text: [],
        cells: cells,
        marker: {cmax: 0, cmin: 0, color: [], size: [], showscale: true, colorbar: {title: @y_axis_title , titleside: 'right'}}
    }
    if @cluster.is_3d?
      expression[:all][:z] = z_array
    end
    cells.each_with_index do |cell, index|
      expression_score = @gene['scores'][cell].to_f.round(4)
      # load correct annotation value based on scope
      annotation_value = annotation[:scope] == 'cluster' ? annotation_array[index] : annotation_hash[cell]
      text_value = "#{cell} (#{annotation[:name]}: #{annotation_value})<br />#{@y_axis_title}: #{expression_score}"
      expression[:all][:annotations] << "#{annotation[:name]}: #{annotation_value}"
      expression[:all][:text] << text_value
      expression[:all][:marker][:color] << expression_score
      expression[:all][:marker][:size] << @study.default_cluster_point_size
    end
    expression[:all][:marker][:line] = { color: 'rgb(255,255,255)', width: @study.show_cluster_point_borders? ? 0.5 : 0}
    color_minmax =  expression[:all][:marker][:color].minmax
    expression[:all][:marker][:cmin], expression[:all][:marker][:cmax] = color_minmax
    expression[:all][:marker][:colorscale] = 'Reds'
    expression
  end

  # load boxplot expression scores vs. scores across each gene for all cells
  # will support a variety of consensus modes (default is mean)
  def load_gene_set_expression_boxplot_scores(annotation, consensus, subsample_threshold=nil)
    values = initialize_plotly_objects_by_annotation(annotation)
    # construct annotation key to load subsample data_arrays if needed, will be identical to params[:annotation]
    subsample_annotation = "#{annotation[:name]}--#{annotation[:type]}--#{annotation[:scope]}"
    # grab all cells present in the cluster, and use as keys to load expression scores
    # if a cell is not present for the gene, score gets set as 0.0
    # will check if there are more than SUBSAMPLE_THRESHOLD cells present in the cluster, and subsample accordingly
    # values hash will be assembled differently depending on annotation scope (cluster-based is array, study-based is a hash)
    cells = @cluster.concatenate_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    if annotation[:scope] == 'cluster'
      annotations = @cluster.concatenate_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      cells.each_with_index do |cell, index|
        values[annotations[index]][:annotations] << annotations[index]
        case consensus
          when 'mean'
            values[annotations[index]][:y] << calculate_mean(@genes, cell)
          when 'median'
            values[annotations[index]][:y] << calculate_median(@genes, cell)
          else
            values[annotations[index]][:y] << calculate_mean(@genes, cell)
        end
      end
    elsif annotation[:scope] == 'user'
      # for user annotations, we have to load by id as names may not be unique to clusters
      user_annotation = UserAnnotation.find(annotation[:id])
      subsample_annotation = user_annotation.formatted_annotation_identifier
      annotations = user_annotation.concatenate_user_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      cells = user_annotation.concatenate_user_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
      cells.each_with_index do |cell, index|
        values[annotations[index]][:annotations] << annotations[index]
        case consensus
          when 'mean'
            values[annotations[index]][:y] << calculate_mean(@genes, cell)
          when 'median'
            values[annotations[index]][:y] << calculate_median(@genes, cell)
          else
            values[annotations[index]][:y] << calculate_mean(@genes, cell)
        end
      end
    else
      # no need to subsample annotation since they are in hash format (lookup done by key)
      annotations =  @study.cell_metadata.by_name_and_type(annotation[:name], annotation[:type]).cell_annotations
      cells.each do |cell|
        val = annotations[cell]
        # must check if key exists
        if values.has_key?(val)
          values[annotations[cell]][:cells] << cell
          case consensus
            when 'mean'
              values[annotations[cell]][:y] << calculate_mean(@genes, cell)
            when 'median'
              values[annotations[cell]][:y] << calculate_median(@genes, cell)
            else
              values[annotations[cell]][:y] << calculate_mean(@genes, cell)
          end
        end
      end
    end
    # remove any empty values as annotations may have created keys that don't exist in cluster
    values.delete_if {|key, data| data[:y].empty?}
    values
  end

  # load scatter expression scores with average of scores across each gene for all cells
  # uses data_array as source for each axis
  # will support a variety of consensus modes (default is mean)
  def load_gene_set_expression_data_arrays(annotation, consensus, subsample_threshold=nil)
    # construct annotation key to load subsample data_arrays if needed, will be identical to params[:annotation]
    subsample_annotation = "#{annotation[:name]}--#{annotation[:type]}--#{annotation[:scope]}"

    x_array = @cluster.concatenate_data_arrays('x', 'coordinates', subsample_threshold, subsample_annotation)
    y_array = @cluster.concatenate_data_arrays('y', 'coordinates', subsample_threshold, subsample_annotation)
    z_array = @cluster.concatenate_data_arrays('z', 'coordinates', subsample_threshold, subsample_annotation)
    cells = @cluster.concatenate_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    annotation_array = []
    annotation_hash = {}
    if annotation[:scope] == 'cluster'
      annotation_array = @cluster.concatenate_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
    elsif annotation[:scope] == 'user'
      # for user annotations, we have to load by id as names may not be unique to clusters
      user_annotation = UserAnnotation.find(annotation[:id])
      subsample_annotation = user_annotation.formatted_annotation_identifier
      annotation_array = user_annotation.concatenate_user_data_arrays(annotation[:name], 'annotations', subsample_threshold, subsample_annotation)
      x_array = user_annotation.concatenate_user_data_arrays('x', 'coordinates', subsample_threshold, subsample_annotation)
      y_array = user_annotation.concatenate_user_data_arrays('y', 'coordinates', subsample_threshold, subsample_annotation)
      z_array = user_annotation.concatenate_user_data_arrays('z', 'coordinates', subsample_threshold, subsample_annotation)
      cells = user_annotation.concatenate_user_data_arrays('text', 'cells', subsample_threshold, subsample_annotation)
    else
      # for study-wide annotations, load from cell_metadata values instead of cluster-specific annotations
      metadata_obj = @study.cell_metadata.by_name_and_type(annotation[:name], annotation[:type])
      annotation_hash = metadata_obj.cell_annotations
    end
    expression = {}
    expression[:all] = {
        x: x_array,
        y: y_array,
        text: [],
        annotations: [],
        cells: cells,
        marker: {cmax: 0, cmin: 0, color: [], size: [], showscale: true, colorbar: {title: @y_axis_title , titleside: 'right'}}
    }
    if @cluster.is_3d?
      expression[:all][:z] = z_array
    end
    cells.each_with_index do |cell, index|
      case consensus
        when 'mean'
          expression_score = calculate_mean(@genes, cell)
        when 'median'
          expression_score = calculate_median(@genes, cell)
        else
          expression_score = calculate_mean(@genes, cell)
      end

      # load correct annotation value based on scope
      annotation_value = annotation[:scope] == 'cluster' ? annotation_array[index] : annotation_hash[cell]
      text_value = "#{cell} (#{annotation[:name]}: #{annotation_value})<br />#{@y_axis_title}: #{expression_score}"
      expression[:all][:annotations] << "#{annotation[:name]}: #{annotation_value}"
      expression[:all][:text] << text_value
      expression[:all][:marker][:color] << expression_score

      expression[:all][:marker][:size] << @study.default_cluster_point_size
    end
    expression[:all][:marker][:line] = { color: 'rgb(40,40,40)', width: @study.show_cluster_point_borders? ? 0.5 : 0}
    color_minmax =  expression[:all][:marker][:color].minmax
    expression[:all][:marker][:cmin], expression[:all][:marker][:cmax] = color_minmax
    expression[:all][:marker][:colorscale] = 'Reds'
    expression
  end

  # method to initialize containers for plotly by annotation values
  def initialize_plotly_objects_by_annotation(annotation)
    values = {}
    annotation[:values].each do |value|
      values["#{value}"] = {y: [], cells: [], annotations: [], name: "#{value}" }
    end
    values
  end

  # load custom coordinate-based annotation labels for a given cluster
  def load_cluster_group_coordinate_labels
    # assemble source data
    x_array = @cluster.concatenate_data_arrays('x', 'labels')
    y_array = @cluster.concatenate_data_arrays('y', 'labels')
    z_array = @cluster.concatenate_data_arrays('z', 'labels')
    text_array = @cluster.concatenate_data_arrays('text', 'labels')
    annotations = []
    # iterate through list of data objects to construct necessary annotations
    x_array.each_with_index do |point, index|
      annotations << {
          showarrow: false,
          x: point,
          y: y_array[index],
          z: z_array[index],
          text: text_array[index],
          font: {
              family: @cluster.coordinate_labels_options[:font_family],
              size: @cluster.coordinate_labels_options[:font_size],
              color: @cluster.coordinate_labels_options[:font_color]
          }
      }
    end
    annotations
  end

  # find mean of expression scores for a given cell & list of genes
  def calculate_mean(genes, cell)
    values = genes.map {|gene| gene['scores'][cell].to_f}
    values.mean
  end

  # find median expression score for a given cell & list of genes
  def calculate_median(genes, cell)
    values = genes.map {|gene| gene['scores'][cell].to_f}
    Gene.array_median(values)
  end

  # set the range for a plotly scatter, will default to data-defined if cluster hasn't defined its own ranges
  # dynamically determines range based on inputs & available axes
  def set_range(inputs)
    # select coordinate axes from inputs
    domain_keys = inputs.map(&:keys).flatten.uniq.select {|i| [:x, :y, :z].include?(i)}
    range = Hash[domain_keys.zip]
    if @cluster.has_range?
      # use study-provided range if available
      range = @cluster.domain_ranges
    else
      # take the minmax of each domain across all groups, then the global minmax
      @vals = inputs.map {|v| domain_keys.map {|k| v[k].minmax}}.flatten.minmax
      # add 2% padding to range
      scope = (@vals.first - @vals.last) * 0.02
      raw_range = [@vals.first + scope, @vals.last - scope]
      range[:x] = raw_range
      range[:y] = raw_range
      range[:z] = raw_range
    end
    range
  end

  # compute the aspect ratio between all ranges and use to enforce equal-aspect ranges on 3d plots
  def compute_aspect_ratios(range)
    # determine largest range for computing aspect ratio
    extent = {}
    range.each.map {|axis, domain| extent[axis] = domain.first.upto(domain.last).size - 1}
    largest_range = extent.values.max

    # now compute aspect mode and ratios
    aspect = {
        mode: extent.values.uniq.size == 1 ? 'cube' : 'manual'
    }
    range.each_key do |axis|
      aspect[axis.to_sym] = extent[axis].to_f / largest_range
    end
    aspect
  end

  ###
  #
  # SEARCH SUB METHODS
  #
  ###

  # generic search term parser
  def parse_search_terms(key)
    terms = params[:search][key]
    if terms.is_a?(Array)
      terms.first.split(/[\s\n,]/).map(&:strip)
    else
      terms.split(/[\s\n,]/).map(&:strip)
    end
  end

  # generic expression score getter, preserves order and discards empty matches
  def load_expression_scores(terms)
    genes = []
    matrix_ids = @study.expression_matrix_files.map(&:id)
    terms.each do |term|
      matches = @study.genes.by_name(term, matrix_ids)
      unless matches.empty?
        genes << load_best_gene_match(matches, term)
      end
    end
    genes
  end

  # search genes and save terms not found.  does not actually load expression scores to improve search speed,
  # but rather just matches gene names if possible.  to load expression values, use load_expression_scores
  def search_expression_scores(terms)
    genes = []
    not_found = []
    known_genes = @study.genes.unique_genes
    known_searchable_genes = known_genes.map(&:downcase)
    terms.each do |term|
      if known_genes.include?(term) || known_searchable_genes.include?(term)
        genes << {'name' => term}
      else
        not_found << {'name' => term}
      end
    end
    [genes, not_found]
  end

  # load best-matching gene (if possible)
  def load_best_gene_match(matches, search_term)
    # iterate through all matches to see if there is an exact match
    matches.each do |match|
      if match['name'] == search_term
        return match
      end
    end
    # go through a second time to see if there is a case-insensitive match by looking at searchable_gene
    # this is done after a complete iteration to ensure that there wasn't an exact match available
    matches.each do |match|
      if match['searchable_name'] == search_term.downcase
        return match
      end
    end
  end

  # helper method to load all possible cluster groups for a study
  def load_cluster_group_options
    @study.cluster_groups.map(&:name)
  end

  # helper method to load all available cluster_group-specific annotations
  def load_cluster_group_annotations
    grouped_options = {
        'Cluster-based' => @cluster.cell_annotations.map {|annot| ["#{annot[:name]}", "#{annot[:name]}--#{annot[:type]}--cluster"]},
        'Study Wide' => @study.cell_metadata.map {|metadata| ["#{metadata.name}", "#{metadata.name}--#{metadata.annotation_type}--study"] }.uniq
    }
    # load available user annotations (if any)
    if user_signed_in?
      user_annotations = UserAnnotation.viewable_by_cluster(current_user, @cluster)
      unless user_annotations.empty?
        grouped_options['User Annotations'] = user_annotations.map {|annot| ["#{annot.name}", "#{annot.id}--group--user"] }
      end
    end
    grouped_options
  end

  ###
  #
  # MISCELLANEOUS SUB METHODS
  #
  ###

  # defaults for annotation fonts
  def annotation_font
    {
        family: 'Helvetica Neue',
        size: 10,
        color: '#333'
    }
  end

  # parse gene list into 2 other arrays for formatting the header responsively
  def divide_genes_for_header
    main = @genes[0..4]
    more = @genes[5..@genes.size - 1]
    [main, more]
  end

  # load all precomputed options for a study
  def load_precomputed_options
    @precomputed = @study.precomputed_scores.map(&:name)
  end

  # retrieve axis labels from cluster coordinates file (if provided)
  def load_axis_labels
    coordinates_file = @cluster.study_file
    {
        x: coordinates_file.x_axis_label.blank? ? 'X' : coordinates_file.x_axis_label,
        y: coordinates_file.y_axis_label.blank? ? 'Y' : coordinates_file.y_axis_label,
        z: coordinates_file.z_axis_label.blank? ? 'Z' : coordinates_file.z_axis_label
    }
  end

  def load_expression_axis_title
    @study.default_expression_label
  end

  # create a unique hex digest of a list of genes for use in set_cache_path
  def construct_gene_list_hash(query_list)
    genes = query_list.split.map(&:strip).sort.join
    Digest::SHA256.hexdigest genes
  end

  # update sample table with contents of sample map
  def populate_rows(existing_list, file_list)
    # create hash of samples => array of reads
    sample_map = DirectoryListing.sample_read_pairings(file_list)
    sample_map.each do |sample, files|
      row = [sample]
      row += files
      # pad out row to make sure it has the correct number of entries (5)
      0.upto(4) {|i| row[i] ||= '' }
      existing_list << row
    end
  end

  # load list of available workflows
  def load_available_workflows
    config_options = AdminConfiguration.where(config_type: 'Workflow Name').to_a
    allowed_workflows = config_options.map(&:value)
    all_workflows = []

    # parellelize gets to speed up performance if there are a lot of workflows
    Parallel.map(allowed_workflows, in_threads: 3) do |workflow_opts|
      namespace, name, snapshot = workflow_opts.split('/')
      all_workflows << Study.firecloud_client.get_methods(namespace: namespace, name: name, snapshotId: snapshot)
    end

    # flatten list as it will be nested arrays
    all_workflows.flatten!

    # assemble readable list for the dropdown menu
    list = all_workflows.sort_by {|w| [w['name'], w['snapshotId'].to_i]}.map {|w| ["#{w['name']} (#{w['snapshotId']})#{w['synopsis'].blank? ? nil : " -- #{w['synopsis']}"}", "#{w['namespace']}--#{w['name']}--#{w['snapshotId']}"]}
    list
  end

  # Helper method for download_bulk_files.  Returns file's curl config, size.
  def get_curl_config(file, fc_client=nil)

    # Is this a study file, or a file from a directory listing?
    is_study_file = file.is_a? StudyFile

    if fc_client == nil
      fc_client = Study.firecloud_client
    end

    filename = (is_study_file ? file.upload_file_name : file[:name])

    begin
      signed_url = fc_client.execute_gcloud_method(:generate_signed_url,
                                                              @study.firecloud_project,
                                                              @study.firecloud_workspace,
                                                              filename,
                                                              expires: 1.day.to_i) # 1 day in seconds, 86400
      curl_config = [
          'url="' + signed_url + '"',
          'output="' + filename + '"'
      ]
    rescue => e
      logger.error "#{Time.now}: error generating signed url for #{filename}; #{e.message}"
      curl_config = [
          '# Error downloading ' + filename + '.  ' +
          'Did you delete the file in the bucket and not sync it in Single Cell Portal?'
      ]
    end
    
    curl_config = curl_config.join("\n")
    file_size = (is_study_file ? file.upload_file_size : file[:size])

    return curl_config, file_size
  end

  protected

  # construct a path to store cache results based on query parameters
  def set_cache_path
    params_key = "_#{params[:cluster].to_s.split.join('-')}_#{params[:annotation]}"
    case action_name
      when 'render_cluster'
        unless params[:subsample].nil?
          params_key += "_#{params[:subsample]}"
        end
        render_cluster_url(study_name: params[:study_name]) + params_key
      when 'render_gene_expression_plots'
        unless params[:subsample].nil?
          params_key += "_#{params[:subsample]}"
        end
        params_key += "_#{params[:plot_type]}"
        unless params[:kernel_type].nil?
          params_key += "_#{params[:kernel_type]}"
        end
        unless params[:band_type].nil?
          params_key += "_#{params[:band_type]}"
        end
        render_gene_expression_plots_url(study_name: params[:study_name], gene: params[:gene]) + params_key
      when 'render_gene_set_expression_plots'
        unless params[:subsample].nil?
          params_key += "_#{params[:subsample]}"
        end
        if params[:gene_set]
          params_key += "_#{params[:gene_set].split.join('-')}"
        else
          gene_list = params[:search][:genes]
          gene_key = construct_gene_list_hash(gene_list)
          params_key += "_#{gene_key}"
        end
        params_key += "_#{params[:plot_type]}"
        unless params[:kernel_type].nil?
          params_key += "_#{params[:kernel_type]}"
        end
        unless params[:band_type].nil?
          params_key += "_#{params[:band_type]}"
        end
        unless params[:consensus].nil?
          params_key += "_#{params[:consensus]}"
        end
        render_gene_set_expression_plots_url(study_name: params[:study_name]) + params_key
      when 'expression_query'
        params_key += "_#{params[:row_centered]}"
        gene_list = params[:search][:genes]
        gene_key = construct_gene_list_hash(gene_list)
        params_key += "_#{gene_key}"
        expression_query_url(study_name: params[:study_name]) + params_key
      when 'annotation_query'
        annotation_query_url(study_name: params[:study_name]) + params_key
      when 'precomputed_results'
        precomputed_results_url(study_name: params[:study_name], precomputed: params[:precomputed].split.join('-'))
    end
  end
end