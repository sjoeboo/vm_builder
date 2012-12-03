vm_builder
==========

Script wrapping virt-install to allow for more flexibility than koan

I've foudn some shortcoming with koan for the way we want to use it (mostly, the inability to pass specific options to virt-install). this is an attempt to wrap virt-install to make it easier for OUR use case

vm_builderrc can be specified with the `-f` flag, or found in `~/.vm_builderrc`. It is a simple YAML hash of otions which will override options from cobbler. Options passed on the cli will also override this config file.

	cobbler_api: http://cobbler/cobbler_api
	ram: 1024
	cpus: 1
	disk_size: 10
	disk_bus: virtio
	disk_type: qcow2
	disk_cache: writeback

