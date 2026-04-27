terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.92.0"
    }
  }
}
locals {
  #Source: https://images.linuxcontainers.org/
  # http://download.proxmox.com/images/system/
  lxc_templates = {
    ubuntu_2204 = "http://download.proxmox.com/images/system/ubuntu-22.04-standard_22.04-1_amd64.tar.zst",
    alpine_3    = "http://download.proxmox.com/images/system/alpine-3.23-default_20260116_amd64.tar.xz"
    ubuntu_2404 = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-root.tar.xz",
    debian_12   = "http://download.proxmox.com/images/system/debian-12-standard_12.12-1_amd64.tar.zst"

  }
  vm_template = {
    ubuntu_2404 = "https://cloud-images.ubuntu.com/noble/20260108/noble-server-cloudimg-amd64.img",
    #Reference: https://cloud-images.ubuntu.com/jammy/current/
    ubuntu_2204 = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
    debian_13   = "https://cdimage.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
  }
  node_name = "pve-master"
  network = {
    private = {
      bridge_address = "192.168.99.1/24"
      bridge_name    = "private"
      node_name      = local.node_name
      bridge_comment = "This network can't be reached from outside and is used for stateful applications."
    },
  }
  lxc = {
    postgresql_16 = {
      ip_address               = "192.168.99.2/24"
      gateway                  = "192.168.99.1"
      network_interface_name   = "eth0"
      network_interface_bridge = "private"
      template_file_id         = resource.proxmox_virtual_environment_download_file.lxc["ubuntu_2204"].id
      operating_system_type    = "ubuntu"
      cores                    = 1
      memory                   = 1024 * 2
      node_name                = local.node_name
      mount_volume_size        = 50 #GB
      vm_id                    = 100
      hostname                 = "postgresql-16.internal"
      tags                     = ["Production", "Database"]
      protection               = true
      startup_config = {
        order      = 1
        up_delay   = 10
        down_delay = 10
      }
    },
    crowdsec_detection_engine = {
      ip_address               = "192.168.1.127/24"
      gateway                  = "192.168.1.1"
      network_interface_name   = "eth0"
      network_interface_bridge = "vmbr0"
      vm_id                    = 317
      template_file_id         = resource.proxmox_virtual_environment_download_file.lxc["ubuntu_2204"].id
      operating_system_type    = "ubuntu"
      on_boot                  = true
      cores                    = 1
      memory                   = 1024 * 1
      node_name                = local.node_name
      mount_volume_size        = 10 #GB
      hostname                 = "crowsec-detection-engine.local"
      tags                     = ["WAF", "production", "security"]
      protection               = true
      startup_config = {
        order      = 1
        up_delay   = 10
        down_delay = 10
      }
    },
  }
  lan_gateway    = "192.168.1.1"
  k8s_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCxraGdlzJDPInNQ4zbyr1usD3nSbeofvjx+kRTN/7lFmEoCujn8UyEfaQfe6k/shGQyH8ghb61XzISkDv3Dcir+apQ1x4ajALZX6m+miF4G0R7tOTObj+2MCdOCZ1iklFolhjSJ/wPunoQD5x9jz8mnmr03zZcCr+xVQzMPDHPCeMZlXN0mDg2AJj4+RxolZeW7T9/v0h2l300ZFYbpbUWG+WkJWAy2iqpf2z3TRt74sCyby0sPPeLbg3G9XqWVpx+lVrI/XfG3mirGx+NgEcGBQNNM7HcobHuJ3IejFsVCCenQHiPrMjMk8XhflJ4Vk8ydTTaMNHY5kn9qSyJIA9JxlWypqmIhJYilUADjPCMYt97ahQR8C8BTFxcFGTH8Nf27db6C9rFaZ/WPlbkWOdmW+IFKTVmqyw6l+KBAIKu1pl3wLbY9eot0kQCODlk6ZSbn5yy6e2HU7zpPCbMVGVqwbiOUlVfcTjTEDrlFUZgVhAp5Z/vu9FjdMeDrTQppKE= akira@legion5"
}
module "network_default" {
  source         = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/network/private?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  for_each       = local.network
  bridge_address = each.value.bridge_address
  node_name      = local.node_name
  bridge_name    = each.key
  bridge_comment = each.value.bridge_comment
}
resource "proxmox_virtual_environment_download_file" "vm" {
  for_each     = local.vm_template
  file_name    = "${each.key}.qcow2"
  datastore_id = "local"
  content_type = "import"
  node_name    = local.node_name
  url          = each.value
}
resource "proxmox_virtual_environment_download_file" "lxc" {
  for_each     = local.lxc_templates
  datastore_id = "local"
  content_type = "vztmpl"
  node_name    = local.node_name
  url          = each.value
}
module "ubuntu_server" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  name              = "UbuntuServer"
  tags              = ["production", "file-storage", "public-facing", "reverse-proxy"]
  node_name         = local.node_name
  ip_address        = "192.168.1.121/24"
  hostname          = "ubuntu-server.local"
  bridge_name       = "vmbr0"
  memory            = 1024 * 12
  gateway           = local.lan_gateway
  protection        = true
  vm_id             = 101
  cpu_type          = "host"
  boot_disk_size    = 256
  cpu_cores         = 4
  public_key        = file("~/OneDrive/credentials/ssh/akira-ubuntu-server/root/id_rsa.pub")
  on_boot           = true
  network_model     = "e1000e"
  startup_config = {
    order      = 2
    up_delay   = 10
    down_delay = 10
  }
  additional_disks = {
    data1 = {
      path_in_datastore = "/dev/disk/by-id/ata-ST500DM002-1BD142_Z3TX81A7"
      file_format       = "raw"
      datastore_id      = ""
      interface         = "virtio1"
      size              = 465
      backup            = false
    },
    data2 = {
      path_in_datastore = "/dev/disk/by-id/ata-HGST_HTS721010A9E630_JR10006P1SSP5F"
      file_format       = "raw"
      datastore_id      = ""
      interface         = "virtio2"
      size              = 931
      backup            = false
    }
  }
}
#Push metrics to influxdb hosted in Ubuntu vm
resource "proxmox_virtual_environment_metrics_server" "influxdb_server" {
  count               = var.influxdb_token == null ? 0 : 1
  name                = "influxdb-ubuntu-server"
  server              = "192.168.1.121"
  port                = 8086
  type                = "influxdb"
  influx_organization = "proxmox"
  influx_bucket       = "proxmox"
  influx_db_proto     = "http"
  influx_token        = var.influxdb_token
}

