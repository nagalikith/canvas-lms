#
# Copyright (C) 2011 - 2012 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

class ApplicationController < ActionController::Base

  attr_accessor :active_tab

  include Api
  include LocaleSelection
  include Api::V1::User
  around_filter :set_locale

  helper :all

  include AuthenticationMethods
  protect_from_forgery
  # load_user checks masquerading permissions, so this needs to be cleared first
  before_filter :clear_cached_contexts
  before_filter :load_account, :load_user
  before_filter :check_pending_otp
  before_filter :set_user_id_header
  before_filter :set_time_zone
  before_filter :set_page_view
  after_filter :log_page_view
  after_filter :discard_flash_if_xhr
  after_filter :cache_buster
  # Yes, we're calling this before and after so that we get the user id logged
  # on events that log someone in and log someone out.
  after_filter :set_user_id_header
  before_filter :fix_xhr_requests
  before_filter :init_body_classes
  after_filter :set_response_headers
  after_filter :update_enrollment_last_activity_at

  add_crumb(proc { %Q{<i title="#{I18n.t('links.dashboard', "My Dashboard")}" class="icon-home standalone-icon"></i>}.html_safe }, :root_path, :class => "home")

  ##
  # Sends data from rails to JavaScript
  #
  # The data you send will eventually make its way into the view by simply
  # calling `to_json` on the data.
  #
  # It won't allow you to overwrite a key that has already been set
  #
  # Please use *ALL_CAPS* for keys since these are considered constants
  # Also, please don't name it stuff from JavaScript's Object.prototype
  # like `hasOwnProperty`, `constructor`, `__defineProperty__` etc.
  #
  # This method is available in controllers and views
  #
  # example:
  #
  #     # ruby
  #     js_env :FOO_BAR => [1,2,3], :COURSE => @course
  #
  #     # coffeescript
  #     require ['ENV'], (ENV) ->
  #       ENV.FOO_BAR #> [1,2,3]
  #
  def js_env(hash = {})
    # set some defaults
    unless @js_env
      @js_env = {
        :current_user_id => @current_user.try(:id),
        :current_user => user_display_json(@current_user, :profile),
        :current_user_roles => @current_user.try(:roles),
        :context_asset_string => @context.try(:asset_string),
        :AUTHENTICITY_TOKEN => form_authenticity_token,
        :files_domain => HostUrl.file_host(@domain_root_account || Account.default, request.host_with_port),
      }
      @js_env[:IS_LARGE_ROSTER] = true if @context.respond_to?(:large_roster?) && @context.large_roster?
    end

    hash.each do |k,v|
      if @js_env[k]
        raise "js_env key #{k} is already taken"
      else
        @js_env[k] = v
      end
    end

    @js_env
  end
  helper_method :js_env

  protected

  def assign_localizer
    I18n.localizer = lambda {
      infer_locale :context => @context,
                   :user => @current_user,
                   :root_account => @domain_root_account,
                   :accept_language => request.headers['Accept-Language']
    }
  end

  def set_locale
    assign_localizer
    yield if block_given?
  ensure
    I18n.localizer = nil
  end

  def init_body_classes
    @body_classes = []
  end

  def set_user_id_header
    headers['X-Canvas-User-Id'] ||= @current_user.global_id.to_s if @current_user
    headers['X-Canvas-Real-User-Id'] ||= @real_current_user.global_id.to_s if @real_current_user
  end

  # make things requested from jQuery go to the "format.js" part of the "respond_to do |format|" block
  # see http://codetunes.com/2009/01/31/rails-222-ajax-and-respond_to/ for why
  def fix_xhr_requests
    request.format = :js if request.xhr? && request.format == :html && !params[:html_xhr]
  end
  
  # scopes all time objects to the user's specified time zone
  def set_time_zone
    if @current_user && !@current_user.time_zone.blank?
      Time.zone = @current_user.time_zone
      if Time.zone && Time.zone.name == "UTC" && @current_user.time_zone && @current_user.time_zone.match(/\s/)
        Time.zone = @current_user.time_zone.split(/\s/)[1..-1].join(" ") rescue nil
      end
    else
      Time.zone = @domain_root_account && @domain_root_account.default_time_zone
    end
  end

  # retrieves the root account for the given domain
  def load_account
    @domain_root_account = request.env['canvas.domain_root_account'] || LoadAccount.default_domain_root_account
    @files_domain = request.host_with_port != HostUrl.context_host(@domain_root_account) && HostUrl.is_file_host?(request.host_with_port)
    @domain_root_account
  end

  def set_response_headers
    headers['X-UA-Compatible'] = 'IE=edge,chrome=1'
    # we can't block frames on the files domain, since files domain requests
    # are typically embedded in an iframe in canvas, but the hostname is
    # different
    if !files_domain? && Setting.get_cached('block_html_frames', 'true') == 'true' && !@embeddable
      headers['X-Frame-Options'] = 'SAMEORIGIN'
    end
    true
  end

  def files_domain?
    !!@files_domain
  end

  def check_pending_otp
    if session[:pending_otp] && !(params[:action] == 'otp_login' && request.method == :post)
      reset_session
      redirect_to login_url
    end
  end

  # used to generate context-specific urls without having to
  # check which type of context it is everywhere
  def named_context_url(context, name, *opts)
    if context.is_a?(UserProfile)
      name = name.to_s.sub(/context/, "profile")
    else
      klass = context.class.base_ar_class
      name = name.to_s.sub(/context/, klass.name.underscore)
      opts.unshift(context)
    end
    opts.push({}) unless opts[-1].is_a?(Hash)
    include_host = opts[-1].delete(:include_host)
    if !include_host
      opts[-1][:host] = context.host_name rescue nil
      opts[-1][:only_path] = true
    end
    self.send name, *opts
  end

  def user_url(*opts)
    opts[0] == @current_user && !@current_user.grants_right?(@current_user, session, :view_statistics) ?
      user_profile_url(@current_user) :
      super
  end

  def tab_enabled?(id)
    if @context && @context.respond_to?(:tabs_available) && !@context.tabs_available(@current_user, :session => session, :include_hidden_unused => true, :root_account => @domain_root_account).any?{|t| t[:id] == id }
      if @context.is_a?(Account)
        flash[:notice] = t "#application.notices.page_disabled_for_account", "That page has been disabled for this account"
      elsif @context.is_a?(Course)
        flash[:notice] = t "#application.notices.page_disabled_for_course", "That page has been disabled for this course"
      elsif @context.is_a?(Group)
        flash[:notice] = t "#application.notices.page_disabled_for_group", "That page has been disabled for this group"
      else
        flash[:notice] = t "#application.notices.page_disabled", "That page has been disabled"
      end
      redirect_to named_context_url(@context, :context_url)
      return false
    end
    true
  end

  def require_password_session
    if session[:used_remember_me_token]
      flash[:warning] = t "#application.warnings.please_log_in", "For security purposes, please enter your password to continue"
      store_location
      redirect_to login_url
      return false
    end
    true
  end

  # checks the authorization policy for the given object using
  # the vendor/plugins/adheres_to_policy plugin.  If authorized,
  # returns true, otherwise renders unauthorized messages and returns
  # false.  To be used as follows:
  # if authorized_action(object, @current_user, session, :update)
  #   render
  # end
  def authorized_action(object, *opts)
    can_do = is_authorized_action?(object, *opts)
    render_unauthorized_action(object) unless can_do
    can_do
  end

  def is_authorized_action?(object, *opts)
    user = opts.shift
    action_session = nil
    action_session ||= session
    action_session = opts.shift if !opts[0].is_a?(Symbol) && !opts[0].is_a?(Array)
    actions = Array(opts.shift)
    can_do = false
    begin
      if object == @context && user == @current_user
        @context_all_permissions ||= @context.grants_rights?(user, session, nil)
        can_do = actions.any?{|a| @context_all_permissions[a] }
      else
        can_do = object.grants_rights?(user, action_session, *actions).values.any?
      end
    rescue => e
      logger.warn "#{object.inspect} raised an error while granting rights.  #{e.inspect}"
    end
    can_do
  end

  def render_unauthorized_action(object=nil)
    object ||= User.new
    object.errors.add_to_base(t "#application.errors.unauthorized.generic", "You are not authorized to perform this action")
    respond_to do |format|
      @show_left_side = false
      clear_crumbs
      params = request.path_parameters
      params[:format] = nil
      @headers = !!@current_user if @headers != false
      @files_domain = @account_domain && @account_domain.host_type == 'files'
      format.html {
        store_location if request.get?
        return if !@current_user && initiate_delegated_login(request.host_with_port)
        if @context.is_a?(Course) && @context_enrollment
          start_date = @context_enrollment.enrollment_dates.map(&:first).compact.min if @context_enrollment.state_based_on_date == :inactive
          if @context.claimed?
            @unauthorized_message = t('#application.errors.unauthorized.unpublished', "This course has not been published by the instructor yet.")
            @unauthorized_reason = :unpublished
          elsif start_date && start_date > Time.now.utc
            @unauthorized_message = t('#application.errors.unauthorized.not_started_yet', "The course you are trying to access has not started yet.  It will start %{date}.", :date => TextHelper.date_string(start_date))
            @unauthorized_reason = :unpublished
          end
        end

        @is_delegated = delegated_authentication_url?
        render :template => "shared/unauthorized", :layout => "application", :status => :unauthorized
      }
      format.zip { redirect_to(url_for(params)) }
      format.json { render_json_unauthorized }
    end
    response.headers["Pragma"] = "no-cache"
    response.headers["Cache-Control"] = "no-cache, no-store, max-age=0, must-revalidate"
  end

  def delegated_authentication_url?
    @domain_root_account.delegated_authentication? &&
    !@domain_root_account.ldap_authentication? &&
    !params[:canvas_login]
  end

  # To be used as a before_filter, requires controller or controller actions
  # to have their urls scoped to a context in order to be valid.
  # So /courses/5/assignments or groups/1/assignments would be valid, but
  # not /assignments
  def require_context
    get_context
    if !@context
      if request.path.match(/\A\/profile/)
        store_location
        redirect_to login_url
      elsif params[:context_id]
        raise ActiveRecord::RecordNotFound.new("Cannot find #{params[:context_type] || 'Context'} for ID: #{params[:context_id]}")
      else
        raise ActiveRecord::RecordNotFound.new("Context is required, but none found")
      end
    end
    return @context != nil
  end

  def clean_return_to(url)
    return nil if url.blank?
    uri = URI.parse(url)
    return nil unless uri.path[0] == ?/
    return "#{request.protocol}#{request.host_with_port}#{uri.path}#{uri.query && "?#{uri.query}"}#{uri.fragment && "##{uri.fragment}"}"
  end
  helper_method :clean_return_to

  def return_to(url, fallback)
    url = clean_return_to(url) || clean_return_to(fallback)
    redirect_to url
  end

  MAX_ACCOUNT_LINEAGE_TO_SHOW_IN_CRUMBS = 3

  # Can be used as a before_filter, or just called from controller code.
  # Assigns the variable @context to whatever context the url is scoped
  # to.  So /courses/5/assignments would have a @context=Course.find(5).
  # Also assigns @context_membership to the membership type of @current_user
  # if @current_user is a member of the context.
  def get_context
    unless @context
      if params[:course_id]
        @context = api_request? ?
          api_find(Course.active, params[:course_id]) : Course.active.find(params[:course_id])
        params[:context_id] = params[:course_id]
        params[:context_type] = "Course"
        if @context && session[:enrollment_uuid_course_id] == @context.id
          session[:enrollment_uuid_count] ||= 0
          if session[:enrollment_uuid_count] > 4
            session[:enrollment_uuid_count] = 0
            self.extend(TextHelper)
            flash[:html_notice] = mt "#application.notices.need_to_accept_enrollment", "You'll need to [accept the enrollment invitation](%{url}) before you can fully participate in this course.", :url => course_url(@context)
          end
          session[:enrollment_uuid_count] += 1
        end
        @context_enrollment = @context.enrollments.find_all_by_user_id(@current_user.id).sort_by{|e| [e.state_sortable, e.rank_sortable, e.id] }.first if @context && @current_user
        @context_membership = @context_enrollment
      elsif params[:account_id] || (self.is_a?(AccountsController) && params[:account_id] = params[:id])
        case params[:account_id]
        when 'self'
          @context = @domain_root_account
        when 'default'
          @context = Account.default
        when 'site_admin'
          @context = Account.site_admin
        else
          @context = api_request? ?
            api_find(Account, params[:account_id]) : Account.find(params[:account_id])
        end
        params[:context_id] = @context.id
        params[:context_type] = "Account"
        @context_enrollment = @context.account_users.find_by_user_id(@current_user.id) if @context && @current_user
        @context_membership = @context_enrollment
        @account = @context
      elsif params[:group_id]
        @context = Group.find(params[:group_id])
        params[:context_id] = params[:group_id]
        params[:context_type] = "Group"
        @context_enrollment = @context.group_memberships.find_by_user_id(@current_user.id) if @context && @current_user      
        @context_membership = @context_enrollment
      elsif params[:user_id] || (self.is_a?(UsersController) && params[:user_id] = params[:id])
        case params[:user_id]
        when 'self'
          @context = @current_user
        else
          @context = api_request? ? api_find(User, params[:user_id]) : User.find(params[:user_id])
        end
        params[:context_id] = params[:user_id]
        params[:context_type] = "User"
        @context_membership = @context if @context == @current_user
      elsif params[:course_section_id] || (self.is_a?(SectionsController) && params[:course_section_id] = params[:id])
        params[:context_id] = params[:course_section_id]
        params[:context_type] = "CourseSection"
        @context = api_request? ? api_find(CourseSection, params[:course_section_id]) : CourseSection.find(params[:course_section_id])
      elsif params[:collection_item_id]
        params[:context_id] = params[:collection_item_id]
        params[:context_type] = 'CollectionItem'
        @context = CollectionItem.find(params[:collection_item_id])
      elsif request.path.match(/\A\/profile/) || request.path == '/' || request.path.match(/\A\/dashboard\/files/) || request.path.match(/\A\/calendar/) || request.path.match(/\A\/assignments/) || request.path.match(/\A\/files/)
        @context = @current_user
        @context_membership = @context
      end
      if @context.try_rescue(:only_wiki_is_public) && params[:controller].match(/wiki/) && !@current_user && (!@context.is_a?(Course) || session[:enrollment_uuid_course_id] != @context.id)
        @show_left_side = false
      end
      if @context.is_a?(Account) && !@context.root_account?
        account_chain = @context.account_chain.to_a.select {|a| a.grants_right?(@current_user, session, :read) }
        account_chain.slice!(0) # the first element is the current context
        count = account_chain.length
        account_chain.reverse.each_with_index do |a, idx|
          if idx == 1 && count >= MAX_ACCOUNT_LINEAGE_TO_SHOW_IN_CRUMBS
            add_crumb(I18n.t('#lib.text_helper.ellipsis', '...'), nil)
          elsif count >= MAX_ACCOUNT_LINEAGE_TO_SHOW_IN_CRUMBS && idx > 0 && idx <= count - MAX_ACCOUNT_LINEAGE_TO_SHOW_IN_CRUMBS
            next
          else
            add_crumb(a.short_name, account_url(a.id), :id => "crumb_#{a.asset_string}")
          end
        end
      end
      set_badge_counts_for(@context, @current_user, @current_enrollment)
      assign_localizer if @context.present?
      add_crumb(@context.short_name, named_context_url(@context, :context_url), :id => "crumb_#{@context.asset_string}") if @context && @context.respond_to?(:short_name)
    end
  end
  
  # This is used by a number of actions to retrieve a list of all contexts
  # associated with the given context.  If the context is a user then it will
  # include all the user's current contexts.
  # Assigns it to the variable @contexts
  def get_all_pertinent_contexts(include_groups = false)
    return if @already_ran_get_all_pertinent_contexts
    @already_ran_get_all_pertinent_contexts = true

    raise(ArgumentError, "Need a starting context") if @context.nil?

    @contexts = [@context]
    only_contexts = ActiveRecord::Base.parse_asset_string_list(params[:only_contexts])
    if @context && @context.is_a?(User)
      # we already know the user can read these courses and groups, so skip
      # the grants_right? check to avoid querying for the various memberships
      # again.
      courses = @context.current_enrollments.select { |e| e.state_based_on_date == :active }.map(&:course).uniq
      groups = include_groups ? @context.current_groups : []
      if only_contexts.present?
        # find only those courses and groups passed in the only_contexts
        # parameter, but still scoped by user so we know they have rights to
        # view them.
        course_ids = only_contexts.select { |c| c.first == "Course" }.map(&:last)
        courses = course_ids.empty? ? [] : courses.select { |c| course_ids.include?(c.id) }
        group_ids = only_contexts.select { |c| c.first == "Group" }.map(&:last)
        groups = group_ids.empty? ? [] : groups.find_all_by_id(group_ids) if include_groups
      end
      @contexts.concat courses
      @contexts.concat groups
    end
    if params[:include_contexts]
      params[:include_contexts].split(",").each do |include_context|
        # don't load it again if we've already got it
        next if @contexts.any? { |c| c.asset_string == include_context }
        context = Context.find_by_asset_string(include_context)
        @contexts << context if context && context.grants_right?(@current_user, nil, :read)
      end
    end
    @contexts = @contexts.uniq
    Course.require_assignment_groups(@contexts)
    @context_enrollment = @context.membership_for_user(@current_user) if @context.respond_to?(:membership_for_user)
    @context_membership = @context_enrollment
  end

  def set_badge_counts_for(context, user, enrollment=nil)
    return if @js_env && @js_env[:badge_counts].present?
    return unless context.present? && user.present?
    return unless context.respond_to?(:content_participation_counts) # just Course and Group so far
    js_env(:badge_counts => badge_counts_for(context, user, enrollment))
  end

  def badge_counts_for(context, user, enrollment=nil)
    badge_counts = {}
    ['Submission'].each do |type|
      participation_count = context.content_participation_counts.
          where(:user_id => user.id, :content_type => type).first
      participation_count ||= ContentParticipationCount.create_or_update({
        :context => context,
        :user => user,
        :content_type => type,
      })
      badge_counts[type.underscore.pluralize] = participation_count.unread_count
    end
    badge_counts
  end

  # Retrieves all assignments for all contexts held in the @contexts variable.
  # Also retrieves submissions and sorts the assignments based on
  # their due dates and submission status for the given user.
  def get_sorted_assignments
    @courses = @contexts.select{ |c| c.is_a?(Course) }
    @just_viewing_one_course = @context.is_a?(Course) && @courses.length == 1
    @context_codes = @courses.map(&:asset_string)
    @context = @courses.first

    if @just_viewing_one_course
      @groups = @courses.first.assignment_groups.active.includes(:active_assignments)
      @assignments = @groups.map(&:active_assignments).flatten
    else
      @groups = AssignmentGroup.for_context_codes(@context_codes).active
      @assignments = Assignment.active.for_course(@courses.map(&:id))
    end
    @assignment_groups = @groups

    @courses.each { |course| log_course(course) }

    @submissions = @current_user.try(:submissions).to_a
    @submissions.each{ |s| s.mute if s.muted_assignment? }

    @assignments.map! {|a| a.overridden_for(@current_user)}
    sorted = SortsAssignments.by_due_date({
      :assignments => @assignments,
      :user => @current_user,
      :session => session,
      :upcoming_limit => 1.week.from_now,
      :submissions => @submissions
    })

    @past_assignments = sorted.past
    @undated_assignments = sorted.undated
    @ungraded_assignments = sorted.ungraded
    @upcoming_assignments = sorted.upcoming
    @future_assignments = sorted.future
    @overdue_assignments = sorted.overdue

    condense_assignments if requesting_main_assignments_page?

    categorized_assignments.each(&:sort!)
  end

  def categorized_assignments
    [
      @assignments,
      @upcoming_assignments,
      @past_assignments,
      @ungraded_assignments,
      @undated_assignments,
      @future_assignments
    ]
  end

  def condense_assignments
    num_weeks = @future_assignments.length > 5 ? 2 : 4
    @future_assignments = SortsAssignments.up_to(@future_assignments, num_weeks.weeks.from_now)
    num_weeks = @past_assignments.length < 5 ? 2 : 4
    @past_assignments = SortsAssignments.down_to(@past_assignments, num_weeks.weeks.ago)

    @overdue_assignments = SortsAssignments.down_to(@overdue_assignments, 4.weeks.ago)
    @ungraded_assignments = SortsAssignments.down_to(@ungraded_assignments, 4.weeks.ago)
  end

  def log_course(course)
    log_asset_access("assignments:#{course.asset_string}", "assignments", "other")
  end

  def requesting_main_assignments_page?
    request.path.match(/\A\/assignments/)
  end

  # Calculates the file storage quota for @context
  def get_quota
    quota_params = Attachment.get_quota(@context)
    @quota = quota_params[:quota]
    @quota_used = quota_params[:quota_used]
  end

  # Renders a quota exceeded message if the @context's quota is exceeded
  def quota_exceeded(redirect=nil)
    redirect ||= root_url
    get_quota
    if response.body.size + @quota_used > @quota
      if @context.is_a?(Account)
        error = t "#application.errors.quota_exceeded_account", "Account storage quota exceeded"
      elsif @context.is_a?(Course)
        error = t "#application.errors.quota_exceeded_course", "Course storage quota exceeded"
      elsif @context.is_a?(Group)
        error = t "#application.errors.quota_exceeded_group", "Group storage quota exceeded"
      elsif @context.is_a?(User)
        error = t "#application.errors.quota_exceeded_user", "User storage quota exceeded"
      else
        error = t "#application.errors.quota_exceeded", "Storage quota exceeded"
      end
      respond_to do |format|
        flash[:error] = error unless request.format.to_s == "text/plain"
        format.html {redirect_to redirect }
        format.json {render :json => {:errors => {:base => error}}.to_json }
        format.text {render :json => {:errors => {:base => error}}.to_json }
      end
      return true
    end
    false
  end
  
  # Used to retrieve the context from a :feed_code parameter.  These 
  # :feed_code attributes are keyed off the object type and the object's
  # uuid.  Using the uuid attribute gives us an unguessable url so
  # that we can offer the feeds without requiring password authentication.
  def get_feed_context(opts={})
    pieces = params[:feed_code].split("_", 2)
    if params[:feed_code].match(/\Agroup_membership/)
      pieces = ["group_membership", params[:feed_code].split("_", 3)[-1]]
    end
    @context = nil
    @problem = nil
    if pieces[0] == "enrollment"
      @enrollment = Enrollment.find_by_uuid(pieces[1]) if pieces[1]
      @context_type = "Course"
      if !@enrollment
        @problem = t "#application.errors.mismatched_verification_code", "The verification code does not match any currently enrolled user."
      elsif @enrollment.course && !@enrollment.course.available?
        @problem = t "#application.errors.feed_unpublished_course", "Feeds for this course cannot be accessed until it is published."
      end
      @context = @enrollment.course unless @problem
      @current_user = @enrollment.user unless @problem
    elsif pieces[0] == 'group_membership'
      @membership = GroupMembership.active.find_by_uuid(pieces[1]) if pieces[1]
      @context_type = "Group"
      if !@membership
        @problem = t "#application.errors.mismatched_verification_code", "The verification code does not match any currently enrolled user."
      elsif @membership.group && !@membership.group.available?
        @problem = t "#application.errors.feed_unpublished_group", "Feeds for this group cannot be accessed until it is published."
      end
      @context = @membership.group unless @problem
      @current_user = @membership.user unless @problem
    else
      @context_type = pieces[0].classify
      if Context::ContextTypes.const_defined?(@context_type)
        @context_class = Context::ContextTypes.const_get(@context_type)
        @context = @context_class.find_by_uuid(pieces[1]) if pieces[1]
      end
      if !@context
        @problem = t "#application.errors.invalid_verification_code", "The verification code is invalid."
      elsif (!@context.is_public rescue false) && (!@context.respond_to?(:uuid) || pieces[1] != @context.uuid)
        if @context_type == 'course'
          @problem = t "#application.errors.feed_private_course", "The matching course has gone private, so public feeds like this one will no longer be visible."
        elsif @context_type == 'group'
          @problem = t "#application.errors.feed_private_group", "The matching group has gone private, so public feeds like this one will no longer be visible."
        else
          @problem = t "#application.errors.feed_private", "The matching context has gone private, so public feeds like this one will no longer be visible."
        end
      end
      @context = nil if @problem
      @current_user = @context if @context.is_a?(User)
    end
    if !@context || (opts[:only] && !opts[:only].include?(@context.class.to_s.underscore.to_sym))
      @problem ||= t("#application.errors.invalid_feed_parameters", "Invalid feed parameters.") if (opts[:only] && !opts[:only].include?(@context.class.to_s.underscore.to_sym))
      @problem ||= t "#application.errors.feed_not_found", "Could not find feed."
      @template_format = 'html'
      @template.template_format = 'html'
      render :text => @template.render(:file => "shared/unauthorized_feed", :layout => "layouts/application"), :status => :bad_request # :template => "shared/unauthorized_feed", :status => :bad_request
      return false
    end
    @context
  end

  def discard_flash_if_xhr
    flash.discard if request.xhr? || request.format.to_s == 'text/plain'
  end
  
  def cancel_cache_buster
    @cancel_cache_buster = true
  end
  
  def cache_buster
    # Annoying problem.  If I set the cache-control to anything other than "no-cache, no-store" 
    # then the local cache is used when the user clicks the 'back' button.  I don't know how
    # to tell the browser to ALWAYS check back other than to disable caching...
    return true if @cancel_cache_buster || request.xhr? || api_request?
    response.headers["Pragma"] = "no-cache"
    response.headers["Cache-Control"] = "no-cache, no-store, max-age=0, must-revalidate"
  end
  
  def clear_cached_contexts
    ActiveRecord::Base.clear_cached_contexts
    RoleOverride.clear_cached_contexts
  end

  def set_page_view
    return true if !page_views_enabled?

    ENV['RAILS_HOST_WITH_PORT'] ||= request.host_with_port rescue nil
    # We only record page_views for html page requests coming from within the
    # app, or if coming from a developer api request and specified as a 
    # page_view.
    if (@developer_key && params[:user_request]) || (!@developer_key && @current_user && !request.xhr? && request.method == :get)
      generate_page_view
    end
  end

  def generate_page_view
    attributes = { :user => @current_user, :developer_key => @developer_key, :real_user => @real_current_user }
    @page_view = PageView.generate(request, attributes)
    @page_view.user_request = true if params[:user_request] || (@current_user && !request.xhr? && request.method == :get)
    @page_before_render = Time.now.utc
  end

  def generate_new_page_view
    return true if !page_views_enabled?

    generate_page_view
    @page_view.generated_by_hand = true
  end

  def disable_page_views
    @log_page_views = false
    true
  end

  def update_enrollment_last_activity_at
    if @context.is_a?(Course) && @context_enrollment
      @context_enrollment.record_recent_activity
    end
  end

  # Asset accesses are used for generating usage statistics.  This is how
  # we say, "the user just downloaded this file" or "the user just
  # viewed this wiki page".  We can then after-the-fact build statistics
  # and reports from these accesses.  This is currently being used
  # to generate access reports per student per course.
  def log_asset_access(asset, asset_category, asset_group=nil, level=nil, membership_type=nil)
    return unless @current_user && @context && asset
    @accessed_asset = {
      :code => asset.is_a?(String) ? asset : asset.asset_string,
      :group_code => asset_group.is_a?(String) ? asset_group : (asset_group.asset_string rescue 'unknown'),
      :category => asset_category,
      :membership_type => membership_type || (@context_membership && @context_membership.class.to_s rescue nil),
      :level => level
    }
  end

  def log_page_view
    return true if !page_views_enabled?

    if @current_user && @log_page_views != false
      if request.xhr? && params[:page_view_id] && !(@page_view && @page_view.generated_by_hand)
        @page_view = PageView.for_request_id(params[:page_view_id])
        if @page_view
          response.headers["X-Canvas-Page-View-Id"] = @page_view.id.to_s if @page_view.id
          @page_view.do_update(params.slice(:interaction_seconds, :page_view_contributed))
          @page_view_update = true
        end
      end
      # If we're logging the asset access, and it's either a participatory action
      # or it's not an update to an already-existing page_view.  We check to make sure 
      # it's not an update because if the page_view already existed, we don't want to 
      # double-count it as multiple views when it's really just a single view.
      if @current_user && @accessed_asset && (@accessed_asset[:level] == 'participate' || !@page_view_update)
        @access = AssetUserAccess.find_or_initialize_by_user_id_and_asset_code(@current_user.id, @accessed_asset[:code])
        @accessed_asset[:level] ||= 'view'
        access_context = @context.is_a?(UserProfile) ? @context.user : @context
        @access.log access_context, @accessed_asset

        if @page_view
          @page_view.participated = %w{participate submit}.include?(@accessed_asset[:level])
          @page_view.asset_user_access = @access
        end

        @page_view_update = true
      end
      if @page_view && !request.xhr? && request.get? && (response.content_type || "").match(/html/)
        @page_view.render_time ||= (Time.now.utc - @page_before_render) rescue nil
        @page_view_update = true
      end
      if @page_view && @page_view_update
        @page_view.context = @context if !@page_view.context_id
        @page_view.account_id = @domain_root_account.id
        @page_view.store
      end
    else
      @page_view.destroy if @page_view && !@page_view.new_record?
    end
  rescue => e
    logger.error "Pageview error!"
    raise e if Rails.env.development?
    true
  end

  # Custom error catching and message rendering.
  def rescue_action_in_public(exception)
    response_code = response_code_for_rescue(exception)
    begin
      @status_code = interpret_status(response_code)
      @status = @status_code
      @status = 'AUT' if exception.is_a?(ActionController::InvalidAuthenticityToken)
      type = 'default'
      type = '404' if @status == '404 Not Found'

      @error = ErrorReport.log_exception(type, exception, {
        :url => request.url,
        :user => @current_user,
        :user_agent => request.headers['User-Agent'],
        :request_context_id => RequestContextGenerator.request_id,
        :account => @domain_root_account,
        :request_method => request.method,
        :format => request.format,
      }.merge(ErrorReport.useful_http_env_stuff_from_request(request)))

      if api_request?
        rescue_action_in_api(exception, @error)
      else
        @headers = nil
        session[:last_error_id] = @error.id rescue nil
        if request.xhr? || request.format == :text
          render :json => {:errors => {:base => "Unexpected error, ID: #{@error.id rescue "unknown"}"}, :status => @status}, :status => @status_code
        else
          @status = '500' unless File.exists?(File.join('app', 'views', 'shared', 'errors', "#{@status.to_s[0,3]}_message.html.erb"))
          render :template => "shared/errors/#{@status.to_s[0, 3]}_message.html.erb", 
            :layout => 'application', :status => @status, :locals => {:error => @error, :exception => exception, :status => @status}
        end
      end
    rescue => e
      # error generating the error page? failsafe.
      render_optional_error_file response_code_for_rescue(exception)
      ErrorReport.log_exception(:default, e)
    end
  end

  if Rails.version < "3.0"
    rescue_responses['AuthenticationMethods::AccessTokenError'] = 401
  else
    ActionDispatch::ShowExceptions.rescue_responses['AuthenticationMethods::AccessTokenError'] = 401
  end

  def rescue_action_in_api(exception, error_report)
    status_code = response_code_for_rescue(exception) || 500
    if status_code.is_a?(Symbol)
      status_code_string = status_code.to_s
    else
      # we want to return a status string of the form "not_found", so take the rails-style "Not Found" and tweak it
      status_code_string = interpret_status(status_code).sub(/\d\d\d /, '').gsub(' ', '').underscore
    end

    data = { :status => status_code_string }
    if error_report.try(:id)
      data[:error_report_id] = error_report.id
    end

    # inject exception-specific data into the response
    case exception
    when ActiveRecord::RecordNotFound
      data[:message] = 'The specified resource does not exist.'
    when AuthenticationMethods::AccessTokenError
      add_www_authenticate_header
      data[:message] = 'Invalid access token.'
    end

    data[:message] ||= "An error occurred."
    render :json => data, :status => status_code
  end

  def rescue_action_locally(exception)
    if api_request?
      # we want api requests to behave the same on error locally as in prod, to
      # ease testing and development. you can still view the backtrace, etc, in
      # the logs.
      rescue_action_in_api(exception, nil)
    else
      super
    end
  end

  def local_request?
    false
  end
  
  def claim_session_course(course, user, state=nil)
    e = course.claim_with_teacher(user)
    session[:claimed_enrollment_uuids] ||= []
    session[:claimed_enrollment_uuids] << e.uuid
    session[:claimed_enrollment_uuids].uniq!
    flash[:notice] = t "#application.notices.first_teacher", "This course is now claimed, and you've been registered as its first teacher."
    if !@current_user && state == :just_registered
      flash[:notice] = t "#application.notices.first_teacher_with_email", "This course is now claimed, and you've been registered as its first teacher. You should receive an email shortly to complete the registration process."
    end
    session[:claimed_course_uuids] ||= []
    session[:claimed_course_uuids] << course.uuid
    session[:claimed_course_uuids].uniq!
    session.delete(:claim_course_uuid)
    session.delete(:course_uuid)
  end

  # Had to overwrite this method so we can say you don't need to have an
  # authenticity_token if the request is coming from an api request.
  # we also check for the session token not being set at all here, to catch
  # those who have cookies disabled.
  def verify_authenticity_token
    token = params[request_forgery_protection_token].try(:gsub, " ", "+")
    params[request_forgery_protection_token] = token if token

    if    protect_against_forgery? &&
          !request.get? &&
          !api_request?
      if session[:_csrf_token].nil? && session.empty? && !request.xhr? && !api_request?
        # the session should have the token stored by now, but doesn't? sounds
        # like the user doesn't have cookies enabled.
        redirect_to(login_url(:needs_cookies => '1'))
        return false
      else
        raise(ActionController::InvalidAuthenticityToken) unless (form_authenticity_token == form_authenticity_param) || (form_authenticity_token == request.headers['X-CSRF-Token'])
      end
    end
    Rails.logger.warn("developer_key id: #{@developer_key.id}") if @developer_key
  end

  API_REQUEST_REGEX = %r{\A/api/v\d}

  def api_request?
    @api_request ||= !!request.path.match(API_REQUEST_REGEX)
  end

  def session_loaded?
    session.send(:loaded?) rescue false
  end

  # Retrieving wiki pages needs to search either using the id or 
  # the page title.
  def get_wiki_page
    page_name = (params[:wiki_page_id] || params[:id] || (params[:wiki_page] && params[:wiki_page][:title]) || "front-page")
    if(params[:format] && !['json', 'html'].include?(params[:format]))
      page_name += ".#{params[:format]}"
      params[:format] = 'html'
    end
    return @page if @page 
    @wiki = @context.wiki
    if params[:action] != 'create'
      @page = @wiki.wiki_pages.deleted_last.find_by_url(page_name.to_s) ||
              @wiki.wiki_pages.deleted_last.find_by_url(page_name.to_s.to_url) ||
              @wiki.wiki_pages.find_by_id(page_name.to_i)
    end
    @page ||= @wiki.wiki_pages.build(
      :title => page_name.titleize,
      :url => page_name.to_url
    )
    if page_name == "front-page" && @page.new_record?
      @page.body = t "#application.wiki_front_page_default_content_course", "Welcome to your new course wiki!" if @context.is_a?(Course)
      @page.body = t "#application.wiki_front_page_default_content_group", "Welcome to your new group wiki!" if @context.is_a?(Group)
    end
  end

  def context_wiki_page_url
    page_name = @page.url
    named_context_url(@context, :context_wiki_page_url, page_name)
  end

  def content_tag_redirect(context, tag, error_redirect_symbol)
    url_params = { :module_item_id => tag.id }
    if tag.content_type == 'Assignment'
      redirect_to named_context_url(context, :context_assignment_url, tag.content_id, url_params)
    elsif tag.content_type == 'WikiPage'
      redirect_to named_context_url(context, :context_wiki_page_url, tag.content.url, url_params)
    elsif tag.content_type == 'Attachment'
      redirect_to named_context_url(context, :context_file_url, tag.content_id, url_params)
    elsif tag.content_type == 'Quiz'
      redirect_to named_context_url(context, :context_quiz_url, tag.content_id, url_params)
    elsif tag.content_type == 'DiscussionTopic'
      redirect_to named_context_url(context, :context_discussion_topic_url, tag.content_id, url_params)
    elsif tag.content_type == 'ExternalUrl'
      @tag = tag
      @module = tag.context_module
      tag.context_module_action(@current_user, :read) unless tag.locked_for? @current_user
      render :template => 'context_modules/url_show'
    elsif tag.content_type == 'ContextExternalTool'
      @tag = tag
      if @tag.context.is_a?(Assignment)
        @assignment = @tag.context
        @resource_title = @assignment.title
      else
        @resource_title = @tag.title
      end
      @resource_url = @tag.url
      @opaque_id = @tag.opaque_identifier(:asset_string)
      @tool = ContextExternalTool.find_external_tool(tag.url, context, tag.content_id)
      @target = '_blank' if tag.new_tab
      tag.context_module_action(@current_user, :read)
      if !@tool
        flash[:error] = t "#application.errors.invalid_external_tool", "Couldn't find valid settings for this link"
        redirect_to named_context_url(context, error_redirect_symbol)
      else
        return unless require_user
        @return_url = named_context_url(@context, :context_external_tool_finished_url, @tool.id, :include_host => true)
        @launch = BasicLTI::ToolLaunch.new(:url => @resource_url, :tool => @tool, :user => @current_user, :context => @context, :link_code => @opaque_id, :return_url => @return_url)
        if @assignment && @context.includes_student?(@current_user)
          @launch.for_assignment!(@tag.context, lti_grade_passback_api_url(@tool), blti_legacy_grade_passback_api_url(@tool))
        end
        @tool_settings = @launch.generate
        render :template => 'external_tools/tool_show'
      end
    else
      flash[:error] = t "#application.errors.invalid_tag_type", "Didn't recognize the item type for this tag"
      redirect_to named_context_url(context, error_redirect_symbol)
    end
  end

  # pass it a context or an array of contexts and it will give you a link to the
  # person's calendar with only those things checked.
  def calendar_url_for(contexts_to_link_to = nil, options={})
    options[:query] ||= {}
    options[:anchor] ||= {}
    contexts_to_link_to = Array(contexts_to_link_to)
    if event = options.delete(:event)
      options[:query][:event_id] = event.id
    end
    if !contexts_to_link_to.empty? && options[:anchor].is_a?(Hash)
      options[:anchor][:show] = contexts_to_link_to.collect{ |c| 
        "group_#{c.class.to_s.downcase}_#{c.id}" 
      }.join(',')
      options[:anchor] = options[:anchor].to_json
    end
    options[:query][:include_contexts] = contexts_to_link_to.map{|c| c.asset_string}.join(",") unless contexts_to_link_to.empty?
    calendar_url(
      options[:query].merge(options[:anchor].empty? ? {} : {
        :anchor => options[:anchor].unpack('H*').first # calendar anchor is hex encoded
      })
    )
  end

  # pass it a context or an array of contexts and it will give you a link to the
  # person's files browser for the supplied contexts.
  def files_url_for(contexts_to_link_to = nil, options={})
    options[:query] ||= {}
    contexts_to_link_to = Array(contexts_to_link_to)
    unless contexts_to_link_to.empty?
      options[:anchor] = "#{contexts_to_link_to.first.asset_string}"
    end
    options[:query][:include_contexts] = contexts_to_link_to.map{|c| c.asset_string}.join(",") unless contexts_to_link_to.empty?
    url_for(
      options[:query].merge({
        :controller => 'files',
        :action => "full_index",
        }.merge(options[:anchor].empty? ? {} : {
          :anchor => options[:anchor]
        })
      )
    )
  end
  helper_method :calendar_url_for, :files_url_for

  def conversations_path(params={})
    hash = params.keys.empty? ? '' : "##{params.to_json.unpack('H*').first}"
    "/conversations#{hash}"
  end
  helper_method :conversations_path
  
  # escape everything but slashes, see http://code.google.com/p/phusion-passenger/issues/detail?id=113
  FILE_PATH_ESCAPE_PATTERN = Regexp.new("[^#{URI::PATTERN::UNRESERVED}/]")
  def safe_domain_file_url(attachment, host_and_shard=nil, verifier = nil, download = false) # TODO: generalize this
    if !host_and_shard
      host_and_shard = HostUrl.file_host_with_shard(@domain_root_account || Account.default, request.host_with_port)
    end
    host, shard = host_and_shard
    res = "#{request.protocol}#{host}"

    shard.activate do
      ts, sig = @current_user && @current_user.access_verifier

      # add parameters so that the other domain can create a session that
      # will authorize file access but not full app access.  We need this in
      # case there are relative URLs in the file that point to other pieces
      # of content.
      opts = { :user_id => @current_user.try(:id), :ts => ts, :sf_verifier => sig }
      opts[:verifier] = verifier if verifier.present?

      if download
        # download "for realz, dude" (see later comments about :download)
        opts[:download_frd] = 1
      else
        # don't set :download here, because file_download_url won't like it. see
        # comment below for why we'd want to set :download
        opts[:inline] = 1
      end

      if @context && Attachment.relative_context?(@context.class.base_ar_class) && @context == attachment.context
        # so yeah, this is right. :inline=>1 wants :download=>1 to go along with
        # it, so we're setting :download=>1 *because* we want to display inline.
        opts[:download] = 1 unless download

        # if the context is one that supports relative paths (which requires extra
        # routes and stuff), then we'll build an actual named_context_url with the
        # params for show_relative
        res += named_context_url(@context, :context_file_url, attachment)
        res += '/' + URI.escape(attachment.full_display_path, FILE_PATH_ESCAPE_PATTERN)
        res += '?' + opts.to_query
      else
        # otherwise, just redirect to /files/:id
        res += file_download_url(attachment, opts.merge(:only_path => true))
      end
    end

    res
  end
  helper_method :safe_domain_file_url

  def feature_enabled?(feature)
    @features_enabled ||= {}
    feature = feature.to_sym
    return @features_enabled[feature] if @features_enabled[feature] != nil
    @features_enabled[feature] ||= begin
      if [:question_banks].include?(feature)
        true
      elsif feature == :twitter
        !!Twitter.config
      elsif feature == :facebook
        !!Facebook.config
      elsif feature == :linked_in
        !!LinkedIn.config
      elsif feature == :google_docs
        !!GoogleDocs.config
      elsif feature == :etherpad
        !!EtherpadCollaboration.config
      elsif feature == :kaltura
        !!Kaltura::ClientV3.config
      elsif feature == :web_conferences
        !!WebConference.config
      elsif feature == :tinychat
        !!Tinychat.config
      elsif feature == :scribd
        !!ScribdAPI.config
      elsif feature == :crocodoc
        !!Canvas::Crocodoc.config
      elsif feature == :lockdown_browser
        Canvas::Plugin.all_for_tag(:lockdown_browser).any? { |p| p.settings[:enabled] }
      else
        false
      end
    end
  end
  helper_method :feature_enabled?

  def service_enabled?(service)
    @domain_root_account && @domain_root_account.service_enabled?(service)
  end
  helper_method :service_enabled?

  def feature_and_service_enabled?(feature)
    feature_enabled?(feature) && service_enabled?(feature)
  end
  helper_method :feature_and_service_enabled?

  def show_new_dashboard?
    @current_user && @current_user.preferences[:new_dashboard]
  end

  def temporary_user_code(generate=true)
    if generate
      session[:temporary_user_code] ||= "tmp_#{Digest::MD5.hexdigest("#{Time.now.to_i.to_s}_#{rand.to_s}")}"
    else
      session[:temporary_user_code]
    end
  end

  def require_account_management(on_root_account = false)
    if (!@context.root_account? && on_root_account) || !@context.is_a?(Account)
      redirect_to named_context_url(@context, :context_url)
      return false
    else
      return false unless authorized_action(@context, @current_user, :manage_account_settings)
    end
  end

  def require_root_account_management
    require_account_management(true)
  end

  def require_site_admin_with_permission(permission)
    unless Account.site_admin.grants_right?(@current_user, permission)
      if @current_user
        flash[:error] = t "#application.errors.permission_denied", "You don't have permission to access that page"
        redirect_to root_url
      else
        redirect_to_login
      end
      return false
    end
  end

  def require_registered_user
    return false if require_user == false
    unless @current_user.registered?
      respond_to do |format|
        format.html { render :template => "shared/registration_incomplete", :layout => "application", :status => :unauthorized }
        format.json { render :json => { 'status' => 'unauthorized', 'message' => t('#errors.registration_incomplete', 'You need to confirm your email address before you can view this page') }, :status => :unauthorized }
      end
      return false
    end
  end

  def check_incomplete_registration
    if @current_user
      js_env :INCOMPLETE_REGISTRATION => params[:registration_success] && @current_user.pre_registered?, :USER_EMAIL => @current_user.email
    end
  end

  def page_views_enabled?
    PageView.page_views_enabled?
  end
  helper_method :page_views_enabled?

  # calls send_file if the io has a local file, or send_data otherwise
  # make sure to rewind the io first, if necessary
  def send_file_or_data(io, opts = {})
    cancel_cache_buster
    if io.respond_to?(:path) && io.path.present? && File.file?(io.path)
      send_file(io.path, opts)
    else
      send_data(io, opts)
    end
  end

  def verified_file_download_url(attachment, *opts)
    file_download_url(attachment, { :verifier => attachment.uuid }, *opts)
  end
  helper_method :verified_file_download_url

  def user_content(str, cache_key = nil)
    return nil unless str
    return str.html_safe unless str.match(/object|embed|equation_image/)

    UserContent.escape(str, request.host_with_port)
  end
  helper_method :user_content

  def find_bank(id, check_context_chain=true)
    bank = @context.assessment_question_banks.active.find_by_id(id) || @current_user.assessment_question_banks.active.find_by_id(id)
    if bank
      (block_given? ?
        authorized_action(bank, @current_user, :read) :
        bank.grants_right?(@current_user, session, :read)) or return nil
    elsif check_context_chain
      (block_given? ?
        authorized_action(@context, @current_user, :read_question_banks) :
        @context.grants_right?(@current_user, session, :read_question_banks)) or return nil
      bank = @context.inherited_assessment_question_banks.find_by_id(id)
    end
    yield if block_given? && (@bank = bank)
    bank
  end

  # refs #6632 -- once the speed grader ipad app is upgraded, we can remove these exceptions
  SKIP_JSON_CSRF_REGEX = %r{\A(?:/login|/logout|/dashboard/comment_session)}
  def prepend_json_csrf?
    request.get? && in_app? && !request.path.match(SKIP_JSON_CSRF_REGEX)
  end

  def in_app?
    @pseudonym_session && !@pseudonym_session.used_basic_auth?
  end

  def json_as_text?
    (request.headers['CONTENT_TYPE'].to_s =~ %r{multipart/form-data}) &&
    (params[:format].to_s != 'json' || in_app?)
  end

  def params_are_integers?(*check_params)
    begin
      check_params.each{ |p| Integer(params[p]) }
    rescue ArgumentError
      return false
    end
    true
  end

  def reset_session
    # when doing login/logout via ajax, we need to have the new csrf token
    # for subsequent requests.
    @resend_csrf_token_if_json = true
    super
  end

  def set_layout_options
    @embedded_view = params[:embedded]
    @headers = false if params[:no_headers] || @embedded_view
    (@body_classes ||= []) << 'embedded' if @embedded_view
  end

  def render(options = nil, extra_options = {}, &block)
    set_layout_options
    if options && options.key?(:json)
      json = options.delete(:json)
      json = ActiveSupport::JSON.encode(json) unless json.is_a?(String)
      # prepend our CSRF protection to the JSON response, unless this is an API
      # call that didn't use session auth, or a non-GET request.
      if prepend_json_csrf?
        json = "while(1);#{json}"
      end

      if @resend_csrf_token_if_json
        response.headers['X-CSRF-Token'] = form_authenticity_token
      end

      # fix for some browsers not properly handling json responses to multipart
      # file upload forms and s3 upload success redirects -- we'll respond with text instead.
      if options[:as_text] || json_as_text?
        options[:text] = json
      else
        options[:json] = json
      end
    end
    super
  end

  def jammit_css_bundles; @jammit_css_bundles ||= []; end
  helper_method :jammit_css_bundles

  def jammit_css(*args)
    opts = (args.last.is_a?(Hash) ? args.pop : {})
    Array(args).flatten.each do |bundle|
      jammit_css_bundles << [bundle, opts[:plugin]] unless jammit_css_bundles.include? [bundle, opts[:plugin]]
    end
    nil
  end
  helper_method :jammit_css

  def js_bundles; @js_bundles ||= []; end
  helper_method :js_bundles

  # Use this method to place a bundle on the page, note that the end goal here
  # is to only ever include one bundle per page load, so use this with care and
  # ensure that the bundle you are requiring isn't simply a dependency of some
  # other bundle.
  #
  # Bundles are defined in app/coffeescripts/bundles/<bundle>.coffee
  #
  # usage: js_bundle :gradebook2
  #
  # Only allows multiple arguments to support old usage of jammit_js
  #
  # Optional :plugin named parameter allows you to specify a plugin which
  # contains the bundle. Example:
  #
  # js_bundle :gradebook2, :plugin => :my_feature
  #
  # will look for the bundle in
  # /plugins/my_feature/(optimized|javascripts)/compiled/bundles/ rather than
  # /(optimized|javascripts)/compiled/bundles/
  def js_bundle(*args)
    opts = (args.last.is_a?(Hash) ? args.pop : {})
    Array(args).flatten.each do |bundle|
      js_bundles << [bundle, opts[:plugin]] unless js_bundles.include? [bundle, opts[:plugin]]
    end
    nil
  end
  helper_method :js_bundle

  def get_course_from_section
    if params[:section_id]
      @section = api_find(CourseSection, params.delete(:section_id))
      params[:course_id] = @section.course_id
    end
  end

  def reject_student_view_student
    return unless @current_user && @current_user.fake_student?
    @unauthorized_message ||= t('#application.errors.student_view_unauthorized', "You cannot access this functionality in student view.")
    render_unauthorized_action(@current_user)
  end

  def set_site_admin_context
    @context = Account.site_admin
    add_crumb t('#crumbs.site_admin', "Site Admin"), url_for(Account.site_admin)
  end

  def flash_notices
    @notices ||= begin
      notices = []
      notices << {:type => 'warning', :content => unsupported_browser, :classes => 'no_close'} if !browser_supported?
      if error = flash.delete(:error)
        notices << {:type => 'error', :content => error}
      end
      if warning = flash.delete(:warning)
        notices << {:type => 'warning', :content => warning}
      end
      if notice = (flash[:html_notice] ? flash.delete(:html_notice).html_safe : flash.delete(:notice))
        notices << {:type => 'success', :content => notice}
      end
      notices
    end
  end
  helper_method :flash_notices

  def unsupported_browser
    t("#application.warnings.unsupported_browser", "Your browser does not meet the minimum requirements for Canvas. Please visit the *Canvas Guides* for a complete list of supported browsers.", :wrapper => @template.link_to('\1', 'http://guides.instructure.com/s/2204/m/4214/l/41056-which-browsers-does-canvas-support'))
  end

  def browser_supported?
    session[:browser_supported] = Browser.supported?(request.user_agent) unless session.key?(:browser_supported)
    session[:browser_supported]
  end

  def profile_data(profile, viewer, session, includes)
    extend Api::V1::UserProfile
    extend Api::V1::Course
    extend Api::V1::Group
    includes ||= []
    data = user_profile_json(profile, viewer, session, includes, profile)
    data[:can_edit] = viewer == profile.user
    known_user = viewer.load_messageable_user(profile.user)
    common_courses = []
    common_groups = []
    if viewer != profile.user
      if known_user
        common_courses = known_user.common_courses.map do |course_id, roles|
          next if course_id.zero?
          c = course_json(Course.find(course_id), @current_user, session, ['html_url'], false)
          c[:roles] = roles.map { |role| Enrollment.readable_type(role) }
          c
        end.compact
        common_groups = known_user.common_groups.map do |group_id, roles|
          next if group_id.zero?
          g = group_json(Group.find(group_id), @current_user, session, :include => ['html_url'])
          # in the future groups will have more roles and we'll need soemthing similar to
          # the roles.map above in courses
          g[:roles] = [t('#group.memeber', "Member")]
          g
        end.compact
      end
    end
    data[:common_contexts] = [] + common_courses + common_groups
    data[:known_user] = known_user
    data
  end

  unless CANVAS_RAILS3
    filter_parameter_logging *LoggingFilter.filtered_parameters
  end

  # filter out sensitive parameters in the query string as well when logging
  # the rails "Completed in XXms" line.
  # this is fixed in Rails 3.x
  def complete_request_uri
    uri = LoggingFilter.filter_uri(request.request_uri)
    "#{request.protocol}#{request.host}#{uri}"
  end

  def self.batch_jobs_in_actions(opts = {})
    batch_opts = opts.delete(:batch)
    around_filter(opts) do |controller, action|
      Delayed::Batch.serial_batch(batch_opts || {}) do
        action.call
      end
    end
  end
end
