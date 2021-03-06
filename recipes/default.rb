# frozen_string_literal: true
#
# Cookbook Name:: rs-mysql
# Recipe:: default
#
# Copyright (C) 2014 RightScale, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require 'mixlib/shellout'
class Chef::Recipe
  include MysqlCookbook::HelpersBase
end

marker 'recipe_start_rightscale' do
  template 'rightscale_audit_entry.erb'
end

# The version of the mysql cookbook we are using does not consistently set mysql/server/service_name
mysql_service_name = node['rs-mysql']['service_name']

# RHEL on some clouds take some time to add RHEL repos.
# Check and wait a few seconds if RHEL repos are not yet installed.
if node['platform'] == 'redhat'
  if !node.attribute?('cloud') || !node['cloud'].attribute?('provider') || !node.attribute?(node['cloud']['provider'])
    log 'Not running on a known cloud - skipping check for RHEL repo'
  else
    # Depending on cloud, add string returned by 'yum --cacheonly repolist' to determine if RHEL repo has been added.
    repo_id_partial = case node['cloud']['provider']
                      when 'rackspace'
                        'rhel-x86_64-server'
    end

    unless repo_id_partial.nil?
      Timeout.timeout(300) do
        loop do
          check_rhel_repo = Mixlib::ShellOut.new("yum --cacheonly repolist | grep #{repo_id_partial}").run_command
          check_rhel_repo.exitstatus == 0 ? break : sleep(1)
        end
      end
    end
  end
end

if node['platform_family'] == 'rhel'
  # verify getenforce exists on the install
  if ::File.exist?('/usr/sbin/getenforce')
    # if selinux is set to enforcing instead of permissive, update mysqld access
    Chef::Log.info 'Implementing RHEL-mysql'
    cookbook_file ::File.join(Chef::Config[:file_cache_path], 'rhel-mysql.te') do
      source 'rhel-mysql.te'
      owner 'root'
      group 'root'
      mode '0644'
      action :nothing
    end.run_action(:create)

    execute 'mysql:compile selinux te to module' do
      command "checkmodule -M -m -o #{::File.join(Chef::Config[:file_cache_path], 'rhel-mysql.mod')} #{::File.join(Chef::Config[:file_cache_path], 'rhel-mysql.te')}"
      action :nothing
    end.run_action(:run)

    execute 'mysql:package selinux module' do
      command "semodule_package -m #{::File.join(Chef::Config[:file_cache_path], 'rhel-mysql.mod')} -o #{::File.join(Chef::Config[:file_cache_path], 'rhel-mysql.pp')}"
      action :nothing
    end.run_action(:run)

    execute 'fix selinux' do
      command "semodule -i #{::File.join(Chef::Config[:file_cache_path], 'rhel-mysql.pp')}"
      action :nothing
    end.run_action(:run)
    node.default['rs-mysql']['tunable']['log-error'] = '/var/log/mysql-default/error.log'
  end
end

# Override the mysql/bind_address attribute with the server IP since
# node['cloud']['local_ipv4'] returns an inconsistent type on AWS (String) and Google (Array) clouds
bind_ip_address = RsMysql::Helper.get_bind_ip_address(node)
Chef::Log.info "Overriding mysql/bind_address to '#{bind_ip_address}'..."
node.override['mysql']['bind_address'] = bind_ip_address

# Calculate MySQL tunable attributes based on system memory and server usage type of 'dedicated' or 'shared'.
# Attributes will be placed in node['mysql']['tunable'] namespace.
RsMysql::Tuning.tune_attributes(
  node.override['rs-mysql']['tunable'],
  node['memory']['total'],
  node['rs-mysql']['server_usage']
)

# Override mysql cookbook attributes
node.override['mysql']['server_root_password'] = node['rs-mysql']['server_root_password']
node.override['mysql']['server_debian_password'] = node['rs-mysql']['server_root_password']
node.override['mysql']['server_repl_password'] = node['rs-mysql']['server_repl_password'] || node['rs-mysql']['server_root_password']

Chef::Log.info 'Overriding mysql/tunable/expire_logs_days to 2'
node.override['rs-mysql']['tunable']['expire_logs_days'] = 2

