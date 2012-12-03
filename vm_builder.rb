#!/usr/bin/env ruby
#
#Matthew Nicholson
#https://github.com/sjoeboo/vm_builder
#
#Script wrapping virt-install for building vms defined in Cobbler
#a Koan replacment/addition

require 'optparse'
require 'pp'
require 'yaml'
require 'xmlrpc/client'
require 'net/http'
require 'timeout'
require 'libvirt'


#Get cmd line options/config file options
options={}
OptionParser.new do |opts|
        opts.banner = "Usage: vm_builder [options] <system_name>"

        opts.on("-f", "--configfile PATH", String, "Set config file") do |path|
                  options[:config] = path
                  opts_from_cfg=Hash[YAML::load(open(path)).map { |k, v| [k.to_sym, v] }]
                  options=opts_from_cfg.merge(options)
        end
        opts.on("-a","--cobbler_api URL", "Cobbler API URL") do |a|
          options[:cobbler_api] = a
        end
        opts.on("-c","--cpus CPUS", "CPUS") do |c|
          options[:cpus] = c
        end
        opts.on("-r", "--ram RAM", "RAM in GB") do |r|
          optoons[:ram] = r
        end
        opts.on("-d","--disk-size DISK_SIZE_GB","Disk Size in GB") do |ds|
          options[:disk_size] = ds
        end
        opts.on("-p","--pool storage_pool","Storage pool to use") do |pool|
          options[:pool] = pool
        end
        opts.on("-b","--disk-bus disk_bus","Disk Bus to use virtio, etc") do |disk_bus|
          options[:disk_bus] = disk_bus
        end
         opts.on("-t","--disk-type disk_type","Disk type to use raw, qcow2, etc") do |disk_type|
           options[:disk_type] = disk_type
         end
end.parse!

#Find and load default config
if options[:config] == nil
  config_opts=Hash.new
  home=File.expand_path('~')
  if File.exists?(home+"/.vm_builderrc")
    config_opts=Hash[YAML::load(open(home+"/.vm_builderrc")).map { |k, v| [k.to_sym, v] }]
  end
  options=config_opts.merge(options)
end

if ARGV.length != 1
        puts "Please pass a system name, see --help"
        exit
else
        system_name = ARGV[0]
end


#Function to get info from cobbler
def cobbler_info(system_name,options)
  connection = XMLRPC::Client.new2("#{options[:cobbler_api]}")
  system_data = connection.call("get_system_as_rendered","#{system_name}")
  return(system_data)
end

def pool_list()
  #need list of storage pools, and their available capactiy...
  conn = Libvirt::open('qemu:///system')
  pool_list = conn.list_storage_pools
  #we don't care about the default pool for this logic
  pool_list.delete_at(pool_list.index("default"))
  #pool_list.delete("gvm_storage")
  return pool_list
end

def pool_biggest(pool_list)
    conn = Libvirt::open('qemu:///system')
    pools_avail = Hash.new
    pool_list.each do |pool_s|
      pool = conn.lookup_storage_pool_by_name(pool_s)
      pools_avail["#{pool_s}"] = pool.info.available.to_i
    end
      biggest_pool = pools_avail.sort{|a,b| a[1] <=> b[1]}.reverse[0][0]
    return(biggest_pool)
end

def make_disk(pool,system_name,disk_size,disk_type)
        refresh_cmd = "virsh pool-refresh #{pool}"
        storage_cmd = "virsh vol-create-as #{pool} #{system_name}-disk0.#{disk_type} #{disk_size}G --format #{disk_type}"
        #puts storage_cmd
        system refresh_cmd
        return(system storage_cmd)
end

def disk_cache(pool)
        case pool
        when /^gvm_storage/
                disk_cache = "writeback"
        when /^vm_storage/
                disk_cache = "none"
        else
                disk_cache = "default"
        end
        return(disk_cache)
