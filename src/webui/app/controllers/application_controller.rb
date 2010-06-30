# Filters added to this controller will be run for all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

require 'common/activexml/transport'
require 'libxml'
require 'person'

class ApplicationController < ActionController::Base

  before_filter :instantiate_controller_and_action_names
  before_filter :set_return_to, :reset_activexml, :authenticate
  before_filter :check_user
  after_filter :set_charset
  after_filter :validate_xhtml
  protect_from_forgery

  if Rails.env.test?
     prepend_before_filter :start_test_api
  end

  # Scrub sensitive parameters from your log
  filter_parameter_logging :password

  class InvalidHttpMethodError < Exception; end
  class MissingParameterError < Exception; end
  class ValidationError < Exception
    attr_reader :xml, :errors

    def message
      errors
    end

    def initialize( _xml, _errors )
      @xml = _xml
      @errors = _errors
    end
  end

  protected

  def set_return_to
    # we cannot get the original protocol when behind lighttpd/apache
    @return_to_host = params['return_to_host'] || "https://" + request.host
    @return_to_path = params['return_to_path'] || request.env['REQUEST_URI'].gsub(/&/, '&amp;')
    logger.debug "Setting return_to: \"#{@return_to_path}\""
  end

  def set_charset
    if !request.xhr? && !headers.has_key?('Content-Type')
      headers['Content-Type'] = "text/html; charset=utf-8"
    end
  end

  def require_login
    if !session[:login]
      render :text => 'Please login' and return if request.xhr?
      flash[:error] = "Please login to access the requested page."
      if (ICHAIN_MODE == 'off')
        redirect_to :controller => :user, :action => :login, :return_to_host => @return_to_host, :return_to_path => @return_to_path
      else
        redirect_to :controller => :main, :return_to_host => @return_to_host, :return_to_path => @return_to_path
      end
    end
  end

  # sets session[:login] if the user is authenticated
  def authenticate
    logger.debug "Authenticating with iChain mode: #{ICHAIN_MODE}"
    if ICHAIN_MODE == 'on' || ICHAIN_MODE == 'simulate'
      authenticate_ichain
    else
      authenticate_form_auth
    end
    if session[:login]
      logger.info "Authenticated request to \"#{@return_to_path}\" from #{session[:login]}"
    else
      logger.info "Anonymous request to #{@return_to_path}"
    end
  end

  def authenticate_ichain
    ichain_user = request.env['HTTP_X_USERNAME']
    ichain_user = ICHAIN_TEST_USER if ICHAIN_MODE == 'simulate' and ICHAIN_TEST_USER
    ichain_email = request.env['HTTP_X_EMAIL']
    ichain_email = ICHAIN_TEST_EMAIL if ICHAIN_MODE == 'simulate' and ICHAIN_TEST_EMAIL
    if ichain_user
      session[:login] = ichain_user
      session[:email] = ichain_email
      # Set the headers for direct connection to the api, TODO: is this thread safe?
      transport = ActiveXML::Config.transport_for( :project )
      transport.set_additional_header( "X-Username", ichain_user )
      transport.set_additional_header( "X-Email", ichain_email ) if ichain_email
    else
      session[:login] = nil
      session[:email] = nil
    end
  end

  def authenticate_form_auth
    if session[:login] and session[:passwd]
      # pass credentials to transport plugin, TODO: is this thread safe?
      ActiveXML::Config.transport_for(:project).login session[:login], session[:passwd]
    end
  end

  def frontend
    FrontendCompat.new
  end

  def valid_project_name? name
    name =~ /^\w[-_+\w\.:]+$/
  end

  def valid_package_name_read? name
    name =~ /^\w[-_+\w\.:]*$/
  end

  def valid_package_name_write? name
    name =~ /^\w[-_+\w\.]*$/
  end

  def valid_file_name? name
    name =~ /^[-\w_+~ ][-\w_\.+~ ]*$/
  end

  def valid_role_name? name
    name =~ /^[\w\-_\.+]+$/
  end

  def valid_target_name? name
    name =~ /^\w[-_\.\w&]*$/
  end

  def reset_activexml
    transport = ActiveXML::Config.transport_for(:project)
    transport.delete_additional_header "X-Username"
    transport.delete_additional_header "X-Email"
    transport.delete_additional_header 'Authorization'
  end

  def rescue_action_locally( exception )
    rescue_action_in_public( exception )
  end

  def rescue_action_in_public( exception )
    logger.error "rescue_action: caught #{exception.class}: #{exception.message}"
    message, code, api_exception = ActiveXML::Transport.extract_error_message exception

    case exception
    when ActionController::RoutingError
      render_error :status => 404, :message => "no such route"
    when ActionController::UnknownAction
      render_error :status => 404, :message => "unknown action"
    when ActiveXML::Transport::ForbiddenError
      # switch to registration on first access
      if code == "unregistered_ichain_user"
        render :template => "user/request_ichain" and return
      else
        #ExceptionNotifier.deliver_exception_notification(exception, self, request, {}) if send_exception_mail?
        if @user
          render_error :status => 403, :message => message
        else
          render_error :status => 401, :message => message
        end
      end
    when ActiveXML::Transport::UnauthorizedError
      ExceptionNotifier.deliver_exception_notification(exception, self, request, {}) if send_exception_mail?
      render_error :status => 401, :message => 'Unauthorized access'
    when ActionController::InvalidAuthenticityToken
      render_error :status => 401, :message => 'Invalid authenticity token'
    when ActiveXML::Transport::ConnectionError
      render_error :message => "Unable to connect to API host. (#{FRONTEND_HOST})", :status => 503
    when Timeout::Error
      render :template => "timeout" and return
    when ValidationError
      ExceptionNotifier.deliver_exception_notification(exception, self, request, {}) if send_exception_mail?
      render :template => "xml_errors", :locals => { :oldbody => exception.xml, :errors => exception.errors }, :status => 400
    when MissingParameterError 
      render_error :status => 400, :message => message
    when InvalidHttpMethodError
      render_error :message => "Invalid HTTP method used", :status => 400
    when Net::HTTPBadResponse
      # The api sometimes sends responses without a proper "Status:..." line (when it restarts?)
      render_error :message => "Unable to connect to API host. (#{FRONTEND_HOST})", :status => 503
    else
      if code != 404 && send_exception_mail?
        ExceptionNotifier.deliver_exception_notification(exception, self, request, {})
      end
      render_error :status => 400, :code => code, :message => message,
        :exception => exception, :api_exception => api_exception
    end
  end

  def render_error( opt={} )
    # :code is a string that comes from the api, :status is the http status code
    @status = opt[:status] || 400
    @code = opt[:code] || @status
    @message = opt[:message] || "No message set"
    @exception = opt[:exception] if local_request?
    @api_exception = opt[:api_exception] if local_request?
    logger.debug "ERROR: #{@code}; #{@message}"
    if request.xhr?
      render :text => @message, :status => @status, :layout => false
    else
      render :template => 'error', :status => @status, :locals => {:code => @code, :message => @message,
        :exception => @exception, :status => @status, :api_exception => @api_exception }
    end
  end

  def valid_http_methods(*methods)
    methods.map {|x| x.to_s.downcase.to_s}
    unless methods.include? request.method
      raise InvalidHttpMethodError, "Invalid HTTP Method: #{request.method.to_s.upcase}"
    end
  end

  def required_parameters(*parameters)
    parameters.each do |parameter|
      unless params.include? parameter.to_s
        raise MissingParameterError, "Required Parameter #{parameter} missing"
      end
    end
  end

  def discard_cache?
    cc = request.headers['Cache-Control']
    cc.blank? ? false : (['no-cache', 'max-age=0'].include? cc)
  end

  def find_cached(classname, *args)
    classname.free_cache( *args ) if discard_cache?
    classname.find_cached( *args )
  end

  def send_exception_mail?
    return !local_request? && !Rails.env.development? && ExceptionNotifier.exception_recipients && ExceptionNotifier.exception_recipients.length > 0
  end

  def instantiate_controller_and_action_names
    @current_action = action_name
    @current_controller = controller_name
  end

  def check_user
    return unless session[:login]
    @user ||= Rails.cache.fetch("person_#{session[:login]}") do 
       Person.find( session[:login] )
    end
    if @user
      begin
        @nr_involved_requests = @user.involved_requests(:cache => !discard_cache?).size
      rescue
      end
    end
  end
 
  private

  @@schema = nil
  def schema
    @@schema ||= LibXML::XML::Document.file(RAILS_ROOT + "/lib/xhtml1-strict.xsd")
  end

  def assert_xml_validates
    errors = []
    xmlbody = String.new response.body
    xmlbody.gsub!(/[\n\r]/, "\n")
    xmlbody.gsub!(/&[^;]*sp;/, '')
    
    LibXML::XML::Error.set_handler { |msg| errors << msg }
    begin
      document = LibXML::XML::Document.string xmlbody
    rescue LibXML::XML::Error => e
    end

    if document
      tmp = Tempfile.new('xml_out')
      tmp.write(xmlbody)
      tmp.close

      out = `xmllint --noout --schema #{RAILS_ROOT}/lib/xhtml1-strict.xsd #{tmp.path} 2>&1`
      if $?.exitstatus != 0
        document = nil
        errors = [out]
      end
    end
    
    # crashes unfortunately on 11.2
    #result = document.validate_schema(schema) do |message, error|
    #  puts "#{error ? 'error' : 'warning'} : #{message}"
    #end if document

    unless document
      erase_render_results
      raise ValidationError.new xmlbody, errors
    end
    return true
  end

  def validate_xhtml
    return unless (Rails.env.development? || Rails.env.test?)
    return if request.xhr?
  
    return if !(response.status =~ /200/ &&
        response.headers['Content-Type'] =~ /text\/html/i)

    if assert_xml_validates
      #assert_w3c_validates
    end
  end

  @@frontend = nil
  def start_test_api
     return if @@frontend
     @@frontend = IO.popen("#{RAILS_ROOT}/script/start_test_api")
     puts "started #{@@frontend.pid}"
     while true do
         line = @@frontend.gets
         break if line =~ /Test API ready/
    end
    puts "done #{@@frontend.pid}"
    at_exit do
       puts "kill #{@@frontend.pid}"
       Process.kill "INT", @@frontend.pid
       @@frontend = nil
    end
  end
end
