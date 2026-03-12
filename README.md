# ROSA Multi-Region Deployment Script

Deploy Red Hat OpenShift Service on AWS (ROSA) Hosted Control Plane clusters in **Sydney** and **Melbourne** using a single automated Bash script.

---

# Overview

This repository contains a Bash script that automatically provisions the infrastructure and ROSA clusters required to run OpenShift in two AWS regions:

* **Sydney:** `ap-southeast-2`
* **Melbourne:** `ap-southeast-4`

The script performs the following tasks:

1. Prompts for **AWS credentials** before deployment.
2. Authenticates to ROSA using `rosa login --use-auth-code`.
3. Creates a **VPC** in each region.
4. Creates **public and private subnets across three availability zones**.
5. Configures:

   * Internet Gateway
   * NAT Gateway
   * Route Tables
6. Tags subnets appropriately for ROSA.
7. Creates **ROSA Hosted Control Plane operator roles**.
8. Deploys **ROSA HCP clusters** in both regions.

At completion, the environment will contain:

| Cluster   | Region         | Machine CIDR | Pod CIDR      |
| --------- | -------------- | ------------ | ------------- |
| rosa-syd  | ap-southeast-2 | 10.0.0.0/16  | 10.128.0.0/14 |
| rosa-melb | ap-southeast-4 | 10.1.0.0/16  | 10.132.0.0/14 |

---

# Architecture

Each region deploys the following network topology:

```
VPC
├── Public Subnet AZ-A
│     └── NAT Gateway
├── Public Subnet AZ-B
├── Public Subnet AZ-C
│
├── Private Subnet AZ-A
├── Private Subnet AZ-B
└── Private Subnet AZ-C
```

Routing configuration:

| Route Table | Route                           |
| ----------- | ------------------------------- |
| Public RT   | `0.0.0.0/0 -> Internet Gateway` |
| Private RT  | `0.0.0.0/0 -> NAT Gateway`      |

ROSA clusters run worker nodes in **private subnets** and expose ingress through **public subnets**.

---

# Prerequisites

Before running the script ensure you have:

### Installed Tools

* AWS CLI
* ROSA CLI
* jq
* bash

Verify installation:

```bash
aws --version
rosa version
```

### AWS Permissions

Your AWS account must allow:

* EC2 VPC creation
* Subnet creation
* NAT Gateway creation
* Elastic IP allocation
* Route table creation
* IAM role usage

### ROSA Prerequisites

The following must already exist:

* ROSA **account roles**
* ROSA **OIDC configuration**

Example:

```
OIDC_ID=26anjg402drs6v8iq1bmq9m1sbj5j0d8
ACCOUNT_ROLES_PREFIX=ManagedOpenShift
```

---

# Files

```
deploy-rosa-syd-melb.sh
README.md
```

| File                    | Description                          |
| ----------------------- | ------------------------------------ |
| deploy-rosa-syd-melb.sh | Deployment script for both clusters  |
| README.md               | Documentation for running the script |

---

# Running the Script

### Step 1 — Make executable

```bash
chmod +x deploy-rosa-syd-melb.sh
```

### Step 2 — Run deployment

```bash
./deploy-rosa-syd-melb.sh
```

The script will prompt for AWS credentials:

```
AWS Access Key ID:
AWS Secret Access Key:
AWS Session Token (optional):
```

It will then request ROSA authentication:

```
rosa login --use-auth-code
```

Follow the browser authentication flow.

---

# Deployment Flow

The script executes the following steps:

### 1 — Authenticate to AWS

Credentials are exported as environment variables.

### 2 — Authenticate to ROSA

Uses:

```
rosa login --use-auth-code
```

### 3 — Create VPC

Example (Sydney):

```
10.0.0.0/16
```

Example (Melbourne):

```
10.1.0.0/16
```

### 4 — Create Subnets

| Region    | Public Subnets                            | Private Subnets                              |
| --------- | ----------------------------------------- | -------------------------------------------- |
| Sydney    | 10.0.1.0/24<br>10.0.2.0/24<br>10.0.3.0/24 | 10.0.11.0/24<br>10.0.12.0/24<br>10.0.13.0/24 |
| Melbourne | 10.1.1.0/24<br>10.1.2.0/24<br>10.1.3.0/24 | 10.1.11.0/24<br>10.1.12.0/24<br>10.1.13.0/24 |

### 5 — Configure Networking

Creates:

* Internet Gateway
* Public route table
* NAT gateway
* Private route table

### 6 — Tag Subnets

Public:

```
kubernetes.io/role/elb=1
```

Private:

```
kubernetes.io/role/internal-elb=1
```

### 7 — Create Operator Roles

```
rosa create operator-roles --hosted-cp
```

### 8 — Deploy ROSA Clusters

```
rosa create cluster --hosted-cp
```

Clusters deployed:

```
rosa-syd
rosa-melb
```

---

# Monitoring Installation

Check cluster status:

```bash
rosa list clusters
```

Detailed view:

```bash
rosa describe cluster -c rosa-syd
rosa describe cluster -c rosa-melb
```

View installation logs:

```bash
rosa logs install -c rosa-syd
rosa logs install -c rosa-melb
```

---

# Accessing the Cluster

After installation completes:

```
rosa create admin -c rosa-syd
rosa create admin -c rosa-melb
```

Login:

```
oc login https://api.<cluster>.openshiftapps.com
```

---

# Cost Considerations

Each region creates:

* 1 VPC
* 3 public subnets
* 3 private subnets
* 1 NAT Gateway
* 1 Elastic IP
* ROSA control plane
* Worker nodes

Estimated minimum AWS cost per region:

| Resource           | Notes                   |
| ------------------ | ----------------------- |
| NAT Gateway        | hourly charge           |
| Elastic IP         | free while attached     |
| EC2 worker nodes   | m5.xlarge               |
| ROSA control plane | billed via subscription |

Deleting clusters does **not automatically delete VPC resources**.

---

# Cleanup

To delete clusters:

```bash
rosa delete cluster -c rosa-syd
rosa delete cluster -c rosa-melb
```

You must manually remove:

* VPC
* NAT gateway
* Elastic IP
* Subnets
* Route tables

---

# Troubleshooting

### Cluster stuck in "waiting"

Ensure operator roles exist:

```
rosa create operator-roles --hosted-cp
```

### Install fails with egress errors

Verify NAT routing:

```
0.0.0.0/0 -> NAT Gateway
```

### Check networking

```
aws ec2 describe-route-tables
aws ec2 describe-nat-gateways
```

---

# Example Output

After successful deployment:

```
Done.
Sydney VPC:    vpc-xxxxx
Sydney cluster: rosa-syd
Melbourne VPC: vpc-yyyyy
Melbourne cluster: rosa-melb
```

---

# Future Improvements

Possible enhancements:

* Multi-AZ NAT gateway architecture
* Terraform version of this deployment
* Automated cleanup script
* ACM multi-cluster hub deployment
* GitOps bootstrap

---

# License

Internal automation script for ROSA deployments.
Use at your own risk.

---
