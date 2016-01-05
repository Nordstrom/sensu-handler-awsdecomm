# sensu-handler-awsdecomm
A Sensu handler to handle decommissioning of EC2 instances in Sensu

awsdecomm
=========

A Sensu handler for decomissioning of AWS EC2 instances in sensu.

A walkthrough to create your own http://www.ragedsyscoder.com/blog/2014/01/14/sensu-automated-decommission-of-clients/

Features
--------
* Checks state of node in AWS (can handle multiple AWS accounts if need be)
* Decomission of node from Sensu
* Email on failure or success of decommission
* Handles normal resolve/create keepalive events when decomm is not needed

Usage and Configuration
-----------------------
This handler uses the sensu-plugin.
  > gem install sensu-plugin

You can either attach this to the client's keepalive handler or attach this to the default handler in sensu.  Sensu sends client keepalive failures to the default handler.  If a client keepalive gets sent to this handler it will proceed to check if it should be removed from sensu and chef.

`/etc/sensu/conf.d/client.json`
````
{
  "client": {
    "name": "i-123456",
    "address": "10.0.0.1",
    "subscriptions": [
      "production",
      "webserver"
    ],
    "keepalive": {
      "handlers": [
      "awsdecomm"
      ]
    }
  }
}
````

`/etc/sensu/conf.d/handlers/default.json`
````
{
  "handlers": {
    "default": {
      "type": "set",
      "handlers": [
        "awsdecomm"
      ]
    }
  }
}
````

You can either leverage the default configuration JSON file or pass a custom configuration JSON file.
This allows for team specific handler configs.

`/etc/sensu/conf.d/handlers/awsdecomm.json`
````
{
  "handlers": {
    "awsdecomm": {
      "type": "pipe",
      "command": "/etc/sensu/handlers/awsdecomm.rb",
      "severities": [
        "ok",
        "warning",
        "critical"
      ]
    }
  }
}
````

`/etc/sensu/conf.d/handlers/webops_awsdecomm.json`
````
{
  "handlers": {
    "awsdecomm": {
      "type": "pipe",
      "command": "/etc/sensu/handlers/awsdecomm.rb -j webops_awsdecomm",
      "severities": [
        "ok",
        "warning",
        "critical"
      ]
    }
  }
}
````

awsdecomm relies on a bunch of configurations set in awsdecomm.json.  You will need to provide AWS credentials and smtp server information.

`/etc/sensu/conf.d/handlers/awsdecomm.json`
````
{ 
  "awsdecomm":{
    "aws": {
      "account1": {
        "access_key_id": "ACCESS_KEY_ID",
        "secret_access_key": "SECRET_ACCESS_KEY",
        "region": "REGION"
      },
      "account2": {
        "access_key_id": "ACCESS_KEY_ID",
        "secret_access_key": "SECRET_ACCESS_KEY",
        "region": "REGION"
      }
    },
    "mail_from": "sensu@example.com",
    "mail_to": "nobody@example.com",
    "smtp_address": "localhost",
    "smtp_port": "25",
    "smtp_domain": "localhost"
  }
}
````

Notables
--------
* This plugin attempts to catch failures and will alert you so that manual intervention can be taken.
* I've tried to incorporate a mildly verbose logging to the sensu-server.log on each step.   
* This handler never terminates servers in AWS itself.  It simply takes action on nodes that do not exist or are in a terminated or shutting-down state.

Contributions
-------------
Please provide a pull request.  


License and Author
==================

Author:: Harvey Bendana <harvey.bendana@nordstrom.com>

Copyright:: 2016, Harvey Bendana

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
