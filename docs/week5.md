# Week 5 — Ansible UAT Automation
## LinkTracker: Automated Environment Setup with Ansible

**Project:** LinkTracker (URL shortener with click analytics)  
**Repo:** `linktracker-infra` → `ansible/`  
**Ansible version:** core 2.21.1  
**Scope:** Dev/UAT environment automation only (prod uses Terraform + Helm directly)

---

## 1. Why We Implemented Ansible (and Why NOT for Prod)

### The problem Ansible solves

Before Week 5, spinning up the UAT environment (a local Kind cluster with the full LinkTracker stack) required running a sequence of manual commands every time:

```bash
kind create cluster --name linktracker-uat --config k8s/kind-cluster.yaml
kubectl apply -f https://raw.githubusercontent.com/.../calico.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl apply -f https://raw.githubusercontent.com/.../ingress-nginx/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=available deployment/ingress-nginx-controller --timeout=300s
helm install linktracker ./helm/linktracker -f values.yaml -f values-uat.yaml -n linktracker-uat
kubectl wait --for=condition=Ready pods --all -n linktracker-uat --timeout=300s
curl http://localhost:9080/api/health
```

This is fragile, not repeatable, and undocumented as executable code. A new team member or a CI runner would need to follow a README and manually run each command in the right order, with no guarantee they'd get identical results.

Ansible turns this into a single command:

```bash
ansible-playbook setup-uat.yml --ask-become-pass
```

### Why Ansible specifically (vs. a bash script)

A bash script could run the same commands — but it would have no idempotency. Running it twice would try to create an already-existing Kind cluster, re-install packages that are already present, and attempt a `helm install` on a release that already exists. Ansible's built-in idempotency model means every task checks whether work is actually needed before doing it. On a machine where everything is already set up, `changed=0` — no side effects.

### Why Ansible is NOT used for prod

This is a deliberate architectural decision, not an oversight:

| Environment | Tooling | Reason |
|---|---|---|
| **Prod (GKE)** | Terraform + Helm | Everything is API-driven and declarative. Terraform provisions infra; Helm deploys the app. Ansible would add a third layer with no benefit — it would just call Helm commands that Helm already handles declaratively. |
| **UAT/Dev (Kind)** | Ansible | Local environment setup is imperative and environment-specific: installing tools, creating local clusters, wiring up CNI and ingress. Ansible is built exactly for this class of work. |

The principle: **right tool for each layer**, not Ansible everywhere because it exists.

---

## 2. How We Implemented Ansible

### Project structure

```
ansible/
├── ansible.cfg                          # Project-level config
├── setup-uat.yml                        # Full UAT setup (one command)
├── teardown-uat.yml                     # Full UAT teardown (one command)
├── inventory/
│   ├── localhost.yml                    # Inventory — runs on local machine
│   └── group_vars/
│       └── all.yml                      # Shared variables (versions, paths, names)
└── roles/
    ├── common/
    │   └── tasks/main.yml               # Install Docker, kubectl, helm, kind
    ├── kind_cluster/
    │   ├── tasks/main.yml               # Create Kind cluster, export kubeconfig
    │   └── files/kind-cluster.yaml      # Kind cluster config (1 control-plane + 2 workers)
    ├── ingress/
    │   └── tasks/main.yml               # Install ingress-nginx, wait for controller
    └── linktracker/
        └── tasks/main.yml               # Helm deploy + pod wait + smoke test
```

### `ansible.cfg`

```ini
[defaults]
inventory = inventory/localhost.yml
roles_path = roles
host_key_checking = False
stdout_callback = default
result_format = yaml
```

`host_key_checking = False` is set because we're running against localhost — SSH host key verification is irrelevant and would cause spurious prompts.

### Inventory (`inventory/localhost.yml`)

```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
      ansible_python_interpreter: /usr/bin/python3
```

`ansible_connection: local` tells Ansible not to SSH anywhere — it runs all tasks directly on the local machine. This is the correct inventory model for local environment automation.

### Group variables (`inventory/group_vars/all.yml`)

