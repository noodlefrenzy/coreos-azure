# App Deployment with Docker and CoreOS on Microsoft Azure

This repo provides everything you need to go from nothing to deploying a scaled application using Docker and CoreOS on Microsoft Azure.

It assumes you are running on an Debian-based system like Ubuntu for the first section on Docker and a POSIX development machine for the second section on CoreOS.

## Docker Fundamentals

You should understand the fundamentals of Docker before we jump into CoreOS. This section will run through building a Docker container that houses our simple node.js application.  If you are familiar with Docker already, you can skim this section and move on to the "Deploying applications with CoreOS" section below.

Docker provides an easy to use mechanism for building containerized applications. Containers introduce a level of virtualization between virtual machines and PaaS: containers share the same underlying OS but utilize a facilility of the OS (LXC in Linux) to run concurrently with other containers on that host. This has memory efficiency benefits at the expense of losing some of the security isolation benefits of virtual machines. If this concept is new to you, I'd recommend reading more on the [Docker website](https://www.docker.com/whatisdocker/) before continuing.

### Installing Docker and this sample repo

Let's get Docker installed. On your Ubuntu machine (I’m using an A1 Azure VM instance running Ubuntu 14.04 LTS for this walkthrough), run the following to install Docker:

```
$ sudo apt-get update
$ sudo apt-get install docker.io
$ sudo ln -sf /usr/bin/docker.io /usr/local/bin/docker
$ sudo sed -i '$acomplete -F _docker docker' /etc/bash_completion.d/docker.io
```

Next, clone this repo into a development directory on your Ubuntu box:

```
$ git clone http://github.com/timfpark/coreos-azure coreos-azure
```

Docker works off the of the priniciple of layered containers. This enables you to build containers on top of more general base containers that you can independently maintain.

The directory ~/containers has three Docker container specifications.  One for ubuntu, one for nodejs, and one for the sampleapp we are going to ultimately going to run and deploy.

### Building a base Ubuntu container

Let's start by looking at the ubuntu specification in ~/containers/ubuntu/Dockerfile

The specification is incredibly simple:

```
FROM ubuntu:14.04
MAINTAINER Tim Park <tpark@microsoft.com>

RUN sudo apt-get update
RUN sudo apt-get install -y git
```

The first line indicates that this container should start from a stock Ubuntu 14.04 image and then the last line installs the 'git' package.

We'll use this as the base image for the rest of our containers. The advantage of this approach is that we can later come back to this Dockerfile and add additional installation or configuration steps and cleanly have these changes flow into all of our downstream containers that start from this Docker image.

We can then build this Docker container using:

```
$ sudo docker build --rm -t 'timpark/ubuntu' .
```

Normally, you'd also push this container to the a Docker registry:

```
$ sudo docker push timpark/ubuntu
```

You won't be able to do this because timpark is my namespace, but this is the workflow you'd follow when you go to build your own containers.

### Building a node.js base image

Let's next look at the first of these dependent containers in ~/containers/nodejs:

```
FROM timpark/ubuntu
MAINTAINER Tim Park <tpark@microsoft.com>

RUN sudo apt-get install -y software-properties-common python-software-properties
RUN sudo add-apt-repository ppa:chris-lea/node.js
RUN sudo apt-get update
RUN sudo apt-get install -y nodejs
RUN sudo npm install npm -g
```

This starts with the timpark/ubuntu container that we built in the last section and layers on a node.js installation and updates npm to the latest version.

This leaves us with a container that we can use as the base for any nodejs application.

### Building our application container

The final step in our progression is to build a container that hosts our actual application.

We're going to use the world's simplest node.js application to demonstrate this: it simply prints out the number of seconds it has been running in response to any request. This application is available at https://github.com/timfpark/simple-nodejs-server

The Dockerfile for our application looks like this:

```
FROM timpark/nodejs
MAINTAINER Tim Park <tpark@microsoft.com>

RUN mkdir /var/www
ADD start.sh /var/www/
RUN chmod +x /var/www/start.sh
CMD ./var/www/start.sh
```

This takes our node.js container that we built in the previous section, creates an application directory in /var/www, adds the local script start.sh to that directory, and makes it executable. Finally, it tells docker that it should run this at startup.

start.sh looks like this:

```
cd /var/www

# remove repo if it already exists
rm -rf simple-nodejs-server; true

# install latest nodejs server
git clone http://github.com/timfpark/simple-nodejs-server simple-nodejs-server
cd simple-nodejs-server
npm install

node server.js
```