module "lxc_production" {
  source                   = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/lxc?ref=5057455e75f154313b393aacac1a854b52988676"
  for_each                 = local.lxc
  ip_address               = each.value.ip_address
  gateway                  = each.value.gateway
  network_interface_name   = each.value.network_interface_name
  template_file_id         = each.value.template_file_id
  operating_system_type    = each.value.operating_system_type
  network_interface_bridge = each.value.network_interface_bridge
  cores                    = each.value.cores
  memory                   = each.value.memory
  vm_id                    = each.value.vm_id
  node_name                = each.value.node_name
  tags                     = each.value.tags
  hostname                 = each.value.hostname
  mount_volume_size        = each.value.mount_volume_size
  protection               = each.value.protection
  startup_config           = each.value.startup_config
  datastore_id             = "local-lvm"
  mount_volume_name        = "local-lvm"
}
module "vpn_server" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["debian_13"].id
  name              = "vpn-server"
  hostname          = "vpn-server.local"
  tags              = ["production", "openvpn"]
  node_name         = local.node_name
  ip_address        = "192.168.1.123/24"
  bridge_name       = "vmbr0"
  memory            = 1024 * 2
  gateway           = local.lan_gateway
  on_boot           = true
  boot_disk_size    = 10
  cpu_cores         = 1
  public_key        = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDsrn8bEdQQsmIOD192lsGXl0gdMZO9zESt4I8+QvIKjGvqYCWsR7Pi0LhvxD6jdm+dfIJymmQ6Qth9W0HgfHnUVZ9SEzW+vi3g2kSClutOA25IdelChrCw3jOrsYamITDH/J5mwb26ezGqx+32INM43seONN3pKuUL/C9WXVf4KMqvl2biAUJjaofRC3KuJUe2FJoA0j+pJZJ+ciCZBTg3CmAqjuUnQgWZOyhfaEDJ5m9q+u/anWKsBNxtJux7QGNyErKFNi3rg+c+yqkAAUfVO3a3N/mmezdaNlGjace3gFncjHfSDEye1RwJv+Oyd1d8mxzTjl9R4tNSOuHd8Xxd4FNwBFn1o1KRIyvur43Z3Aqj/3qWjTrhY5DoV920Wq7xZEr+u+BdQUF3nTzrqt/B48BJpxAm6CTHpq/OFXTD+ZFRaPIgJAG04sjp4oWOGS2ni40v4Y9vooweCqmr1kGog9nqcTU6lxV+umDjBc0ekdDAKnWnUOJzhP8rO5ogQ4c= akira@legion5"
  network_model     = "e1000e"
  startup_config = {
    order      = 1
    up_delay   = 10
    down_delay = 10
  }
}

module "k8s_masters" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=fe948c3e53255a50a62a2021d69f5df0d3bcd2af"
  count             = 3
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  hostname          = "master-nodes-${count.index}.local"
  name              = "master-nodes-${count.index}"
  public_key        = local.k8s_public_key
  ip_address        = "192.168.1.18${count.index}/24"
  tags              = ["production", "kubernetes-masters"]
  gateway           = "192.168.1.1"
  memory            = 1024*5 
  cpu_cores         = 2
  cpu_type = "host"
  node_name         = local.node_name
  boot_disk_size    = 50
  datastore_id      = "local-lvm"
  bridge_name       = "vmbr0"
  startup_config = {
    order      = 3
    up_delay   = 5
    down_delay = 30
  }
}
module "k8s_workers" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=fe948c3e53255a50a62a2021d69f5df0d3bcd2af"
  count             = 4
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  hostname          = "worker-nodes-${count.index}.local"
  name              = "worker-nodes-${count.index}"
  public_key        = local.k8s_public_key
  ip_address        = "192.168.1.19${count.index}/24"
  tags              = ["production", "kubernetes-workers"]
  boot_disk_size    = 250
  gateway           = "192.168.1.1"
  memory            = 1024 * 10
  cpu_cores         = 10
  cpu_type = "host"
  node_name         = local.node_name
  datastore_id      = "local-lvm"
  bridge_name       = "vmbr0"
  startup_config = {
    order      = 4
    up_delay   = 5
    down_delay = 30
  }
}
output "lxc_default" {
  value     = module.lxc_production
  sensitive = true
}
output "k8s-masters" {
  value = module.k8s_masters
}
output "k8s-workers" {
  value = module.k8s_workers
}