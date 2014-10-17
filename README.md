# Deploying Apps with Docker and CoreOS on Microsoft Azure

This quickstart repo provides everything you need to go from nothing to deploying a scaled node.js application using Docker and CoreOS on Microsoft Azure.

This quickstart assumes you are running on an Debian-based system like Ubuntu. I’m going to use a Azure VM running Ubuntu 14.04 LTS for this walkthrough, so if you don't have a native Ubuntu machine, go ahead now and spin up a small (A1) Azure VM.

## Docker Fundamentals

Before we jump into CoreOS, you should understand the fundamentals of Docker. This section will run through building a Docker container that houses our node.js application.  If you are familiar with Docker already, you can skim this section and move on to the second section ( "Deploying applications with CoreOS").

Docker provides an easy to use mechanism for building containerized cloud workloads. Containers introduce another level of virtualization between a VM and bare metal. Containers share the same underlying OS but utilize a facilility of the OS (LXC in Linux) to run concurrently with other containers on that host. This has memory efficiency benefits at the expense of losing some of the security isolation benefits of full VMs. If this concept is new to you, I'd recommend reading more on the [Docker website](https://www.docker.com/whatisdocker/) before continuing.

### Installing Docker and this sample repo

On your Ubuntu instance, run the following to install Docker if you haven't already:

```
$ sudo apt-get update
$ sudo apt-get install docker.io
$ sudo ln -sf /usr/bin/docker.io /usr/local/bin/docker
$ sudo sed -i '$acomplete -F _docker docker' /etc/bash_completion.d/docker.io
```

With Docker installed, clone this repo into your Ubuntu box:

```
$ git clone http://github.com/timfpark/coreos-azure coreos-azure
```

Docker works off the of the priniciple of layered containers.  This enables you to build containers on top of more general containers that you can independently maintain.

This sample has three Docker specifications for ubuntu, nodejs, and the sampleapp we are going to ultimately going to run and deploy.

### Building a base Ubuntu container

Let's start by looking at the ubuntu specification in ~/coreos-azure/containers/ubuntu/Dockerfile

The specification is incredibly simple:

```
FROM ubuntu:14.04
MAINTAINER Tim Park <tpark@microsoft.com>

RUN sudo apt-get update
RUN sudo apt-get install -y git
```

The first line indicates that this container should start from a stock image of Ubuntu 14.04 and then adds in the 'git' package that we very frequently use in our downstream containers.

We'll use this as the base image for the rest of our containers.  The advantage of this approach is that we can later come back to this Dockerfile and add additional installation or configuration steps and cleanly rebuild all of our downstream containers that depend on this Dockerfile.

We can then build this Docker container using:

```
$ sudo docker build --rm -t 'timpark/ubuntu' .
```

Normally, you'd also push this container to the a Docker registry:

```
$ sudo docker push timpark/ubuntu
```

You won't be able to do this because timpark is my namespace, but this is the workflow when you go to do this for real.

### Building a node.js base image

Let's next look at the first of these dependent containers in ~/coreos-azure/containers/nodejs:

```
FROM timpark/ubuntu
MAINTAINER Tim Park <tpark@microsoft.com>

RUN sudo apt-get install -y software-properties-common python-software-properties
RUN sudo add-apt-repository ppa:chris-lea/node.js
RUN sudo apt-get update
RUN sudo apt-get install -y nodejs
RUN sudo npm install npm -g
```

This starts with the timpark/ubuntu container that we built in the last section and layers on a set of run steps that installs node.js and updates npm to the latest version.

This leaves us with a container that we can use as the base for any nodejs application.

### Building our application container

The final step in our progression is to build a container that hosts our actual application.

We're going to use the world's simplest node.js application to demonstrate this: it simply prints out the number of seconds it has been running in response to any request.  This application is available at https://github.com/timfpark/simple-nodejs-server

The Dockerfile for our application looks like this:

```
FROM timpark/nodejs
MAINTAINER Tim Park <tpark@microsoft.com>

RUN mkdir /var/www
ADD start.sh /var/www/
RUN chmod +x /var/www/start.sh
CMD ./var/www/start.sh
```

