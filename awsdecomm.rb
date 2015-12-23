#!/usr/bin/env ruby
#
# Sensu Handler: awsdecomm
#
# Copyright 2013, Bryan Brandau <agent462@gmail.com>
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
require 'ridley'
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
    retries = 1
    begin
      if api_request(:DELETE, '/clients/' + @event['client']['name']).code != '202' then raise "Sensu API call failed;" end
    rescue StandardError => e
      if (retries -= 1) >= 0
        sleep 3
        puts e.message + " Deletion failed; retrying to delete sensu client #{@event['client']['name']}."
        retry
      else
        puts @b << e.message + " Deleting sensu client #{@event['client']['name']} failed permanently."
        @s = "failed"
      end 
    end
  end

  def delete_chef_node
    json_config = config[:json_config]

    orgs = settings[json_config]['chef']

    orgs.each do |org|      
      ridley = Ridley.new(
        server_url: "#{org['server_url']}",
        client_name: "#{org['client_name']}",
        client_key: "#{org['client_key']}"
      )

      node = ridley.node.find("#{@event['client']['name']}")

      if node.nil?
        puts "Chef node #{@event['client']['name']} does not exist in #{org} org"
      else
        retries = 1
        begin
          puts "Chef node #{@event['client']['name']} is being deleted"
          ridley.node.delete(node)
          ridley.client.delete(node)
        rescue StandardError, Ridley::Error => e
          if (retries -= 1) >= 0
            sleep 3
            puts e.message + "Deletion failed; retrying to delete Chef node #{@event['client']['name']}"
            retry
          else
            puts @b << e.message + " Deleting chef node #{@event['client']['name']} failed permanently."
            @s = "failed"
          end
        end
      end 
    end
  end

  def check_ec2
    json_config = config[:json_config]

    accounts = settings[json_config]['aws']

    accounts.each do |account|
      ec2 = Aws::EC2::Resource.new({
        access_key_id: account[:aws_access_key],
        secret_access_key: account[:aws_secret_access_key],
        region: account[:aws_region]
      })

      instance = false
      
      retries = 1
      begin
        i = ec2.instance([@event['client']['name']])
        if i.exists?
          puts "Instance #{@event['client']['name']} exists; Checking state"
          instance = true
          if i.status.name.to_s === "terminated" || i.status.to_s === "shutting_down"
            puts "Instance #{@event['client']['name']} is #{i.status.name}; I will proceed with decommission activities."
            delete_sensu_client
            delete_chef_node
          else
            puts "Client #{@event['client']['name']} is #{i.status.name}"
            @s = "alert"
            mail
            bail
          end
        end
      rescue Aws::EC2::Errors::ServiceError => e
        if (retries -= 1) >= 0
          sleep 3
          puts e.message + " AWS lookup for #{@event['client']['name']} has failed; trying again."
          retry
        else
          @b << "AWS instance lookup failed permanently for #{@event['client']['name']}."
          @s = "failed"
          mail
          bail(@b)
        end 
      end
      if instance == false
        @b << "AWS instance was not found #{@event['client']['name']}."
        delete_sensu_client
        delete_chef_node
      end
    end

  end

  def mail
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

    case @s
      when "success"
        sub = "Decommission of #{@event['client']['name']} was successful."
      when "alert"
        sub = "ALERT - #{@event['client']['name']}/#{@event['check']['name']}: #{@event['check']['notification']}"
      when "resolve"
        sub = "RESOLVED - #{@event['client']['name']}/#{@event['check']['name']}: #{@event['check']['notification']}" 
      else
        sub = "FAILURE: Decommission of #{@event['client']['name']} failed."  
    end

    if @b != "" then body = @b end

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
    @b = ""
    @s = ""
    if @event['action'].eql?('create')
      check_ec2
      if @s === "" then @s = "success" end
      mail
    elsif @event['action'].eql?('resolve')
      @s = "resolve"
      mail
    end
  end

end