```yaml
# Kind Cluster
kind_cluster_name: linktracker-uat
kind_config: "{{ lookup('env', 'HOME') }}/Documents/linktracker/k8s/kind-cluster.yaml"
kind_kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/config"

# Helm
helm_release_name: linktracker
helm_chart_path: "{{ lookup('env', 'HOME') }}/Documents/linktracker-infra/helm/linktracker"
helm_values_base: "{{ helm_chart_path }}/values.yaml"
helm_values_uat: "{{ helm_chart_path }}/values-uat.yaml"
helm_namespace: linktracker-uat

# Tool versions
kubectl_version: "v1.36.2"
helm_version: "v3.17.0"
kind_version: "v0.29.0"

# Ingress
ingress_namespace: ingress-nginx
ingress_manifest: https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Python
ansible_python_interpreter: /usr/bin/python3
```

Centralizing versions here means upgrading kubectl/helm/kind requires changing one line, not hunting through multiple role files.

### Role: `common`

Installs Docker, kubectl, helm, and kind — **only if not already present**. Every tool check follows the same idempotency pattern:

```yaml
- name: Check if Docker is installed
  command: docker --version
  register: docker_check
  ignore_errors: true
  changed_when: false

- name: Install Docker and configure group
  when: docker_check.rc != 0
  block:
    - name: Install Docker
      become: true
      apt:
        name: docker.io
        state: present
        update_cache: true

    - name: Add current user to docker group
      become: true
      user:
        name: "{{ ansible_facts.user_id }}"
        groups: docker
        append: true

    - name: Start and enable Docker service
      become: true
      systemd:
        name: docker
        state: started
        enabled: true
```

The entire install block is wrapped in `when: docker_check.rc != 0` — if Docker is already installed, the block is skipped entirely, including the `become: true` tasks that would otherwise prompt for a sudo password unnecessarily.

The same pattern applies to kubectl, helm, and kind — download + install only if the version check command fails.

### Role: `kind_cluster`

```yaml
- name: Check if Kind cluster already exists
  command: kind get clusters
  register: kind_clusters
  changed_when: false

- name: Create Kind cluster
  command: >
    kind create cluster
    --name {{ kind_cluster_name }}
    --config {{ kind_config }}
  when: kind_cluster_name not in kind_clusters.stdout

- name: Export Kind kubeconfig
  command: kind export kubeconfig --name {{ kind_cluster_name }}
  changed_when: false

- name: Switch kubectl context to Kind cluster
  command: kubectl config use-context kind-{{ kind_cluster_name }}
  changed_when: false

- name: Wait for nodes to become Ready
  command: kubectl wait --for=condition=Ready nodes --all --timeout=180s
  register: wait_result
  retries: 3
  delay: 10
  until: wait_result.rc == 0
  changed_when: false
```

The Kind cluster config (`kind-cluster.yaml`) is stored in `roles/kind_cluster/files/` and defines:
- 1 control-plane node with `ingress-ready=true` label and port mappings (80→9080, 443→9443)
- 2 worker nodes
- Calico CNI (`disableDefaultCNI: true`) with `podSubnet: 10.226.0.0/16`

### Role: `ingress`

```yaml
- name: Check if ingress-nginx namespace exists
  command: kubectl get namespace {{ ingress_namespace }}
  register: ingress_ns
  failed_when: false
  changed_when: false

- name: Install ingress-nginx
  command: kubectl apply -f {{ ingress_manifest }}
  when: ingress_ns.rc != 0

- name: Wait for ingress controller deployment
  command: >
    kubectl wait
    --namespace {{ ingress_namespace }}
    --for=condition=available
    deployment/ingress-nginx-controller
    --timeout=300s
  changed_when: false
```

### Role: `linktracker`

```yaml
- name: Ensure application namespace exists
  kubernetes.core.k8s:
    api_version: v1
    kind: Namespace
    name: "{{ helm_namespace }}"
    state: present

- name: Deploy or upgrade LinkTracker Helm release
  kubernetes.core.helm:
    release_name: "{{ helm_release_name }}"
    chart_ref: "{{ helm_chart_path }}"
    release_namespace: "{{ helm_namespace }}"
    create_namespace: true
    values_files:
      - "{{ helm_values_base }}"
      - "{{ helm_values_uat }}"
    wait: true
    timeout: "600s"
    state: present

- name: Wait for all pods to be ready
  command: >
    kubectl wait --for=condition=Ready pods
    --all -n {{ helm_namespace }}
    --timeout=300s
  changed_when: false

- name: Smoke test — backend health check
  uri:
    url: "http://localhost:9080/api/health"
    method: GET
    status_code: 200
    timeout: 10
  register: health_check
  retries: 5
  delay: 10
  until: health_check.status == 200

- name: Show smoke test result
  debug:
    msg: >
      Smoke test {{ 'PASSED ✅' if health_check.status == 200
      else 'FAILED ❌ — check ingress and backend logs' }}
```

