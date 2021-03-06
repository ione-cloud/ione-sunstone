require 'date'
require 'time'

# Extensions for OpenNebula::VirtualMachine class
class OpenNebula::VirtualMachine
  # Actions supported by OpenNebula scheduler
  SCHEDULABLE_ACTIONS = %w(
    terminate
    terminate-hard
    hold
    release
    stop
    suspend
    resume
    reboot
    reboot-hard
    poweroff
    poweroff-hard
    undeploy
    undeploy-hard
    snapshot-create
  )
  # Generates template for OpenNebula scheduler record
  def generate_schedule_str id, action, time
    "\nSCHED_ACTION=[\n" +
      "  ACTION=\"#{action}\",\n" +
      "  ID=\"#{id}\",\n" +
      "  TIME=\"#{time}\" ]"
  end

  # Returns allowed actions to schedule
  # @return [Array]
  def schedule_actions
    SCHEDULABLE_ACTIONS
  end

  # Adds actions to OpenNebula internal scheduler, like --schedule in 'onevm' cli utility
  # @param [String] action - Action which should be scheduled
  # @param [Integer] time - Time when action schould be perfomed in secs
  # @param [String] periodic - Not working now
  # @return true
  def schedule action, time, _periodic = nil
    return 'Unsupported action' if !SCHEDULABLE_ACTIONS.include? action

    self.info!
    id =
      begin
        ids = self.to_hash['VM']['USER_TEMPLATE']['SCHED_ACTION']
        if ids.class == Array then
          ids.last['ID'].to_i + 1
        elsif ids.class == Hash then
          ids['ID'].to_i + 1
        elsif ids.class == NilClass then
          ids.to_i
        else
          raise
        end
      rescue
        0
      end

    # str_periodic = ''

    self.update(self.user_template_str << generate_schedule_str(id, action, time))
  end

  # Unschedules given action by ID
  # @note Not working, if action is already initialized
  def unschedule id
    self.info!
    schedule_data, object = self.to_hash['VM']['USER_TEMPLATE']['SCHED_ACTION'], nil

    if schedule_data.class == Array then
      schedule_data.map do | el |
        object = el if el['ID'] == id.to_s
      end
    elsif schedule_data.class == Hash then
      return 'none' if schedule_data['ID'] != id.to_s

      object = schedule_data
    else
      return 'none'
    end
    action, time = object['ACTION'], object['TIME']
    template = self.user_template_str
    template.slice!(generate_schedule_str(id, action, time))
    self.update(template)
  end

  # Lists actions scheduled in OpenNebula
  # @return [NilClass | Hash | Array]
  def scheduler
    self.info!
    self.to_hash['VM']['USER_TEMPLATE']['SCHED_ACTION']
  end

  # Waits until VM will have the given state
  # @param [Integer] s - VM state to wait for
  # @param [Integer] lcm_s - VM LCM state to wait for
  # @return [Boolean]
  def wait_for_state s = 3, lcm_s = 3
    i = 0
    until state!() == s && lcm_state!() == lcm_s do
      return false if i >= 3600

      sleep(1)
      i += 1
    end
    true
  end

  # !@group vCenterHelper

  # Sets resources allocation limits at vCenter node
  # @note For correct work of this method, you must keep actual vCenter Password at VCENTER_PASSWORD_ACTUAL attribute in OpenNebula
  # @note Attention!!! VM will be rebooted at the process
  # @note Valid units are: CPU - MHz, RAM - MB
  # @note Method searches VM by it's default name: one-(id)-(name), if target vm got another name, you should provide it
  # @param [Hash] spec - List of limits should be applied to target VM
  # @option spec [Integer] :cpu  MHz limit for VMs CPU usage
  # @option spec [Integer] :ram  MBytes limit for VMs RAM space usage
  # @option spec [Integer] :iops IOPS limit for VMs disk
  # @option spec [String]  :name VM name on vCenter node
  # @return [String]
  # @example Return messages decode
  #   vm.setResourcesAllocationLimits(spec)
  #     => 'Reconfigure Success' -- Task finished with success code, all specs are equal to given
  #     => 'Reconfigure Unsuccessed' -- Some of specs didn't changed
  #     => 'Reconfigure Error:{error message}' -- Exception has been generated while proceed, check your configuration
  def setResourcesAllocationLimits spec
    LOG_DEBUG spec.debug_out
    return 'Unsupported query' if IONe.new($client, $db).get_vm_data(self.id)['IMPORTED'] == 'YES'

    query, host = {}, onblock(:h, IONe.new($client, $db).get_vm_host(self.id))
    datacenter = get_vcenter_dc(host)

    vm = recursive_find_vm(datacenter.vmFolder, spec[:name].nil? ? "one-#{self.info! || self.id}-#{self.name}" : spec[:name]).first
    disk = vm.disks.first

    query[:cpuAllocation] = { :limit => spec[:cpu].to_i, :reservation => 0 } if !spec[:cpu].nil?
    query[:memoryAllocation] = { :limit => spec[:ram].to_i } if !spec[:ram].nil?
    if !spec[:iops].nil? then
      disk.storageIOAllocation.limit = spec[:iops].to_i
      disk.backing.sharing = nil
      query[:deviceChange] = [{
        :device => disk,
        :operation => :edit
      }]
    end

    state = true
    begin
      LOG_DEBUG 'Powering VM Off'
      LOG_DEBUG vm.PowerOffVM_Task.wait_for_completion
    rescue
      state = false
    end

    LOG_DEBUG 'Reconfiguring VM'
    LOG_DEBUG vm.ReconfigVM_Task(:spec => query).wait_for_completion

    begin
      LOG_DEBUG 'Powering VM On'
      LOG_DEBUG vm.PowerOnVM_Task.wait_for_completion
    rescue
      nil
    end if state
    return nil
  rescue => e
    return "Reconfigure Error:#{e.message}<|>Backtrace:#{e.backtrace}"
  end

  # Checks if vm is on given vCenter Datastore
  def is_at_ds? ds_name
    host = onblock(:h, IONe.new($client, $db).get_vm_host(self.id))
    datacenter = get_vcenter_dc(host)
    begin
      datastore = recursive_find_ds(datacenter.datastoreFolder, ds_name, true).first
    rescue
      return 'Invalid DS name.'
    end
    self.info!
    search_template = "VirtualMachine(\"#{self.deploy_id}\")"
    datastore.vm.each do | vm |
      return true if vm.to_s == search_template
    end
    false
  end

  # Gets the datastore, where VM allocated is
  # @return [String] DS name
  def get_vms_vcenter_ds
    host = onblock(:h, IONe.new($client, $db).get_vm_host(self.id))
    datastores = get_vcenter_dc(host).datastoreFolder.children

    self.info!
    search_template = "VirtualMachine(\"#{self.deploy_id}\")"
    datastores.each do | ds |
      ds.vm.each do | vm |
        return ds.name if vm.to_s == search_template
      end
    end
  end

  # Resizes VM without powering off the VM
  # @param [Hash] spec
  # @option spec [Integer] :cpu CPU amount to set
  # @option spec [Integer] :ram RAM amount in MB to set
  # @option spec [String] :name VM name on vCenter node
  # @return [Boolean | String]
  # @note Method returns true if resize action ended correct, false if VM not support hot reconfiguring
  def hot_resize spec = { :name => nil }
    return false if !self.hotAddEnabled?

    begin
      host = onblock(:h, IONe.new($client, $db).get_vm_host(self.id))
      datacenter = get_vcenter_dc(host)

      vm = recursive_find_vm(datacenter.vmFolder, spec[:name].nil? ? "one-#{self.info! || self.id}-#{self.name}" : spec[:name]).first
      query = {
        :numCPUs => spec[:cpu],
        :memoryMB => spec[:ram]
      }
      vm.ReconfigVM_Task(:spec => query).wait_for_completion
      return true
    rescue => e
      return "Reconfigure Error:#{e.message}"
    end
  end

  # Checks if resources hot add enabled
  # @param [String] name VM name on vCenter node
  # @note For correct work of this method, you must keep actual vCenter Password at VCENTER_PASSWORD_ACTUAL attribute in OpenNebula
  # @note Method searches VM by it's default name: one-(id)-(name), if target vm got another name, you should provide it
  # @return [Hash | String] Returns limits Hash if success or exception message if fails
  def hotAddEnabled? name = nil
    begin
      host = onblock(:h, IONe.new($client, $db).get_vm_host(self.id))
      datacenter = get_vcenter_dc(host)

      vm = recursive_find_vm(datacenter.vmFolder, name.nil? ? "one-#{self.info! || self.id}-#{self.name}" : name).first
      return {
        :cpu => vm.config.cpuHotAddEnabled, :ram => vm.config.memoryHotAddEnabled
      }
    rescue => e
      return "Unexpected error, cannot handle it: #{e.message}"
    end
  end

  # Sets resources hot add settings
  # @param [Hash] spec
  # @option spec [Boolean] :cpu
  # @option spec [Boolean] :ram
  # @option spec [String]  :name VM name on vCenter node
  # @return [true | String]
  def hotResourcesControlConf spec = { :cpu => true, :ram => true, :name => nil }
    begin
      host, name = onblock(:h, IONe.new($client, $db).get_vm_host(self.id)), spec[:name]
      datacenter = get_vcenter_dc(host)

      vm = recursive_find_vm(datacenter.vmFolder, name.nil? ? "one-#{self.info! || self.id}-#{self.name}" : name).first
      query = {
        :cpuHotAddEnabled => spec[:cpu],
        :memoryHotAddEnabled => spec[:ram]
      }
      state = true
      begin
        LOG_DEBUG 'Powering VM Off'
        LOG_DEBUG vm.PowerOffVM_Task.wait_for_completion
      rescue
        state = false
      end

      LOG_DEBUG 'Reconfiguring VM'
      LOG_DEBUG vm.ReconfigVM_Task(:spec => query).wait_for_completion

      begin
        LOG_DEBUG 'Powering VM On'
        LOG_DEBUG vm.PowerOnVM_Task.wait_for_completion
      rescue
        nil
      end if state
    rescue => e
      "Unexpected error, cannot handle it: #{e.message}"
    end
  end

  # Gets resources allocation limits from vCenter node
  # @param [String] name VM name on vCenter node
  # @note For correct work of this method, you must keep actual vCenter Password at VCENTER_PASSWORD_ACTUAL attribute in OpenNebula
  # @note Method searches VM by it's default name: one-(id)-(name), if target vm got another name, you should provide it
  # @return [Hash | String] Returns limits Hash if success or exception message if fails
  def getResourcesAllocationLimits name = nil
    begin
      host = onblock(:h, IONe.new($client, $db).get_vm_host(self.id))
      datacenter = get_vcenter_dc(host)

      vm = recursive_find_vm(datacenter.vmFolder, name.nil? ? "one-#{self.info! || self.id}-#{self.name}" : name).first
      vm_disk = vm.disks.first
      { cpu: vm.config.cpuAllocation.limit, ram: vm.config.cpuAllocation.limit, iops: vm_disk.storageIOAllocation.limit }
    rescue => e
      "Unexpected error, cannot handle it: #{e.message}"
    end
  end

  # !@endgroup

  # Returns owner user ID
  # @param [Boolean] info - method doesn't get object full info one more time -- usefull if collecting data from pool
  # @return [Integer]
  def uid info = true
    self.info! if info
    self['UID']
  end

  # Returns owner user name
  # @param [Boolean] info - method doesn't get object full info one more time -- usefull if collecting data from pool
  # @param [Boolean] from_pool - levels differenct between object and object received from pool.each | object |
  # @return [String]
  def uname info = true, from_pool = false
    self.info! if info
    return @xml[0].children[3].text.to_i unless from_pool

    @xml.children[3].text
  end

  # Gives info about snapshots availability
  # @return [Boolean]
  def got_snapshot?
    self.info!
    !self.to_hash['VM']['TEMPLATE']['SNAPSHOT'].nil?
  end

  # Returns all available snapshots
  # @return [Array<Hash>, Hash, nil]
  def list_snapshots
    out = self.to_hash!['VM']['TEMPLATE']['SNAPSHOT']
    out.class == Array ? out : [out]
  end

  # Returns actual state without calling info! method
  def state!
    self.info! || self.state
  end

  # Returns actual lcm state without calling info! method
  def lcm_state!
    self.info! || self.lcm_state
  end

  # Returns actual state as string without calling info! method
  def state_str!
    self.info! || self.state_str
  end

  # Returns actual lcm state as string without calling info! method
  def lcm_state_str!
    self.info! || self.lcm_state_str
  end

  # Calculates VMs Showback
  # @param [Integer] stime_req - Point from which calculation starts(timestamp)
  # @param [Integer] etime_req - Point at which calculation stops(timestamp)
  # @param [Boolean] group_by_day - Groups showbacks by days
  # @return [Hash]
  def calculate_showback stime_req, etime_req, _group_by_day = false
    raise ShowbackError, ["Wrong Time-period given", stime_req, etime_req] if stime_req >= etime_req

    info!

    stime, etime = stime_req, etime_req

    raise ShowbackError, ["VM didn't exist in given time-period", etime, self['/VM/STIME'].to_i] if self['/VM/STIME'].to_i > etime

    stime = self['/VM/STIME'].to_i if self['/VM/STIME'].to_i > stime
    etime = self['/VM/ETIME'].to_i if self['/VM/ETIME'].to_i < etime && self['/VM/ETIME'].to_i != 0

    bp = self['//BILLING_PERIOD']

    if bp.nil? || bp == 'PAYG' then
      billing = Billing.new self, stime, etime
      billing.make_bill
      billing.receipt

      return {
        id: id, name: name,
        showback: billing.bill,
        TOTAL: billing.total
      }
    elsif bp.include? 'PRE' then
      curr = self['/VM/STIME'].to_i
      delta = bp.split('_')[1].to_i * 86400

      total = 0

      while curr < etime do
        if (stime..etime).include? curr then
          b = Billing.new self, curr, curr + delta
          b.make_bill
          b.receipt

          total += b.total
        end
        curr += delta
      end

      return {
        id: id, name: name,
        TOTAL: total
      }
    end
  end

  # Original OpenNebula#VirtualMachine.snapshot_create method
  alias :snapshot_create_original :snapshot_create
  # Create snapshot overload, brings restriction and quota check
  def snapshot_create name = ""
    info!

    if self['/VM/USER_TEMPLATE/SNAPSHOTS_ALLOWED'] != 'TRUE' && !IONe::Settings['SNAPSHOTS_ALLOWED_DEFAULT'] then
      return OpenNebula::Error.new("Snapshots aren't allowed for this VM. Set SNAPSHOTS_ALLOWED attribute to TRUE")
    end

    snapshots_quota = self['/VM/USER_TEMPLATE/SNAPSHOTS_QUOTA']
    if !snapshots_quota.nil? and list_snapshots.length >= snapshots_quota.to_i then
      return OpenNebula::Error.new("Unable to create a snapshot, snapshots quota exceed")
    end

    snapshot_create_original name
  end

  # Error while processing(calculating) showback Exception
  class ShowbackError < StandardError
    attr_reader :params

    def initialize params = []
      @params = params[1...params.length]
      super "#{params[0]}\nParams:#{@params.inspect}"
    end
  end

  # List VM Drives
  # @return [Array<Hash>]
  def drives
    r = to_hash!['VM']['TEMPLATE']['DISK']
    r.class == Array ? r : [r]
  end

  # List TrafficRecords
  # @return [Hash]
  def traffic_records
    info!
    {
      records: TrafficRecords.new(id).records,
      monitoring: monitoring(['NETTX', 'NETRX'])
    }
  end

  # Generates VNC proxy token file
  def start_vnc
    r = info!
    return { error: "No access to VM" } if OpenNebula.is_error? r

    if self['TEMPLATE/GRAPHICS/TYPE'].nil? ||
       !(["vnc", "spice"].include?(self['TEMPLATE/GRAPHICS/TYPE'].downcase))
      return { error: "VM has no VNC configured" }
    end

    # Proxy data
    host     = self['/VM/HISTORY_RECORDS/HISTORY[last()]/HOSTNAME']
    vnc_port = self['TEMPLATE/GRAPHICS/PORT']
    vnc_pw   = self['TEMPLATE/GRAPHICS/PASSWD']

    # If it is a vCenter VM
    if self['USER_TEMPLATE/HYPERVISOR'] == "vcenter"
      if self['MONITORING/VCENTER_ESX_HOST']
        host = self['MONITORING/VCENTER_ESX_HOST']
      else
        return {
          error: "Could not determine the vCenter ESX host where the VM is running. Wait till the VCENTER_ESX_HOST attribute is retrieved once the host has been monitored"
        }
      end
    end

    # Generate token random_str: host:port
    random_str = rand(36**20).to_s(36) # random string a-z0-9 length 20
    token = "#{random_str}: #{host}:#{vnc_port}"
    token_file = "one-#{self['ID']}"

    # Create token file
    begin
      f = File.open(File.join('/var/lib/one/sunstone_vnc_tokens/', token_file), 'w')
      f.write(token)
      f.close
    rescue
      return { error: "Cannot create VNC proxy token" }
    end

    return {
      :token => random_str,
      :vm_name => self['NAME']
    }
  end

  # Deletes VNC proxy token file
  def stop_vnc
    File.delete(File.join('/var/lib/one/sunstone_vnc_tokens/', "one-#{id}"))
  end
end
