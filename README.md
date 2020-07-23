# terraform-kubernetes-service

This is a Terraform module which encapsulates running an HTTP service on
SCIMMA's Kubernetes cluster.

You provide a container image which runs an HTTP service, listening on port 80.
You also provide a DNS hostname you'd like the service to run under, and a set
of IAM permissions you'd like the service to have.

You get the container running on an EKS cluster, complete with DNS, load
balancing, and HTTPS handling out of the box.

## Example usage

A full example is the `scimma-admin` application, invoked in the (private)
SCIMMA aws-dev repository
[here](https://github.com/scimma/aws-dev/blob/499abb36af91341de02f0af03e048fb2c773b06c/tf/eksDeployments/scimma-admin.tf).

## Inputs

See `variables.tf` for a full list of input variables for the module and what they do.
