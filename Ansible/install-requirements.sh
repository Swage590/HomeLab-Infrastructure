#!/bin/bash

# Install Ansible w/Dependancies
sudo apt update
sudo apt install software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install ansible

# Install passlib to Enable Password Encryption
pipx inject ansible passlib
