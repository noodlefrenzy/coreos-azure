# Deploying Apps on Microsoft Azure with Docker and CoreOS

Docker has swept the industry.
Microsoft is a big fan of containerization.
Containers introduce another level of virtualization.
Multiple containers share the same underlying OS.
More memory efficient but sharing OS adds deployment security considerations.

This tutorial assumes you are running on an Debian-based system like Ubuntu.

I’m going to use a Azure VM running Ubuntu 14.04 LTS for this walkthrough.

## Docker Fundamentals

Before we jump into CoreOS, you should understand the fundamentals of Docker.  This section will run through building a Docker container that houses our node.js application.  If you are familiar with Docker already, you can skim this section and move on to the second section on CoreOS.

### Installing Docker

In your Ubuntu 14.04 VM, run the following:

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

## Starting a CoreOS cluster

REVISE THIS SECTION ONCE IMAGE IS LAUNCHED IN GALLERY --->

Upload CoreOS VM image to your storage account:

First create an image in your subscription based on this blob using the Azure CLI on any machine:

azure vm disk upload --verbose https://coreos.blob.core.windows.net/public/coreos-469.0.0-alpha.vhd http://<your-storage-account>.blob.core.windows.net/<your-container>/coreos-469.0.0-alpha.vhd <your storage key>

Then create a VM image for this VHD:

azure vm image create coreos --location "East US" --blob-url http://<your-storage-account>.blob.core.windows.net/<your-container>/coreos-469.0.0-alpha.vhd --os linux

 <--- END OF BLOCK