# Private Cloud Actions Architecture

This document records the current private-cloud controller structure and the
local validation rule for future changes.

## Controller DAG

```mermaid
flowchart TD
  dispatch["workflow_dispatch\noperation: apply|destroy\nopenstack_lifecycle: tenant-stack-only|full-openstack\nvalidate_gpu: boolean"]

  dispatch --> op_apply{"operation == apply"}
  dispatch --> op_destroy{"operation == destroy"}

  op_destroy --> destroy["Destroy\n./ha destroy\ncleanup_devstack = full-openstack"]

  op_apply --> devstack["DevStack\n./ha apply --phases devstack\nrun_mode = apply|reinstall"]
  devstack --> images["Image Cache\n./ha apply --phases images"]
  images --> terraform["Terraform\n./ha apply --phases terraform"]

  terraform --> cp["VM / Control Plane\n./ha apply --phases control-plane"]
  terraform --> build["VM / Build Worker\n./ha apply --phases build-worker"]
  terraform --> gpu["VM / GPU Worker\n./ha apply --phases gpu-worker"]
  terraform --> gitlab["VM / GitLab\n./ha apply --phases gitlab"]
  terraform --> harbor["VM / Harbor\n./ha apply --phases harbor"]

  cp --> k8s["Kubernetes\n./ha apply --phases k8s"]
  build --> k8s
  gpu --> k8s

  k8s --> storage["Storage\n./ha apply --phases storage"]
  storage --> model["Model Build\n./ha apply --phases model-build"]
  harbor --> model

  gitlab --> proxy["Reverse Proxy\n./ha apply --phases proxy"]
  harbor --> proxy

  model --> finalize["Finalize\n./ha apply --phases finalize"]
  proxy --> finalize
```

## Mutual Exclusion

```mermaid
flowchart LR
  controller["GitHub concurrency group\nprivate-cloud-foundation"] --> host["One controller run owns the host"]
  host --> reusable["private-cloud-remote.yml\nSSH command wrapper"]
  reusable --> phase_lock["private-cloud-apply.sh phase lock\n.ha/ci/locks/<phase>.lockdir"]
  phase_lock --> phase["Single phase execution"]

  phase_lock -. allows .-> different_phase["Different phases can run in parallel\nwhen the DAG says they are independent"]
  phase_lock -. blocks .-> same_phase["Same phase cannot run twice\non the same host"]
```

Rules:

- Do not dispatch remote apply or destroy before the equivalent local command
  has passed.
- Do not commit or push provisioning changes if the local full rebuild fails.
- Keep `devstack`, `images`, and `terraform` serialized.
- Run VM role phases as separate jobs after Terraform so logs are split by role.
- Run `k8s` only after control-plane, build-worker, and gpu-worker are ready.
- Run `model-build` only after storage and Harbor are ready.
- Run `proxy` only after GitLab and Harbor are ready.

## Image And GitLab I/O

```mermaid
flowchart TD
  local_cache["Local qcow2 cache\n.ha/openstack/image-cache/*.qcow2"] --> lxd_tmp["LXD push\n/var/lib/snapd/hostfs/... -> ha-openstack:/tmp/*.qcow2"]
  lxd_tmp --> glance["Glance image create\nfile backend write"]
  glance --> active["OpenStack image status: active"]

  active --> terraform["Terraform boots VMs from cached images"]
  terraform --> gitlab_vm["GitLab VM"]
  gitlab_vm --> gitlab_io["GitLab runtime I/O profile\n/tmp + logs tmpfs\noptional Rails tmpfs off by default\ncontainer blkio weight\nrecreate only on profile drift"]
```

Observed local full rebuild notes:

- The image phase reuses local qcow2 files when the cache hits.
- A full OpenStack rebuild removes the DevStack container and Glance backend,
  so cached images must still be uploaded into the new Glance service.
- Large Glance uploads are storage-bound and should be treated as the main
  image-phase I/O bottleneck.
- GitLab runtime I/O mitigation is applied during the GitLab bootstrap phase,
  not while uploading the GitLab base image into Glance.
- GitLab keeps `/tmp` and logs on tmpfs by default, limits Docker logs, and
  applies a lower container blkio weight. Rails tmpfs is off by default because
  it invalidates boot caches and makes cold starts CPU-bound.
- GitLab reapply must not recreate the container when the image and I/O profile
  already match; otherwise every apply pays the full Omnibus/Rails cold-start
  cost.