This script manages the application lifecycle for the application. At startup it deletes the old copy (if any) from the application directory, clones the latest version from this repo, installs dependencies, and then starts the server. This enables you to do upgrades of this application by simply restarting the container without having to rebuild an entire container for deployment. In a real deployment environment, this would typically clone from a deployment branch where you have known good bits.

Let's see this all work in action. You can launch this container from the command line with:

```
$ sudo docker run -p 8000:8000 timpark/simpleapp
```

The port mapping tells docker that port 8000 on the inside of our container should be exposed on the host as port 8000. In addition, Docker will automatically fetch the container, start it, and the application then should log that it is up and running:

```
simple node.js server started and listening on port: 8000
```

Open up another shell to your Ubuntu instance.  Let's see our container running in docker with 'ps':

```
$ sudo docker ps

CONTAINER ID        IMAGE                      COMMAND                CREATED             STATUS              PORTS                    NAMES
d97f04223df7        timpark/simpleapp:latest   /bin/sh -c ./var/www   4 seconds ago       Up 3 seconds        0.0.0.0:8000->8000/tcp   sleepy_rosalind
```

We can see we have one Docker container running and that it is our timpark/simpleapp container.

Let's hit the endpoint we opened up with 'curl':

```
$ curl localhost:8000
This server has been running for 61501ms.
```

The app we started with Docker responds with the number of milliseconds it has been running.

We can also look at the logs for this Docker container:

```
$ sudo docker logs d97f04223df7

Cloning into 'simple-nodejs-server'...
simple node.js server started and listening on port: 8000
request received, sending 61501
```

Where d97f04223df7 is the container's ID that we obtained above from 'docker ps'.

We can also stop our Docker container with:

```
$ sudo docker stop d97f04223df7
```

That's docker in a nutshell. Let's review what we have done: we have built a Docker container for a node.js application based off of two hierarchically composed base containers and we are able to start exact binary replicas of this application container with Docker.

Let's next see how we can use CoreOS to manage these application containers at scale.

## Deploying applications with CoreOS

Now that we have a Docker image how do we go about deploying it in a production scenario where we have potentially a very large farm of frontend servers?

Enter CoreOS. CoreOS provides the infrastructure for deploying and managing containerized workloads. It is a stripped down Linux distribution that provides OS-as-a-service auto updates for the host OS and rule based container assignment, execution, and lifecycle management based on Systemd. Finally, it also provides the ancillary services that you need to run a distributed service like etcd for service discovery.

### Upload CoreOS VM image to your storage account:

We'll use your POSIX (Mac or Linux) development machine for this section of the quickstart. If you haven't already, install node.js on your development machine, the Azure command line tools, and import your subscription:

```
$ sudo npm install -g azure
$ azure account download
```

We also need to prep a couple of items in the Azure portal before we can get started:

1. Create a storage account in your subscription with a container in "East US". Note the storage account name, container name, and key.
2. Create a virtual network. Call it "coreos-network" and place it in "East US".

Finally let's create SSH keys that we'll use for connecting to your CoreOS cluster machines using the 'generate-keys' script in the ~/keys directory (accept all of the defaults that OpenSSL asks you for):

```
$ cd keys
$ ./generate-keys
```

We now have what we need now from an Azure perspective. Let's next configure our CoreOS cluster.

Change to the ~/cluster directory.

The first thing we need to do is get a discovery token for etcd. 'etcd' is a distributed key-value store built on the Raft protocol and acts as a store for configuration information for CoreOS. Fleet, another part of the CoreOS puzzle, is a low-level init system built on 'etcd' that provides the functionality of Systemd over a distributed cluster.

This discovery token is configured in a set of cloud-init file called coreos-1.yml, coreos-2.yml, and coreos-3.yml. This configures the CoreOS image once it is provisioned by Azure and, in particular, it injects the etcd discovery token into the virtual machine so that it knows which CoreOS cluster it belongs to. Its important to have a new and unique value for this, otherwise your cluster could fail to initialize correctly.

Let's provision a new one for our cluster:

```
$ curl https://discovery.etcd.io/new
```

This will fetch a discovery URL that looks something like https://discovery.etcd.io/e6a84781d11952da545316cb90c9e9ab. Copy this and edit each of the coreos-x.yml files and paste this discovery token into it. Additionally, copy the contents of ~/keys/ssh-authorized.key and add it in the ssh_authorized_keys block. Your final set of cloud-init files should something like this:

```
# coreos cloud-init
#cloud-config
coreos:
    etcd:
        name: coreos-1
    # generate a new token for each unique cluster from https://discovery.etcd.io/new
        discovery: https://discovery.etcd.io/233fad306300e898a38c6c2a9cfe0e3f
    # multi-region and multi-cloud deployments need to use $public_ipv4
        addr: $private_ipv4:4001
        peer-addr: $private_ipv4:7001
    fleet:
        public-ip: $private_ipv4
        metadata: region=us-east
    units:
      - name: etcd.service
        command: start
      - name: fleet.service
        command: start
        after: etcd.service
ssh_authorized_keys:
  - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsk+NkMJrnkIF09Tn3PsDGRic9hAYbyTmy2F4hYmpM1LNmrWAkqZ5diD2V0ak1n3dpk8LtIHEjAG8NFUpMV0tCXyhX9kpY/AEf2q5p1EQUSHFaXDniKfoOJP8kFI4E0hIgobM2UB7l9K/enjVjX8kZ+9UkS9uRN1aLL0lbqIHk/xPOIv+d7fyivnbLi9bjvVvKnG9xbH4rfZcG3hWw6Ptc9JsYLVo3Q0Vm4f0KndXO2fIUwsRHLljKwuE1JOZk4U68TTZn+JCBSnqpkiGl7+Ax0I7sU0t5RIl7hpUbNJtm1n6NyXX/lDs9WqIpn/tF1In45bv2R3nACq+ZTAZe4huj
hostname: coreos-1
```

Ok, we're ready to provision our cluster. The quickstart repo has a script that takes the tedium out of this called 'create-cluster'. We'll first need to create an affinity group for this cluster so the hosts selected for the CoreOS VMs are close to each other:

```
$ azure account affinity-group create coreos-affinity -l "East US" -e "CoreOS App"
```

Next, create a cloud service for this cluster. We are going to assign containers to each of the hosts in this cluster to serve web traffic so we want to load balance incoming requests across them using a cloud service. This cloud service name needs to be unique across all of Azure, so choose a unique one:

```
$ azure service create --affinitygroup coreos-affinity [cloud service name]
```

Finally, edit 'create-cluster' and replace "[cloud service name]" with the cloud service name that you chose.

```
azure vm create \
[cloud service name] \
2b171e93f07c4903bcad35bda10acf22__CoreOS-Alpha-475.1.0 \
ops \
--vm-size small \
--vm-name coreos-1 \
--affinity-group coreos-affinity \
--availability-set coreos-cluster-as \
--ssh 22001 \
--ssh-cert ../keys/ssh-cert.pem \
--no-ssh-password \
--virtual-network-name coreos-network \
--subnet-names coreos \
--custom-data coreos-1.yml

azure vm create \
[cloud service name] \
2b171e93f07c4903bcad35bda10acf22__CoreOS-Alpha-475.1.0 \
ops \
--connect \
--vm-size small \
--vm-name coreos-2 \
--availability-set coreos-cluster-as \
--ssh 22002 \
--ssh-cert ../keys/ssh-cert.pem \
--no-ssh-password \
--virtual-network-name coreos-network \
--subnet-names coreos \
--custom-data coreos-2.yml

azure vm create \
[cloud service name] \
2b171e93f07c4903bcad35bda10acf22__CoreOS-Alpha-475.1.0 \
ops \
--connect \
--availability-set coreos-cluster-as \
--vm-size small \
--vm-name coreos-3 \
--ssh 22003 \
--ssh-cert ../keys/ssh-cert.pem \
--no-ssh-password \
--virtual-network-name coreos-network \
--custom-data coreos-3.yml

azure vm endpoint --lb-set-name http create coreos-1 80 80
azure vm endpoint --lb-set-name http create coreos-2 80 80
azure vm endpoint --lb-set-name http create coreos-3 80 80
```

Then run the script to launch your CoreOS cluster. This will create a three machine cluster and load balance all of them behind the cloud service you created.

```
$ ./create-cluster
```

Let's quickly ssh into the first machine in the cluster and check to make sure everything looks ok:

```
$ ssh ops@[cloud service name].cloudapp.net -p 22001 -i ../keys/ssh-private.key
```

Let's first make sure etcd is up and running:

```
$ sudo etcdctl ls --recursive
/coreos.com
/coreos.com/updateengine
/coreos.com/updateengine/rebootlock
/coreos.com/updateengine/rebootlock/semaphore
```