# The directory that contains the MySQL binary logs. This directory will only be created as part of the initial MySQL
# installation and setup. If the data directory is changed, this should not be created again as the data from
# /var/lib/mysql will be moved to the new location.
if node['mysql']['data_dir'] == "/var/lib/#{mysql_service_name}"
  Chef::Log.info "Overriding mysql/server/directories/bin_log_dir to '#{node['mysql']['data_dir']}/mysql_binlogs'"
  node.override['mysql']['server']['directories']['bin_log_dir'] = "#{node['mysql']['data_dir']}/mysql_binlogs"
end

Chef::Log.info "Overriding mysql/tunable/log_bin to '#{node['mysql']['data_dir']}/mysql_binlogs/mysql-bin'"
node.override['rs-mysql']['tunable']['log_bin'] = "#{node['mysql']['data_dir']}/mysql_binlogs/mysql-bin"

Chef::Log.info "Overriding mysql/tunable/binlog_format to 'MIXED'"
node.override['rs-mysql']['tunable']['binlog_format'] = 'MIXED'

# Drop first 2 hex numbers from MAC address to have a 32-bit integer and use it for the server-id attribute in my.cnf.
# This is used since MAC addresses within the same network must be different to correctly talk to each other.
# Some clouds use the same public IP with different ports for multiple instances, so IP is not unique.
server_id = node['macaddress'].split(/\W/)[2..-1].join.to_i(16)

Chef::Log.info "Overriding mysql/tunable/server_id to '#{server_id}'"
node.override['rs-mysql']['tunable']['server_id'] = server_id

service mysql_service_name do
  action :stop
  only_if do
    ::File.exist?("#{node['mysql']['data_dir']}/ib_logfile0") &&
      ::File.size("#{node['mysql']['data_dir']}/ib_logfile0") != RsMysql::Tuning.megabytes_to_bytes(
        node['rs-mysql']['tunable']['innodb_log_file_size']
      )
  end
end

execute 'delete innodb log files' do
  command "rm -f #{node['mysql']['data_dir']}/ib_logfile*"
  action :run
  only_if do
    ::File.exist?("#{node['mysql']['data_dir']}/ib_logfile0") &&
      ::File.size("#{node['mysql']['data_dir']}/ib_logfile0") != RsMysql::Tuning.megabytes_to_bytes(
        node['rs-mysql']['tunable']['innodb_log_file_size']
      )
  end
end

mysql_data_dir = node['mysql']['data_dir']

execute 'update mysql binlog index with new data_dir' do
  command "sed -i -r -e 's#^.*/(mysql_binlogs/.*)$##{mysql_data_dir}/\\1#' '#{mysql_data_dir}/mysql_binlogs/mysql-bin.index'"
  action :run
  only_if { ::File.exist?("#{mysql_data_dir}/mysql_binlogs/mysql-bin.index") }
end

# TODO: ADD TESTS
if node['platform_family'] == 'rhel'
  case node['rs-mysql']['mysql']['version']
  when '5.5'
    include_recipe 'yum-mysql-community::mysql55'
  when '5.6'
    include_recipe 'yum-mysql-community::mysql56'
  when '5.7'
    include_recipe 'yum-mysql-community::mysql57'
  end
end

# TODO: ADD TESTS
case node['platform_family']
when 'rhel'
  package 'mysql-community-devel'
when 'debian'
  package "mysql-server-#{node['rs-mysql']['mysql']['version']}"
end

# TODO: ADD TESTS
mysql_client 'default' do
  action :create
end

mysql_service 'default' do
  initial_root_password node['rs-mysql']['server_root_password']
  version node['rs-mysql']['mysql']['version']
  action [:create]
end

directory mysql_data_dir do
  owner 'mysql'
  group 'mysql'
  recursive true
  mode '0770'
  action :create
end

directory "#{mysql_data_dir}/mysql_binlogs" do
  recursive true
  user 'mysql'
  group 'mysql'
  mode '0770'
  action :create
end

