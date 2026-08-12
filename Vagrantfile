# -*- mode: ruby -*-
# vi: set ft=ruby :

#
# Kubernetes The Hard Way - Vagrant Lab
#
# Purpose:
#   Creates the virtual infrastructure used by the Kubernetes The Hard Way lab.
#
# Responsibilities:
#   Vagrant is responsible only for virtual machine infrastructure:
#
#     - VM creation
#     - Hostnames
#     - CPU and memory allocation
#     - Private networking
#     - SSH bootstrap access
#
#   Guest operating system configuration and Kubernetes prerequisites are
#   managed separately with Ansible.
#
# Cluster:
#   - jumpbox  192.168.56.10  Management node
#   - server   192.168.56.20  Kubernetes control plane
#   - node-0   192.168.56.50  Kubernetes worker
#   - node-1   192.168.56.60  Kubernetes worker
#
# Requirements:
#   - Vagrant 2.3+
#   - VirtualBox
#   - Approximately 8 GB RAM available
#
# Tested Host Platforms:
#   - macOS / amd64
#   - macOS / arm64
#
# Architecture:
#   The Vagrant box may provide artifacts for multiple architectures.
#   Vagrant and VirtualBox select a compatible guest image for the host
#   platform when available.
#
#   Guest architecture detection and architecture-specific software
#   installation are handled by Ansible rather than this Vagrantfile.
#
# Environment Overrides:
#   VAGRANT_BOX - Override the default Vagrant box.
#
# Author: Omara Ouk
# Version: 2.0
#

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

NETWORK_PREFIX = "192.168.56"
NETWORK_NETMASK = "255.255.255.0"

VM_BOX = ENV.fetch("VAGRANT_BOX", "bento/ubuntu-24.04")

VM_SETTINGS = {
  "jumpbox" => {
    memory: 1024,
    cpus: 1,
    ip: "#{NETWORK_PREFIX}.10"
  },
  "server" => {
    memory: 2048,
    cpus: 1,
    ip: "#{NETWORK_PREFIX}.20"
  },
  "node-0" => {
    memory: 2048,
    cpus: 1,
    ip: "#{NETWORK_PREFIX}.50"
  },
  "node-1" => {
    memory: 2048,
    cpus: 1,
    ip: "#{NETWORK_PREFIX}.60"
  }
}

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------

Vagrant.require_version ">= 2.3.0"

# ---------------------------------------------------------------------------
# Vagrant Configuration
# ---------------------------------------------------------------------------

Vagrant.configure("2") do |config|

  # -------------------------------------------------------------------------
  # Base Box
  # -------------------------------------------------------------------------

  config.vm.box = VM_BOX
  config.vm.box_check_update = false

  # -------------------------------------------------------------------------
  # VirtualBox Defaults
  # -------------------------------------------------------------------------

  config.vm.provider "virtualbox" do |vb|
    vb.gui = false
    vb.linked_clone = true
  end

  # -------------------------------------------------------------------------
  # SSH
  #
  # Vagrant provides the initial SSH access used to bootstrap Ansible.
  # Ansible connects as the Vagrant user and escalates privileges with sudo.
  # -------------------------------------------------------------------------

  config.ssh.forward_agent = true
  config.ssh.insert_key = true
  config.ssh.keys_only = true

  # -------------------------------------------------------------------------
  # Virtual Machines
  # -------------------------------------------------------------------------

  VM_SETTINGS.each do |name, settings|
    config.vm.define name, primary: (name == "jumpbox") do |machine|

      machine.vm.hostname = name

      # Private cluster network
      machine.vm.network "private_network",
        ip: settings[:ip],
        netmask: NETWORK_NETMASK

      # VirtualBox resources
      machine.vm.provider "virtualbox" do |vb|
        vb.name = name
        vb.memory = settings[:memory]
        vb.cpus = settings[:cpus]
      end
    end
  end
end