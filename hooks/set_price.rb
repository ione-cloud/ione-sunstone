#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2020, IONe Cloud Project, Support.by                             #
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
# -------------------------------------------------------------------------- #

STARTUP_TIME = Time.now.to_f

RUBY_LIB_LOCATION = "/usr/lib/one/ruby"
ETC_LOCATION      = "/etc/one/"
ONED_CONF         = ETC_LOCATION + "oned.conf"

$: << RUBY_LIB_LOCATION
$: << RUBY_LIB_LOCATION + '/onedb'

require 'base64'
require 'yaml'
require 'json'
require 'sequel'
require 'nokogiri'
require 'opennebula'
require 'onedb'
require 'onedb_live'
include OpenNebula

require 'augeas'

work_file_dir  = File.dirname(ONED_CONF)
work_file_name = File.basename(ONED_CONF)

aug = Augeas.create(:no_modl_autoload => true,
                    :no_load          => true,
                    :root             => work_file_dir,
                    :loadpath         => ONED_CONF)

aug.clear_transforms
aug.transform(:lens => 'Oned.lns', :incl => work_file_name)
aug.context = "/files/#{work_file_name}"
aug.load

if aug.get('DB/BACKEND') != "\"mysql\"" then
  STDERR.puts "OneDB backend is not MySQL, exiting..."
  exit 1
end

ops = {}
ops[:host]     = aug.get('DB/SERVER')
ops[:user]     = aug.get('DB/USER')
ops[:password] = aug.get('DB/PASSWD')
ops[:database] = aug.get('DB/DB_NAME')

ops.each do |k, v|
  next if !v || !(v.is_a? String)

  ops[k] = v.chomp('"').reverse.chomp('"').reverse
end

ops.merge! adapter: :mysql2, encoding: 'utf8mb4'

$db = Sequel.connect(**ops)
xml = Nokogiri::XML(Base64::decode64(ARGV.first))
unless xml.xpath("/CALL_INFO/RESULT").text.to_i == 1 then
  puts "VM wasn't allocated, skipping"
  exit 0
end

vm = VirtualMachine.new xml.xpath('//EXTRA/VM'), Client.new
vm.info!

begin
  if vm.to_hash['VM']['USER_TEMPLATE']['HOOK_VARS']['SET_COST'] != "TRUE" then
    raise
  end
rescue
  puts "Attribute HOOK_VARS/SET_COST is FALSE or not set. Skipping..."
  exit 0
end

db = $db[:settings].as_hash(:name, :body)

costs = {}

if %(vcenter kvm).include?(vm['USER_TEMPLATE/HYPERVISOR'].downcase) then
  costs.merge!(
    'CPU_COST' => JSON.parse(db['CAPACITY_COST'])['CPU_COST'].to_f,
      'MEMORY_COST' => JSON.parse(db['CAPACITY_COST'])['MEMORY_COST'].to_f,
      'DISK_COST' => JSON.parse(db['DISK_COSTS'])[vm['/VM/TEMPLATE/CONTEXT/DRIVE']].to_f,
      'PUBLIC_IP_COST' => db['PUBLIC_IP_COST'].to_f
  )
elsif vm['USER_TEMPLATE/HYPERVISOR'].downcase == 'azure' then
  sku = JSON.parse(
    JSON.parse(db['AZURE_SKUS'])[ vm['USER_TEMPLATE/PUBLIC_CLOUD/INSTANCE_TYPE'] ]
  )

  costs.merge!(
    'CPU_COST' => sku['PRICE'].to_f / 2,
    'MEMORY_COST' => sku['PRICE'].to_f / 2,
    'DISK_COST' => JSON.parse(db['AZURE_DISK_COSTS'])[vm['USER_TEMPLATE/DRIVE']].to_f
  )
end

template =
  costs.inject("") do | result, el |
    result += "#{el.first} = \"#{el.last}\"\n"
  end

vm.update(template, true)

action = OneDBLive.new
costs.each do | key, value |
  action.change_body('vm', "/VM/TEMPLATE/#{key}", value.to_s, { :id => vm.id })
end

puts "Work time: #{(Time.now.to_f - STARTUP_TIME).round(6)} sec"
