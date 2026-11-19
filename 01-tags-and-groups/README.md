# Tags and groups

Post 1 of [Tag-Based Firewall Rules](../README.md). Deploy a three-tier demo on a Supervisor namespace, watch the Kubernetes labels show up as NSX tags on VPC subnet ports, build three groups and one policy, and prove the rules.

TODO: the jonschulz.com URL for this post is not published yet. Add it to the series table in the repo README when it is live.

Lab and demo code only. Rule 40 is a default deny for the three demo groups, and rule 10 drops web-to-web. Use a lab VPC. Replace every placeholder before you apply anything. Do not commit a copy with real ids filled in. `curl -u` and `nsx/nsx-api.sh` prompt for the NSX password. Do not put the password in the `-u` argument, in a shell history, or in a file you commit.

## Files

| File | What it is |
| --- | --- |
| [`k8s/three-tier.yaml`](k8s/three-tier.yaml) | nginx Deployment (2 pods) and LoadBalancer Service, plus VirtualMachines `demo-db` and `demo-app` |
| [`nsx/tagdemo-web.json`](nsx/tagdemo-web.json) | VPC group for `security.tier\|web` |
| [`nsx/tagdemo-app.json`](nsx/tagdemo-app.json) | VPC group for `security.tier\|app` |
| [`nsx/tagdemo-db.json`](nsx/tagdemo-db.json) | VPC group for `security.tier\|db` |
| [`nsx/policy-3tier.json`](nsx/policy-3tier.json) | Policy `tagdemo-3tier` (the full five-rule body) |
| [`nsx/nsx-api.sh`](nsx/nsx-api.sh) | The same Policy API calls, with the password kept off the command line |

Labels on the workloads:

| Workload | Labels |
| --- | --- |
| nginx pods | `app=nginx`, `security.tier=web`, `security.env=dev` |
| `demo-app` | `app=demo-app`, `security.tier=app`, `security.env=dev` |
| `demo-db` | `app=demo-db`, `security.tier=db`, `security.env=dev` |

The pod labels are on the Deployment pod template. The VM labels are on the VirtualMachine object. The Supervisor copies them onto the VPC subnet port. The label key becomes the tag scope and the label value becomes the tag, written in a group condition as `scope|tag` (for example `security.tier|web`). There is no `dis:k8s:` prefix. That prefix is what Antrea adds for pods on VKS clusters.

## Placeholders

| Placeholder | Replace with |
| --- | --- |
| `<supervisor-ip>` | Supervisor API endpoint used by the VCF CLI |
| `<namespace>` | vSphere namespace |
| `<storage-class>` | storage class for the two VMs |
| `vmi-xxxx` | Ubuntu image name visible to that namespace |
| `<nsx-manager>` | NSX Manager host |
| `<api-user>` | NSX local user with the Security Engineer role |
| `<vpc-id>` | VPC id of the namespace (last element of the path below) |
| `<subnet-id>` | pod subnet when you inspect nginx ports; VM subnet when you inspect `demo-app-eth0` and `demo-db-eth0` |
| `<avi-se-datanics-group-id>` | Avi-created group in that VPC whose id ends in `DataNics` |
| `<ip-db>` | `demo-db` address, written into the app VM before that VM is applied |
| `<ip-app>`, `<ip-web-1>`, `<ip-web-2>` | addresses used only in the test commands |
| `<external-ip>` | `EXTERNAL-IP` of Service `nginx`, used only to curl the VIP |

The VCF CLI login is a vCenter SSO user. The CLI asks for it. `<api-user>` is a different account, the NSX local user.

Org and project in every Policy path below are `default`:

```bash
NSX=https://<nsx-manager>
V=/policy/api/v1/orgs/default/projects/default/vpcs/<vpc-id>
```

The script uses the same paths. From `01-tags-and-groups/nsx`:

