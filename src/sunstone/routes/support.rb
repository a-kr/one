# -------------------------------------------------------------------------- #
# Copyright 2002-2019, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #
require 'curb'
require 'base64'

# Too hard to get rid of $conf variable
# rubocop:disable Style/GlobalVars

UNSUPPORTED_RUBY = !(RUBY_VERSION =~ /^1.8/).nil?
GITHUB_TAGS_URL = 'https://api.github.com/repos/opennebula/one/tags'
ENTREPRISE_REPO_URL = 'https://downloads.opennebula.systems/repo/<VERSION>/'

begin
    require 'zendesk_api'
rescue LoadError
    STDERR.puts '[OpenNebula Support] Missing zendesk_api gem'
    ZENDESK_API_GEM = false
else
    ZENDESK_API_GEM = true
end

if RUBY_VERSION < '2.1'
    require 'scrub_rb'
end

def invalid_user_with_id(client)
    client.current_user.nil? || client.current_user.id.nil?
end

helpers do
    def zendesk_client
        client = ZendeskAPI::Client.new do |config|
            # Mandatory:
            config.url = SUPPORT[:zendesk_url]

            # Basic / Token Authentication
            config.username = session['zendesk_email']

            # Choose one of the following depending on your auth choice
            # config.token = 'your zendesk token'
            config.password = session['zendesk_password']

            # OAuth Authentication
            # config.access_token = 'your OAuth access token'

            # Optional:

            # Retry uses middleware to notify the user
            # when hitting the rate limit, sleep automatically,
            # then retry the request.
            config.retry = true

            # Logger prints to STDERR by default, to e.g. print to stdout:
            # require 'logger'
            # config.logger = Logger.new(STDOUT)

            # Changes Faraday adapter
            # config.adapter = :patron

            # When getting the error
            #   'hostname does not match the server certificate'
            # use the API at https://yoursubdomain.zendesk.com/api/v2
        end

        if invalid_user_with_id(client)
            error 401, 'Incorrect Zendesk account credentials'
        end

        client
    end

    def zrequest_to_one(zrequest)
        one_zrequest = {
            'id' => zrequest.id,
            'url' => zrequest.url,
            'subject' => zrequest.subject,
            'description' => zrequest.description,
            'status' => zrequest.status,
            'created_at' => zrequest.created_at,
            'updated_at' => zrequest.updated_at,
            'comments' => []
        }

        zrequest.custom_fields.each do |field|
            case field.id
            when SUPPORT[:custom_field_version]
                one_zrequest['opennebula_version'] = field.value
            when SUPPORT[:custom_field_severity]
                one_zrequest['severity'] = field.value
            end
        end

        if zrequest.comments
            htmlcomment = zrequest.comments.delete_at(0)
            one_zrequest['html_description'] = htmlcomment.html_body

            zrequest.comments.each do |comment|
                one_zrequest['comments'] << {
                    'created_at' => comment.created_at,
                    'html_body' => comment.html_body,
                    'author_id' => comment.author_id,
                    'body' => comment.body
                }
            end
        end

        one_zrequest
    end

    def check_zendesk_api_gem
        error 500, 'Ruby version >= 1.9 is required' if UNSUPPORTED_RUBY

        error 500, 'zendesk_api gem missing' unless ZENDESK_API_GEM
    end
end

get '/support/request' do
    check_zendesk_api_gem

    zrequests = zendesk_client.requests(:status => 'open,pending')

    open_requests = 0
    pending_requests = 0
    one_zrequests = {
        'REQUEST_POOL' => {
        }
    }

    if !zrequests.empty?
        one_zrequests['REQUEST_POOL']['REQUEST'] = []
    end

    zrequests.each do |zrequest|
        if zrequest.status == 'pending'
            pending_requests += 1
        elsif zrequest.status == 'open'
            open_requests += 1
        end

        one_zrequests['REQUEST_POOL']['REQUEST'] << zrequest_to_one(zrequest)
    end

    one_zrequests['open_requests'] = open_requests
    one_zrequests['pending_requests'] = pending_requests

    [200, JSON.pretty_generate(one_zrequests)]
end

get '/support/request/:id' do
    check_zendesk_api_gem

    zrequest = zendesk_client.requests.find(:id => params[:id])

    error 404, "Cannot find request with #{params[:id]}" if zrequest.nil?

    one_zrequest = {
        'REQUEST' => zrequest_to_one(zrequest)
    }

    [200, JSON.pretty_generate(one_zrequest)]
end

post '/support/request' do
    check_zendesk_api_gem

    body_hash = JSON.parse(@request_body)

    zen_api = ZendeskAPI::Request

    zrequest = zen_api.new(
        zendesk_client,
        :subject => body_hash['subject'],
        :comment => { :value => body_hash['description'] },
        :custom_fields => [
            { :id => SUPPORT[:custom_field_severity],
              :value => body_hash['severity'] },
            { :id => SUPPORT[:custom_field_version],
              :value => body_hash['opennebula_version'] }
        ],
        :tags => [body_hash['severity']]
    )

    if zrequest.save
        [201, JSON.pretty_generate(zrequest_to_one(zrequest))]
    else
        [403, Error.new(zrequest.errors['base'][0]['description']).to_json]
    end
end

