# Coworking Space Service Extension
The Coworking Space Service is a set of APIs that enables users to request one-time tokens and administrators to authorize access to a coworking space. This service follows a microservice pattern and the APIs are split into distinct services that can be deployed and managed independently of one another.

For this project, you are a DevOps engineer who will be collaborating with a team that is building an API for business analysts. The API provides business analysts basic analytics data on user activity in the service. The application they provide you functions as expected locally and you are expected to help build a pipeline to deploy it in Kubernetes.

## Getting Started

### Dependencies
#### Local Environment
1. Python Environment - run Python 3.6+ applications and install Python dependencies via `pip`
2. Docker CLI - build and run Docker images locally
3. `kubectl` - run commands against a Kubernetes cluster
4. `helm` - apply Helm Charts to a Kubernetes cluster

#### Remote Resources
1. AWS CodeBuild - build Docker images remotely
2. AWS ECR - host Docker images
3. Kubernetes Environment with AWS EKS - run applications in k8s
4. AWS CloudWatch - monitor activity and logs in EKS
5. GitHub - pull and clone code

### Setup
#### 1. Configure a Database
Set up a Postgres database using a Helm Chart.

1. Set up Bitnami Repo
```bash
helm repo add <REPO_NAME> https://charts.bitnami.com/bitnami
```

2. Install PostgreSQL Helm Chart
```
helm install <SERVICE_NAME> <REPO_NAME>/postgresql
```

This should set up a Postgre deployment at `<SERVICE_NAME>-postgresql.default.svc.cluster.local` in your Kubernetes cluster. You can verify it by running `kubectl svc`

By default, it will create a username `postgres`. The password can be retrieved with the following command:
```bash
export POSTGRES_PASSWORD=$(kubectl get secret --namespace default <SERVICE_NAME>-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

echo $POSTGRES_PASSWORD
```