```bash
export NSX_MANAGER=<nsx-manager>
export NSX_USER=<api-user>
export VPC_ID=<vpc-id>
# Leave NSX_PASSWORD unset. The script prompts and stores the secret in a
# mode-600 curl config file that it deletes on exit.
./nsx-api.sh --help
```

`NSX_MANAGER` may be a host or an `https://` URL. `-k` is set because the lab manager certificate is self-signed. The script prints the response body on stdout and `HTTP <code>` on stderr.

## Run order

Run the `kubectl` commands from `01-tags-and-groups/`. Run `nsx-api.sh` and the `curl -d @...json` commands from `01-tags-and-groups/nsx/`.

Tested-on versions are in the [repo README](../README.md). You need VCF 9.1.1 with vDefend Firewall, a Supervisor using NSX VPC networking, a namespace (it can be shared with VKS nodes), an Ubuntu image in a content library that namespace can see, VM class `best-effort-small`, Avi providing the LoadBalancer, plus the VCF CLI, kubectl, and curl. The lab namespace had no ResourceQuota and no LimitRange.

### 1. Create a VCF CLI context

Do this before any YAML. Basic auth logs in with a vCenter SSO user, and the CLI asks for that password:

```bash
vcf context create supervisor --endpoint https://<supervisor-ip> --insecure-skip-tls-verify --auth-type basic
vcf context list
vcf context use supervisor:<namespace>
```

Creating the context also adds a `supervisor:<namespace>` context for each vSphere namespace you can access. `vcf context use` makes it the kubectl default. `--insecure-skip-tls-verify` is for a lab with a self-signed certificate. In production, trust the vCenter root CA or replace the Supervisor certificate.

### 2. Fill in the workload manifest

In [`k8s/three-tier.yaml`](k8s/three-tier.yaml), replace `<namespace>`, `<storage-class>`, and `vmi-xxxx`. Leave `<ip-db>` until `demo-db` exists. The address is not known before that VM object is created, and cloud-init writes it once.

### 3. Apply the web tier and demo-db

The file is the post's `three-tier.yaml`: nginx Deployment, nginx Service, `demo-db`, then `demo-app`. The first apply stops before `demo-app` (everything above the third `---` line):

```bash
awk 'BEGIN{n=0} /^---$/{n++} n<3' k8s/three-tier.yaml | kubectl apply -f -
```

Expect the Deployment, the Service, and VirtualMachine `demo-db`. The nginx pods and the Service external address usually show up within a minute:

```bash
kubectl -n <namespace> get deploy nginx
kubectl -n <namespace> get svc nginx
kubectl -n <namespace> get vm demo-db
```

The VM subnet port, and the address on it, appears about 40 seconds after the VirtualMachine object is created. The guest takes longer. The first power-on of a new image waits about nine minutes while the Supervisor caches the image. A later VM on an image that is already cached took about ten minutes in the lab, including guest boot.

`status.network.primaryIP4` stays empty when VMware Tools is not running. On this image the lab sometimes saw Tools report the address only after the guest was up. Read both:

```bash
kubectl -n <namespace> get vm demo-db -o yaml
```

Use `status.network.primaryIP4` or the address under `status.network.config`. The same address is on the NSX port `demo-db-eth0` (step 5) as soon as the port exists, which is enough to fill in `<ip-db>`. You do not need the guest to be up for that.

### 4. Apply demo-app

Replace `<ip-db>` in `k8s/three-tier.yaml` with that address and no port. `/dbcheck` connects to port 5432 itself. Then apply the whole file:

```bash
kubectl apply -f k8s/three-tier.yaml
kubectl -n <namespace> get vm demo-app demo-db
```

If you recreate `demo-db`, the address changes. Put the new address in the manifest and recreate `demo-app`. Cloud-init does not pick up a later edit on an existing VM.

### 5. Find the VPC, the subnets, and the tags

The namespace annotation `nsx.vmware.com/vpc_network_config` is the VPC path. The last element is `<vpc-id>`:

