cd /var/www

# remove repo if it already exists
rm -rf simple-nodejs-server; true

# install latest nodejs server
git clone http://github.com/timfpark/simple-nodejs-server simple-nodejs-server
cd simple-nodejs-server
npm install

node server.js