<sup><sub>* The instructions are adapted from [Bitnami's PostgreSQL Helm Chart](https://artifacthub.io/packages/helm/bitnami/postgresql).</sub></sup>

3. Test Database Connection
The database is accessible within the cluster. This means that when you will have some issues connecting to it via your local environment. You can either connect to a pod that has access to the cluster _or_ connect remotely via [`Port Forwarding`](https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/)

* Connecting Via Port Forwarding
```bash
kubectl port-forward --namespace default svc/<SERVICE_NAME>-postgresql 5432:5432 &
    PGPASSWORD="$POSTGRES_PASSWORD" psql --host 127.0.0.1 -U postgres -d postgres -p 5432
```

* Connecting Via a Pod
```bash
kubectl exec -it <POD_NAME> bash
PGPASSWORD="<PASSWORD HERE>" psql postgres://postgres@<SERVICE_NAME>:5432/postgres -c <COMMAND_HERE>
```

4. Run Seed Files
We will need to run the seed files in `db/` in order to create the tables and populate them with data.

```bash
kubectl port-forward --namespace default svc/<SERVICE_NAME>-postgresql 5432:5432 &
    PGPASSWORD="$POSTGRES_PASSWORD" psql --host 127.0.0.1 -U postgres -d postgres -p 5432 < <FILE_NAME.sql>
```

### 2. Running the Analytics Application Locally
In the `analytics/` directory:

1. Install dependencies
```bash
pip install -r requirements.txt
```
2. Run the application (see below regarding environment variables)
```bash
<ENV_VARS> python app.py
```

There are multiple ways to set environment variables in a command. They can be set per session by running `export KEY=VAL` in the command line or they can be prepended into your command.

* `DB_USERNAME`
* `DB_PASSWORD`
* `DB_HOST` (defaults to `127.0.0.1`)
* `DB_PORT` (defaults to `5432`)
* `DB_NAME` (defaults to `postgres`)

If we set the environment variables by prepending them, it would look like the following:
```bash
DB_USERNAME=username_here DB_PASSWORD=password_here python app.py
```
The benefit here is that it's explicitly set. However, note that the `DB_PASSWORD` value is now recorded in the session's history in plaintext. There are several ways to work around this including setting environment variables in a file and sourcing them in a terminal session.

3. Verifying The Application
* Generate report for check-ins grouped by dates
`curl <BASE_URL>/api/reports/daily_usage`

* Generate report for check-ins grouped by users
`curl <BASE_URL>/api/reports/user_visits`

## Project Instructions
1. Set up a Postgres database with a Helm Chart
2. Create a `Dockerfile` for the Python application. Use a base image that is Python-based.
3. Write a simple build pipeline with AWS CodeBuild to build and push a Docker image into AWS ECR
4. Create a service and deployment using Kubernetes configuration files to deploy the application
5. Check AWS CloudWatch for application logs

### Deliverables
1. `Dockerfile`
2. Screenshot of AWS CodeBuild pipeline
3. Screenshot of AWS ECR repository for the application's repository
4. Screenshot of `kubectl get svc`
5. Screenshot of `kubectl get pods`
6. Screenshot of `kubectl describe svc <DATABASE_SERVICE_NAME>`
7. Screenshot of `kubectl describe deployment <SERVICE_NAME>`
8. All Kubernetes config files used for deployment (ie YAML files)
9. Screenshot of AWS CloudWatch logs for the application
10. `README.md` file in your solution that serves as documentation for your user to detail how your deployment process works and how the user can deploy changes. The details should not simply rehash what you have done on a step by step basis. Instead, it should help an experienced software developer understand the technologies and tools in the build and deploy process as well as provide them insight into how they would release new builds.


### Stand Out Suggestions
Please provide up to 3 sentences for each suggestion. Additional content in your submission from the standout suggestions do _not_ impact the length of your total submission.
1. Specify reasonable Memory and CPU allocation in the Kubernetes deployment configuration
2. In your README, specify what AWS instance type would be best used for the application? Why?
3. In your README, provide your thoughts on how we can save on costs?

### Best Practices
* Dockerfile uses an appropriate base image for the application being deployed. Complex commands in the Dockerfile include a comment describing what it is doing.
* The Docker images use semantic versioning with three numbers separated by dots, e.g. `1.2.1` and  versioning is visible in the  screenshot. See [Semantic Versioning](https://semver.org/) for more details.

# Deployment
Assume a VPC is created
## Prerequisites

Make sure `eksctl`, `helm` are installed

Install `eksctl`:
```bash
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl
```


## Networking Deployment
Run following command to create network configuration:

```
aws cloudformation create-stack \
  --stack-name eks-subnets \
  --template-body file://deployment/cloudformation/resources/networking.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=VpcId,ParameterValue=vpc-xxxx
```

Run following commands to check for creation of resources:

```
# For VPC
aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value[]]' --output table

# For Subnets
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
  --output table
  
# For Internet Gateway
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=<vpc-id>" \
  --query 'InternetGateways[*].[InternetGatewayId,Tags[?Key==`Name`].Value[]]' \
  --output table
  
# For NAT Gateway
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=<vpc-id>" \
  --query 'NatGateways[*].[NatGatewayId,SubnetId,State]' \
  --output table
  
# For Route Tables
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'RouteTables[*].[RouteTableId,Tags[?Key==`Name`].Value[]]' \
  --output table
  
# CloudFormation Status and Outputs:
# Check stack status
aws cloudformation describe-stacks \
  --stack-name eks-subnets \
  --query 'Stacks[*].[StackName,StackStatus]' \
  --output table

# Check stack outputs
aws cloudformation describe-stacks \
  --stack-name eks-subnets \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table
  
aws cloudformation describe-stacks \
  --stack-name eks-subnets \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table
```

## EKS Deployment
```
aws cloudformation create-stack \
--stack-name eks-cluster \
--template-body file://eks.yaml \
--parameters \
ParameterKey=Environment,ParameterValue=dev \
ParameterKey=VpcId,ParameterValue=<vpc-id> \
ParameterKey=PrivateSubnet1,ParameterValue=subnet-XXXX \
ParameterKey=PrivateSubnet2,ParameterValue=subnet-YYYY \
--capabilities CAPABILITY_IAM
```
Command to check for EKS creation:

```
# List EKS clusters
aws eks list-clusters

# Describe specific cluster
aws eks describe-cluster --name dev-eks-cluster

# Get node groups
aws eks list-nodegroups --cluster-name dev-eks-cluster

# List roles with 'eks' in the name
aws iam list-roles \
  --query 'Roles[?contains(RoleName, `eks`)].[RoleName,Arn]' \
  --output table
```

### kubeconfig Update

```
aws eks --region us-east-1 update-kubeconfig --name <cluster-name>
```

Output should be:

```
Added new context arn:aws:eks:us-east-1:<id>:cluster/<cluster-name> to <local path to .kube/config>
```

The crucial role of the config:

The ~/.kube/config file is crucial for `kubectl` to communicate with your EKS cluster. Here's how it works:

When you ran `aws eks update-kubeconfig`, it:

* Gets the cluster endpoint from AWS
* Gets authentication details
* Updates ~/.kube/config with this information

The `kubeconfig` file contains:

* Cluster information (API server endpoint)
* Authentication details (AWS IAM credentials)
* Context (which connects cluster and user details)

When you run `kubectl` commands:

* kubectl reads the config file
* Uses the AWS IAM credentials to authenticate
* Makes API calls to the cluster endpoint

Command to verify context:

```bash
# View current context
kubectl config current-context

# View full config details
kubectl config view

```

### Kubernetes Verification

```
kubectl get nodes -o wide

kubectl get pods -n kube-system

kubectl get storageclass

kubectl get namespaces
```

# Delete Stacks

```bash
# Delete the EKS CloudFormation stack
aws cloudformation delete-stack --stack-name eks-cluster

# Delete the networking stack
aws cloudformation delete-stack --stack-name eks-subnets
```

# Use Scripts for Provisioning and Tearing Down Infrastructure

Make sure these scripts executable, run following commands at root of the project:
```bash
chmod +x setup-eks.sh
chmod +x teardown-eks.sh
```

# Deploy Database Service

## Prerequisites
Create the OIDC provider:

```bash
eksctl utils associate-iam-oidc-provider \
    --cluster dev-eks-cluster \
    --region us-east-1 \
    --approve
```

The expected output:
```
2024-12-17 22:53:09 [ℹ]  will create IAM Open ID Connect provider for cluster "dev-eks-cluster" in "us-east-1"
2024-12-17 22:53:09 [✔]  created IAM Open ID Connect provider for cluster "dev-eks-cluster" in "us-east-1"
```

Verify the creation:

```bash
eksctl utils describe-stacks --region us-east-1 --cluster dev-eks-cluster
```

with output:

```
2024-12-17 22:54:15 [!]  only 0 stacks found, for a ready-to-use cluster there should be at least 2
```

Create an IAM service account for the EBS CSI Driver:

```bash
eksctl create iamserviceaccount \
    --name ebs-csi-controller-sa \
    --namespace kube-system \
    --cluster dev-eks-cluster \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    --approve \
    --region us-east-1
```

The output should be:

```
2024-12-17 22:56:06 [ℹ]  1 iamserviceaccount (kube-system/ebs-csi-controller-sa) was included (based on the include/exclude rules)
2024-12-17 22:56:06 [!]  serviceaccounts that exist in Kubernetes will be excluded, use --override-existing-serviceaccounts to override
2024-12-17 22:56:06 [ℹ]  1 task: { 
    2 sequential sub-tasks: { 
        create IAM role for serviceaccount "kube-system/ebs-csi-controller-sa",
        create serviceaccount "kube-system/ebs-csi-controller-sa",
    } }2024-12-17 22:56:06 [ℹ]  building iamserviceaccount stack "eksctl-dev-eks-cluster-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa"
2024-12-17 22:56:06 [ℹ]  deploying stack "eksctl-dev-eks-cluster-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa"
2024-12-17 22:56:06 [ℹ]  waiting for CloudFormation stack "eksctl-dev-eks-cluster-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa"
2024-12-17 22:56:36 [ℹ]  waiting for CloudFormation stack "eksctl-dev-eks-cluster-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa"
2024-12-17 22:56:36 [ℹ]  created serviceaccount "kube-system/ebs-csi-controller-sa"
```

## Scripts

Make sure these scripts executable, run following commands at root of the project:
```bash
chmod +x postgres-helm-startup.sh
chmod +x postgres-helm-cleanup.sh
```

Start up the service using `./postgres-helm-startup.sh`

Clean up the service using `./postgres-helm-cleanup.sh`

Verify the cleaning up:

To ensure that all resources, including the PersistentVolumeClaim (PVC), are deleted after running your cleanup script, you can follow these steps:

### Verify Pods

Check that no pods associated with your PostgreSQL setup are running:

kubectl get pods --all-namespaces | grep postgresql

	•	If no results are returned, all related pods have been deleted.

### Verify Services

Check that the PostgreSQL service has been removed:

kubectl get svc --all-namespaces | grep postgresql

	•	If no results are returned, the service has been deleted.

### Verify Deployments and StatefulSets

Ensure that no StatefulSets or Deployments associated with PostgreSQL exist:

kubectl get statefulsets --all-namespaces | grep postgresql
kubectl get deployments --all-namespaces | grep postgresql

	•	If no results are returned, these resources have been removed.

### Verify PVC

Check that the PersistentVolumeClaim has been deleted:

kubectl get pvc --all-namespaces | grep postgresql

	•	If no results are returned, the PVC has been deleted.

### Verify PersistentVolumes

Sometimes, deleting a PVC does not immediately delete the corresponding PersistentVolume (depending on the reclaimPolicy):

kubectl get pv | grep postgresql

	•	If no results are returned, the PersistentVolume has been deleted.
	•	If results appear, check the status of the PV:

kubectl describe pv <PV_NAME>

If the status is Released or Available, manually delete it:

kubectl delete pv <PV_NAME>

### Verify Helm Release

Ensure that the Helm release has been fully removed:

helm list --all-namespaces | grep postgresql

	•	If no results are returned, the Helm release has been deleted.

### Check for Other Resources

Check for any lingering ConfigMaps, Secrets, or other Kubernetes resources:

kubectl get configmaps --all-namespaces | grep postgresql
kubectl get secrets --all-namespaces | grep postgresql

Manually delete any lingering resources if necessary:

kubectl delete configmap <CONFIGMAP_NAME>
kubectl delete secret <SECRET_NAME>

### Comprehensive Cleanup

If you want to ensure no resources remain:

kubectl get all --all-namespaces | grep postgresql

This will show any remaining PostgreSQL-related resources.

### Clean Logs for Debugging

(Optional) Check the logs of your cleanup script to ensure there were no errors during execution.

Example Cleanup Script Verification:

To summarize, after cleanup, these commands should return no results:

kubectl get pods --all-namespaces | grep postgresql
kubectl get svc --all-namespaces | grep postgresql
kubectl get pvc --all-namespaces | grep postgresql
kubectl get pv | grep postgresql
helm list --all-namespaces | grep postgresql

If all these checks are clear, your cleanup was successful, and all PostgreSQL-related resources have been deleted. Let me know if you need help automating this verification process!
## Manual Cleaning Up (If Necessary)

Delete the PVC with:

```bash
kubectl delete pvc data-postgresql-0
```

# Exploration
## VPC Information

Run command:
```
aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table
```
print a table of:
* VPC ID
* CIDR Block Range
* Name tag (if one exists)

```
-------------------------------------------
|              DescribeVpcs               |
+---------------+-----------------+-------+
|  <vpc-id> |  <cidr-block>       |  None |
+---------------+-----------------+-------+
```

Just print default VPC:
```
aws ec2 describe-vpcs --filters Name=isDefault,Values=true
```
Output can be:
```json
{
    "Vpcs": [
        {
            "CidrBlock": "",
            "DhcpOptionsId": "d",
            "State": "available",
            "VpcId": "<vpc-id>",
            "OwnerId": "<owner-id>",
            "InstanceTenancy": "default",
            "CidrBlockAssociationSet": [
                {
                    "AssociationId": "<cidr-block-association-id",
                    "CidrBlock": "",
                    "CidrBlockState": {
                        "State": "associated"
                    }
                }
            ],
            "IsDefault": true
        }
    ]
}
```
### CIDR Block Information
Use this to list CIDR Block of your VPC
```
aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,CidrBlock]' --output table
```

```
aws ec2 describe-subnets \
--filters "Name=vpc-id,Values=vpc-7aa76207" \
--query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone]' \
--output table
```

```
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-7aa76207" \
  --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```
## Subnet Information

```
aws ec2 describe-subnets
```

```
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-xxxxx"
```

## Internet Gateway Information

```
aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=vpc-7aa76207"
```

Output:

```json
{
    "InternetGateways": []
}
```

## Persistent Volume and Persistent Volume Claim

Persistent Volumes (PV) and Persistent Volume Claims (PVC) are needed for database services because:

Data Persistence:

* Pods are ephemeral (temporary) in Kubernetes
* If a pod crashes or restarts, all data inside the container is lost
* PV provides persistent storage that survives pod restarts


Storage Management:

* PV defines the actual storage resource (like an AWS EBS volume)
* PVC is the request for that storage by the application

This separation allows:

* Admins to manage storage resources (PV)
* Developers to request storage (PVC) without knowing storage details

## Port Forwarding from a Pod

Port forwarding in this context serves as a way to securely access the PostgreSQL database running in your Kubernetes cluster from your local machine. Here's why it's important:

1. Security:
    - The PostgreSQL pod is not directly exposed to the internet
    - Port forwarding creates a secure tunnel between your local machine and the pod

2. Local Development:
    - Allows you to connect to the database using local tools (like pgAdmin)
    - You can run database migrations from your local machine
    - You can test database connections from your local environment

In the instructions:
```bash
kubectl port-forward service/postgresql-service 5433:5432 &
```
This means:
- Local port 5433 -> forwards to -> Pod's port 5432
- You can then connect using: `localhost:5433`
- The `&` runs it in background

Example usage after port forwarding:
```bash
# Connect using psql from local machine
PGPASSWORD="mypassword" psql --host 127.0.0.1 -U myuser -d mydatabase -p 5433

# Run migrations or seed files
psql --host 127.0.0.1 -p 5433 < your_seed_file.sql
```

Without port forwarding, you wouldn't be able to access the database from outside the Kubernetes cluster since it's internal to the cluster network.