```bash
kubectl get ns <namespace> \
  -o go-template='{{index .metadata.annotations "nsx.vmware.com/vpc_network_config"}}{{"\n"}}'
```

Set `VPC_ID` from that path, then list subnets. In the lab the vSphere Pod subnet name started with `pod-default` and the VM subnet name started with `vm-default`. Leave the per-cluster VKS subnets alone.

```bash
cd nsx
./nsx-api.sh subnets
```

The same call as curl, from this `nsx/` directory. `curl -u '<api-user>'` prompts for the password:

```bash
curl -k -u '<api-user>' "$NSX$V/subnets"
curl -k -u '<api-user>' "$NSX$V/subnets/<subnet-id>/ports"
```

Or `./nsx-api.sh ports <subnet-id>`.

Trimmed to the tags that matter, an nginx pod port looks like this:

```text
app                  | nginx
security.tier        | web
security.env         | dev
pod-template-hash    | <hash>
nsx-op/namespace     | <namespace>
```

Other `nsx-op/*` system tags are on every port. `demo-app-eth0` carries `security.tier|app`. `demo-db-eth0` carries `security.tier|db`.

The tags sit on the subnet port. NSX VM inventory shows `tags: null` for both VMs (`GET /api/v1/fabric/virtual-machines`), so a group of type VirtualMachine with a Tag condition is empty. The groups below use member type `VpcSubnetPort`.

### 6. Find the Avi SE data-NIC group

```bash
./nsx-api.sh groups
# curl -k -u '<api-user>' "$NSX$V/groups"
```

Use the group whose id ends in `DataNics`. That id is `<avi-se-datanics-group-id>`. Export it for the script:

```bash
export AVI_SE_DATANICS_GROUP_ID=<avi-se-datanics-group-id>
```

Rule 35 sources this group. It is an Avi-created group. The cleanup below does not delete it.

### 7. List leftover global policies

Do this before you write the VPC policy. Global policies are evaluated before VPC policies. A global allow for the same tag overrides rule 10.

```bash
./nsx-api.sh infra-policies
# curl -k -u '<api-user>' "$NSX/policy/api/v1/infra/domains/default/security-policies"
```

