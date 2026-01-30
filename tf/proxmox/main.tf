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
    ubuntu_2204 = "https://images.linuxcontainers.org/images/ubuntu/jammy/amd64/cloud/20250826_07:42/rootfs.tar.xz",
    alpine_3 = "http://download.proxmox.com/images/system/alpine-3.23-default_20260116_amd64.tar.xz"

  }

  vm_template = {
    ubuntu_2404 = "https://cloud-images.ubuntu.com/noble/20260108/noble-server-cloudimg-amd64.img",
    #Reference: https://cloud-images.ubuntu.com/jammy/current/
    ubuntu_2204 = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
    debian_13   = "https://cdimage.debian.org/images/cloud/trixie/20251117-2299/debian-13-generic-amd64-20251117-2299.qcow2"
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
      cores                    = 1
      memory                   = 1024 * 4
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
    kafka = {
      ip_address               = "192.168.99.2/24"
      gateway                  = "192.168.99.1"
      network_interface_name   = "eth0"
      network_interface_bridge = "private"
      vm_id                    = 315
      template_file_id         = resource.proxmox_virtual_environment_download_file.lxc["ubuntu_2204"].id
      cores                    = 4
      memory                   = 1024 * 8
      node_name                = local.node_name
      mount_volume_size        = 30 #GB
      hostname                 = "kafka.internal"
      tags                     = ["Production"]
      protection               = true
      startup_config = {
        order      = 2
        up_delay   = 10
        down_delay = 10
      }
    },
    core_dns = {
      ip_address               = "192.168.1.126/24"
      gateway                  = "192.168.1.1"
      network_interface_name   = "eth0"
      network_interface_bridge = "vmbr0"
      vm_id                    = 316
      template_file_id         = resource.proxmox_virtual_environment_download_file.lxc["alpine_3"].id
      on_boot = true
      cores                    = 1 
      memory                   = 128
      node_name                = local.node_name
      mount_volume_size        = 1 #GB
      hostname                 = "core-dns.internal"
      tags                     = ["Production"]
      protection               = true
      startup_config = {
        order      = 1
        up_delay   = 10
        down_delay = 10
      }
    }
  }
  lan_gateway    = "192.168.1.1"
  k8s_public_key = file("~/OneDrive/credentials/ssh/k8s/id_rsa.pub")
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
module "ubuntu_server" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  name              = "UbuntuServer"
  tags              = ["production", "file-storage", "public-facing", "reverse-proxy"]
  node_name         = local.node_name
  ip_address        = "192.168.1.121/24"
  hostname          = "ubuntu-server.local"
  bridge_name       = "vmbr0"
  memory            = 1024 * 16
  gateway           = local.lan_gateway
  protection        = true
  vm_id             = 101
  cpu_type          = "host"
  boot_disk_size    = 256
  cpu_cores         = 4
  public_key        = file("~/OneDrive/credentials/ssh/akira-ubuntu-server/root/id_rsa.pub")
  on_boot = true
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

