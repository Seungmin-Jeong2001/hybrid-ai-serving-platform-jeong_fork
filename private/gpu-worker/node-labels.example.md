# GPU Node Labels

Apply labels and taints after GPU nodes join the cluster.

```sh
kubectl label node <gpu-node-name> accelerator=nvidia node-role.kubernetes.io/gpu-worker=true
kubectl taint node <gpu-node-name> nvidia.com/gpu=true:NoSchedule
```