# Returns whether this OpenNebula instances is supported or not
get '/support/check' do
    one_version = OpenNebula::VERSION
    if !one_version.empty? &&
       !$conf[:token_remote_support].nil? &&
       !$conf[:token_remote_support].empty?

        $conf[:one_support_time] = 0 if $conf[:one_support_time].nil?
        validate_time = Time.now.to_i - $conf[:one_support_time]

        if validate_time < 86400
            return [200, JSON.pretty_generate(:pass => true)]
        end

        version = one_version.slice(0..one_version.rindex('.') - 1)
        minor_version = version.slice(version.rindex('.') + 1..-1).to_i
        minor_version -= 1 unless minor_version.even?
        major_version = version.slice(0..version.rindex('.') - 1)

        full_version = "#{major_version}.#{minor_version}"
        url = ENTREPRISE_REPO_URL.sub('<VERSION>', full_version)
        begin
            http = Curl.get(url) do |http_options|
                token_enc = Base64.strict_encode64($conf[:token_remote_support])
                http_options.headers['Authorization'] = 'Basic ' + token_enc
            end
        rescue StandardError
            [400, JSON.pretty_generate(:pass => false)]
        end

        if !http.nil? && http.response_code < 400
            $conf[:opennebula_support_time] = Time.now.to_i
            [200, JSON.pretty_generate(:pass => true)]
        else
            [400, JSON.pretty_generate(:pass => false)]
        end
    else
        [400, JSON.pretty_generate(:pass => false)]
    end
end

# Returns latest available version
get '/support/check/version' do
    $conf[:one_version_time] = 0 if $conf[:one_version_time].nil?
    $conf[:one_last_version] = '0' if $conf[:one_last_version].nil?
    find = 'release-'
    validate_time = Time.now.to_i - $conf[:one_version_time]

    if validate_time < 86400
        return [200, JSON.pretty_generate(:version => $conf[:one_last_version])]
    end

    begin
        http = Curl.get(GITHUB_TAGS_URL) do |http_options|
            http_options.headers['User-Agent'] = 'One'
        end
    rescue StandardError
        return [400, JSON.pretty_generate(:version => 0)]
    end

    if !http.nil? && http.response_code == 200
        JSON.parse(http.body_str).each  do |tag|
            next unless tag &&
                        tag['name'] &&
                        !tag['name'].nil? &&
                        !tag['name'].empty? &&
                        tag['name'].start_with?(find)

            version = tag['name'].tr(find, '')
            memory_version = $conf[:one_last_version]
            if version.to_f > memory_version.to_f
                $conf[:one_last_version] = version
            end

            minor_version = version.slice(version.rindex('.').to_i + 1..-1).to_i
            memory_version_index = memory_version.rindex('.').to_i
            minor_memory_version =
                memory_version.slice(memory_version_index.to_i + 1..-1).to_i

            if version.to_f == memory_version.to_f &&
               minor_version >= minor_memory_version
                $conf[:one_last_version] = version
            end
        end
        $conf[:one_version_time] = Time.now.to_i
        [200, JSON.pretty_generate(:version => $conf[:one_last_version])]
    else
        [400, JSON.pretty_generate(:version => 0)]
    end
end

post '/support/request/:id/action' do
    check_zendesk_api_gem

    body_hash = JSON.parse(@request_body)
    if body_hash['action']['params']['comment']
        comment_value = body_hash['action']['params']['comment']['value']
    else
        logger.error('[OpenNebula Support] Missing comment message')
        error = Error.new(e.message)
        error 403, error.to_json
    end

    zrequest = zendesk_client.requests.find(:id => params[:id])

    error 404, "Cannot find request with #{params[:id]}" if zrequest.nil?

    zrequest.comment = { 'value' => comment_value }
    zrequest.solved = true if body_hash['action']['params']['solved']
    zrequest.save!

    one_zrequest = {
        'REQUEST' => zrequest_to_one(zrequest)
    }

    [201, JSON.pretty_generate(one_zrequest)]
end

post '/support/request/:id/upload' do
    check_zendesk_api_gem

    name = params[:tempfile]

    if !name
        [500, OpenNebula::Error.new('There was a problem uploading the file, \
                please check the permissions on the file').to_json]
    else
        tmpfile = File.join(Dir.tmpdir, name)

        zrequest = zendesk_client.requests.find(:id => params[:id])
        error 404, "Cannot find request with #{params[:id]}" if zrequest.nil?

        comment = ZendeskAPI::Request::Comment.new(zendesk_client,
                                                   'value' => name)
        comment.uploads << tmpfile

        zrequest.comment = comment
        zrequest.save

        one_zrequest = {
            'REQUEST' => zrequest_to_one(zrequest)
        }

        FileUtils.rm(tmpfile)

        [201, JSON.pretty_generate(one_zrequest)]
    end
end

post '/support/credentials' do
    check_zendesk_api_gem

    body_hash = JSON.parse(@request_body)
    if body_hash['email'].nil? || body_hash['password'].nil?
        error 401, 'Zendesk credentials not provided'
    end

    session['zendesk_email'] = body_hash['email']
    session['zendesk_password'] = body_hash['password']

    zendesk_client

    [204, '']
end

delete '/support/credentials' do
    check_zendesk_api_gem

    session['zendesk_email'] = nil
    session['zendesk_password'] = nil

    [204, '']
end

# rubocop:enable Style/GlobalVars
