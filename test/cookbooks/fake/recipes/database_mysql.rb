#
# Cookbook Name:: fake
# Recipe:: database_mysql
#
# Copyright (C) 2013 RightScale, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# The connection hash to use to connect to mysql
mysql_connection_info = {
  :host => 'localhost',
  :username => 'root',
  :password => node['mysql']['server_root_password']
}

# Create the test database
mysql_database node['fake']['database_name'] do
  connection mysql_connection_info
  action :create
end

# Obtain the mysql dump file
cookbook_file '/tmp/mysql.dump' do
  source 'mysql.dump'
end

# Import the mysql dump
execute 'import mysql dump' do
  command "cat /tmp/mysql.dump | mysql --user=root -b #{node['fake']['database_name']}" +
    " --password=#{node['mysql']['server_root_password']}"
end