The `kubernetes.core.helm` module uses `helm upgrade --install` internally, meaning it handles both first-time installs and updates with a single task. Combined with the `helm-diff` plugin (see Issue 4 below), it becomes fully idempotent.

### `setup-uat.yml`

```yaml
---
- hosts: localhost
  gather_facts: true

  roles:
    - common
    - kind_cluster
    - ingress
    - linktracker
```

Note: no `become: true` at the playbook level. Individual tasks that need sudo have `become: true` applied directly — this prevents all tasks from running as root, which would create files owned by root in the wrong home directory paths.

### `teardown-uat.yml`

```yaml
---
- hosts: localhost
  gather_facts: false

  tasks:
    - name: Uninstall LinkTracker Helm release
      kubernetes.core.helm:
        release_name: "{{ helm_release_name }}"
        release_namespace: "{{ helm_namespace }}"
        state: absent
      ignore_errors: true

    - name: Delete linktracker-uat namespace
      kubernetes.core.k8s:
        api_version: v1
        kind: Namespace
        name: "{{ helm_namespace }}"
        state: absent
      ignore_errors: true

    - name: Delete Kind cluster
      command: kind delete cluster --name {{ kind_cluster_name }}
      register: kind_delete
      changed_when: kind_delete.rc == 0
      ignore_errors: true

    - name: Confirm cluster deleted
      command: kind get clusters
      register: remaining_clusters
      changed_when: false

    - name: Show remaining clusters
      debug:
        msg: "Remaining Kind clusters: {{ remaining_clusters.stdout | default('none') }}"
```

---

## 3. Issues Encountered, Root Causes, and Fixes

### Issue 1 — `sudo: a password is required` during `--check` mode

**Symptom:**
```
TASK [common : Add current user to docker group]
fatal: [localhost]: FAILED! => {"msg": "Task failed: Premature end of stream
waiting for become success.\n>>> Standard Error\nsudo: a password is required"}
```

**Root cause:**  
The `Add current user to docker group` task had `become: true` but was placed **outside** the Docker install block, meaning it ran unconditionally on every playbook execution — even when Docker was already installed. In `--check` mode, Ansible cannot prompt for sudo interactively, causing it to fail.

Additionally, `--check` mode was run without `--ask-become-pass`, so Ansible had no way to provide the sudo password.

**Fix:**  
Moved the Docker group and systemd tasks **inside** the `when: docker_check.rc != 0` block, so they only run when Docker actually needs to be installed:

```yaml
- name: Install Docker and configure group
  when: docker_check.rc != 0
  block:
    - name: Install Docker
      become: true
      apt: ...

    - name: Add current user to docker group
      become: true
      user: ...

    - name: Start and enable Docker service
      become: true
      systemd: ...
```

Also added a separate always-running task just to ensure Docker is started (without triggering group changes):

```yaml
- name: Ensure Docker service is running
  become: true
  systemd:
    name: docker
    state: started
  changed_when: false
```

For `--check` mode, the correct command is:
```bash
ansible-playbook setup-uat.yml --check --diff --ask-become-pass
```

---

### Issue 2 — `kind_config` variable undefined

**Symptom:**
```
TASK [kind_cluster : Create Kind cluster]
fatal: [localhost]: FAILED! => {"msg": "The task includes an option with an
undefined variable. 'kind_config' is undefined"}
```

**Root cause:**  
The `kind_cluster` role's task referenced `{{ kind_config }}` in the `kind create cluster` command, but this variable was never defined in `group_vars/all.yml`. The variable `kind_kubeconfig` existed (pointing at the wrong path anyway — see Issue 3), but `kind_config` (the path to the Kind cluster config YAML) was missing entirely.