module "teleport" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  name              = "Teleport"
  tags              = ["development", "infra-access", "public-facing"]
  node_name         = local.node_name
  ip_address        = "192.168.1.122/24"
  hostname          = "teleport.local"
  bridge_name       = "vmbr0"
  memory            = 1024 * 2
  gateway           = local.lan_gateway
  protection        = false
  boot_disk_size    = 30
  cpu_cores         = 1
  public_key        = file("~/OneDrive/credentials/ssh/teleport/id_rsa.pub")
  network_model     = "e1000e"
  startup_config = {
    order      = 3
    up_delay   = 60
    down_delay = 60
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
resource "proxmox_virtual_environment_download_file" "lxc" {
  for_each       = local.lxc_templates
  file_name      = "${each.key}.tar.xz"
  datastore_id   = "local"
  content_type   = "vztmpl"
  node_name      = local.node_name
  url            = each.value
  upload_timeout = 10
}
module "lxc_production" {
  source                   = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/lxc?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  for_each                 = local.lxc
  ip_address               = each.value.ip_address
  gateway                  = each.value.gateway
  network_interface_name   = each.value.network_interface_name
  template_file_id         = each.value.template_file_id
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
module "k8s_masters" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  count             = 3
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  hostname          = "master-nodes-${count.index}.local"
  name              = "master-nodes-${count.index}"
  public_key        = local.k8s_public_key
  ip_address        = "192.168.1.13${count.index}/24"
  tags              = ["development", "kubernetes-masters"]
  gateway           = "192.168.1.1"
  memory            = 4096
  cpu_cores         = 2
  node_name         = local.node_name
  boot_disk_size    = 50
  datastore_id      = "local-lvm"
  bridge_name       = "vmbr0"
  vm_id             = 300 + count.index
  startup_config = {
    order      = 3
    up_delay   = 3
    down_delay = 30
  }
}
module "k8s_workers" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  count             = 5
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  hostname          = "worker-nodes-${count.index}.local"
  name              = "worker-nodes-${count.index}"
  public_key        = local.k8s_public_key
  ip_address        = "192.168.1.14${count.index}/24"
  tags              = ["development", "kubernetes-workers"]
  boot_disk_size    = 200
  gateway           = "192.168.1.1"
  memory            = 1024 * 5
  cpu_cores         = 4
  node_name         = local.node_name
  datastore_id      = "local-lvm"
  bridge_name       = "vmbr0"
  vm_id             = 310 + count.index
  startup_config = {
    order      = 4
    up_delay   = 10
    down_delay = 30
  }
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

module "hephaestus" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  name              = "hephaestus"
  tags              = ["Gitlab-runner", "Github-runner", "production"]
  hostname          = "hephaestus.local"
  node_name         = local.node_name
  ip_address        = "192.168.1.124/24"
  bridge_name       = "vmbr0"
  memory            = 1024 * 16
  gateway           = local.lan_gateway
  description       = "The server to run multiple CI tools such as Github Runner, Gitlab Runner"
  on_boot           = true
  boot_disk_size    = 150
  cpu_cores         = 4
  public_key        = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCrERHvr2Wb8+W9BtivbGS6O0Z7ggXtMYGUgfjWgG2xtVfy/3KjzrTuo/Qycb+sLOQUEYK3ciXe8UMEP0nsh3oLwH6ty19izzFqjptAXfErkWY43FV0SfOj/NmdoAfDT0VSawjcxKDZlaJuFynIzjweR4vt7zvwOohxbz6sJv1EOQzjhwV+dBR8B2sT0bt1pwGK/L9Yb6y0XBCafTCErwM32sraa0EJOI7614BxrQ4f57i3Qxru9vFkHmAcH45MOuXTdjYvmfAKs+TlePV0tSgZfR/NgI+/opzvwOxYK3m4myAf+SpObopfEqIclAdqPNytwgGjORXey7am7IzzUWOJ2f2WaCHxLgs6OezfCSewz1w4riN5XCD8k2AAm1UgYWKcjGr3iG4ipoUA3F3s5lDNu7TKW39WzuMsBD/LUexY6C6HCFnipM+BJZYJ97TDcQB8BrZCZgFPf7YpMr8OkUmDLgroiZsWWvpmUxj3VvMQmMOp/0QktS2N8QxTLptjzu0= akira@legion5"
  network_model     = "e1000e"
  startup_config = {
    order      = 3
    up_delay   = 30
    down_delay = 1
  }
}
module "sonarqube" {
  source            = "git::https://github.com/ngodat0103/terraform-module.git//proxmox/vm?ref=623d6edb16c1b609627de5c878c794cb8dd41c64"
  template_image_id = resource.proxmox_virtual_environment_download_file.vm["ubuntu_2204"].id
  name              = "sonarqube"
  tags              = ["Sonarqube", "production"]
  hostname          = "sonarqube.local"
  node_name         = local.node_name
  ip_address        = "192.168.1.125/24"
  bridge_name       = "vmbr0"
  memory            = 1024 * 8
  gateway           = local.lan_gateway
  on_boot           = true
  boot_disk_size    = 150
  cpu_cores         = 4
  public_key        = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCTbsuzpC3Crbmy8bq6NfKqGoJKrxFdSPz4+HSfE/gljWKzMimRQZY46j8JEK3tgZxHkgW8gRewV7cIyOkw0GbOnBjISQIO+zrPJjxJrdXR/odbOFQ+Xqpk6llHoZcNd15dDmVITD34QVyVvdNxm04lnOKKixuvjJ+rLn8FxSFED6oBeLF8H5JWodhn/GsK0ysQEJGHrE1JPfY73V0wr2rnKdAyYEYZvqj4XNcOkDAzGP7minTHQVyJC+b9PNu1SzRPimbkXio/pns/wDonc44lq1+XiBHr7vrny0lqLMZI8APmYfQ6F0lE2yAEnMNEET6c6mR8vpzSHXZH2g7b6N8etoTAZBM3e1ufrw7+E6LxOzULvIAXHzZOMlb8GeKrcrXc8j6KxPGAoHkXGU8evoEtNpd5wuNNNmtENbNtqopR6tpiMkifQSuzlWq2Vw6SX5RQXfQaeeiNc4j2iZpUw3ps8vKLZOB2a1r/QoTXyLKeJJr+EBvsz1SG9CzCC7KxwyM= akira@legion5"
  network_model     = "e1000e"
  startup_config = {
    order      = 1
    up_delay   = 30
    down_delay = 1
  }
}