if node['platform_family'] == 'rhel' && node['platform_version'].split('.').first == '7'
  execute "mysql_install_db --datadir #{mysql_data_dir}"

  execute "chown -R mysql:mysql #{mysql_data_dir}" do
    action :run
  end

  bash 'setup db' do
    code <<-EOF
  mysqld --defaults-file=/etc/mysql-default/my.cnf --init-file=/tmp/mysql-default/my.sql &
  sleep 10
  pkill mysqld
  touch /tmp/configured
  EOF
    not_if ::File.exist?('/tmp/configured')
  end

end
# TODO: ADD TESTS
# Configure the MySQL service.
mysql_service 'default' do
  initial_root_password node['rs-mysql']['server_root_password']
  action [:start]
end

execute "chown -R mysql:mysql #{mysql_data_dir}" do
  action :run
end

mysql_config 'default' do
  source 'tunable.erb'
  variables(config: node['rs-mysql']['tunable'])
  notifies :run, 'execute[delete innodb log files]', :immediately
  notifies :restart, 'mysql_service[default]', :immediately
  action :create
end

# allow client to make connections using the default location
# for the system /etc/my.cnf
link '/etc/my.cnf' do
  to "/etc/#{mysql_service_name}/my.cnf"
end

# TODO: ADD TESTS
mysql2_chef_gem 'default' do
  gem_version '0.4.5'
  action :install
end

include_recipe 'rightscale_tag::default'
include_recipe 'rightscale_volume::default'
include_recipe 'rightscale_backup::default'

ruby_block 'wait for listening' do
  block do
    mysql_connection_info = {
      host: 'localhost',
      username: 'root',
      password: node['rs-mysql']['server_root_password'],
    }
    RsMysql::Helper.verify_mysqld_is_up(mysql_connection_info, node['rs-mysql']['startup-timeout'])
  end
end

# Setup database tags on the server.
# See https://github.com/rightscale-cookbooks/rightscale_tag#database-servers for more information about the
# `rightscale_tag_database` resource.
rightscale_tag_database node['rs-mysql']['backup']['lineage'] do
  bind_ip_address node['mysql']['bind_address']
  bind_port node['mysql']['port']
  action :create
end

# The connection hash to use to connect to MySQL
mysql_connection_info = {
  host: 'localhost',
  username: 'root',
  password: node['rs-mysql']['server_root_password'],
  default_file: "/etc/#{mysql_service_name}/my.cnf",
}

# Create the application database
mysql_database 'application database' do
  connection mysql_connection_info
  database_name node['rs-mysql']['application_database_name']
  action :create
  not_if { node['rs-mysql']['application_database_name'].to_s.empty? }
end

if !node['rs-mysql']['application_username'].to_s.empty? && !node['rs-mysql']['application_password'].to_s.empty?
  if node['rs-mysql']['application_database_name'].to_s.empty?
    raise 'rs-mysql/application_database_name is required for creating user!'
  end

  # Create the application user to connect from localhost and any other hosts
  ['localhost', '%'].each do |hostname|
    mysql_database_user node['rs-mysql']['application_username'] do
      connection mysql_connection_info
      password node['rs-mysql']['application_password']
      database_name node['rs-mysql']['application_database_name']
      host hostname
      privileges node['rs-mysql']['application_user_privileges']
      action [:create, :grant]
    end
  end
end

file '/var/log/mysql.err' do
  action :delete
  only_if do
    ::File.exist?('/var/log/mysql.err')
  end
end

file '/var/log/mysql.log' do
  action :delete
  only_if do
    ::File.exist?('/var/log/mysql.log')
  end
end

file '/var/log/mysql/error.log' do
  action :delete
  only_if do
    ::File.exist?('/var/log/mysql/error.log')
  end
end

directory '/var/log/mysql' do
  recursive true
  action :delete
  only_if do
    ::Dir.exist?('/var/log/mysql')
  end
end

directory '/var/lib/mysql' do
  recursive true
  action :delete
  only_if do
    ::Dir.exist?('/var/lib/mysql')
  end
end

link '/var/lib/mysql' do
  to "/var/lib/#{mysql_service_name}"
  link_type :symbolic
end

link '/var/log/mysql' do
  to "/var/log/#{mysql_service_name}"
  link_type :symbolic
end