This takes our node.js container that we built in the previous section, creates an application directory in /var/www, adds the local script start.sh to that directory, and makes it executable.  Finally, it tells docker that it should run this script at startup.

This start.sh script looks like this:

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

This script manages the application lifecycle for the application.  At boot it deletes the old copy (if any) from the application directory, clones the latest version from this repo, installs dependencies, and then fires it up. This enables you to do upgrades of this application by simply restarting the container and not having to rebuild an entire container for deployment.

Let's see this all work in action. You can launch this container from the command line with:

```
$ sudo docker run -p 8000:8000 timpark/simpleapp
```

The port mapping tells docker that port 8000 on the inside of our container should be exposed on the host as port 8000. In addition, Docker will automatically fetch the container, start it, and the application then should log that it is up and running:

```
simple node.js server started and listening on port: 8000
```

Open up another shell to this instance.  Let's see our container running in docker with 'ps':

```
$ sudo docker ps

CONTAINER ID        IMAGE                      COMMAND                CREATED             STATUS              PORTS                    NAMES
d97f04223df7        timpark/simpleapp:latest   /bin/sh -c ./var/www   4 seconds ago       Up 3 seconds        0.0.0.0:8000->8000/tcp   sleepy_rosalind
```

We can see we have one Docker container running and that it is our timpark/simpleapp container.

Let's hit the endpoint we opened up with 'curl':

```
$ curl localhost:8000

61501
```

The app we started with Docker responds with the number of milliseconds since it was started.

We can also look at the logs for this Docker container:

```
$ sudo docker logs d97f04223df7

Cloning into 'simple-nodejs-server'...
simple node.js server started and listening on port: 8000
request received, sending 61501
```

Where d97f04223df7 is the container's ID that we obtained from 'docker ps' above.

And we can stop our Docker container with:

```
$ sudo docker stop d97f04223df7
```

Let's review what we have done in this first section.  We have built a Docker container for a node.js application based on two hierarchy base containers and we are able to start exact binary replicas of this application with Docker.

Let's next see how we can use CoreOS to manage these application containers at scale.

## Deploying applications with CoreOS

Now that we have a Docker image how do we go about deploying it?

Enter CoreOS

CoreOS provides instructure for deploying containers at scale.
* Stripped down Linux distribution
* Self updating Linux distribution based off of the technology behind Chromium.
* Cluster management of container hosts.
* Rule based container assignment to hosts.
* Service discovery of where services are running on the cluster.

### Upload CoreOS VM image to your storage account:

If you haven't yet, install node.js on your development machine, the Azure command line tools, and import your subscription:

```
$ sudo npm install -g azure
$ azure account download
```

(revise this when CoreOS image is available in the VM gallery)

Next, we need to do a couple of prep items in the Azure portal before we can get started:

1. Create a storage account in your subscription with a container. Note the storage account name, container name, and key.
2. Create a virtual network. Call it "coreos-network" and place it in "East US".

Now upload the CoreOS disk image to your subscription using the Azure command line tools:

```
$ azure vm disk upload --verbose https://coreos.blob.core.windows.net/public/coreos-469.0.0-alpha.vhd http://<your-storage-account>.blob.core.windows.net/<your-container>/coreos-469.0.0-alpha.vhd <your storage key>
```

And create a VM image for this VHD:

```
$ azure vm image create coreos --location "East US" --blob-url http://<your-storage-account>.blob.core.windows.net/<your-container>/coreos-469.0.0-alpha.vhd --os linux
```

Create SSH keys that we'll use for connecting to your CoreOS cluster machines. There is a script in the keys directory to do this for you. Accept all of the defaults that openssl asks you for.

```
$ cd keys
$ ./generate-keys
```

Ok, we have what we need now from an Azure perspective. Let's now configure our CoreOS cluster.

Change to the ~/environments/dev directory.

The first thing we are going to do is get a discovery token for etcd. 'etcd' is a distributed key-value store built on the Raft protocol and acts as a store for configuration information for CoreOS. Fleet, another part of the CoreOS puzzle, is a low-level init system built on 'etcd' that provides the functionality of Systemd over a distributed cluster.

