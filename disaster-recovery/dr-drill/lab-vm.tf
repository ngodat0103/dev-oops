# Provider config
terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_network" "k8s_net" {
  name      = "dev-homelab-k8s"
  autostart= true
  mode      = "nat"
  addresses = ["192.168.100.0/24"]
}

# resource "libvirt_pool" "k8s" {
#   name = "k8s-dev"
#   type = "dir"
#   source = "/var/lib/libvirt/images/dev-homelab-k8s"
# }



# resource "libvirt_volume" "base" {
#   name   = "ubuntu-base.qcow2"
#   pool   = libvirt_pool.k8s.name
#   source = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
# }

# resource "libvirt_volume" "node_disk" {
#   count          = 3
#   name           = "node${count.index}.qcow2"
#   pool           = libvirt_pool.k8s.name
#   base_volume_id = libvirt_volume.base.id
#   size           = 30 * 1024 * 1024 * 1024 # 30GB
# }



# resource "libvirt_cloudinit_disk" "cloudinit" {
#   count = 3
#   name  = "cloudinit-node${count.index}.iso"
#   pool  = libvirt_pool.k8s.name
#   user_data = templatefile("${path.module}/cloud_init.cfg", {
#     hostname = "node${count.index}"
#   })
# }

# resource "libvirt_domain" "node" {
#   count  = 3
#   name   = "node${count.index}"
#   memory = 4096
#   vcpu   = 2

#   disk {
#     volume_id = libvirt_volume.node_disk[count.index].id
#   }

#   network_interface {
#     network_id     = libvirt_network.k8s_net.id
#     addresses      = ["192.168.100.${10 + count.index}"]
#     wait_for_lease = true
#   }
#   cloudinit = libvirt_cloudinit_disk.cloudinit[count.index].id
#   console {
#     type        = "pty"
#     target_type = "serial"
#     target_port = "0"
#   }
# }