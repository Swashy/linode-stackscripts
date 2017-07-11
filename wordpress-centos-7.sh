#!/bin/bash
#
#<UDF name="pubkey" Label="Enter your public key here" default="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC5c8Eyp/+gET8irVN6ck2/eC7jcAaPF7bKJBWbe4w8Df61jwaaBHREH33R65cxOZtC0FRwvOU3uDMyGh+Zqt1Pwab15hmFs98LLZ3ZwPC6GPhIZlAUD78l8ZHV2tW2N4XWBU65Ek3SDOiDg/YHswg2S6lwQ8GlwloNlt9oaydXsZwReJfMqQO6JSj8QN0YdNoeGfC3cipx8H3k3p45dJDtssXu+qlC/lLkpLMuChGG+mMuIGN45Emrb0kEqAfQeGjb5HVN6kg8r0OQi/2YWEauSkFTIy5ghBScEf2C/aveagZASFSdjb5bFT+D/Gm+8IcNYkd5RZaYuxWyK+fExllb"/>
#PUBKEY=
#<UDF name="dbrootpass" Label="A Database root password?"/>
#<UDF name="wpdbpass" Label="A wordpress database password?"/>
#<UDF name="FQDN" Label="The website URL? (e.g. example.com)"/>

#Run a command under the serial tty because apparently CentOS 7 doesn't like the regular tty stackscripts run as
#Simple running a restart or enable command will return an error
#"Error creating textual authentication agent: Error opening current controlling terminal for the process (`/dev/tty')""

use_systemctl() {
	openvt 2
	#pass vars into the bash shell we're making
	setsid sh -c 'exec systemctl $1 $2 <> /dev/tty2 >&0 2>&1' $1 $2
}

set -x
yum update -y && yum install epel-release -y
yum install mlocate php php-mysql php-fpm wget nginx epel-release bzip2 iptables-services bind-utils mariadb mariadb-server php-gd -y

systemctl disable firewalld
systemctl stop firewalld

iptables -N LOGDROP
iptables -A LOGDROP -j LOG
iptables -A LOGDROP -j DROP
iptables -I INPUT -p tcp --dport 22 -i eth0 -m state --state NEW -m recent --set
iptables -I INPUT -p tcp --dport 22 -i eth0 -m state --state NEW -m recent  --update --seconds 60 --hitcount 10 -j LOGDROP

/usr/libexec/iptables/iptables.init save
systemctl enable iptables.service

#If the public key exists....
if ! [ -z "$PUBKEY" ]; then
  cd /root/
  mkdir /root/.ssh
  touch /root/.ssh/authorized_keys
  echo "$PUBKEY" >> /root/.ssh/authorized_keys
  sed -i.bak "/PasswordAuthentication/ s/yes/no/" /etc/ssh/sshd_config
fi
echo "MaxAuthTries 10" >> /etc/ssh/sshd_config
systemctl restart sshd

mkdir -p /srv/www/
cd /srv/www/

#-4, force ipv4
#-t, number of retries if fail
#-S, print server response for debugging
#-P, directory prefix
wget -4 -w3 -t5 -S -P /srv/www/ https://wordpress.org/latest.tar.gz
tar -xzvf latest.tar.gz
useradd wordpress -d /srv/www/wordpress/
chown -R nginx: /srv/www/

systemctl start mariadb
systemctl enable mariadb
systemctl start nginx
systemctl enable nginx

sed -i.bak "/;cgi.fix_pathinfo=1/ s/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/" /etc/php.ini
sed -i.bak "/127.0.0.1:9000/ s/127.0.0.1:9000/\/var\/run\/php-fpm\/php-fpm.sock/" /etc/php-fpm.d/www.conf
sed -i.bak "/;listen.owner/ s/;listen.owner/listen.owner/" /etc/php-fpm.d/www.conf
sed -i.bak "/;listen.group/ s/;listen.group/listen.group/" /etc/php-fpm.d/www.conf
sed -i.bak "s/apache/nginx/" /etc/php-fpm.d/www.conf

systemctl start php-fpm
systemctl enable php-fpm

