# Cluster of 2 x Pulse vTMs for deploying into an existing VPC

## What does this template do

Given an ID of an existing VPC, its CIDR, and Subnet IDs of two **public** subnets, this template will deploy a pair of Pulse vTMs using an Auto Scaling Group. It is highly recommended (but not required) that the two subnets belong to different Availability Zones (AZ), to ensure vTM cluster redundancy.

vTMs will be automatically clustered together and ready to take configuration both through REST API (e.g., using [Terraform Provider](https://github.com/pulse-vadc/terraform-provider-vtm) for vTM), or Web UI.

It will be possible to adjust the size of the Auto Scaling Group at later stage, which will add or remove vTMs in the cluster.

> **Note**: if you're using `Traffic IP Groups` (TIP Groups), you will need to adjust your TIP Groups configuration every time cluster membership changes.

> If you are using Terraform Provider for vTM, you can use data source `vtm_traffic_manager_list` to retrieve current list of vTMs in a cluster and update TIP Group configuration during a `terraform apply` run.

## Prerequisites

### AWS Marketplace subscription

To successfully deploy this template, the AWS account used to deploy must have an existing subscription to [Pulse Secure Virtual Traffic Manager Developer & BYOL Edition](https://aws.amazon.com/marketplace/pp/B00S04V5HU). Open the link and look for "Continue to Subscribe" button at the top right. You do not need to launch the vTM from Marketplace; you only need to accept the Terms and Conditions.

Please see [AWS Marketplace FAQ](https://aws.amazon.com/marketplace/help/buyer-managing-products) for more detail.

### Existing VPC

This template assumes that you have an existing VPC with at least two **public** subnets. vTM instances require access to the Internet to download additional components, e.g., automatic cluster management scripts and `jq` and AWS CLI tools that these scripts use.

You will also need to supply the CIDR block used by the VPC you've selected (gotta [love CloudFormation](https://serverfault.com/questions/799154/cloudformation-vpc-getatt-parameter-internal-failure/799163) that won't let you just query it from the VPC ID). This value is used for the vTMs' Security Group rules that allow vTM clustering components to talk to each other.

### Permissions to create an IAM Role

AWS Account used to deploy this template must have permission to create IAM Roles and Policies. This is needed for the IAM Role attached to vTM instances that allows them to manage their Traffic IPs, implement built-in pool node autoscaling, and perform automatic vTM cluster management without storing AWS credentials and secrets.

### Registration with Pulse Services Director

If you are using Pulse Services Director (SD) to supply vTMs with licenses, SD must be able to reach your vTMs on their primary **private** IP address.

## Template Parameters

### VPC Configuration

| Parameter | Description
| --- | ---
| VPC | ID of the VPC to deploy into, e.g., `vpc-12345678`
| VPCCIDR | CIDR block associated with the VPC above, e.g., `10.0.0.0/16`
| PublicSubnet1 | Public subnet from the VPC above for the first vTM instance, e.g., `subnet-1234abdc`
| PublicSubnet2 | Public subnet from the VPC above for the second vTM instance

> If vTM Auto Scaling group is adjusted later to deploy more than 2 vTM instances, any additional instances will be placed across the same two public subnets, in a round-robin fashion.

### vTM Deployment Configuration

| Parameter | Description
| --- | ---
| vTMVers | De-dotted version of vTM to deploy; e.g., `18.1` would be specified as `181`. Supported values are `172r2`, `173`, `174`, and `181`.
| InstanceType | AWS EC2 instance type to use for vTM instances; default = `m4.large`; see the template source for the full list.<br/>Please make sure that the instance type you select is available in the AWS region you're deploying into; for example m4.* instances are not available in newer regions.
| KeyName | SSH Key Pair name to use for vTM instances. This is used for SSH access to vTMs using `admin` username.
| AdminPass | Password for the `admin` user, 6 to 32 characters, containing letters, numbers, and symbols.
| vTMUserData | A string of `key=value` vTM UserData parameters separated by spaces or newline characters. Supported keys are documented in [vTM Cloud Services Installation and Getting Started Guide](https://www.pulsesecure.net/download/techpubs/current/1256/Pulse-vADC-Solutions/Pulse-Virtual-Traffic-Manager/18.1/ps-vtm-18.1-cloud-gsg.pdf). Typically this would be used to supply set of keys provided by a Cloud Registration created by admin of the Pulse Services Director to cause vTMs attempt self-registration with the SD for licensing and management.<br/><br/>**Note:** SD Cloud Registration usually contains key `password` which should not be supplied through this parameter. This template supplies `password` through the separate input Parameter `AdminPass` described above.

### Security Configuration

| Parameter | Description
| --- | ---
| EnvSGs | Comma-delimited (no spaces) list of AWS Security Group IDs (SG IDs) that will be attached to vTM instances in addition to their own Security Group; e.g., `sg-1234abcd,sg-ab78c76de`<br/>This typically is required to allow vTMs to access the backend servers, where access to those servers is controlled by their own Security Group (SG) that has entries that refer to the same SG by name.<br/>For example, network access to a group of backend EC2 instances could be controlled by an SG `sg-ab78c76de` that has one or more entries with `Source` set to `sg-ab78c76de`. Adding `sg-ab78c76de` to vTM's `EnvSGs` would allow vTM access accordingly.
| RemoteAccessCIDR | CIDR notation of an IPv4 subnet or a host that will have access to vTM cluster's SSH (`TCP/22`), Web UI (`TCP/9090`), and REST API (`TCP/9070`) ports.<br/><br/>**Note:** In addition to these, HTTP (`TCP/80`) and HTTPS (`TCP/443`) are configured open to everything (`0.0.0.0/0`).

## Outputs

At present, template produces a single output `vTMManagementIPs` which contains the EC2 instance IDs of the two vTM instances with their public IP addresses. An example output:

`{"i-0eca298092a7df302":"13.126.50.207","i-069922090ffbcc7e7":"35.154.97.237"}`

## Implemented functionality

### vTM EC2 instance and Cluster management

This template manages vTM EC2 instances through an AWS Auto Scaling Group (ASG). This ASG is configured with default settings of `MinSize`, `MaxSize`, and `DesiredCapacity` all set to `2`.

At present, ASG **is not** configured to receive signals from CloudWatch that could change the size of the ASG based on the vTM EC2 instances' resource utilisation. If ASG configuration is adjusted by hand, the ASG/vTM setup will accommodate the change by expanding or shrinking the vTM cluster accordingly. It is also capable of recovering from a complete loss of all vTM instances in the cluster.

> **Note:** the above assumes that there is a separate, outside system capable of: (a) detecting vTM cluster membership changes (e.g., new vTMs joining the cluster, or individual vTMs leaving it), and  updating at the very least Traffic IP Group configuration `machines` parameter; and (b) detecting whether the vTM configuration was lost entirely (e.g., with a loss of the complete cluster), and re-applying the configuration.

> A very simple implementation of such system can be found in [UpdateClusterConfig.sh](https://github.com/dkalintsev/vADC-CloudFormation/blob/v1.1.2/Template/UpdateClusterConfig.sh) script (not a part of this template) that can run as a cron job from a separate EC2 instance to perform these two functions.

### Integration with Pulse Services Director

If `vTMUserData` contains a set of keys that instruct vTM instances to attempt self-registration with Pulse Services Director (SD), the following factors need to be considered:

- The automatic clustering process used in this template will initially bring up each vTM instance as a single member of its own stand-alone vTM cluster. It will then attempt to register vTM with the SD. If registration is successful, SD will register a new vTM and a new vTM Cluster.
- Once vTM is up, it will search for other vTMs with the same AWS Tag `ClusterID` as itself, plus Tag `ClusterState` set to `Active`. If it finds such instance, it will attempt to join that instance's cluster and abandon its own cluster, if the join is successful. This means that the vTM's original Cluster on the SD will become empty. In its present implementation, SD will not automatically reap these empty clusters.
- If a vTM instance goes away, for example, due to Auto Scaling Group action, SD will keep the vTM instance in its inventory. In its present implementation, SD will not automatically reap these defunct vTM instances.

## vTM deployment process and automated cluster management scripts

Deploy time configuration of the vTM instances is described in the corresponding `LaunchConfiguration` part of the CloudFormation template. To implement this configuration, template makes use of [AWS::CloudFormation::Init](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-init.html). More specifically, `cfn-init` is used to:

- Download and install `jq` and AWS CLI tool;
- Download script `housekeeper.sh` into `/opt/aws` and `autocluster.sh` into `/tmp`
- Set `housekeeper.sh` up as a cron job to run every 2 minutes
- Enable `Developer Mode` on the vTM

### Scripts: `housekeeper.sh`

The `housekeeper.sh` script runs on each vTM node in the cluster from cron, every 2 minutes. It performs the following functions:

- If it finds a copy of `autocluster.sh` in `/tmp`, it will run it, and then delete it.
- Check how many secondary private IP addresses a vTM has, and add or remove them to make sure there are enough to back the configured Traffic IPs.
- Compare the list of vTMs in the cluster with the list of currently running vTM EC2 instances. If it finds a cluster member that doesn't have a matching running vTM EC2 instance, it removes such orphaned cluster member. This function is only performed on the vTM cluster leader.

### Scripts: `autocluster.sh`

The `autocluster.sh` script is run once on each vTM instance in the cluster. This run is performed from the `housekeeper.sh` cron job, typically the very first time after vTM has been deployed.

The role of this script is to make vTM instance either form a new cluster that other vTMs will join, or to join a cluster that was created earlier.

To do this, the script uses a few AWS EC2 tags, specifically:

- `ClusterID`: used to identify EC2 instances that belong to the same vTM cluster.
- `ClusterState`: used to identify vTMs in a particular state, e.g., `Active` meaning "member of an active cluster", and `Joining` meaning a vTM is attempting to join an existing cluster.
- `ElectionState`: used to identify vTM instances that are currently forming a new cluster.

After this script finishes its run, all vTM instances - members of the same cluster will have the same value of the tag `ClusterID`, and tag `ClusterState` set to `Active`.

Briefly, the automatic clustering logic from the point of view of a vTM that runs the script is as follows:

- Search for EC2 instances with the same `ClusterID` as mine and `ClusterState` set to `Active`.
- If found, attempt to join that instance's cluster. If found more than one, select a random one for join operation. Once join succeeds, set `ClusterState` to `Active`, and exit.
- If not found, set own tag `ClusterState` to `Active`, and exit.

## Tools

`vTM-amis.sh` in the `Tools` directory is used to build a list of vTM AMIs. By default the template uses the AMIs of the Developer Edition of vTM. Use this tool to build a list of AMIs of any other listed SKU of the Pulse vTM, if necessary.

