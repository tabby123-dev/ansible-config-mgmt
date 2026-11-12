# Ansible Dynamic Roles and HAProxy 


Automate a PHP Tooling application  using **static Ansible imports**, **dynamic task/role inclusion**, a Galaxy community role, shared NFS storage and HAProxy. OCI instances were provisioned before the exercise; the work focused on configuration and deployment.


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

### Web1 and Web2 mount the **same** export at `/var/www`, so `/var/www/html` is shared.

## Repository layout

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
## Confirm the prerequisite are installed and web servers reachable.

```bash
cd /home/opc/ansible-config-mgmt/dynamic-assignment
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
ansible --version
ansible-inventory --graph
ansible webservers --list-hosts  
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

[webservers:children]`:

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

## Static versus dynamic Ansible assignments

| Technique | When evaluated | Project use |
|---|---|---|
| `import_playbook` | Parse time | Compose top-level plays |
| `import_tasks` | Parse time | Common OS checks |
| `import_role` | Parse time | Reusable `common` role |
| `include_tasks` | Run time | OS/service-specific checks |
| `include_vars` | Run time | Load exercise environment variables |
| `include_role` | Run time | Select `tooling_web` or `haproxy` |

**Static Role:**

```yaml
# new-dynamictask/main.yml
---
- name: Import configuration exercise
  ansible.builtin.import_playbook: configuration.yml
```

```yaml
# new-dynamictask/configuration.yml 
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

**Dynamic Role**

```yaml
# new-dynamictask/deploy-tooling.yml 
- name: Deploy selected application role
  ansible.builtin.include_role:
    name: "{{ tooling_role }}"
```

The exercise used `tooling_role: tooling_web`, `tooling_version: main`, and environment variables loaded with `include_vars`.

```bash
ansible-playbook new-dynamictask/main.yml --syntax-check
ansible-playbook new-dynamictask/static-role.yml --list-tasks
ansible-playbook new-dynamictask/static-role.yml
ansible-playbook new-dynamictask/deploy-tooling.yml --limit Web1 --check
```

## Tooling application deployment (NFS-aware)

The custom `tooling_web` role verifies Oracle Linux 8, ensures `httpd` and `git`, checks out `tooling-solution` to `/opt/tooling-source`, and publishes selected files from `html/` to `/var/www/html`.
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

![Successful dynamic role checkout](screenshots/main.jpeg)

![PHP and application inspection](screenshots/php.jpeg)


## 6. MySQL, NFS and community roles

- Actual DB engine: **MySQL 8.0.46** (`mysqld`). NFS service is active on the same Oracle Linux 9 VM.
- Both web hosts mount `10.0.1.29:/mnt/apps` on `/var/www` (NFSv4.2). MySQL TCP 3306 was reachable from Web1;
- `geerlingguy.mysql` **6.5.0** was installed and discovered.

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

## HAProxy role and network validation

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



```bash
# Read-only health checks
ansible all -m ansible.builtin.ping
ansible webservers -b -m ansible.builtin.command -a 'systemctl is-active httpd'
ansible LoadBalancer -b -m ansible.builtin.command -a 'systemctl is-active haproxy'
ansible LoadBalancer -b -m ansible.builtin.command -a 'haproxy -c -f /etc/haproxy/haproxy.cfg'
curl -sS -o /dev/null -w '%{http_code}\n' http://10.0.1.64:8081/login.php
```


   