**Fix:**  
Added `kind_config` to `inventory/group_vars/all.yml`:

```yaml
kind_config: "{{ lookup('env', 'HOME') }}/Documents/linktracker/k8s/kind-cluster.yaml"
```

Also copied the Kind cluster config into the role's `files/` directory as a self-contained copy, so the role is portable:

```bash
cp ~/Documents/linktracker/k8s/kind-cluster.yaml \
   ansible/roles/kind_cluster/files/kind-cluster.yaml
```

---

### Issue 3 — `kind_kubeconfig` variable pointed at wrong path

**Symptom:**  
No direct error, but the variable was semantically wrong and misleading:

```yaml
# Original (wrong) — points at Kind cluster CONFIG, not kubeconfig
kind_kubeconfig: "{{ lookup('env', 'HOME') }}/Documents/linktracker/k8s/kind-cluster.yaml"
```

**Root cause:**  
`kind-cluster.yaml` is the **cluster creation config** (node layout, port mappings, CNI settings). The **kubeconfig** (what `kubectl` uses to connect to the cluster) lives at `~/.kube/config` and is written there automatically by `kind export kubeconfig`. These are two completely different files. The variable name `kind_kubeconfig` suggested the latter but pointed at the former.

The variable was also never referenced in any role task, making it dead and misleading.

**Fix:**  
Corrected the variable to point at the actual kubeconfig location:

```yaml
kind_kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/config"
```

The `kind_cluster` role already runs `kind export kubeconfig --name {{ kind_cluster_name }}` which writes to this path automatically — so the variable is now consistent with actual behavior even if not actively used.

---

### Issue 4 — Helm task reporting `changed` on every run despite no real changes

**Symptom:**
```
TASK [linktracker : Deploy or upgrade LinkTracker Helm release]
[WARNING]: The default idempotency check can fail to report changes in certain
cases. Install helm diff >= 3.4.1 for better results.
changed: [localhost]
```

Even on the second run with nothing changed, the task showed `changed=1` and Helm created a new revision (revision 2, 3, 4...) with identical content.

**Root cause:**  
This is a known limitation of the `kubernetes.core.helm` Ansible module. Without the `helm-diff` plugin, the module has no way to compare the currently deployed manifests against the newly rendered ones. So it calls `helm upgrade --install` unconditionally on every run, which Helm always counts as a new revision — even if the rendered YAML is byte-for-byte identical to what's already deployed.

This is not a bug in the playbook — it's a limitation of Helm itself (Helm doesn't diff before upgrading) and of the Ansible module without the diff plugin.

**Fix:**  
Installed the `helm-diff` plugin:

```bash
helm plugin install https://github.com/databus23/helm-diff
```

With `helm-diff` installed, the `kubernetes.core.helm` module can now:
1. Render the chart with the given values
2. Diff the rendered output against the currently deployed release
3. Only call `helm upgrade` if there are actual differences

Second run after installing `helm-diff`:
```
TASK [linktracker : Deploy or upgrade LinkTracker Helm release]
ok: [localhost]

PLAY RECAP
localhost: ok=29  changed=0  unreachable=0  failed=0  skipped=11
```

`changed=0` — fully idempotent.

---

### Issue 5 — `become: true` at playbook level causing root-owned files

**Symptom:**  
Setting `become: true` at the top of `setup-uat.yml` caused all tasks — including `kind export kubeconfig`, `kubectl config use-context`, and Helm commands — to run as root. This created `~/.kube/config` owned by root, which then caused permission errors when running `kubectl` as a normal user after the playbook finished.

**Root cause:**  
`become: true` at the playbook level is a blunt instrument — it escalates all tasks without discrimination. Most tasks in this playbook (kubectl, helm, kind, kubernetes.core modules) should run as the normal user. Only `apt install` and `systemd` tasks genuinely need root.

**Fix:**  
Removed `become: true` from the playbook level entirely:

```yaml
# Before (wrong)
- hosts: localhost
  gather_facts: true
  become: true      ← removed
  roles: ...

# After (correct)
- hosts: localhost
  gather_facts: true
  roles: ...
```

`become: true` is now only applied at the individual task level, on the specific tasks that genuinely need it (`apt`, `user`, `systemd`, `copy` to `/usr/local/bin`).

