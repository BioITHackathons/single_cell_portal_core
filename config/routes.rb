Rails.application.routes.draw do
	scope 'single_cell' do

		# portal admin actions
		post 'admin/reset_user_download_quotas', to: 'admin_configurations#reset_user_download_quotas', as: :reset_user_download_quotas
		post 'admin/restart_locked_jobs', to: 'admin_configurations#restart_locked_jobs', as: :restart_locked_jobs
		post 'admin/firecloud_access', to: 'admin_configurations#manage_firecloud_access', as: :manage_firecloud_access
		post 'admin/refresh_api_connections', to: 'admin_configurations#refresh_api_connections', as: :refresh_api_connections
		get 'admin/service_account', to: 'admin_configurations#get_service_account_profile', as: :get_service_account_profile
		post 'admin/service_account', to: 'admin_configurations#update_service_account_profile', as: :update_service_account_profile
    get 'admin/users/:id/edit', to: 'admin_configurations#edit_user', as: :edit_user
		match 'admin/users/:id', to: 'admin_configurations#update_user', via: [:post, :patch], as: :update_user
    get 'admin/email_users/compose', to: 'admin_configurations#compose_users_email', as: :compose_users_email
    post 'admin/email_users/compose', to: 'admin_configurations#deliver_users_email', as: :deliver_users_email
		get 'admin/firecloud_api_status', to: 'admin_configurations#firecloud_api_status', as: :firecloud_api_status
		get 'admin/create_portal_user_group', to: 'admin_configurations#create_portal_user_group', as: :create_portal_user_group
		get 'admin/sync_portal_user_group', to: 'admin_configurations#sync_portal_user_group', as: :sync_portal_user_group
		resources :admin_configurations, path: 'admin'

    # branding groups
    resources :branding_groups

    # study reporter actions
    get 'reports', to: 'reports#index', as: :reports
    post 'reports/report_request', to: 'reports#report_request', as: :report_request

    # firecloud billing project actions
		get 'billing_projects', to: 'billing_projects#index', as: :billing_projects
		post 'billing_projects/create', to: 'billing_projects#create', as: :create_billing_project
		get 'billing_projects/:project_name', to: 'billing_projects#show_users', as: :show_billing_project_users
		get 'billing_projects/:project_name/new_user', to: 'billing_projects#new_user', as: :new_billing_project_user
		post 'billing_projects/:project_name/add_user', to: 'billing_projects#create_user', as: :create_billing_project_user
		delete 'billing_projects/:project_name/:role/:email', to: 'billing_projects#delete_user', as: :delete_billing_project_user, constraints: {email: /.*/}
		get 'billing_projects/:project_name/storage_estimate', to: 'billing_projects#storage_estimate', as: :billing_project_storage_estimate
		get 'billing_projects/:project_name/workspaces', to: 'billing_projects#workspaces', as: :billing_project_workspaces
		get 'billing_projects/:project_name/workspaces/:study_name', to: 'billing_projects#edit_workspace_computes', as: :edit_workspace_computes
		post 'billing_projects/:project_name/workspaces/:study_name', to: 'billing_projects#update_workspace_computes', as: :update_workspace_computes

    # study admin actions
		mount Ckeditor::Engine => 'ckeditor'
    devise_for :users, :controllers => { :omniauth_callbacks => 'users/omniauth_callbacks' }
    resources :studies do
			member do
				get 'upload', to: 'studies#initialize_study', as: :initialize
				get 'sync', to: 'studies#sync_study', as: :sync
				get 'sync/:submission_id', to: 'studies#sync_submission_outputs', as: :sync_submission_outputs
				patch 'upload', to: 'studies#do_upload'
        get 'resume_upload', to: 'studies#resume_upload'
        patch 'update_status', to: 'studies#update_status'
        get 'reset_upload', to: 'studies#reset_upload'
        get 'retrieve_upload', to: 'studies#retrieve_upload', as: :retrieve_upload
        get 'retrieve_wizard_upload', to: 'studies#retrieve_wizard_upload', as: :retrieve_wizard_upload
        get 'study_files/new', to: 'studies#new_study_file', as: :new_study_file
				match 'study_files', to: 'studies#update_study_file', via: [:post, :patch], as: :update_study_file
				match 'update_synced_file', to: 'studies#update_study_file_from_sync', via: [:post, :patch], as: :update_study_file_from_sync
				match 'sync_study_file', to: 'studies#sync_study_file', via: [:post, :patch], as: :sync_study_file
				match 'sync_orphaned_study_file', to: 'studies#sync_orphaned_study_file', via: [:post, :patch], as: :sync_orphaned_study_file
				match 'sync_directory_listing', to: 'studies#sync_directory_listing', via: [:post, :patch], as: :sync_directory_listing
				post 'send_to_firecloud', to: 'studies#send_to_firecloud', as: :send_to_firecloud
				delete 'study_files/:study_file_id', to: 'studies#delete_study_file', as: :delete_study_file
				delete 'study_files/unsync/:study_file_id', to: 'studies#unsync_study_file', as: :unsync_study_file
				delete 'directory_listings/:directory_listing_id', to: 'studies#delete_directory_listing', as: :delete_directory_listing
        post 'parse', to: 'studies#parse', as: :parse_study_file
        get 'load_annotation_options', to: 'studies#load_annotation_options', as: :load_annotation_options
        post 'update_default_options', to: 'studies#update_default_options', as: :update_default_options
        patch 'update_analysis_metadata/:analysis_metadata_id', to: 'studies#update_analysis_metadata', as: :update_analysis_metadata
			end
    end

    # user annotation actions
		resources :user_annotations, only: [:index, :edit, :update, :destroy]
    get 'download_user_annotation/:id', to: 'user_annotations#download_user_annotation', as: :download_user_annotation
		get 'publish_to_study/:id', to: 'user_annotations#publish_to_study', as: :publish_to_study

		# public/private file download links (redirect to signed_urls from Google)
		get 'data/public/:study_name', to: 'site#download_file', as: :download_file
		get 'data/private/:study_name', to: 'studies#download_private_file', as: :download_private_file

    post 'totat', to: 'site#create_totat', as: :create_totat
		get 'bulk_data/:study_name/:download_object/:totat', to: 'site#download_bulk_files', as: :download_bulk_files, constraints: {filename: /.*/}

		# autocomplete
		resources :gene, only: [:show, :index] do
			get :autocomplete_gene_name, on: :collection
    end

    # user account actions
		get 'profile/:id', to: 'profiles#show', as: :view_profile
		match 'profile/:id', to: 'profiles#update', via: [:post, :patch], as: :update_profile
		match 'profile/:id/subscriptions/share/:study_share_id', to: 'profiles#update_share_subscription', via: [:post, :patch], as: :update_share_subscription
		match 'profile/:id/subscriptions/study/:study_id', to: 'profiles#update_study_subscription', via: [:post, :patch], as: :update_study_subscription
		post 'profile/:id/firecloud_profile', to: 'profiles#update_firecloud_profile', as: :update_user_firecloud_profile

		# data viewing actions
		get 'study/:study_name', to: 'site#study', as: :view_study
		get 'study/:study_name/edit_study_description', to: 'site#edit_study_description', as: :edit_study_description
		match 'study/:study_name/update_settings', to: 'site#update_study_settings', via: [:post, :patch], as: :update_study_settings
		get 'study/:study_name/render_cluster', to: 'site#render_cluster', as: :render_cluster
		get 'study/:study_name/get_new_annotations', to: 'site#get_new_annotations', as: :get_new_annotations
    post 'study/:study_name/search', to: 'site#search_genes', as: :search_genes
    get 'study/:study_name/gene_expression/:gene/', to: 'site#view_gene_expression', as: :view_gene_expression, constraints: {gene: /.*/}
    get 'study/:study_name/render_gene_expression_plots/:gene/', to: 'site#render_gene_expression_plots', as: :render_gene_expression_plots, constraints: {gene: /.*/}
    get 'study/:study_name/gene_expression', to: 'site#view_gene_expression_heatmap', as: :view_gene_expression_heatmap
    get 'study/:study_name/gene_set_expression', to: 'site#view_gene_set_expression', as: :view_gene_set_expression
    get 'study/:study_name/render_gene_set_expression_plots', to: 'site#render_gene_set_expression_plots', as: :render_gene_set_expression_plots
		get 'study/:study_name/expression_query', to: 'site#expression_query', as: :expression_query
		get 'study/:study_name/annotation_query', to: 'site#annotation_query', as: :annotation_query
		get 'study/:study_name/annotation_values', to: 'site#annotation_values', as: :annotation_values
    post 'study/:study_name/precomputed_gene_expression', to: 'site#search_precomputed_results', as: :search_precomputed_results
    get 'study/:study_name/precomputed_gene_expression', to: 'site#view_precomputed_gene_expression_heatmap', as: :view_precomputed_gene_expression_heatmap
    get 'study/:study_name/precomputed_results', to: 'site#precomputed_results', as: :precomputed_results

    # analysis metadata routes
    get 'analysis/search', to: 'site#search_analysis_metadata', as: :search_analysis_metadata
    get 'analysis/download/:submission_id', to: 'site#get_analysis_metadata', as: :get_analysis_metadata

    # user annotation actions
    post 'study/:study_name/create_user_annotations', to: 'site#create_user_annotations', as: :create_user_annotations
    get 'study/:study_name/show_user_annotations_form', to: 'site#show_user_annotations_form', as: :show_user_annotations_form

    # workflow actions
    get 'study/:study_name/get_fastq_files', to: 'site#get_fastq_files', as: :get_fastq_files
		get 'study/:study_name/workspace_samples', to: 'site#get_workspace_samples', as: :get_workspace_samples
		get 'study/:study_name/submissions', to: 'site#get_workspace_submissions', as: :get_workspace_submissions
		post 'study/:study_name/submissions', to: 'site#create_workspace_submission', as: :create_workspace_submission
		get 'study/:study_name/submissions/:submission_id', to: 'site#get_submission_workflow', as: :get_submission_workflow
		get 'study/:study_name/submissions/:submission_id/metadata', to: 'site#get_submission_metadata', as: :get_submission_metadata
		get 'study/:study_name/submissions/:submission_id/metadata_export', to: 'site#export_submission_metadata', as: :export_submission_metadata
		delete 'study/:study_name/submissions/:submission_id', to: 'site#abort_submission_workflow', as: :abort_submission_workflow
		delete 'study/:study_name/submissions/:submission_id/outputs', to: 'site#delete_submission_files', as: :delete_submission_files
		get 'study/:study_name/submissions/:submission_id/outputs', to: 'site#get_submission_outputs', as: :get_submission_outputs
		get 'study/:study_name/submissions/:submission_id/errors', to: 'site#get_submission_errors', as: :get_submission_errors
		post 'study/:study_name/workspace_samples', to: 'site#update_workspace_samples', as: :update_workspace_samples
		post 'study/:study_name/delete_workspace_samples', to: 'site#delete_workspace_samples', as: :delete_workspace_samples
    get 'view_workflow_wdl', to: 'site#view_workflow_wdl', as: :view_workflow_wdl
    get 'workflow_options', to: 'site#get_workflow_options', as: :get_workflow_options

    # base actions
    get 'search', to: 'site#search', as: :search
    get 'log_action', to: 'site#log_action', as: :log_action
    get 'privacy_policy', to: 'site#privacy_policy', as: :privacy_policy
    get '/', to: 'site#index', as: :site
    root to: 'site#index'
  end

  # The priority is based upon order of creation: first created -> highest priority.
  # See how all your routes lay out with "rake routes".

  # You can have the root of your site routed with "root"
  # root 'welcome#index'

  # Example of regular route:
  #   get 'products/:id' => 'catalog#view'

  # Example of named route that can be invoked with purchase_url(id: product.id)
  #   get 'products/:id/purchase' => 'catalog#purchase', as: :purchase

  # Example resource route (maps HTTP verbs to controller actions automatically):
  #   resources :products

  # Example resource route with options:
  #   resources :products do
  #     member do
  #       get 'short'
  #       post 'toggle'
  #     end
  #
  #     collection do
  #       get 'sold'
  #     end
  #   end

  # Example resource route with sub-resources:
  #   resources :products do
  #     resources :comments, :sales
  #     resource :seller
  #   end

  # Example resource route with more complex sub-resources:
  #   resources :products do
  #     resources :comments
  #     resources :sales do
  #       get 'recent', on: :collection
  #     end
  #   end

  # Example resource route with concerns:
  #   concern :toggleable do
  #     post 'toggle'
  #   end
  #   resources :posts, concerns: :toggleable
  #   resources :photos, concerns: :toggleable

  # Example resource route within a namespace:
  #   namespace :admin do
  #     # Directs /admin/products/* to Admin::ProductsController
  #     # (app/controllers/admin/products_controller.rb)
  #     resources :products
  #   end
end