This discovery token is configured in a set of cloud-init file called coreos-1.yml, coreos-2.yml, and coreos-3.yml. This configures the CoreOS image once it is provisioned by Azure and, in particular, it injects the etcd discovery token into the virtual machine so that it knows which CoreOS cluster it belongs to. Let's provision a new one for our cluster:

```
$ curl https://discovery.etcd.io/new
```

This will fetch a discovery URL that looks something like https://discovery.etcd.io/e6a84781d11952da545316cb90c9e9ab. Copy this and edit coreos.yml and paste this into the cloud-init like this:

```
# coreos cloud-init

coreos:
    etcd:
        # generate a new token for each unique cluster from https://discovery.etcd.io/new
        discovery: https://discovery.etcd.io/e6a84781d11952da545316cb90c9e9ab

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
```

Ok, we're ready to provision our cluster. The quickstart repo has a script that makes this easier for you (create-cluster). We'll first need to create an affinity group for this cluster so the hosts selected for the CoreOS VMs are close to each other:

```
$ azure account affinity-group create coreos-affinity -l "East US" -e "CoreOS App"
```

Next, create a cloud service for this cluster. We are going to assign containers to each of the hosts in this cluster to serve web traffic so we want to load balancing incoming requests across them using a cloud service. This cloud service name needs to be unique across all of Azure, so choose a unique one for your cloud service:

```
$ azure service create --affinitygroup coreos-affinity [cloud service name]
```

And then edit create-cluster and replace "[cloud service name]" with the cloud service name that you chose.

azure vm create \
[cloud service name] \
coreos \
ops \
--vm-size small \
--vm-name coreos-1 \
--affinity-group coreos-affinity \
--availability-set coreos-cluster-as \
--ssh 22001 \
--ssh-cert ../../keys/ssh-cert.pem \
--no-ssh-password \
--virtual-network-name coreos-network \
--custom-data coreos-1.yml

azure vm create \
[cloud service name] \
coreos \
ops \
--connect \
--vm-size small \
--vm-name coreos-2 \
--affinity-group coreos-affinity \
--availability-set coreos-cluster-as \
--ssh 22002 \
--ssh-cert ../../keys/ssh-cert.pem \
--no-ssh-password \
--virtual-network-name coreos-network \
--custom-data coreos-2.yml

azure vm create \
[cloud service name] \
coreos \
ops \
--connect \
--vm-size small \
--vm-name coreos-3 \
--affinity-group coreos-affinity \
--availability-set coreos-cluster-as \
--ssh 22002 \
--ssh-cert ../../keys/ssh-cert.pem \
--no-ssh-password \
--virtual-network-name coreos-network \
--custom-data coreos-3.yml

```
$ ./create-cluster
```

We should have a running CoreOS cluster now. Let's quickly ssh into the first machine in the cluster and check to make sure everything looks ok:

```
$ ssh ops@[cloud service name].cloudapp.net -p 22001 -i ../../keys/ssh-private.key
```

Let's first make sure etcd is up and running:

```
$ sudo etcdctl ls --recursive
```

TODO: The expected output

And that fleetctl knows about all of the members of the cluster:

```
$ sudo fleetctl list-machines
```

TODO: The expected output

Exit the ssh session to the cluster. Let's setup our development machine to be able to control the cluster. The first thing we need to do install fleetctl locally. We do that by cloning the fleet repo (in another directory), building it locally, and installing it manually:

```
$ git clone https://github.com/coreos/fleet.git
$ cd fleet
$ ./build
$ cp bin/fleetctl /usr/local/bin
```

CoreOS security works off the principle that if you have the credentials to ssh into the cluster you are also authorized to manage it. fleetctl is the most frequently used tool for managing our cluster so let's set an environment variable so that fleetctl knows to tunnel over ssh to control the cluster.

```
$ export FLEETCTL_TUNNEL=[your cloud service name].cloudapp.net:2222
```

Now you should be able to use your development machine to control the cluster. Let's list the units on the cluster:

```
$ fleetctl list-units
```

TODO: The expected output

Ok, so we have setup our cluster, and our development machine locally to control the cluster. Let's next schedule a unit on the cluster for execution. A unit is a