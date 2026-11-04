# Ansible Configuration Management

Ansible project for managing Linux hosts over SSH. It includes a small
environment inventory, a playbook for common host maintenance, and a role
that installs Apache and publishes the HTML content of a separate website
repository to UAT web servers.
# Ansible Static Roles Configuration Management with Jenkins and GitHub
> **DevOps Portfolio Project,Configuration
> Management & CI/CD**
------------------------------------------------------------------------

## What this repository does

- Defines development and UAT hosts in Ansible inventory files.
- Installs or removes Wireshark on the `nfs` and `web` groups.
- Creates a temporary directory and file, configures the timezone to
  `Africa/Nairobi`, and reports basic server information.
- Installs Apache and Git on UAT hosts, clones the
  `tabby123-dev/tooling-solution` repository, and copies its HTML content to
  Apache's document root.

## Repository layout

```text
.
A linux  server was configured as the **Ansible control node**. SSH
key-based authentication was established between the control node and
the managed servers, allowing Ansible to remotely execute configuration
tasks.

The Ansible project was organized into separate `inventory` and
`playbooks` `role` and `static assignements` directories. A development inventory file was created to
define the remote hosts, while multiple Ansible playbooks were developed
to automate:

-   Installation and uninstallation of Wireshark.
-   Creation of a directory and file on a remote server.
-   Configuration of the server timezone to `Africa/Nairobi`.

The project was then integrated with a **GitHub repository and
Jenkins**. A GitHub webhook was configured so that a repository change
can trigger the Jenkins job automatically.

------------------------------------------------------------------------

# Architecture

## High-Level Architecture

The architecture consists of a developer workstation, GitHub,
Jenkins/Ansible control node, and multiple managed servers.

![Project Architecture](images/architecture.png)

### Architecture Components

  -----------------------------------------------------------------------
  Component                           Role
  ----------------------------------- -----------------------------------
  **Developer PC**                        Used to create and modify Ansible
                                      automation code

  **GitHub**                              Version control and central
                                      repository for the automation code

  **GitHub Webhook**                      Sends an event to Jenkins when
                                      repository changes occur

  **Jenkins**                             Automates the CI/CD execution
                                      workflow

  **Ansible Control Node**              Executes playbooks against managed
                                      servers

  **Ansible Inventory**                 Defines and groups the managed
                                      hosts

  **SSH**                                 Secure communication between the
                                      control node and managed servers

  **RHEL 8 Servers**                      Remote servers managed by Ansible

  **Ubuntu Server**                      Remote development
                                      server/load-balancer environment
  -----------------------------------------------------------------------

# Repository Structure

The Ansible project is organized to separate inventory configuration
from automation playbooks.

``` text
ansible-configuration-mgmt/
│
├── inventory/
│   ├── dev.yml
│   ├── prod.yml
│   ├── staging.yml
│   └── uat.yml
├── playbooks/
│   └── site.yml
├── roles/
│   └── webserver/
│       ├── defaults/main.yml
│       ├── handlers/main.yml
│       ├── meta/main.yml
│       ├── tasks/main.yml
│       └── README.md
├── scripts/
│   └── server-info.sh
└── static-assigments/
    ├── common.yml
    ├── common-del.yml
    └── uat-webservers.yml
