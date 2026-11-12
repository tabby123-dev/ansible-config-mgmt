# OCI Tooling Application | Jenkins, Ansible and HAProxy

> **Status: implemented lab; production go-live pending controls listed below.** This is a reproducible implementation and operations guide, not a claim that the environment is production-certified. Last documented: 12 November 2026.

Automate a PHP Tooling application on Oracle Cloud Infrastructure (OCI) using **static Ansible imports**, **dynamic task/role inclusion**, a Galaxy community role, shared NFS storage and HAProxy. OCI instances were provisioned before the exercise; the work focused on configuration and deployment.

**Repositories:** [Ansible configuration](https://github.com/tabby123-dev/ansible-config-mgmt) · [Tooling application](https://github.com/tabby123-dev/tooling-solution)

## 1. Architecture and current state

![Original reference architecture](screenshots/architecture.jpeg)

| Host | OS | Private IP | Function |
|---|---|---|---|
| Jenkins controller | Oracle Linux 9.8 | `10.0.0.166` | Jenkins, Git, Ansible Core 2.14.18 |
| Web1 | Oracle Linux 8.10 | `10.0.1.229` | Apache, PHP, Tooling backend |
| Web2 | Oracle Linux 8.10 | `10.0.1.136` | Apache, PHP, Tooling backend |
| db-server | Oracle Linux 9.8 | `10.0.1.29` | **MySQL 8.0.46** and NFSv4.2 server |
| LoadBalancer | Ubuntu 22.04 | `10.0.1.64` | HAProxy `:8081`; existing Apache `:80` |

```text
GitHub → Jenkins/Ansible (10.0.0.166)
                  │ SSH / private VCN
                  ▼
     HAProxy 10.0.1.64:8081
          ├── Web1 10.0.1.229:80
          └── Web2 10.0.1.136:80
                   │
          NFS: 10.0.1.29:/mnt/apps → /var/www (BOTH web hosts)
          MySQL: 10.0.1.29:3306
```

**Critical shared-storage constraint:** Web1 and Web2 mount the **same** export at `/var/www`, so `/var/www/html` is shared. A deployment to Web1 can change the files Web2 serves, even when the playbook uses `--limit uat`. The earlier `uat`/`prod` inventory labels were used for learning exercises; the final architecture decision is **one load-balanced application tier**. Align release, database configuration and session behavior before enabling production traffic. The Ubuntu load balancer remains in a **private subnet**; this setup does not provide public ingress.

## 2. Repository layout

```text
ansible-config-mgmt/
└── dynamic-assignment/
    ├── ansible.cfg
    ├── inventory/hosts.ini
    ├── group_vars/               # historical UAT/prod exercises
    ├── roles/
    │   ├── common/tasks/main.yml
    │   ├── tooling_web/tasks/main.yml
    │   └── haproxy/
    │       ├── defaults/main.yml
    │       ├── tasks/main.yml
    │       ├── templates/haproxy.cfg.j2
    │       └── handlers/main.yml
    ├── new-dynamictask/
    │   ├── main.yml
    │   ├── static-role.yml
    │   ├── deploy-tooling.yml
    │   ├── fix-web2-php.yml
    │   └── deploy-haproxy.yml
    └── requirement.yml
```

Paths reflect the implementation discussed; check the working tree before copying example files. The original Galaxy role directory was later missing and **must be reinstalled and reviewed** before use.

## 3. Prerequisites and inventory

- OCI VCN routing and restrictive NSG/security-list rules: Jenkins → managed hosts TCP 22; HAProxy → Web1/Web2 TCP 80; web hosts → MySQL TCP 3306 and NFS TCP 2049; Jenkins → HAProxy TCP 8081 for testing. Host firewalls must also permit the intended flows.
- SSH key accessible only to the Jenkins automation identity; use Jenkins Credentials for pipeline execution, **never commit private keys or database passwords**.
- `sudo`/`become` permissions, Python on managed hosts, Ansible and Git on controller; pin role/collection versions.

```bash
cd /home/opc/ansible-config-mgmt/dynamic-assignment
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
ansible --version
ansible-inventory --graph
ansible webservers --list-hosts  # must show ONLY Web1 and Web2
ansible all -m ansible.builtin.ping
ansible all -b -m ansible.builtin.command -a 'id -u'
```

`ansible.cfg`:

```ini
[defaults]
inventory = inventory/hosts.ini
roles_path = ./roles
host_key_checking = True
```

Representative inventory (adapt users/keys to actual OCI images; **do not place `loadbalancer` under `[webservers:children]`**):

```ini
[webservers]
Web1 ansible_host=10.0.1.229
Web2 ansible_host=10.0.1.136

[dbservers]
db-server ansible_host=10.0.1.29

[loadbalancer]
LoadBalancer ansible_host=10.0.1.64 ansible_user=ubuntu

[all:vars]
ansible_ssh_private_key_file=/home/opc/private.key
ansible_python_interpreter=/usr/bin/python3
```

For Oracle Linux hosts, configure `ansible_user=opc` via host/group variables; ensure the Ubuntu host uses its **verified** SSH user. Do not assume all hosts share one account. A real pipeline should use a managed credential rather than a hard-coded filesystem path.

![Inventory inspection during troubleshooting](screenshots/inventory-graph.png)

## 4. Static versus dynamic Ansible assignments

| Technique | When evaluated | Project use |
|---|---|---|
| `import_playbook` | Parse time | Compose top-level plays |
| `import_tasks` | Parse time | Common OS checks |
| `import_role` | Parse time | Reusable `common` role |
| `include_tasks` | Run time | OS/service-specific checks |
| `include_vars` | Run time | Load exercise environment variables |
| `include_role` | Run time | Select `tooling_web` or `haproxy` |

**Static example:**

```yaml
# new-dynamictask/main.yml
---
- name: Import configuration exercise
  ansible.builtin.import_playbook: configuration.yml
```

```yaml
# new-dynamictask/configuration.yml (illustrative)
---
- name: Static and dynamic checks
  hosts: all
  gather_facts: true
  tasks:
    - name: Import static OS tasks
      ansible.builtin.import_tasks: tasks/static.yml
    - name: Include dynamic service tasks
      ansible.builtin.include_tasks: tasks/dynamic.yml
```

```yaml
# new-dynamictask/static-role.yml
---
- name: Reuse common role statically
  hosts: all
  gather_facts: true
  tasks:
    - name: Run common checks
      ansible.builtin.import_role:
        name: common
```

**Dynamic example:**

```yaml
# new-dynamictask/deploy-tooling.yml (role selection excerpt)
- name: Deploy selected application role
  ansible.builtin.include_role:
    name: "{{ tooling_role }}"
```

The exercise used `tooling_role: tooling_web`, `tooling_version: main`, and environment variables loaded with `include_vars`. For the **shared production tier**, replace conflicting per-host UAT/prod variables with **one release identifier and one reviewed application configuration**. Pin deployments to a tested commit or tag, not a moving branch, for repeatability.

```bash
ansible-playbook new-dynamictask/main.yml --syntax-check
ansible-playbook new-dynamictask/static-role.yml --list-tasks
ansible-playbook new-dynamictask/static-role.yml
ansible-playbook new-dynamictask/deploy-tooling.yml --limit Web1 --check
```

## 5. Tooling application deployment (NFS-aware)

The custom `tooling_web` role verifies Oracle Linux 8, ensures `httpd` and `git`, checks out `tooling-solution` to `/opt/tooling-source`, and publishes selected files from `html/` to `/var/www/html`. **Do not publish the repository root**: it includes `tooling-db.sql`, Docker and Jenkins files.

```yaml
- name: Checkout Tooling source
  ansible.builtin.git:
    repo: "{{ tooling_repo }}"
    dest: /opt/tooling-source
    version: "{{ tooling_version }}"   # production: pinned tag or commit
    update: true
    force: false

- name: Copy a reviewed application file
  ansible.builtin.copy:
    src: /opt/tooling-source/html/index.php
    dest: /var/www/html/index.php
    remote_src: true
    mode: '0644'
```

**Production guardrails:** the deployed `functions.php` differs from Git and may contain DB credentials: **preserve it** until replaced by a secret-managed template; preserve `health.html`. Do not recursively `chown` NFS content or disable root squashing/SELinux. On Web1, SELinux was `Enforcing`, the NFS content label was `nfs_t`, and `httpd_use_nfs` was `on`. Confirm Web2's equivalent settings. Deploy shared files **once** through a controlled publisher or release directory with atomic activation; do not concurrently write the same NFS tree from both web hosts. Test rollback of both code and database migrations separately.

```bash
# Read-only checks
ansible webservers -b -m ansible.builtin.command -a 'findmnt -T /var/www/html -o TARGET,SOURCE,FSTYPE'
ansible Web1 -b -m ansible.builtin.command -a 'getenforce'
curl -I http://10.0.1.229/login.php
curl -I http://10.0.1.136/login.php
```

The source checkout eventually succeeded at commit `1755db3ce9755c3be32f41834b23422b4bf97780`. Two sample deployed file hashes (`index.php`, `style.css`) matched their checkout versions. This does **not** prove every file or DB workflow was verified.

![Successful dynamic role checkout](screenshots/dynamic-role-checkout.png)

![PHP and application inspection](screenshots/uat-http-php.png)

![Ansible publication check-mode evidence](screenshots/deployment-check-mode.png)

## 6. MySQL, NFS and community roles

- Actual DB engine: **MySQL 8.0.46** (`mysqld`), not MariaDB. NFS service is active on the same Oracle Linux 9 VM.
- Both web hosts mount `10.0.1.29:/mnt/apps` on `/var/www` (NFSv4.2). MySQL TCP 3306 was reachable from Web1; **DB login/query functionality is not yet proven**.
- `geerlingguy.mysql` **6.5.0** was installed and discovered earlier, but the role directory later disappeared. **Do not run it against the existing database until variables, backups, privileges, and changes are reviewed.**

```yaml
# requirement.yml — example; verify the role's actual version and dependencies
---
- name: geerlingguy.mysql
  version: '6.5.0'
```

```bash
ansible-galaxy role install -r requirement.yml -p roles/
ansible-galaxy role list -p roles/
ansible Web1 -m ansible.builtin.wait_for -a 'host=10.0.1.29 port=3306 timeout=5 state=started'
```

```yaml
# Demonstration only — DO NOT apply to a live DB without change review
- name: Include community MySQL role dynamically
  ansible.builtin.include_role:
    name: geerlingguy.mysql
```

## 7. HAProxy role and network validation

The Ubuntu load balancer already ran Apache on port 80, so HAProxy was installed on **8081** without disrupting Apache.

```yaml
# roles/haproxy/defaults/main.yml
---
haproxy_frontend_port: 8081
haproxy_backend_servers:
  - { name: Web1, address: 10.0.1.229, port: 80 }
  - { name: Web2, address: 10.0.1.136, port: 80 }
```

```jinja2
# roles/haproxy/templates/haproxy.cfg.j2 (relevant sections)
frontend tooling_frontend
    bind *:{{ haproxy_frontend_port }}
    mode http
    default_backend tooling_backend

backend tooling_backend
    mode http
    balance roundrobin
    option httpchk
    http-check send meth GET uri /login.php
    http-check expect status 200
{% for server in haproxy_backend_servers %}
    server {{ server.name }} {{ server.address }}:{{ server.port }} check inter 3s fall 3 rise 2
{% endfor %}
```

Role tasks use `ansible.builtin.apt` for HAProxy, `ansible.builtin.template` with `validate: '/usr/sbin/haproxy -c -f %s'`, and `ansible.builtin.service` to enable/start HAProxy; a handler reloads on config changes. The role is dynamically invoked:

```yaml
# new-dynamictask/deploy-haproxy.yml
---
- name: Configure Ubuntu HAProxy
  hosts: loadbalancer
  become: true
  tasks:
    - name: Include HAProxy role
      ansible.builtin.include_role:
        name: haproxy
```

```bash
ansible-playbook new-dynamictask/deploy-haproxy.yml --syntax-check
ansible-playbook new-dynamictask/deploy-haproxy.yml --list-hosts
ansible-playbook new-dynamictask/deploy-haproxy.yml
ansible LoadBalancer -b -m ansible.builtin.command -a 'haproxy -c -f /etc/haproxy/haproxy.cfg'
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://10.0.1.64:8081/login.php
```

**Observed:** HAProxy deployment `ok=6 changed=3 failed=0`; localhost HTTP 200; after a host-firewall adjustment, Jenkins → HAProxy HTTP 200; **20/20** test requests returned HTTP 200. Round-robin distribution **still requires a per-backend count**; successful requests alone do not prove both nodes were selected. `/login.php` is a basic HTTP check, not a complete DB health check. Verify session sharing/stickiness and use HTTPS for real users.

```bash
# Generate identifiable requests, then count on BOTH backends
for i in $(seq 1 20); do
  curl -sS -o /dev/null "http://10.0.1.64:8081/login.php?lbtest=oci2026-$i"
done
ansible webservers -b -m ansible.builtin.shell \
  -a 'grep -h "lbtest=oci2026-" /var/log/httpd/*access* 2>/dev/null | grep -c "10.0.1.64" || true'
```

Web1's virtual host writes to **`/var/log/httpd/myapp_access.log`**, not the generic `access_log`; this caused an initially misleading empty log. Use the actual configured `CustomLog` location on each server.

## 8. Troubleshooting record

| Symptom | Root cause / evidence | Resolution or status |
|---|---|---|
| `tooling_role is defined` assertion failed | Variables not loaded in nested playbook context | Explicit `include_vars` for exercise; longer term put `group_vars` beside inventory |
| Git `pathspec 'develop'` | Branch unavailable | Used existing `main`; pin a reviewed release for production |
| `tooling_web` / Galaxy role missing | Role directories absent in working tree | Recreated `tooling_web`; Galaxy role reinstall/review pending |
| `LoadBalancer` targeted as web server | `loadbalancer` nested under `[webservers:children]` | Corrected inventory; all four Ansible pings passed |
| Web2 `/login.php` HTTP 500 | `php-mysqlnd` absent; `mysqli` and `pdo_mysql` unavailable | Installed matching OL8 `php-mysqlnd`, restarted PHP-FPM; Web2 returned 200 |
| NFS files labeled `nfs_t` | Both web hosts mount `/mnt/apps` via NFS | Verified `httpd_use_nfs=on` on Web1; avoid blind relabel/chown |
| HAProxy cannot bind `:80` | Existing Ubuntu Apache listens on port 80 | Used HAProxy port 8081 |
| Jenkins → HAProxy `No route to host` | Ubuntu iptables INPUT chain rejected new traffic except SSH | Added narrow runtime ACCEPT before REJECT; Jenkins HTTP 200; **persistence pending** |
| Web1 `access_log` empty | Custom vhost logs to `myapp_access.log` | Found correct log and verified direct request |

**Firewall persistence is not complete.** Before go-live, manage a restricted rule for source `10.0.0.166/32` to TCP 8081 with the instance's supported persistent firewall mechanism, preserving OCI-provided instance-service and SSH rules. Confirm OCI NSG/security-list ingress too. Do not flush iptables, open `0.0.0.0/0`, or disable the host firewall.

## 9. Jenkins CI/CD: proposed pipeline (not yet deployed)

A production pipeline should use Jenkins credentials and explicit approvals, with these stages: checkout pinned automation revision → install pinned Galaxy dependencies → lint/syntax check → plan/diff review → UAT/staging verification → approval → single-writer shared-NFS publication → smoke tests → rollback on failure. **No evidence in this project yet confirms a running GitHub-triggered Jenkins pipeline.**

Minimal validation stage example (run in the repository's `dynamic-assignment` directory):

```groovy
pipeline {
  agent any
  stages {
    stage('Validate Ansible') {
      steps {
        dir('dynamic-assignment') {
          sh '''
            set -eu
            export ANSIBLE_CONFIG="$PWD/ansible.cfg"
            ansible-playbook new-dynamictask/deploy-tooling.yml --syntax-check
            ansible-playbook new-dynamictask/deploy-haproxy.yml --syntax-check
          '''
        }
      }
    }
  }
}
```

This example is **validation only**; it does not configure credentials, deploy applications, or publish to OCI. Use reviewed Jenkins Credentials bindings, protected branches, a controlled agent, and approvals before adding deployment stages.

## 10. Operations: verification, backup and rollback

**Before changes:** record Git commit/tag, back up the shared NFS application tree **and** MySQL independently, verify restore procedures, confirm both Apache hosts are healthy, and ensure the intended release uses one consistent DB configuration. Keep backups outside the shared serving directory and restrict access because they may contain secrets.

```bash
# Read-only health checks
ansible all -m ansible.builtin.ping
ansible webservers -b -m ansible.builtin.command -a 'systemctl is-active httpd'
ansible LoadBalancer -b -m ansible.builtin.command -a 'systemctl is-active haproxy'
ansible LoadBalancer -b -m ansible.builtin.command -a 'haproxy -c -f /etc/haproxy/haproxy.cfg'
curl -sS -o /dev/null -w '%{http_code}\n' http://10.0.1.64:8081/login.php
```

**Rollback approach (must be rehearsed):** stop further pipeline writes; remove unhealthy backend(s) from rotation if needed; restore the previous **pinned** application release through the single writer (or restore the verified NFS backup); restore configuration/secrets using the approved secret store; roll back DB migrations only with a tested migration/restore plan; recheck login, session continuity, backend health and logs. Do not use an unreviewed `git reset --hard` or restore an old DB snapshot over current data without a recovery decision.

## 11. Production go-live checklist

- [x] Ansible SSH/Python and privilege escalation on all four managed hosts
- [x] Static `import_tasks`/`import_role` and dynamic `include_tasks`/`include_role` exercises executed
- [x] Web1/Web2 PHP login endpoints respond HTTP 200
- [x] HAProxy installed and local/remote HTTP 200; 20/20 requests succeeded
- [ ] Verify request distribution to **both** backends and HAProxy role idempotency (`changed=0` on repeat)
- [ ] Persist and audit least-privilege host firewall + OCI NSG rules
- [ ] Unify UAT/prod settings for shared-NFS production tier; enforce single-writer atomic releases
- [ ] Confirm MySQL authentication, least-privilege grants, application workflows and DB backup/restore
- [ ] Validate PHP sessions across backends and failure behavior; implement TLS/HTTPS ingress
- [ ] Upgrade end-of-life PHP 7.4 after application compatibility testing
- [ ] Move secrets into Jenkins Credentials/Ansible Vault; scan Git history for exposed secrets
- [ ] Pin dependencies and releases; restore/review `geerlingguy.mysql` before use
- [ ] Add monitoring, alerting, audit logs, capacity and HA/failover tests
- [ ] Implement reviewed Jenkins pipeline with approvals and rollback; validate NFS/MySQL single points of failure

**Bottom line:** the project demonstrates functional Ansible automation and HAProxy HTTP forwarding. It is **not yet production-ready infrastructure** until the unchecked controls are implemented and tested.