mysqladmin password "$DBROOTPASS"
echo -e "[client]\nuser=root\npassword=" > ~/.my.cnf
sed -i.bak "s/password=/password=$DBROOTPASS/g" ~/.my.cnf
chmod 400 ~/.my.cnf
#Running mysql_secure_installation myself
mysql --defaults-file=~/.my.cnf -e "DELETE FROM mysql.user WHERE User=''"
mysql --defaults-file=~/.my.cnf -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql --defaults-file=~/.my.cnf -e "DROP DATABASE test;"
mysql --defaults-file=~/.my.cnf -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';"
mysql --defaults-file=~/.my.cnf -e "CREATE DATABASE wordpress;"
mysql --defaults-file=~/.my.cnf -e "CREATE USER wordpress@localhost IDENTIFIED BY 'wordpress@';"
mysql --defaults-file=~/.my.cnf -e "grant all privileges on wordpress.* to wordpress@localhost identified by 'wordpress@';"
mysql --defaults-file=~/.my.cnf -e "FLUSH PRIVILEGES;"

wpsalts=$(wget -qO- https://api.wordpress.org/secret-key/1.1/salt)

mkdir -p /srv/www/wp-secure.d/
touch /srv/www/wp-secure.d/wp-config.php
cat > /srv/www/wp-secure.d/wp-config.php <<__FILE__
<?php
/**
 * The base configuration for WordPress
 *
 * The wp-config.php creation script uses this file during the
 * installation. You don't have to use the web site, you can
 * copy this file to "wp-config.php" and fill in the values.
 *
 * This file contains the following configurations:
 *
 * * MySQL settings
 * * Secret keys
 * * Database table prefix
 * * ABSPATH
 *
 * @link https://codex.wordpress.org/Editing_wp-config.php
 *
 * @package WordPress
 */
// ** MySQL settings - You can get this info from your web host ** //
/** The name of the database for WordPress */
define('DB_NAME', 'wordpress');
/** MySQL database username */
define('DB_USER', 'wordpress');
/** MySQL database password */
define('DB_PASSWORD', '$WPDBPASS);
/** MySQL hostname */
define('DB_HOST', 'localhost');
/** Database Charset to use in creating database tables. */
define('DB_CHARSET', 'utf8');
/** The Database Collate type. Don't change this if in doubt. */
define('DB_COLLATE', '');
/**#@+
 * Authentication Unique Keys and Salts.
 *
 * Change these to different unique phrases!
 * You can generate these using the {@link https://api.wordpress.org/secret-key/1.1/salt/ WordPress.org secret-key service}
 * You can change these at any point in time to invalidate all existing cookies. This will force all users to have to log in again.
 *
 * @since 2.6.0
 */
$wpsalts
/**#@-*/
/**
 * WordPress Database Table prefix.
 *
 * You can have multiple installations in one database if you give each
 * a unique prefix. Only numbers, letters, and underscores please!
 */
/* \$table_prefix  = 'wp_'; */
/**
 * For developers: WordPress debugging mode.
 *
 * Change this to true to enable the display of notices during development.
 * It is strongly recommended that plugin and theme developers use WP_DEBUG
 * in their development environments.
 *
 * For information on other constants that can be used for debugging,
 * visit the Codex.
 *
 * @link https://codex.wordpress.org/Debugging_in_WordPress
 */
define('WP_DEBUG', false);
/* That's all, stop editing! Happy blogging. */
/** Absolute path to the WordPress directory. */
if ( !defined('ABSPATH') )
	define('ABSPATH', dirname(__FILE__) . '/');
/** Sets up WordPress vars and included files. */
require_once(ABSPATH . 'wp-settings.php');
__FILE__

<?php

cat > /srv/www/wordpress/wp-config.php <<__FILE__
/** Absolute path to the WordPress directory. */
if ( !defined('ABSPATH') )
    define('ABSPATH', dirname(__FILE__) . '/');
/** Location of your WordPress configuration. */
require_once(ABSPATH . '../wp-secure.d/wp-config.php');
__FILE__


cat > /etc/nginx/conf.d/default.conf <<__FILE__
server {
    listen       80;
    server_name  $FQDN;
    # note that these lines are originally from the "location /" block
    root   /usr/share/nginx/html;
    index index.php index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:/var/run/php-fpm/php-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
}
__FILE__

systemctl restart nginx

set +x