```

The `static-assigments` spelling is the directory name used in this repository.
`playbooks/site.yml` imports `static-assigments/uat-webservers.yml`, which
applies the `webserver` role.

## Requirements

- Ansible installed on the control node.
- SSH access from the control node to each managed host, with a working
  account and private key.
- Privilege escalation (sudo) where required by the tasks.
- For the webserver role, Debian- or Ubuntu-based UAT hosts with access to
  their package repositories and to GitHub.
- For the common playbook, hosts in the `nfs` and `web` groups must support the
  `yum` package module and the `timedatectl` command.

Check the installed Ansible version and connectivity before running changes:

```bash
ansible --version
ansible-inventory -i inventory/dev.yml --graph
ansible all -i inventory/dev.yml -m ansible.builtin.ping
```

## Configure inventory and SSH

Inventory files define host groups, connection users, and private-key paths.
The development inventory currently defines `nfs` and `web` groups; the UAT
inventory defines `uatweb`. Update host addresses, usernames, and key paths to
match your environment before use. `inventory/staging.yml` and
`inventory/prod.yml` are currently empty and do not define deployable hosts.

Keep private keys outside the repository. Do not commit credentials, private
keys, or other secrets. Use a protected key file with restrictive permissions,
and verify that each account can connect to its host over SSH. For example:

```bash
ssh -i /path/to/private-key <user>@<host>
```

You can inspect the hosts selected by a playbook without applying changes:

```bash
ansible-playbook -i inventory/uat.yml playbooks/site.yml --list-hosts
```

## Run the automation

### Deploy the UAT webserver role

`playbooks/site.yml` imports the UAT webserver play. Run it with the UAT
inventory:

```bash
ansible-playbook -i inventory/uat.yml playbooks/site.yml --syntax-check
ansible-playbook -i inventory/uat.yml playbooks/site.yml
```

The `webserver` role:

1. Installs `apache2` and `git`.
2. Clones `https://github.com/tabby123-dev/tooling-solution.git` at the
   `main` branch into `/var/www/tooling`.
3. Copies `/var/www/tooling/html/` into `/var/www/html/`.
4. Starts and enables the Apache service.
5. Removes `/var/www/html/html` if it exists.

The role uses fixed paths and follows the mutable `main` branch. Review these
choices before using it for production deployments. Also, the play does not
enable privilege escalation globally: while several role tasks explicitly use
`become`, the service and cleanup tasks do not. Configure privilege escalation
for those tasks or the play if the remote connection user is not root.

### Apply common host configuration

The common playbook targets the `nfs` and `web` groups in the selected
inventory. For the development inventory:

```bash
ansible-playbook -i inventory/dev.yml static-assigments/common.yml --syntax-check
ansible-playbook -i inventory/dev.yml static-assigments/common.yml
```

It installs Wireshark using `yum`, creates `/tmp/test_directory` and
`/tmp/test_directory/test_file.txt`, displays the current timezone, sets
`Africa/Nairobi`, and runs `scripts/server-info.sh` on each target. The script
reports the hostname, date, uptime, IP addresses, disk usage, and memory usage.

**Controller path requirement:** the playbook currently refers to the script
using the absolute control-node path
`/home/opc/ansible-config-mgmt/scripts/server-info.sh`. If this repository is
checked out elsewhere, update that `cmd` path in
`static-assigments/common.yml` before running the playbook.

### Remove Wireshark

`static-assigments/common-del.yml` removes Wireshark from the `nfs` and `web`
groups. Review the target hosts before applying this change:

```bash
ansible-playbook -i inventory/dev.yml static-assigments/common-del.yml --list-hosts
ansible-playbook -i inventory/dev.yml static-assigments/common-del.yml
```

## Validation and operational notes

- Use `--syntax-check` and `--list-hosts` before applying changes.
- Ansible check mode (`--check`) can help preview supported changes, but is not
  a guarantee that every task will be simulated or validated.
- The common playbook changes the system timezone and installs software; run it
  only against intended hosts with suitable privilege.
- The common playbook uses `yum`, while the webserver role uses `apt`. Use
  inventories whose target operating systems match the relevant tasks.
- The webserver role pulls website content at run time, so deployment depends
  on GitHub availability and the selected branch contents.
- No Jenkins pipeline, CI workflow, dependency lock file, or automated test
  suite is included in this repository. Any CI/CD integration must be
  configured separately.

## Related project

The website content is maintained separately in
[tooling-solution](https://github.com/tabby123-dev/tooling-solution). This
repository only contains the Ansible automation that clones and deploys it.
