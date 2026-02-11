CREATE ROLE k3s
  WITH LOGIN
  PASSWORD 'STRONG_PASSWORD_HERE'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOINHERIT;

CREATE DATABASE k3s_production
  OWNER k3s
  TEMPLATE template0
  ENCODING 'UTF8';

\c k3s_production

ALTER SCHEMA public OWNER TO k3s;
GRANT ALL ON SCHEMA public TO k3s;

// Remember to change password when run this script in production database