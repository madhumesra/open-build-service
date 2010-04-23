require 'project_status'
require 'collection'
require 'buildresult'
require 'role'
require 'models/package'

include ActionView::Helpers::UrlHelper

class ProjectController < ApplicationController

  class NoChangesError < Exception; end

  before_filter :require_project, :only => [:delete, :buildresult, :view,
    :edit, :save, :add_target_simple, :save_target, :status, :prjconf,
    :remove_person, :save_person, :add_person, :remove_target, :toggle_watch,
    :show, :monitor, :edit_prjconf, :list_requests,
    :packages, :users, :subprojects, :repositories, :attributes,
    :meta, :edit_meta, :edit_comment, :change_flag, :save_targets, :autocomplete_repositories ]

  before_filter :load_current_requests, :only => [:delete, :view,
    :edit, :save, :add_target_simple, :save_target, :status, :prjconf,
    :remove_person, :save_person, :add_person, :remove_target,
    :show, :monitor, :edit_prjconf, :list_requests,
    :packages, :users, :subprojects, :repositories, :attributes, :meta, :edit_meta ]
  before_filter :require_prjconf, :only => [:edit_prjconf, :prjconf ]
  before_filter :require_meta, :only => [:edit_meta, :meta ]

  def index
    redirect_to :action => 'list_public'
  end

  def list_all
    list and return
  end

  def list_public
    params['excludefilter'] = 'home:'
    list and return
  end

  def list
    @important_projects = get_important_projects
    @filterstring = params[:searchtext] || ''
    @excludefilter = params['excludefilter'] if params['excludefilter'] and params['excludefilter'] != 'undefined'
    get_filtered_projectlist @filterstring, @excludefilter
    if request.xhr?
      render :partial => 'search_project', :locals => {:project_list => @projects} and return
    end
    if @projects.length == 1
      redirect_to :action => 'show', :project => @projects.first and return
    end
    render :list, :status => params[:nextstatus]
  end

  def autocomplete_projects
    get_filtered_projectlist params[:q], ''
    render :text => @projects.map{|p| p.name}.join("\n")
  end

  def autocomplete_repositories
    @repos = @project.repositories
    render :text => @repos.join("\n")
  end

  def get_filtered_projectlist(filterstring, excludefilter='')
    # remove illegal xpath characters
    filterstring.sub!(/[\[\]\n]/, '')
    filterstring.sub!(/[']/, '&apos;')
    filterstring.sub!(/["]/, '&quot;')
    predicate = filterstring.empty? ? '' : "contains(@name, '#{filterstring}')"
    predicate += " and " if !predicate.empty? and !excludefilter.blank?
    predicate += "not(starts-with(@name,'#{excludefilter}'))" if !excludefilter.blank?
    result = Collection.find_cached :id, :what => "project", :predicate => predicate, :expires_in => 2.minutes
    @projects = result.each.sort {|a,b| a.name.downcase <=> b.name.downcase}
  end
  private :get_filtered_projectlist

  # TODO: move to home controller
  def list_my
    if not check_user
      flash[:error] = 'Requires login'
      redirect_to :action => :list_public
      return
    end
    if @user.has_element? :watchlist
      #extract a list of project names and sort them case insensitive
      @watchlist = @user.watchlist.each_project.map {|p| p.name }.sort {|a,b| a.downcase <=> b.downcase }
    end

    @iprojects = @user.involved_projects.each.map {|x| x.name}.uniq.sort
    @ipackages = Hash.new
    pkglist = @user.involved_packages.each.reject {|x| @iprojects.include?(x.project)}
    pkglist.sort(&@user.method('packagesorter')).each do |pack|
      @ipackages[pack.project] ||= Array.new
      @ipackages[pack.project] << pack.name if !@ipackages[pack.project].include? pack.name
    end
  end

  def users
    @email_hash = Hash.new
    @project.each_person do |person|
      @email_hash[person.userid.to_s] = Person.find_cached( person.userid, :expires_in => 30.minutes ).email.to_s
    end
    @roles = Role.local_roles
  end

  def subprojects
    @subprojects = Hash.new
    sub_names = Collection.find :id, :what => "project", :predicate => "starts-with(@name,'#{@project}:')"
    sub_names.each do |sub|
      @subprojects[sub.name] = Project.find_cached( sub.name )
    end
    @parentprojects = Hash.new
    parent_names = @project.name.split ':'
    parent_names.each_with_index do |parent, idx|
      parent_name = parent_names.slice(0, idx+1).join(':')
      unless [@project.name, 'home'].include?( parent_name )
        parent_project = Project.find_cached( parent_name )
        @parentprojects[parent_name] = parent_project unless parent_project.blank?
      end
    end
  end

  def attributes
    @attributes = Attribute.find(:project, :project => params[:project])
  end

  def remove_watched_project
    project = params[:project]
    if check_user
      logger.debug "removing watched project '#{project}' from user '#@user'"
      @user.remove_watched_project project
      @user.save

      if @user.has_element? :watchlist
        @watchlist = @user.watchlist.each_project.map {|p| p.name }.sort {|a,b| a.downcase <=> b.downcase }
      end

      render :partial => 'watch_list'
    end
  end

  def new
    @namespace = params[:ns]
    @project_name = params[:project]
    if params[:ns] == "home:#{session[:login]}"
      @project = Project.find_cached params[:ns]
      unless @project
        flash.now[:note] = "Your home project doesn't exist yet. You can create it now by entering some" +
          " descriptive data and press the 'Create Project' button."
        @project_name = params[:ns]
      end
    end
    if @project_name =~ /home:(.+)/
      @project_title = "#$1's Home Project"
    else
      @project_title = ""
    end
  end

  def show
    @bugowner_mail = Person.find_cached( @project.bugowner ).email.to_s if @project.bugowner
    @packages = Rails.cache.fetch("%s_packages_mainpage" % @project, :expires_in => 30.minutes) do
      Package.find_cached( :all, :project => @project, :expires_in => 30.seconds )
    end

    @problem_packages = Rails.cache.fetch("%s_problem_packages" % @project, :expires_in => 30.minutes) do
      buildresult = Buildresult.find_cached( :project => @project, :view => 'status', :code => ['failed', 'broken', 'unresolvable'], :expires_in => 2.minutes )
      if buildresult
        results = buildresult.data.find( 'result/status' )
        results.map{|e| e.attributes['package'] }.uniq.size
      else
        0
      end
    end

    render :show, :status => params[:nextstatus] if params[:nextstatus]
  end

  # TODO we need the architectures in api/distributions
  def add_target_simple
    dist_xml = Rails.cache.fetch("distributions", :expires_in => 30.minutes) do
      frontend = ActiveXML::Config::transport_for( :package )
      frontend.direct_http URI("/distributions"), :method => "GET"
    end
    @distributions = XML::Document.string dist_xml
  end

  def add_person
    @roles = Role.local_roles
  end

  def buildresult
    @buildresult = Buildresult.find_cached( :project => params[:project], :view => 'summary', :expires_in => 30.seconds )

    @repohash = Hash.new
    @statushash = Hash.new
    @repostatushash = Hash.new
    @packagenames = Array.new

    @buildresult.each_result do |result|
      repo = result.repository
      arch = result.arch

      # repository status cache
      @repostatushash[repo] ||= Hash.new
      @repostatushash[repo][arch] = Hash.new

      if result.has_attribute? :state
        if result.has_attribute? :dirty
          @repostatushash[repo][arch] = "outdated_" + result.state.to_s
        else
          @repostatushash[repo][arch] = result.state.to_s
        end
      end
    end if @buildresult
    if @buildresult
      @buildresult = @buildresult.to_a
    else
      @buildresult = Array.new
    end
    render :partial => 'buildstatus', :locals => {:has_data => true}
  end

  def delete
    valid_http_methods :post
    @confirmed = params[:confirmed]
    if @confirmed == "1"
      begin
        if params[:force] == "1"
          @project.delete :force => 1
        else
          @project.delete
        end
        Rails.cache.delete("%s_packages_mainpage" % @project)
        Rails.cache.delete("%s_problem_packages" % @project)
      rescue ActiveXML::Transport::Error => err
        @error, @code, @api_exception = ActiveXML::Transport.extract_error_message err
        logger.error "Could not delete project #{@project}: #{@error}"
      end
    end
  end

  def arch_list
    if @arch_list.nil?
      tmp = []
      @project.each_repository do |repo|
        tmp += repo.archs
      end
      @arch_list = tmp.sort.uniq
    end
    return @arch_list
  end

  def enable_arch
    @project = Project.find_cached(params[:project])
    @arch_list = arch_list
    repo = @project.repository[params[:repo]]
    repo.add_arch params[:arch]
    if @project.save
      render :partial => 'repository_item', :locals => { :repo => repo, :has_data => true }
    else
      render :text => 'enabling architecture failed'
    end
  end

  def edit_target
    repo = @project.repository[params[:repo]]
    @arch_list = arch_list
    render :partial => 'repository_edit_form', :locals => { :repo => repo, :error => nil }
  end

  def update_target
    valid_http_methods :post
    repo = @project.repository[params[:repo]]
    repo.name = params[:name]
    repo.archs = params[:arch].to_a
    @arch_list = arch_list
    begin
      @project.save
      render :partial => 'repository_item', :locals => { :repo => repo, :has_data => true }
    rescue => e
      repo.name = params[:original_name]
      render :partial => 'repository_edit_form', :locals => { :error => "#{ActiveXML::Transport.extract_error_message( e )[0]}",
        :repo => repo } and return
    end
  end

  def repositories
    # overwrite @project with different view
    # TODO to get this cached we need to make sure it gets purged on repo updates
    @project = Project.find( params[:project], :view => :flagdetails )
  end

  def packages
    @packages = Package.find_cached( :all, :project => @project, :expires_in => 30.seconds )
    # push to long time cache for the project frontpage
    Rails.cache.write("#{@project}_packages_mainpage", @packages, :expires_in => 30.minutes)
  end

  def autocomplete_packages
    @project = params[:project]
    packages
    render :text => @packages.each.select{|p| p.name.index(params[:q]) }.map{|p| p.name}.join("\n")
  end


  def list_requests
  end

  def save_new
    if params[:name].blank? || !valid_project_name?( params[:name] )
      flash[:error] = "Invalid project name '#{params[:name]}'."
      redirect_to :action => "new", :ns => params[:ns] and return
    end

    project_name = params[:name].strip
    project_name = params[:ns].strip + ":" + project_name.strip if params[:ns]

    if Project.exists? project_name
      flash[:error] = "Project '#{project_name}' already exists."
      redirect_to :action => "new", :ns => params[:ns] and return
    end

    #store project
    @project = Project.new(:name => project_name)
    @project.title.text = params[:title]
    @project.description.text = params[:description]
    @project.set_remoteurl(params[:remoteurl]) if params[:remoteurl]
    @project.add_person :userid => session[:login], :role => 'maintainer'
    @project.add_person :userid => session[:login], :role => 'bugowner'
    begin
      if @project.save
        flash[:note] = "Project '#{@project}' was created successfully"
        redirect_to :action => 'show', :project => project_name and return
      else
        flash[:error] = "Failed to save project '#{@project}'"
      end
    rescue ActiveXML::Transport::ForbiddenError => err
      flash[:error] = "You lack the permission to create the project '#{@project}'. " +
        "Please create it in your home:%s namespace" % session[:login]
      redirect_to :action => 'new', :ns => "home:" + session[:login] and return
    end
    redirect_to :action => 'new'
  end

  def save
    if ( !params[:title] )
      flash[:error] = "Title must not be empty"
      redirect_to :action => 'edit', :project => params[:project]
      return
    end

    @project.title.text = params[:title]
    @project.description.text = params[:description]

    if @project.save
      flash[:note] = "Project '#{@project}' was saved successfully"
    else
      flash[:error] = "Failed to save project '#{@project}'"
    end

    redirect_to :action => :show, :project => @project
  end


  def save_targets
    valid_http_methods :post
    if (params['repo'].blank?)
      flash[:error] = "Please select a repository."
      redirect_to :action => :add_target_simple, :project => @project and return
    end

    params['repo'].each do |repo|
      if !valid_target_name? repo
        flash[:error] = "Illegal target name #{repo}."
        redirect_to :action => :add_target_simple, :project => @project and return
      end
      repo_path = params[repo + '_repo'] || "#{params['target_project']}/#{params['target_repo']}"
      repo_archs = params[repo + '_arch'] || params['arch']
      logger.debug "Adding repo: #{repo_path}, archs: #{repo_archs}"
      @project.add_repository :reponame => repo, :repo_path => repo_path, :arch => repo_archs

      # FIXME: will be cleaned up after implementing FATE #308899
      if repo == "images"
        prjconf = frontend.get_source(:project => @project, :filename => '_config')
        unless prjconf =~ /^Type:/
          prjconf = "%if \"%_repository\" == \"images\"\nType: kiwi\nRepotype: none\nPatterntype: none\n%endif\n" << prjconf
          frontend.put_file(prjconf, :project => @project, :filename => '_config')
        end
      end
    end

    begin
      if @project.save
        flash[:note] = "Build targets were added successfully"
      else
        flash[:error] = "Failed to add build targets"
      end
    rescue ActiveXML::Transport::Error => e
      message, code, api_exception = ActiveXML::Transport.extract_error_message e
      flash[:error] = "Failed to add build targets: " + message
    end
    redirect_to :action => :repositories, :project => @project
  end


  def remove_target
    valid_http_methods :post
    if not params[:target]
      flash[:error] = "Target removal failed, no target selected!"
      redirect_to :action => :show, :project => params[:project]
    end
    @project.remove_repository params[:target]

    begin
      if @project.save
        flash[:note] = "Target '#{params[:target]}' was removed"
      else
        flash[:error] = "Failed to remove target '#{params[:target]}'"
      end
    rescue ActiveXML::Transport::Error => e
      message, code, api_exception = ActiveXML::Transport.extract_error_message e
      flash[:error] = "Failed to remove target '#{params[:target]}' " + message
    end

    redirect_to :action => :repositories, :project => @project
  end


  def save_person
    valid_http_methods(:post)
    user = Person.find_cached( params[:userid] )
    unless user
      flash[:error] = "Unknown user with id '#{params[:userid]}'"
      redirect_to :action => :add_person, :project => @project, :role => params[:role]
      return
    end
    @project.add_person( :userid => user.login.to_s, :role => params[:role] )
    if @project.save
      flash[:note] = "Added user #{user.login} with role #{params[:role]} to project #{@project}"
    else
      flash[:error] = "Failed to add user '#{params[:userid]}'"
    end
    redirect_to :action => :users, :project => @project
  end


  def remove_person
    if params[:userid].blank?
      flash[:note] = "User removal aborted, no user id given!"
      redirect_to :action => :show, :project => params[:project] and return
    end
    @project.remove_persons( :userid => params[:userid], :role => params[:role] )
    if @project.save
      flash[:note] = "Removed user #{params[:userid]}"
    else
      flash[:error] = "Failed to remove user '#{params[:userid]}'"
    end
    redirect_to :action => :users, :project => params[:project]
  end


  def monitor
    @name_filter = params[:pkgname]
    @lastbuild_switch = params[:lastbuild]
    if params[:defaults]
      defaults = (Integer(params[:defaults]) rescue 1) > 0
    else
      defaults = true
    end
    params['expansionerror'] = 1 if params['unresolvable']
    @avail_status_values =
      ['succeeded', 'failed', 'unresolvable', 'broken',
      'blocked', 'dispatching', 'scheduled', 'building', 'finished',
      'signing', 'disabled', 'excluded', 'unknown']
    @filter_out = ['disabled', 'excluded', 'unknown']
    @status_filter = []
    @avail_status_values.each { |s|
      id=s.gsub(' ', '')
      if params.has_key?(id)
        next unless (Integer(params[id]) rescue 1) > 0
      else
        next unless defaults
      end
      next if defaults && @filter_out.include?(s)
      @status_filter << s
    }

    @avail_arch_values = []
    @avail_repo_values = []

    @project.each_repository { |r|
      @avail_repo_values << r.name
      @avail_arch_values << r.archs if r.archs
    }
    @avail_arch_values = @avail_arch_values.flatten.uniq.sort
    @avail_repo_values = @avail_repo_values.flatten.uniq.sort

    @arch_filter = []
    @avail_arch_values.each { |s|
      if defaults || (params.has_key?('arch_' + s) && params['arch_' + s])
        @arch_filter << s
      end
    }

    @repo_filter = []
    @avail_repo_values.each { |s|
      if defaults || (params.has_key?('repo_' + s) && params['repo_' + s])
        @repo_filter << s
      end
    }

    find_opt = { :project => @project, :view => 'status', :code => @status_filter,
      :arch => @arch_filter, :repo => @repo_filter }
    find_opt[:lastbuild] = 1 unless @lastbuild_switch.blank?

    @buildresult = Buildresult.find_cached( find_opt.merge({:expires_in => 1.minute}) )
    unless @buildresult
      flash[:error] = "No build results for project '#{@project}'"
      redirect_to :action => :show, :project => params[:project]
      return
    end

    if not @buildresult.has_element? :result
      @buildresult_unavailable = true
      return
    end

    @repohash = Hash.new
    @statushash = Hash.new
    @repostatushash = Hash.new
    @packagenames = Array.new

    @buildresult.each_result do |result|
      @resultvalue = result
      repo = result.repository
      arch = result.arch

      next unless @repo_filter.include? repo
      @repohash[repo] ||= Array.new
      next unless @arch_filter.include? arch
      @repohash[repo] << arch

      # package status cache
      @statushash[repo] ||= Hash.new

      stathash = Hash.new
      result.each_status do |status|
        stathash[status.package.to_s] = status
      end
      stathash.keys.each do |p|
        @packagenames << p.to_s
      end

      @statushash[repo][arch] = stathash

      # repository status cache
      @repostatushash[repo] ||= Hash.new
      @repostatushash[repo][arch] = Hash.new

      if result.has_attribute? :state
        if result.has_attribute? :dirty
          @repostatushash[repo][arch] = "outdated_" + result.state.to_s
        else
          @repostatushash[repo][arch] = result.state.to_s
        end
      end
    end
    @packagenames = @packagenames.flatten.uniq.sort

    ## Filter for PackageNames ####
    @packagenames.reject! {|name| not filter_matches?(name,@name_filter) } if not @name_filter.blank?
    packagename_hash = Hash.new
    @packagenames.each { |p| packagename_hash[p.to_s] = 1 }

    # filter out repos without current packages
    @statushash.each do |repo, hash|
      hash.each do |arch, packages|

        has_packages = false
        packages.each do |p, status|
          if packagename_hash.has_key? p
            has_packages = true
            break
          end
        end
        unless has_packages
          @repohash[repo].delete arch
        end
      end
    end
  end

  def filter_matches?(input,filter_string)
    result = false
    filter_string.gsub!(/\s*/,'')
    filter_string.split(',').each { |filter|
      no_invert = filter.match(/(^!?)(.+)/)
      if no_invert[1] == '!'
        result = input.include?(no_invert[2]) ? result : true
      else
        result = input.include?(no_invert[2]) ? true : result
      end
    }
    return result
  end

  # should be in the package controller, but all the helper functions to render the result of a build are in the project
  def package_buildresult
    @project = params[:project]
    @package = params[:package]
    begin
      @buildresult = Buildresult.find_cached( :project => params[:project], :package => params[:package], :view => 'status', :lastbuild => 1, :expires_in => 2.minutes )
    rescue ActiveXML::Transport::Error # wild work around for backend bug (sends 400 for 'not found')
    end
    @repohash = Hash.new
    @statushash = Hash.new

    @buildresult.each_result do |result|
      repo = result.repository
      arch = result.arch

      @repohash[repo] ||= Array.new
      @repohash[repo] << arch

      # package status cache
      @statushash[repo] ||= Hash.new
      @statushash[repo][arch] = Hash.new

      stathash = @statushash[repo][arch]
      result.each_status do |status|
        stathash[status.package] = status
      end
    end if @buildresult
    render :layout => false
  end

  def toggle_watch
    render :update do |page|
      if @user.watches? @project.name
        logger.debug "Remove #{@project} from watchlist for #{@user}"
        @user.remove_watched_project @project.name
        page << "$('#imgwatch').attr('src', '../images/magnifier_zoom_in.png');"
        page << "$('#imgwatch').attr('title', 'Watch this project');"
        page << "$('#watchlist_#{Digest::MD5.hexdigest @project.name}').remove(); "
      else
        logger.debug "Add #{@project} to watchlist for #{@user}"
        @user.add_watched_project @project.name
        page << "$('#imgwatch').attr('src', '../images/magnifier_zoom_out.png');"
        page << "$('#imgwatch').attr('title', \"Don't watch this project\");"
        page << "$('#menu-favorites').append('<li id=\"watchlist_#{ Digest::MD5.hexdigest @project.name }\">#{link_to @project, {:controller => 'project', :action => :show, :project => @project}}</li>'); "
      end
    end
    @user.save
    Person.free_cache( :login => session[:login] )
  end

  def edit_meta
  end

  def meta
  end

  def prjconf
  end

  def edit_prjconf
  end

  def change_flag
    if request.post? and params[:cmd] and params[:flag]
      frontend.source_cmd params[:cmd], :project => @project, :repository => params[:repository], :arch => params[:arch], :flag => params[:flag], :status => params[:status]
    end
    Project.free_cache( :name => params[:project], :view => :flagdetails )
    if request.xhr?
      @project = Project.find_cached( :name => params[:project], :view => :flagdetails )
      render :partial => 'shared/repositories_flag_table', :locals => { :flags => @project.send(params[:flag]), :obj => @project }
    else
      redirect_to :action => :repositories, :project => @project
    end
  end

  def save_prjconf
    frontend.put_file(params[:config], :project => params[:project], :filename => '_config')
    flash[:note] = "Project Config successfully saved"
    redirect_to :action => :prjconf, :project => params[:project]
  end

  def save_meta
    frontend.put_file(params[:meta], :project => params[:project], :filename => '_meta')
    flash[:note] = "Config successfully saved"
    Project.free_cache params[:project]
    redirect_to :action => :meta, :project => params[:project]
  end

  def clear_failed_comment
    # TODO(Jan): put this logic in the Attribute model
    transport ||= ActiveXML::Config::transport_for(:package)
    params["package"].to_a.each do |p|
      begin
        transport.direct_http URI("/source/#{params[:project]}/#{p}/_attribute/OBS:ProjectStatusPackageFailComment"), :method => "DELETE"
      rescue ActiveXML::Transport::ForbiddenError => e
        message, code, api_exception = ActiveXML::Transport.extract_error_message e
        flash[:error] = message
        redirect_to :action => :status, :project => params[:project]
        return
      end
    end
    if request.xhr?
      render :text => '<em>Cleared comment</em>'
      return
    end
    if params["package"].to_a.length > 1
      flash[:note] = "Cleared comment for packages %s" % params[:package].to_a.join(',')
    else
      flash[:note] = "Cleared comment for package #{params[:package]}"
    end
    redirect_to :action => :status, :project => params[:project]
  end

  def edit_comment_form
    @comment = params[:comment]
    @project = params[:project]
    @package = params[:package]
    render :partial => "edit_comment_form"
  end

  def edit_comment
    @package = params[:package]
    attr = Attribute.new(:project => params[:project], :package => params[:package])
    attr.set('OBS', 'ProjectStatusPackageFailComment', params[:text])
    result = attr.save
    @result = result
    if result[:type] == :error
      @comment = params[:last_comment]
    else
      @comment = params[:text]
    end
    render :partial => "edit_comment"
  end

  def get_changes_md5(project, package)
    begin
      dir = Directory.find_cached(:project => project, :package => package, :expand => "1")
    rescue => e
      dir = nil
    end
    return nil unless dir
    changes = []
    dir.each_entry do |e|
      name = e.name.to_s
      if name =~ /.changes$/
        if name == package + ".changes"
          return e.md5.to_s
        end
        changes << e.md5.to_s
      end
    end
    if changes.size == 1
      return changes[0]
    end
    logger.debug "can't find unique changes file: " + dir.dump_xml
    raise NoChangesError, "no .changes file in #{project}/#{package}"
  end
  private :get_changes_md5

  def changes_file_difference(project1, package1, project2, package2)
    md5_1 = get_changes_md5(project1, package1)
    md5_2 = get_changes_md5(project2, package2)
    return md5_1 != md5_2
  end
  private :changes_file_difference

  def status
    status = Rails.cache.fetch("status_%s" % @project, :expires_in => 10.minutes) do
      ProjectStatus.find(:project => @project)
    end

    all_packages = "All Packages"
    no_project = "No Project"
    @current_develproject = params[:filter_devel] || all_packages
    @ignore_pending = params[:ignore_pending] || false
    @limit_to_fails = !(!params[:limit_to_fails].nil? && params[:limit_to_fails] == 'false')
    @include_versions = !(!params[:include_versions].nil? && params[:include_versions] == 'false')

    attributes = PackageAttribute.find_cached(:namespace => 'OBS',
      :name => 'ProjectStatusPackageFailComment', :project => @project, :expires_in => 2.minutes)
    comments = Hash.new
    attributes.data.find('/attribute/project/package/values').each do |p|
      # unfortunately libxml's find_first does not work on nodes, but on document (known bug)
      p.each_element do |v|
        comments[p.parent['name']] = v.content
      end
    end

    upstream_versions = Hash.new
    upstream_urls = Hash.new

    if @include_versions
      attributes = PackageAttribute.find_cached(:namespace => 'openSUSE',
        :name => 'UpstreamVersion', :project => @project, :expires_in => 2.minutes)
      attributes.data.find('//package//values').each do |p|
        # unfortunately libxml's find_first does not work on nodes, but on document (known bug)
        p.each_element do |v|
          upstream_versions[p.parent['name']] = v.content
        end
      end

      attributes = PackageAttribute.find_cached(:namespace => 'openSUSE',
        :name => 'UpstreamTarballURL', :project => @project, :expires_in => 2.minutes)
      attributes.data.find('//package//values').each do |p|
        # unfortunately libxml's find_first does not work on nodes, but on document (known bug)
        p.each_element do |v|
          upstream_urls[p.parent['name']] = v.content
        end
      end
    end

    raw_requests = Rails.cache.fetch("requests_new", :expires_in => 5.minutes) do
      Collection.find(:what => 'request', :predicate => "(state/@name='new')")
    end

    @requests = Hash.new
    submits = Hash.new
    raw_requests.each_request do |r|
      id = Integer(r.data['id'])
      @requests[id] = r
      #logger.debug r.dump_xml + " " + (r.has_element?('action') ? r.action.data['type'] : "false")
      if r.has_element?('action') && r.action.data['type'] == "submit"
        target = r.action.target.data
        key = target['project'] + "/" + target['package']
        submits[key] ||= Array.new
        submits[key] << id
      end
    end

    @develprojects = Array.new

    @packages = Array.new
    status.each_package do |p|
      currentpack = Hash.new
      currentpack['name'] = p.name
      currentpack['failedcomment'] = comments[p.name] if comments.has_key? p.name
      newest = 0

      p.each_failure do |f|
        next if f.repo =~ /ppc/
        next if f.repo =~ /staging/
        next if f.repo =~ /snapshot/
        next if newest > (Integer(f.time) rescue 0)
        next if f.srcmd5 != p.srcmd5
        currentpack['failedarch'] = f.repo.split('/')[1]
        currentpack['failedrepo'] = f.repo.split('/')[0]
        newest = Integer(f.time)
        currentpack['firstfail'] = newest
      end

      currentpack['problems'] = Array.new
      currentpack['requests_from'] = Array.new
      currentpack['requests_to'] = Array.new

      key = @project.name + "/" + p.name
      if submits.has_key? key
        currentpack['requests_from'].concat(submits[key])
      end

      currentpack['version'] = p.version
      if upstream_versions.has_key? p.name
        upstream_version = upstream_versions[p.name]
        if p.version < upstream_version
          currentpack['upstream_version'] = upstream_version
          currentpack['upstream_url'] = upstream_urls[p.name] if upstream_urls.has_key? p.name
        end
      end

      currentpack['md5'] = p.srcmd5

      if p.has_element? :develpack
        @develprojects << p.develpack.proj
        currentpack['develproject'] = p.develpack.proj
        if (@current_develproject != p.develpack.proj or @current_develproject == no_project) and @current_develproject != all_packages
          next
        end
        currentpack['develpackage'] = p.develpack.pack
        key = "%s/%s" % [p.develpack.proj, p.develpack.pack]
        if submits.has_key? key
          currentpack['requests_to'].concat(submits[key])
        end
        currentpack['develmd5'] = p.develpack.package.srcmd5

        if currentpack['md5'] and currentpack['develmd5'] and currentpack['md5'] != currentpack['develmd5']
          currentpack['problems'] << Rails.cache.fetch("dd_%s_%s" % [currentpack['md5'], currentpack['develmd5']]) do
            begin
              if changes_file_difference(@project.name, p.name, currentpack['develproject'], currentpack['develpackage'])
                'different_changes'
              else
                'different_sources'
              end
            rescue NoChangesError => e
              e.message
            end
          end
        end
        if p.develpack.package.has_element? :error
          currentpack['problems'] << 'error-' + p.develpack.package.error.to_s
        end
      elsif @current_develproject != no_project
        next if @current_develproject != all_packages
      end

      next if !currentpack['requests_from'].empty? and @ignore_pending
      if @limit_to_fails
        next if !currentpack['firstfail']
      else
        next unless (currentpack['firstfail'] or currentpack['failedcomment'] or currentpack['upstream_version'] or
            !currentpack['problems'].empty? or !currentpack['requests_from'].empty? or !currentpack['requests_to'].empty?)
      end
      @packages << currentpack
    end

    @develprojects.sort! { |x,y| x.downcase <=> y.downcase }.uniq!
    @develprojects.insert(0, all_packages)
    @develprojects.insert(1, no_project)

    @packages.sort! { |x,y| x['name'] <=> y['name'] }
  end

  private

  def get_important_projects
    predicate = "[attribute/@name='OBS:VeryImportantProject']"
    return Collection.find_cached :id, :what => "project", :predicate => predicate
  end


  def filter_packages( project, filterstring )
    result = Collection.find :id, :what => "package",
      :predicate => "@project='#{project}' and contains(@name,'#{filterstring}')"
    return result.each.map {|x| x.name}
  end

  def require_project
    if !valid_project_name? params[:project]
      unless request.xhr?
        flash[:error] = "#{params[:project]} is not a valid project name"
        redirect_to :controller => "project", :action => "list_public", :nextstatus => 404 and return
      else
        render :text => 'Not a valid project name', :status => 404 and return
      end
    end
    @project = Project.find_cached( params[:project], :expires_in => 5.minutes )
    check_user
    unless @project
      if @user and params[:project] == "home:#{@user}"
        # checks if the user is registered yet
        flash[:note] = "Your home project doesn't exist yet. You can create it now by entering some" +
          " descriptive data and press the 'Create Project' button."
        redirect_to :action => :new, :project => "home:" + session[:login] and return
      end
      # remove automatically if a user watches a removed project
      if @user and @user.watches? params[:project]
        @user.remove_watched_project params[:project] and @user.save
      end
      unless request.xhr?
        flash[:error] = "Project not found: #{params[:project]}"
        redirect_to :controller => "project", :action => "list_public", :nextstatus => 404 and return
      else
        render :text => "Project not found: #{params[:project]}", :status => 404 and return
      end
    end
  end

  def require_prjconf
    begin
      @config = frontend.get_source(:project => params[:project], :filename => '_config')
    rescue ActiveXML::Transport::NotFoundError
      flash[:error] = "Project _config not found: #{params[:project]}"
      redirect_to :controller => "project", :action => "list_public", :nextstatus => 404
    end
  end

  def require_meta
    begin
      @meta = frontend.get_source(:project => params[:project], :filename => '_meta')
    rescue ActiveXML::Transport::NotFoundError
      flash[:error] = "Project _meta not found: #{params[:project]}"
      redirect_to :controller => "project", :action => "list_public", :nextstatus => 404
    end
  end

  def load_current_requests
    predicate = "state/@name='new' and action/target/@project='#{@project}'"
    @current_requests = Collection.find_cached :what => :request, :predicate => predicate, :expires_in => 1.minutes
    @project_has_requests = !@current_requests.is_empty?
  end

end
