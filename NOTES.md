# Notes

## Manually create cluster

```sh
undistro create cluster develop \
    --namespace eks-develop \
    --k8s-version v1.21.0 \
    --infra aws \
    --flavor eks \
    --generate-file
```

Add CIDR to file `eks-develop.yaml`:

```yaml
spec:
  network:
    vpc:
      cidrBlock: 10.3.0.0/16     ## Use non-conflicting range
```

## Active autoscale

## Upgrade control-plane

# Features to explore

## OIDC

https://kubeconfig-mgmt.undistro.io

## Default Policies

https://undistro.io/docs#default-policies
https://undistro.io/docs#network-policy

### Highlights:

- Namespaces isolation: traffic-deny
- Requests are mandatory: require-requests-limits

## Native Helm Release (proprietary)

https://undistro.io/docs#specification

# Open Issues

## HPA/cluster-autoscaler (backlog)
