# HomeLab-Infrastructure
This is my configuration files that I use to configure my HomeLab

# Dependancies
Terraform --> https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli

Ansible   --> https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html

# Directions for setup




```bash
git clone https://github.com/Swage590/HomeLab-Infrastructure
cd HomeLab-Infrastructure
chmod +x inject-op-token.sh
chmod +x windows-op-wrapper.sh
chmod +x Ansible/ansible-vault-password.sh
cd Terraform
terraform init
```

# Terraform Instructions

```bash
./inject-op-token.sh
cd Terraform
terraform apply
```

# Ansible Instructions

```bash
cd Ansible
python3 sync-host-vars.py
ansible-playbook main.yml --vault-password-file ansible-vault-password.sh
```