end
def merge_ops(cobbler_info,options)
        #merge/reconcile the options passed with cobbler.
        #return the final hash of all ops we care about
        vm_ops=Hash.new
        vm_ops[:name] = cobbler_info["system_name"]
        #RAM
        case options[:ram]
        when !nil
                vm_ops[:ram] = options[:ram]
        else
                vm_ops[:ram] = cobbler_info["virt_ram"]
        end
        #CPUS
        case options[:cpus]
        when !nil
                vm_ops[:cpus] = options[:cpus]
        else
                vm_ops[:cpus] = cobbler_info["virt_cpus"]
        end
        #ARCH
        case options[:arch]
        when !nil
                vm_ops[:arch] = options[:arch]
        else
                vm_ops[:arch] = cobbler_info["arch"]
        end
        #OS
        case options[:os_variant]
        when !nil
                vm_ops[:os_variant] = options[:os_variant]
        else
                vm_ops[:os_variant] = cobbler_info["os_version"]
        end
        #DISK_SIZE
        case options[:disk_size]
        when !nil
                vm_ops[:disk_size] = options[:disk_size]
        else
                vm_ops[:disk_size] = cobbler_info["virt_file_size"]
        end
        #DISK_BUS
        #No else, not in cobbler
        case options[:disk_bus]
        when !nil
                vm_ops[:disk_bus] = options[:disk_bus]
        else
                vm_ops[:disk_bus] = "virtio"
        end
        #DISK_TYPE
        case options[:disk_type]
        when !nil
                vm_ops[:disk_type] = options[:disk_type]
        else
                vm_ops[:disk_type] = cobbler_info["virt_disk_driver"]
        end
        #DISK_CACHE
        #no else, not in cobbler as an option
        vm_ops[:disk_cache] = options[:disk_cache]

        #NET_BRIDGE
        case options[:net_bridge]
        when !nil
                vm_ops[:net_bridge] = options[:net_bridge]
        else
                vm_ops[:net_bridge] = cobbler_info["virt_bridge_eth0"]
        end
        #NET_MAC
        case options[:net_mac]
        when !nil
                vm_ops[:net_mac] = options[:net_mac]
        else
                vm_ops[:net_mac] = cobbler_info["mac_address_eth0"]
        end
        #install tree
        case options["location"]
        when !nil
                vm_ops[:location] = options[:location]
        else
                ks_meta = cobbler_info["ks_meta"].sub("tree=","").strip
                vm_ops[:location] = ks_meta
        end
        #extra
        case options["extra"]
        when !nil
                vm_ops[:extra] = options[:extra]
        else
                vm_ops[:extra] = "ks=http://#{cobbler_info['server']}/cblr/svc/op/ks/system/#{cobbler_info['system_name']} ksdevice=link kssendmac lang= text"
        end
        return(vm_ops)
end

def virt_install(vm_ops)
        #Does the virt-install command build, and calls virt-install!
        vi_cmd="virt-install --connect qemu:///system --name #{vm_ops[:name]} --ram #{vm_ops[:ram]} --vcpus #{vm_ops[:cpus]} --vnc --virt-type kvm --extra-args='#{vm_ops[:extra]}'  --location #{vm_ops[:location]} --arch #{vm_ops[:arch]} --os-variant #{vm_ops[:os_variant]} --disk path=#{vm_ops[:disk_path]},size=10,bus=#{vm_ops[:disk_bus]},driver_type=#{vm_ops[:disk_type]},cache=#{vm_ops[:disk_cache]} --network bridge=#{vm_ops[:net_bridge]},model=virtio,mac=#{vm_ops[:net_mac]} --wait 0 --noautoconsole"
        return(system vi_cmd)
end
#"Main"
info=cobbler_info(system_name,options)
if options[:pool] == nil
        pools=pool_list
        pool=pool_biggest(pools)
else
        pool = options[:pool]
end
options[:disk_cache] = disk_cache(pool)
vm_ops=merge_ops(info,options)
vm_ops[:name]=system_name
#We have a specific path
vm_ops[:disk_path]="/#{pool}/images/#{system_name}-disk0.#{vm_ops[:disk_type]}"

#Do it
make_disk(pool,system_name,vm_ops[:disk_size],vm_ops[:disk_type])
virt_install(vm_ops)
puts "Your VM, #{system_name} should now be building. Please note it will shutdown at the end of installation"
