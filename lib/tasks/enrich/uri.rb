module Intrigue
module Task
module Enrich
class Uri < Intrigue::Task::BaseTask

  include Intrigue::Ident

  def self.metadata
    {
      :name => "enrich/uri",
      :pretty_name => "Enrich Uri",
      :authors => ["jcran"],
      :description => "Fills in details for a URI",
      :references => [],
      :type => "enrichment",
      :passive => false,
      :allowed_types => ["Uri"],
      :example_entities => [
        {"type" => "Uri", "details" => {"name" => "https://intrigue.io"}}],
      :allowed_options => [
        {:name => "correlate_endpoints", :regex => "boolean", :default => false }
      ],
      :created_types => []
    }
  end

  def run

    uri = _get_entity_name
    begin
      hostname = URI.parse(uri).host
      port = URI.parse(uri).port
      scheme = URI.parse(uri).scheme
    rescue URI::InvalidURIError => e
      _log_error "Error parsing... #{uri}"
      return nil
    end

    _log "Making initial requests, following redirect"
    # Grab the full response
    response = http_request :get, uri
    response2 = http_request :get, uri

    unless response && response2 && response.body
      _log_error "Unable to receive a response for #{uri}, bailing"
      return
    end

    response_data_hash = Digest::SHA256.base64digest(response.body)

    # we can check the existing response, so send that
    _log "Checking if Forms"
    contains_forms = check_forms(response.body)

    # we'll need to make another request
    _log "Checking OPTIONS"
    verbs_enabled = check_options_endpoint(uri)

    # grab all script_references, normalize to include full uri if needed 
    _log "Parsing out Scripts"
    temp_script_links = response.body.scan(/<script.*?src=["|'](.*?)["|']/).map{ |x| x.first if x }
    # add http/https where appropriate
    temp_script_links = temp_script_links.map { |x| x =~ /^\/\// ? "#{scheme}:#{x}" : x }
    # add base_url where appropriate
    script_links = temp_script_links.map { |x| x =~ /^\// ? "#{uri}#{x}" : x }

    # Parse out, and fingeprint the componentes 
    script_components = extract_and_fingerprint_scripts(script_links, hostname)
    _log "Got fingerprinted script components: #{script_components.map{|x| x["product"] }}"

    ### Check for vulns in included scripts
    fingerprint = []
    if script_components.count > 0
      fingerprint.concat(add_vulns_by_cpe(script_components))
    end

    # Save the Headers
    headers = []
    _log "Saving Headers"
    response.each_header{|x| headers << "#{x}: #{response[x]}" }

    # Use intrigue-ident code to request all of the pages we
    # need to properly fingerprint
    _log "Attempting to fingerprint (without the browser)!"
    ident_matches = generate_http_requests_and_check(uri,{:enable_browser => false}) || {}

    ident_fingerprints = ident_matches["fingerprint"] || []
    ident_content_checks = ident_matches["content"] || []
    _log "Got #{ident_fingerprints.count} fingerprints!"

    # get the request/response we made so we can keep track of redirects
    ident_responses = ident_matches["responses"]
    _log "Received #{ident_responses.count} responses for fingerprints!"

    ###
    ### Check for vulns based on Ident FPs
    ###
    if ident_fingerprints.count > 0
      fingerprint.concat(add_vulns_by_cpe(ident_fingerprints))
    end

    # we can check the existing response, so send that
    # also need to send over the existing fingeprints
    _log "Checking if API Endpoint" 
    api_endpoint = check_api_enabled(response, fingerprint)
    
    # process interesting content checks that requested an issue be created
    issues_to_be_created = ident_content_checks.select {|c| c["issue"] }
    _log "Issues to be created: #{issues_to_be_created}"
    if issues_to_be_created.count > 0
      issues_to_be_created.each do |c|
        _create_linked_issue c["issue"], c
      end
    end

    # if we ever match something we know the user won't
    # need to see (aka the fingerprint's :hide parameter is true), go ahead
    # and hide the entity... meaning no recursion and it shouldn't show up in
    # the UI / queries if any of the matches told us to hide the entity, do it.
    # EXAMPLE TEST CASE: http://103.24.203.121:80 (cpanel missing page)
    if fingerprint.detect{|x| x["hide"] == true }
      _log "Entity hidden based on fingerprint!"
      @entity.hidden = true
      @entity.save_changes
    end

    # figure out ciphers if this is an ssl connection
    # only create issues if we're getting a 200
    if response.code == "200"

      # capture cookies
      set_cookie = response.header['set-cookie']
      _log "Got Cookie: #{set_cookie}" if set_cookie
      
      # TODO - cookie scoped to parent domain
      _log "Domain Cookie: #{set_cookie.split(";").detect{|x| x =~ /Domain:/i }}" if set_cookie

      if scheme == "https"

        _log "HTTPS endpoint, checking security, grabbing certificate..."

        # grab and parse the certificate
        cert = connect_ssl_socket_get_cert(hostname,port)
        if cert 
          alt_names = parse_names_from_cert(cert)
        else
          alt_names = []
        end

        _log "Got cert's alt names: #{alt_names}"

        if set_cookie
          _log "Secure Cookie: #{set_cookie.split(";").detect{|x| x =~ /secure/i }}"
          _log "Httponly Cookie: #{set_cookie.split(";").detect{|x| x =~ /httponly/i }}"

          # check for authentication and if so, bump the severity
          auth_endpoint = ident_content_checks.select{|x|
            x["result"]}.join(" ") =~ /Authentication/

          if auth_endpoint
            # create an issue if not detected
            if !(set_cookie.split(";").detect{|x| x =~ /httponly/i })
              # 4 since we only create an issue if it's an auth endpoint
              severity = 4
              _create_missing_cookie_attribute_http_only_issue(uri, set_cookie)
            end

            if !(set_cookie.split(";").detect{|x| x =~ /secure/i } )
              # set a default,4 since we only create an issue if it's an auth endpoint
              severity = 4
              _create_missing_cookie_attribute_secure_issue(uri, set_cookie)
            end

          end

        end

        _log "Gathering ciphers since this is an ssl endpoint"
        accepted_connections = _gather_supported_ciphers(hostname,port).select{|x|
          x[:status] == :accepted }

        # Create findings if we have a weak cipher
        if accepted_connections && accepted_connections.detect{ |x| x[:weak] == true }
          create_weak_cipher_issue(uri, accepted_connections)
        end

        # Create findings if we have a deprecated protocol
        if accepted_connections && accepted_connections.detect{ |x|
            (x[:version] =~ /SSL/ || x[:version] == "TLSv1" ) }
            
          _create_deprecated_protocol_issue(uri, accepted_connections)
        end

      else # http endpoint, just check for httponly

        if set_cookie
          _log "Httponly Cookie: #{set_cookie.split(";").detect{|x| x =~ /httponly/i }}"

          # create an issue if not detected
          if !set_cookie.split(";").detect{|x| x =~ /httponly/i }
            _create_missing_cookie_attribute_http_only_issue(uri, set_cookie)
          end
        end

        alt_names = []

      end
    else 
      _log "Did not receive 200, got #{response.code}!"
    end

    ###
    ### get the favicon & hash it
    ###
    _log "Getting Favicon"
    favicon_response = http_request(:get, "#{uri}/favicon.ico")

    if favicon_response && favicon_response.code == "200"
      favicon_data = Base64.strict_encode64(favicon_response.body)
      favicon_md5 = Digest::MD5.hexdigest(favicon_response.body)
      favicon_sha1 = Digest::SHA1.hexdigest(favicon_response.body)
    # else
    #
    # <link rel="shortcut icon" href="https://static.dyn.com/static/ico/favicon.1d6c21680db4.ico"/>
    # try link in the body
    # TODO... maybe this should be the other way around?
    #
    end

    ###
    ### Fingerprint the app server
    ###
    app_stack = []
    _log "Inferring app stack from fingerprints!"
    ident_app_stack = fingerprint.map do |x|
      version_string = "#{x["vendor"]} #{x["product"]}"
      version_string += " #{x["version"]}" if x["version"]
    version_string
    end
    app_stack.concat(ident_app_stack)
    _log "Setting app stack to #{app_stack.uniq}"

    ###
    ### grab the page attributes
    match = response.body.match(/<title>(.*?)<\/title>/i)
    title = match.captures.first if match

    # save off the generator string
    generator_match = response.body.match(/<meta name=\"?generator\"? content=\"?(.*?)\"?\/>/i)
    generator_string = generator_match.captures.first.gsub("\"","") if generator_match

    ###
    ### Browser-based data grab
    ### 
    browser_data_hash = capture_screenshot_and_requests(uri)
    # split out request hosts, and then verify them
    if !browser_data_hash.empty?

      # look for mixed content
      if uri =~ /^https/
        _log "Since we're here (and https), checking for mixed content..."
        _check_requests_for_mixed_content(uri, browser_data_hash["extended_browser_requests"])
      end

      _log "Checking for other oddities..."
      request_hosts = browser_data_hash["request_hosts"]
      _check_request_hosts_for_suspicious_request(uri, request_hosts)
      _check_request_hosts_for_exernally_hosted_resources(uri,request_hosts)

    else
      request_hosts = []
    end

    # set up the details
    new_details = @entity.details
    new_details.merge!({
      "alt_names" => alt_names,
      "api_endpoint" => api_endpoint,
      "code" => response.code,
      "cookies" => response.header['set-cookie'],
      "favicon_md5" => favicon_md5,
      "favicon_sha1" => favicon_sha1,
      "fingerprint" => fingerprint.uniq,
      "forms" => contains_forms,
      "generator" => generator_string,
      "headers" => headers,
      "hidden_favicon_data" => favicon_data,
      "hidden_response_data" => response.body,
      #"products" => products.compact,
      "redirect_chain" => ident_responses.first[:response_urls] || [],
      "response_data_hash" => response_data_hash,
      "title" => title,
      "verbs" => verbs_enabled,
      "scripts" => script_components,
      "extended_content" => ident_content_checks.uniq,
      "extended_ciphers" => accepted_connections,             # new ciphers field
      "extended_configuration" => ident_content_checks.uniq,  # new content field
      "extended_full_responses" => ident_responses,           # includes all the redirects etc
      "extended_favicon_data" => favicon_data,
      "extended_response_body" => response.body,
    })
    
    # add in the browser results
    new_details.merge! browser_data_hash

    # Set the details, and make sure raw response data is a hidden (not searchable) detail
    _set_entity_details new_details
      
    new_details = nil

    ###
    ### Alias Grouping
    ###

    if _get_option("correlate_endpoints")
      # Check for other entities with this same response hash
      _log "Attempting to identify aliases"
        # parse our content with Nokogiri
      our_doc = "#{response.body}".sanitize_unicode
      Intrigue::Model::Entity.scope_by_project_and_type(
        @entity.project.name,"Uri").paged_each(:rows_per_fetch => 100) do |e|
        next if @entity.id == e.id

        # Do some basic up front checking
        # TODO... make this a filter using JSONb in postgres
        old_title = e.get_detail("title")
        unless "#{title}".strip.sanitize_unicode == "#{old_title}".strip.sanitize_unicode
          _log "Skipping #{e.name}, title doesnt match (#{old_title})"
          next
        end
        
        # check response code  
        unless response.code == e.get_detail("code")
          _log "Skipping #{e.name}, code doesnt match"
          next
        end
        
        # check fingeprint
        unless fingerprint.uniq.map{|x| 
          "#{x["vendor"]} #{x["product"]} #{x["version"]}"} == e.get_detail("fingerprint").map{ |x| 
            "#{x["vendor"]} #{x["product"]} #{x["version"]}" }
          _log "Skipping #{e.name}, fingerprint doesnt match"
          next
        end

        # if we made it this far, parse them & compare them
        # TODO ... is this overkill? 
        their_doc = e.details["hidden_response_data"]
        diffs = parse_html_diffs(our_doc, their_doc)
        their_doc = nil

        # if they're the same, alias
        if diffs.empty?
          _log "No difference, match found!! Attaching to entity: #{e.name}"
          e.alias_to @entity.alias_group_id
        else
          _log  "HTML Content Diffs for #{e.name}"
          #diffs.each do |d|
          #  _log "DIFF #{d}"
          #end
        end

        e = nil 
      end
    end

    ###
    ### Finally, cloud provider determination
    ###

    # Now that we have our core details, check cloud statusi
    cloud_providers = determine_cloud_status(@entity)
    _set_entity_detail "cloud_providers", cloud_providers.uniq.sort
    _set_entity_detail "cloud_hosted",  !cloud_providers.empty?

  end

  def _gather_supported_ciphers(hostname,port)
    require 'rex/sslscan'
    scanner = Rex::SSLScan::Scanner.new(hostname, port)
    result = scanner.scan
  result.ciphers.to_a
  end

  def check_options_endpoint(uri)
    response = http_request(:options, uri)
    (response["allow"] || response["Allow"]) if response
  end

  ###
  ### Checks to see if we return anything that's an 'application' content type
  ###   or if we've been fingerprinted with an "API" tech"
  ###
  def check_api_enabled(response, fingerprints)
    
    # check for content type
    return true if response.header['Content-Type'] =~ /application/s

    # check fingeprrints
    fingerprints.each do |fp|
      return true if fp["tags"] && fp["tags"].include?("API")
    end 

    # try to parse it 
    begin
      j = JSON.parse(response.body)
      return true if j
    rescue JSON::ParserError      
    end

  # otherwise default to false 
  false
  end

  def check_forms(response_body)
    return true if response_body =~ /<form/i
  false
  end

 
end
end
end
end



