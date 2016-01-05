#!/usr/bin/env ruby
#
# Sensu Handler: awsdecomm
#
# Copyright 2016, Harvey Bendana <harvey.bendana@nordstrom.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-handler'
require 'aws-sdk'
require 'mail'
require 'timeout'

class AwsDecomm < Sensu::Handler
  option :json_config,
         description: 'Config Name',
         short: '-j JsonConfig',
         long: '--json_config JsonConfig',
         required: false,
         default: 'awsdecomm'

  def delete_sensu_client
    puts "Sensu client #{@event['client']['name']} is being deleted."
    if api_request(:DELETE, '/clients/' + @event['client']['name']).code != '202'
      puts "Sensu API call failed;" 
    end
  end

  def check_ec2
    json_config = config[:json_config]

    i_state = Hash.new

    accounts = settings[json_config]['aws']

    accounts.each do |account, creds|
      ec2 = Aws::EC2::Resource.new({
        access_key_id: creds['access_key_id'],
        secret_access_key: creds['secret_access_key'],
        region: creds['region']
      })

      i = ec2.instance(@event['client']['name'])
      if i.exists?
        puts "Instance #{@event['client']['name']} exists in #{account} account; Checking state"
        if i.state.name.to_s === "terminated" || i.state.name.to_s === "shutting_down"
          puts "Instance #{@event['client']['name']} is #{i.state.name.to_s}; proceeding with decommission activities."
          delete_sensu_client
        else
          puts "Instance #{@event['client']['name']} exists in #{account} account and is #{i.state.name.to_s}; check the Sensu Client!"
          @body << "A decommission activity was attempted but failed because instance #{@event['client']['name']} exists in #{account} account and is #{i.state.name.to_s}; check the Sensu client!"
          mail('alert')
          bail('alert')
        end
      else
        puts "Instance #{@event['client']['name']} does not exist in #{account} account"
        i_state[account] = 'no_exist'
      end
    end

    if i_state.values.all? {|x| x == 'no_exist'}
      puts "Instance #{@event['client']['name']} was not found in any account; proceeding with decommission activities."
      delete_sensu_client
    end
  end

  def status_to_string
    case @event['check']['status']
    when 0
      'OK'
    when 1
      'WARNING'
    when 2
      'CRITICAL'
    else
      'UNKNOWN'
    end
  end

  def mail(subject)
    json_config = config[:json_config]

    params = {
      :mail_to   => settings[json_config]['mail_to'],
      :mail_from => settings[json_config]['mail_from'],
      :smtp_addr => settings[json_config]['smtp_address'],
      :smtp_port => settings[json_config]['smtp_port'],
      :smtp_domain => settings[json_config]['smtp_domain']
    }

    body = <<-BODY.gsub(/^ {14}/, '')
            #{@event['check']['output']}
            Host: #{@event['client']['name']}
            Timestamp: #{Time.at(@event['check']['issued'])}
            Address:  #{@event['client']['address']}
            Check Name:  #{@event['check']['name']}
            Command:  #{@event['check']['command']}
            Status:  #{@event['check']['status']}
            Occurrences:  #{@event['occurrences']}
          BODY

    case subject
      when "success"
        sub = "SUCCESS: Decommission of #{@event['client']['name']} was successful."
      when "alert"
        sub = "ALERT: #{@event['client']['name']}/#{@event['check']['name']}: #{status_to_string}"
      when "resolve"
        sub = "RESOLVED: #{@event['client']['name']}/#{@event['check']['name']}: #{status_to_string}" 
      else
        sub = "FAILURE: Decommission of #{@event['client']['name']} failed."  
    end

    if @body != "" then body = @body end

    Mail.defaults do
      delivery_method :smtp, {
        :address => params[:smtp_addr],
        :port    => params[:smtp_port],
        :domain  => params[:smtp_domain],
        :openssl_verify_mode => 'none'
      }
    end

    begin
      timeout 10 do
        Mail.deliver do
          to      params[:mail_to]
          from    params[:mail_from]
          subject sub
          body    body
        end

        puts "mail -- #{sub}"
      end
    rescue Timeout::Error
      puts "mail -- timed out while attempting to deliver message #{sub}"
    end
  end

  def handle
    @body = ""
    if @event['action'].eql?('create')
      check_ec2
      mail('success')
    elsif @event['action'].eql?('resolve')
      mail('resolve')
    end
  end

end
