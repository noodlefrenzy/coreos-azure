FROM dockerfile/ubuntu
MAINTAINER Tim Park <tim@nitrogen.io>

RUN apt-get install -y python-software-properties --fix-missing
RUN add-apt-repository ppa:chris-lea/node.js
RUN apt-get update
RUN apt-get install -y nodejs

RUN apt-get install -y git

RUN mkdir -p /var/www/api
RUN git clone https://github.com/nitrogenjs/service /var/www/api/service
RUN cd /var/www/api/service && npm install

# add init.d script

ADD nitrogen /etc/init.d/nitrogen
RUN update-rc.d nitrogen defaults

# add new n2 startup script

ADD n2 /var/www/api/n2