And that fleetctl knows about all of the members of the cluster:

```
$ sudo fleetctl list-machines
MACHINE     IP      METADATA
36a636af... 10.0.0.4    region=us-east
40078616... 10.0.0.5    region=us-east
f6ebd7d1... 10.0.2.4    region=us-east
```

Ok, so our cluster is working - go ahead and exit the ssh session with it and return to your development machine's shell.

Let's setup our development machine to be able to control the cluster. The CoreOS utility fleetctl allows us to control our cluster so let's install that locally. We do that by cloning the fleet repo (in your development directory), building it, and installing it manually:

```
$ git clone https://github.com/coreos/fleet.git
$ cd fleet
$ ./build
$ cp bin/fleetctl /usr/local/bin
```

CoreOS security works off the principle that if you have the credentials to ssh into the cluster you are also authorized to manage it. The next step is to setup an environment variable so that fleetctl knows to tunnel over ssh to control the cluster. We'll use the first instance in the cluster to tunnel our fleetctl requests.

```
$ export FLEETCTL_TUNNEL=[your cloud service].cloudapp.net:22001
```

You should now be able to use your development machine to control the cluster. Let's list the machines on the cluster to check that it's working:

```
$ fleetctl list-machines
MACHINE     IP      METADATA
36a636af... 10.0.0.4    region=us-east
40078616... 10.0.0.5    region=us-east
f6ebd7d1... 10.0.2.4    region=us-east
```

Success! We have setup our cluster and our development machine locally to control the cluster. The final step is scheduling workloads to run on the cluster. CoreOS uses the Systemd system management daemon to manage workloads on individual cluster machines and extends this concept to scheduling rule based distributed workloads across cluster machines.

The Systemd unit file for our application looks like this:

```
[Unit]
Description=Simple node.js application
After=docker.service
Requires=docker.service

[Service]
ExecStartPre=/usr/bin/docker pull timpark/simpleapp:latest
ExecStart=/usr/bin/docker run --name simpleapp -p 80:8000 timpark/simpleapp
ExecStopPre=/usr/bin/docker kill simpleapp
ExecStop=/usr/bin/docker rm simpleapp
TimeoutStartSec=0
Restart=always
RestartSec=10s

[X-Fleet]
X-Conflicts=simpleapp@*.service
```

This unit file has two functions. First, it tells Systemd how to start and stop this container. In this case, we are using it to download and start up the node.js container we built and pushed to the Docker repository in the first part of this quickstart. Secondly, it tells CoreOS how this workload can be distributed across the cluster. Here, X-Conflicts tells CoreOS that only one instance of this container can be run on a given CoreOS host. We use this to ensure that the containers will be executed such that we get redundancy and load balancing across the cluster.

The fact that this filename ends in @ indicates that it is a unit file template for CoreOS and that it can be applied multiple times. We can use that to spin up three instances of our simple application:

```
$ fleetctl start simpleapp@{1,2,3}.service
Unit simpleapp@2.service launched
Unit simpleapp@3.service launched
Unit simpleapp@1.service launched on 36a636af.../10.0.0.4
```

If we then list our the units running we can see that our simpleapp is now coming online:

```
$ fleetctl list-units
UNIT            MACHINE         ACTIVE      SUB
simpleapp@1.service 36a636af.../10.0.0.4    activating  start-pre
simpleapp@2.service 40078616.../10.0.0.5    activating  start-pre
simpleapp@3.service f6ebd7d1.../10.0.2.4    activating  start-pre
```

The start-pre indicates that our ExecStartPre directive above is being executed, which in our scenario means the cluster member is pulling the Docker container down from the registry.

Trying again roughly a minute later, you should see that each member of our CoreOS cluster has started the Docker container and is up and running.

```
$ fleetctl list-units
UNIT            MACHINE         ACTIVE  SUB
simpleapp@1.service 36a636af.../10.0.0.4    active  running
simpleapp@2.service 40078616.../10.0.0.5    active  running
simpleapp@3.service f6ebd7d1.../10.0.2.4    active  running
```

If we make a request against the web farm, we see that we are routed to one of the instances of our container running in the web farm and get back a count of the number of milliseconds it has been executing:

```
$ curl [your cloud servicename].cloudapp.net
This server has been running for 23443ms.
```

And that's it: we have deployed a node.js application across a three machine frontend cluster using CoreOS and Docker on Microsoft Azure!