---

### Issue 6 — `ansible_python_interpreter` pointing at non-existent venv

**Symptom:**
```
fatal: [localhost]: FAILED! => {"msg": "Failed to import the required Python
library (kubernetes) on the remote machine..."}
```

**Root cause:**  
`group_vars/all.yml` had:
```yaml
ansible_python_interpreter: "{{ lookup('env', 'HOME') }}/Documents/linktracker-infra/.venv/bin/python"
```

This `.venv` didn't exist on the machine. The `kubernetes.core.helm` and `kubernetes.core.k8s` modules are Python-based and need a Python interpreter with the `kubernetes` library installed. Pointing at a non-existent venv meant the modules couldn't find any Python at all.

**Fix:**  
Changed to the system Python:
```yaml
ansible_python_interpreter: /usr/bin/python3
```

Also updated `inventory/localhost.yml` (which had a separate typo):
```yaml
# Before (typo — key is silently ignored by Ansible)
ansible_python_interpretor: /usr/bin/python3

# After (correct spelling)
ansible_python_interpreter: /usr/bin/python3
```

The typo (`interpretor` vs `interpreter`) caused the setting to be silently ignored — Ansible accepted the unknown key without error but used its own default Python, which may or may not have the `kubernetes` library available.

---

## 4. Final Verified State

### Play recap — first run (fresh setup)
```
PLAY RECAP
localhost: ok=24  changed=8  unreachable=0  failed=0  skipped=4
```

### Play recap — second run (idempotency verified)
```
PLAY RECAP
localhost: ok=29  changed=0  unreachable=0  failed=0  skipped=11
```

`changed=0` on the second run confirms full idempotency across all 4 roles.

### Smoke test output
```
TASK [linktracker : Show smoke test result]
ok: [localhost] => {
    "msg": "Smoke test PASSED ✅"
}
```

### Pod status verified by playbook
```
NAME                        READY   STATUS    RESTARTS   AGE
backend-5494cd8cf8-4v4gt    1/1     Running   0          2m
backend-5494cd8cf8-66wrr    1/1     Running   0          2m
frontend-885b589fb-pngjv    1/1     Running   0          2m
postgres-575f9b469f-7qlmw   1/1     Running   0          2m
redis-645655768c-kpnzg      1/1     Running   0          2m
worker-7d86496c44-6l9qx     1/1     Running   0          2m
```

---

## 5. Deployment Commands Reference

```bash
# Setup full UAT environment
cd ~/Documents/linktracker-infra/ansible
ansible-playbook setup-uat.yml --ask-become-pass

# Teardown UAT environment
ansible-playbook teardown-uat.yml

# Dry run (check what would change without executing)
ansible-playbook setup-uat.yml --check --diff --ask-become-pass

# Syntax check
ansible-playbook --syntax-check setup-uat.yml
```

---

## 6. Key Learnings

| Topic | Learning |
|---|---|
| Ansible scope | Ansible is ideal for imperative, local environment setup (installing tools, creating Kind clusters). For API-driven cloud infra already handled by Terraform, it adds no value and should not be used. |
| Idempotency | Every task should be safe to run twice. Use `register` + `when` to skip tasks that are already complete. Never assume a task is "safe to re-run" without testing it. |
| `become: true` scope | Apply `become: true` at the task level, never at the playbook level. Blanket root escalation breaks tool configs that write to user home directories (kubeconfig, helm cache, etc.). |
| `helm-diff` plugin | The `kubernetes.core.helm` module cannot detect real changes without `helm-diff`. Without it, every run creates a new Helm revision even when nothing changed. Install it as part of your standard toolchain. |
| Variable naming | Be precise with variable names — `kind_config` (cluster creation config) vs `kind_kubeconfig` (connection credentials) are completely different files. A wrong variable silently works until it doesn't. |
| Typos in Ansible | Ansible silently ignores unknown YAML keys in inventory (e.g., `ansible_python_interpretor`). Always verify your settings are actually being applied, not just accepted without error. |
| `changed_when: false` | Use this on read-only tasks (`command: kubectl get ...`, `command: kind get clusters`) to prevent them from falsely reporting changes and cluttering your play recap. |