What to look for, and what the lab did about it, is in [Cleanup](#cleanup) and [Gotchas](#gotchas-worth-knowing).

### 8. Optional baseline, before any tagdemo rule

Run the [test commands](#prove-it) once the guests answer. Before the policy, the lab saw all of these open: web to app on 8080 (`tagdemo-app ok`), `/dbcheck` (`OK`), web to db on 5432, and web to the other web pod on 80. A timeout at this point is the guest firewall or a listener that is not up yet, not an NSX rule.

### 9. Create the three groups

Still in `nsx/`. Each file is one condition: member type `VpcSubnetPort`, key `Tag`, value `security.tier|web` (or `app`, or `db`). PATCH creates or updates. Expect HTTP 200 and an empty body. Membership showed up in about 15 seconds.

```bash
./nsx-api.sh apply-groups
```

The web call the post shows:

```bash
curl -k -u '<api-user>' -X PATCH "$NSX$V/groups/tagdemo-web" \
  -H 'Content-Type: application/json' -d @tagdemo-web.json
```

Repeat for `@tagdemo-app.json` and `@tagdemo-db.json`, or let the script do all three.

### 10. Check membership

```bash
./nsx-api.sh members
```

```bash
curl -k -u '<api-user>' "$NSX$V/groups/tagdemo-web/members/subnet-ports"
curl -k -u '<api-user>' "$NSX$V/groups/tagdemo-web/members/ip-addresses"
```

Run the same two paths for `tagdemo-app` and `tagdemo-db`. Expected:

| Group | Ports | Addresses |
| --- | --- | --- |
| `tagdemo-web` | the two nginx pod ports | `<ip-web-1>`, `<ip-web-2>` |
| `tagdemo-app` | `demo-app-eth0` | `<ip-app>` |
| `tagdemo-db` | `demo-db-eth0` | `<ip-db>` |

`members/ip-addresses` for the web group looks like:

```json
{ "results" : [ "<ip-web-1>", "<ip-web-2>" ], "result_count" : 2 }
```

Nothing from other VKS clusters that share the VPC should be in these groups. They match only the `security.tier` tag. Use `members/subnet-ports` and `members/ip-addresses`. `members/vpc-subnet-ports` and `members/segment-ports` return HTTP 500 on this build ("The URI is invalid"). `members/virtual-machines` returns an empty set, because the tags are on the port.

### 11. Create the policy

[`policy-3tier.json`](nsx/policy-3tier.json) is the full body. The post prints the header and rules 10 and 20. The file also has rules 30, 35, and 40. One PATCH sends the policy and its rules. Scope is only the three tagdemo groups. `sequence_number` on the policy is 10. `stateful` is true, `tcp_strict` is false, `logging_enabled` is true, and every rule is `logged`. Direction is `IN_OUT`. `ip_protocol` is `IPV4_IPV6`.

| Seq | Id | Action | Source | Destination | Service | Applied to |
| --- | --- | --- | --- | --- | --- | --- |
| 10 | `tagdemo-a-drop-web-web` | DROP | tagdemo-web | tagdemo-web | ANY | tagdemo-web |
| 20 | `tagdemo-b-allow-web-app-8080` | ALLOW | tagdemo-web | tagdemo-app | `/infra/services/Oracle_XMLDB_HTTP_port` (TCP 8080) | web, app |
| 30 | `tagdemo-c-allow-app-db-5432` | ALLOW | tagdemo-app | tagdemo-db | `/infra/services/PostgreSQL` (TCP 5432) | app, db |
| 35 | `tagdemo-e-allow-lb-web-80` | ALLOW | Avi SE data-NIC group | tagdemo-web | `/infra/services/HTTP` (TCP 80) | tagdemo-web |
| 40 | `tagdemo-d-default-deny` | DROP | ANY | ANY | ANY | web, app, db |

`Oracle_XMLDB_HTTP_port` is the built-in TCP 8080 service. The name is misleading. VPC rules cannot use a custom service: the lab tried a global service, a project service, and inline `service_entries`, and NSX rejected all three. Keep rule 35 in this PATCH. With rules 10, 20, 30, and 40 only, rule 40 also drops Avi service-engine traffic to the nginx pods. In the lab the demo VIP then failed 279 of 3,000 probe requests for about 30 seconds. Rule 35 restored it.

The checked-in file still contains `<vpc-id>` and `<avi-se-datanics-group-id>`. The script substitutes a temporary copy and deletes it:

```bash
export AVI_SE_DATANICS_GROUP_ID=<avi-se-datanics-group-id>
./nsx-api.sh apply-policy
```

The post's call is the same PATCH. Point `-d` at a copy in which those two placeholders are already replaced. Leave the file in git untouched:

```bash
curl -k -u '<api-user>' -X PATCH "$NSX$V/security-policies/tagdemo-3tier" \
  -H 'Content-Type: application/json' -d @policy-3tier.local.json
```

Expect HTTP 200 and an empty body. Read it back with `./nsx-api.sh policy` and `./nsx-api.sh rules`. A plain GET already includes `rules`. `?include_rules=true` returns HTTP 400 on this build.

NSX assigns a numeric `rule_id` per rule. Those numbers differ per environment. The statistics calls below print them.

## Prove it

Run these from the jump box. `kubectl exec` runs each one in an nginx pod. A drop is silent, so a blocked test times out. It does not refuse the connection.

`<ip-web-2>` is the other web pod. `<ip-app>` and `<ip-db>` are the group member addresses from step 10.

```bash
kubectl -n <namespace> exec deploy/nginx -- wget -qO- -T4 http://<ip-app>:8080/
tagdemo-app ok

kubectl -n <namespace> exec deploy/nginx -- wget -qO- -T6 http://<ip-app>:8080/dbcheck
OK
```

`/dbcheck` opens a TCP connection from `demo-app` to `<ip-db>:5432` with a 2 second timeout.

```bash
kubectl -n <namespace> exec deploy/nginx -- nc -zv -w3 <ip-db> 5432
nc: <ip-db> (<ip-db>:5432): Operation timed out

kubectl -n <namespace> exec deploy/nginx -- wget -qO- -T4 http://<ip-web-2>/
wget: download timed out

kubectl -n <namespace> exec deploy/nginx -- nc -zv -w3 <ip-app> 22
kubectl -n <namespace> exec deploy/nginx -- nc -zv -w3 <ip-db> 22
```

| Test | Expected |
| --- | --- |
| web to app, TCP 8080 | allowed (`tagdemo-app ok`) |
| app to db, TCP 5432, via `/dbcheck` | allowed (`OK`) |
| web to db, TCP 5432 | blocked (timeout) |
| web to web, TCP 80 | blocked (timeout) |
| web to app or db, TCP 22 | blocked (timeout) |
| demo LoadBalancer VIP | HTTP 200 |

```bash
kubectl -n <namespace> get svc nginx
curl -fsS http://<external-ip>/
```

In the lab, a second pre-existing VIP in the same environment was probed at the same time and also returned 200. That was the check that a policy scoped to the three groups left other load balancers alone.

The realized-state status call the lab made for the VPC returned HTTP 500. Use these traffic tests as the proof that the rules are realized.

### Hit counters

Counters lag. Rule 10 in the lab read 0 for several minutes (about four or five) after the first blocked attempts, then moved. Read them, wait, and read again. Not every retransmitted SYN is counted. Rules 35 and 40 also count other traffic (load-balancer health checks and probes on 35, DNS and NTP and anything else the allow rules do not match on 40), so those two numbers are noisy.

```bash
./nsx-api.sh stats
# curl -k -u '<api-user>' "$NSX$V/security-policies/tagdemo-3tier/statistics"
```

Optional, if you have `jq`:

```bash
./nsx-api.sh stats | jq -r '.results[0].statistics.results[] | "rule_id=\(.internal_rule_id) hit=\(.hit_count) pkts=\(.packet_count) bytes=\(.byte_count) sessions=\(.session_count)"'
```

One rule (the numbers are under `.results[0].statistics`):

```bash
./nsx-api.sh rule-stats tagdemo-a-drop-web-web
```

Once the lab counters had refreshed, they matched the table from the post. Your counts will differ.

| Rule | Action | Hits | Packets | Sessions |
| --- | --- | --- | --- | --- |
| 10 | DROP | 15 | 15 | 0 |
| 20 | ALLOW | 8 | 80 | 8 |
| 30 | ALLOW | 4 | 36 | 4 |
| 35 | ALLOW | 2287 | 37079 | 2279 |
| 40 | DROP | 2595 | 2604 | 3 |

Rule 10 showed 15 packets for about 27 blocked attempts.

## Cloud-init

Both listeners are in [`k8s/three-tier.yaml`](k8s/three-tier.yaml), under `bootstrap.cloudInit.cloudConfig`.

`demo-db` listens on TCP 5432 on all interfaces, writes `tagdemo-db ok`, and closes. `demo-app` listens on TCP 8080 on all interfaces. `GET /` returns `tagdemo-app ok`. `GET /dbcheck` connects to the address in `/etc/tagdemo/db_host` on port 5432 and returns `OK` or `FAIL`.

The `iptables`, `ip6tables`, and `ufw` lines are there because the Ubuntu 24.04 VKS node image in the lab ships with an INPUT policy of DROP. It allows a few ports (22, 6443, 10250, 30000–32767, and so on) and drops the rest. With listeners only, 8080 and 5432 timed out even when no NSX rule was in the way. Each `runcmd` inserts an accept for that VM's port. On an image with no host firewall the same lines are harmless (`|| true`).

The three `ssh` lines only make sure host keys exist (`ssh-keygen -A`) and that sshd is enabled. There is no user account, password, or key in the cloud-init. Drop those three lines if you do not want SSH.

## Gotchas worth knowing

- **Tags are on the subnet port.** Group on `VpcSubnetPort`. A VirtualMachine tag group does not match these VMs.
- **Scope by tag.** The lab namespace also held VKS cluster nodes, on the same VPC. A namespace-wide or VPC-wide rule would have hit them. The policy scope is the three tagdemo groups.
- **Default deny needs a path for the load balancer.** That path is rule 35, sourced from the Avi group whose id ends in `DataNics`.
- **VPC rules use built-in services by path.** `/infra/services/Oracle_XMLDB_HTTP_port` (TCP 8080), `/infra/services/PostgreSQL` (TCP 5432), `/infra/services/HTTP` (TCP 80). The lab's custom services `/infra/services/tagdemo-tcp-8080` and `/infra/services/tagdemo-tcp-5432` were created, could not be referenced from the VPC rule, and were deleted. This folder does not create them. A search for `query=tagdemo-tcp` returns nothing, because the search index splits on hyphens. `resource_type:Service AND display_name:tagdemo*` is the query that finds them.
- **Hit counters lag** by several minutes. An early read of all zeros is normal.
- **A leftover global policy can hide rule 10.** The lab's was named `legacy-k8s-policy`. It had one allow rule from `legacy web group` to itself, and that group matched `security.tier|web` on a segment port. Global policy wins over this VPC policy. See [Cleanup](#cleanup).
- **`kubectl get virtualmachineclassbindings`** uses the deprecated v1alpha1 API and returned nothing in the lab. `best-effort-small` was already bound for other VMs in the namespace, and a server dry-run accepted it.
- **The image name in an older lab file was not on this Supervisor.** Only VKS node images were in the namespace library. Use an Ubuntu image that `kubectl get vmi,cvmi` actually lists, and keep the guest-firewall lines unless you know the image does not drop the listener ports.

## Cleanup

Deletes the objects this folder creates. It does not delete the Avi `DataNics` group.

From `nsx/`, the script asks you to type `tagdemo-3tier` before it deletes. Set `CONFIRM=tagdemo-3tier` only when you intend the delete. Policy first, then the three groups. A 404 on a second run is treated as already gone.

```bash
./nsx-api.sh delete
```

The same calls:

```bash
curl -k -u '<api-user>' -X DELETE "$NSX$V/security-policies/tagdemo-3tier"
curl -k -u '<api-user>' -X DELETE "$NSX$V/groups/tagdemo-web"
curl -k -u '<api-user>' -X DELETE "$NSX$V/groups/tagdemo-app"
curl -k -u '<api-user>' -X DELETE "$NSX$V/groups/tagdemo-db"
```

Then the workloads, from `01-tags-and-groups/`:

```bash
kubectl delete -f k8s/three-tier.yaml
```

### Leftover global policy

Only if you own the policy, you have a backup, and you mean to remove it. `./nsx-api.sh delete` does not do this.

`./nsx-api.sh infra-policies` lists policies under `/infra/domains/default`. The lab's leftover was named `legacy-k8s-policy`. Take the id from that GET. This write-up uses the name `legacy-k8s-policy` in the path below, so confirm the id before you delete. A plain GET of the policy includes its rules. Also GET `.../security-policies/<id>/rules` and save both. Restore is a PATCH of that saved body. The lab left the group (`legacy web group`) in place and deleted the policy.

```bash
# curl -k -u '<api-user>' -X DELETE \
#   "$NSX/policy/api/v1/infra/domains/default/security-policies/legacy-k8s-policy"
```

After that delete in the lab, web-to-web started timing out on rule 10 about a minute later.
