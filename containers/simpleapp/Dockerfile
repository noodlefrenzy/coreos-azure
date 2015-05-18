FROM noodlefrenzy/nodejs
MAINTAINER Michael Lanzetta <milanz@microsoft.com>

RUN mkdir /var/www
ADD start.sh /var/www/
RUN chmod +x /var/www/start.sh
CMD ./var/www/start.sh
