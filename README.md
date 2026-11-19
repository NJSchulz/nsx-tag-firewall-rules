# Tag-Based Firewall Rules

Companion code for Jon Schulz's [jonschulz.com](https://jonschulz.com) series on label-driven NSX firewall rules for vSphere Pods and VM Service VMs. The labs run on a VCF 9 Supervisor in VPC mode: Kubernetes labels become NSX tags, and those tags select VPC east-west firewall rules.

This is lab and demo code. Hosts, ids, addresses, and usernames in the manifests are placeholders. Nothing here should be pointed at a production VPC as-is. The post 1 policy includes a default deny scoped to the three demo groups. Credentials are not stored in this repo. The API script reads them from the environment or a prompt.

## Posts

| | Post | Code | Write-up |
| --- | --- | --- | --- |
| 1 | Tags and groups | [`01-tags-and-groups/`](01-tags-and-groups/) | TODO: jonschulz.com post URL is not published yet |
| 2 | Tags as code | [`02-tags-as-code/`](02-tags-as-code/) (coming soon) | |
| 3 | Pod labels | [`03-pod-labels/`](03-pod-labels/) (coming soon) | |

Post 1 deploys a three-tier demo, watches the labels become NSX tags, builds three tag-based VPC groups and one five-rule policy, and proves it with traffic tests and hit counts. The long cloud-init and the full JSON are in that folder.

The next post, Tags as code, rebuilds the same groups and policy with the NSX Policy API and Terraform. After that, the series brings VKS clusters in with Antrea, and then mixes VMs and pods under one policy.

## Tested on

Versions from the post 1 lab (VCF 9.1.1 is the release the post targets; NSX reported 9.1.1):

| Component | Version |
| --- | --- |
| VCF | 9.1.1, vDefend Firewall, Supervisor using NSX VPC networking |
| NSX | 9.1.1 (`GET /api/v1/node/version`) |
| Supervisor Kubernetes API | v1.35.8+vmware.2 |
| kubectl client | v1.35.10 |
| VM Operator | v1alpha1 through v1alpha5 served; manifests use `vmoperator.vmware.com/v1alpha5` (v1alpha1 is deprecated) |
| VM class | `best-effort-small` (2 CPU, 4 GiB) |
| VM image | Ubuntu 24.04 content-library image, referenced as `vmi-xxxx`. The lab copy was a VKS node image (hardware version 21, EFI, 20 GiB disk) with a default-drop guest firewall |
| Web image | `nginx:1.25-alpine` |
| Load balancer | Avi |

The lab namespace had no ResourceQuota and no LimitRange. Org and project in the Policy API paths are `default`.

## Layout

```
01-tags-and-groups/          post 1, complete
  README.md                  run order, tests, cleanup
  k8s/three-tier.yaml        nginx Deployment and LoadBalancer Service,
                             demo-db and demo-app VirtualMachines
  nsx/tagdemo-web.json       VPC group, security.tier|web
  nsx/tagdemo-app.json       VPC group, security.tier|app
  nsx/tagdemo-db.json        VPC group, security.tier|db
  nsx/policy-3tier.json      policy tagdemo-3tier, rules 10, 20, 30, 35, 40
  nsx/nsx-api.sh             curl wrapper for the Policy API calls
02-tags-as-code/             placeholder
03-pod-labels/               placeholder
```

The cloud-init the post points at is `bootstrap.cloudInit.cloudConfig` on `demo-db` and `demo-app`. VM Service takes it inline, so it lives in `k8s/three-tier.yaml` rather than in a second copy. `nsx/policy-3tier.json` is the full policy body. The post shows that body trimmed to the header and the first two rules.

## License

MIT. Copyright Jon Schulz. See [LICENSE](LICENSE).
