# Zulip Docker image overview

[![](https://images.microbadger.com/badges/image/zulip/docker-zulip.svg)](https://microbadger.com/images/zulip/docker-zulip "Get your own image badge on microbadger.com") [![**docker-zulip** stream](https://img.shields.io/badge/zulip-join_chat-brightgreen.svg)](https://chat.zulip.org/#narrow/stream/backend/topic/docker)

`docker-zulip` is the official Docker container image for running a
[Zulip server](https://zulip.com) in
[production][prod-overview]. Built images are available from: [Docker
Hub](https://hub.docker.com/r/zulip/docker-zulip):

```console
$ docker pull zulip/docker-zulip:9.4-0
```

Current Zulip version: `9.4`
Current Docker image version: `9.4-0`

We recommend using the Docker image if your organization has a
preference for deploying services using Docker. Deploying with Docker
moderately increases the effort required to install, maintain, and
upgrade a Zulip installation, compared with the [standard Zulip
installer][normal-install].

[normal-install]: https://zulip.readthedocs.io/en/latest/production/install.html
[zulip-architecture]: https://zulip.readthedocs.io/en/latest/overview/architecture-overview.html

## Prerequisites

To use `docker-zulip`, you need the following:

- An installation of [Docker][install-docker] and
  [Docker Compose][install-docker-compose] or a Kubernetes runtime
  engine.
- We [recommend at least 2GB of available RAM][prod-requirements] for
  running a production Zulip server; you'll want 4GB if you're
  building the container (rather than using the pre-built images). If
  you're just testing and/or aren't expecting a lot of users/messages,
  you can get away with significantly less especially for the
  `postgres`, `memcached`, etc. containers, because Docker makes it
  easy to sharply limit the RAM allocated to the services Zulip
  depends on, like Redis, memcached, and PostgreSQL (at the cost of
  potential performance issues).
- This project doesn't support `docker-rootless`; Zulip needs root
  access to set properties like the maximum number of open file
  descriptions via `ulimit` (which is important for it to handle
  thousands of connected clients).

If you aren't already a Docker expert, we recommend starting by
reading our brief overview of how Docker and containers work in the
next section for important background that the rest of this
documentation will assume.

Otherwise, you can jump to our documentation for your preferred
container runtime:

- [Docker Compose](#running-a-zulip-server-with-docker-compose)
- [Kubernetes](#running-a-zulip-server-with-kubernetes)

[install-docker]: https://docs.docker.com/install/
[install-docker-compose]: https://docs.docker.com/compose/install/
[prod-overview]: https://zulip.readthedocs.io/en/latest/production/overview.html
[prod-requirements]: https://zulip.readthedocs.io/en/latest/production/requirements.html

## The Docker data storage model

Docker and other container systems are built around shareable
container images. An image is a read-only template with instructions
for creating a container.

Often, an image is based on another image, with a bit of additional
customization. For example, Zulip's `zulip-postgresql` image extends
the standard `postgresql` image (by installing a couple `postgres`
extensions). Meanwhile, the `zulip` image is built on top of a
standard `ubuntu` image, adding all the code for a Zulip
application/web server.

Every time you boot a container based on a given image, it's like
booting off a CD-ROM: you get the exact same image (and anything
written to the image's filesystem is lost). To handle persistent
state that needs to persist after the Docker equivalent of a reboot or
upgrades (like uploaded files or the Zulip database), container
systems let you configure certain directories inside the container
from the host.

This project's `docker-compose.yml` configuration file uses [Docker
managed volumes][volumes] to store [persistent Zulip
data][persistent-data]. If you use the Docker Compose deployment, you
should make sure that Zulip's volumes are backed up, to ensure that
Zulip's data is backed up.

This project defines a Docker image for a Zulip server, as well as
sample configuration to run that Zulip server with each of the major
[services that Zulip uses][zulip-architecture] in its own container:
`redis`, `postgres`, `rabbitmq`, `memcached`.

[volumes]: https://docs.docker.com/storage/volumes/
[persistent-data]: https://zulip.readthedocs.io/en/latest/production/export-and-import.html#backups

## Running a Zulip server with docker-compose

To use this project, we recommend starting by cloning the repository (since
you'll want to edit the `docker-compose.yml` file in this project):

```
git clone https://github.com/zulip/docker-zulip.git
cd docker-zulip
# Edit `docker-compose.yml` to configure; see docs below
```

If you're in hurry to try Zulip, you can skip to [start the Zulip
server](#starting-the-server), but for production use, you'll need to
generate secrets and do some configuration.

### Configuration

With `docker-compose`, it is traditional to configure a service by
setting environment variables declared in the `zulip -> environment`
section of the `docker-compose.yml` file; this image follows that
convention.

**Mandatory settings**. You must configure these settings (more
discussion in the main [Zulip installation docs][install-normal]):

- `SETTING_EXTERNAL_HOST`: The hostname your users will use to
  connect to your Zulip server. If you're testing on your laptop,
  the default of `localhost.localdomain` is great.
  Note that it needs to contain a top level domain to work, e.g.
 `mycomputer.lan`.
- `SETTING_ZULIP_ADMINISTRATOR`: The email address to receive error
  and support emails generated by the Zulip server and its users.

**Mandatory settings for production use**. Before you allow production
traffic, you need to generate secrets. We recommend using long random
strings of alphanumeric characters for your secrets; not every special
character works.

- `POSTGRES_PASSWORD` is the password for the PostgreSQL
  instance. `SECRETS_postgres_password` configures the Zulip server to
  know the PostgreSQL password. While `SECRETS_postgres_password` is
  synced to the Zulip container on every boot, `POSTGRES_PASSWORD` is
  only accessed by the PostgreSQL container on first boot, so if you
  later want to change your PostgreSQL password after booting the
  container, you'll need to either do an [ALTER
  ROLE][postgres-alter-role] query inside the `postgres` container or
  rebuild the PostgreSQL database (only if you don't need your data!).
- `RABBITMQ_DEFAULT_PASS` and `SECRETS_rabbitmq_password` are similar,
  just for the RabbitMQ container.
- `MEMCACHED_PASSWORD` and `SECRETS_memcached_password` are similar,
  just for the memcached container.
- `REDIS_PASSWORD` and `SECRETS_redis_password` are similar, just for
  the Redis container.
- `SECRETS_secret_key` should be a long (e.g. 50 characters), random
  string. This value is important to keep secret and constant over
  time, since it is used to (among other things) sign login cookies
  (so if you change this, all your users will be forcibly logged out).
- `SETTING_EMAIL_*`: Where you configure Zulip's ability to send
  [outgoing email][outgoing-email].

[postgres-alter-role]: https://www.postgresql.org/docs/9.3/static/sql-alterrole.html

**Other settings**. If an environment variable name doesn't start with
`SETTING` or `SECRETS` in `docker-compose.yml`, it is specific to the
Docker environment. Standard [Zulip server settings][server-settings]
are secrets are set using the following syntax:

- `SETTING_MY_SETTING` will become `MY_SETTING` in
  `/etc/zulip/settings.py`
- `SECRETS_my_secret` will become `my_secret` in
  `/etc/zulip/zulip-secrets.conf`.

Reading the comments in the sample
[Zulip's settings.py file][prod-settings-template] is the best way to
learn about the full set of Zulip's supported server-level settings.

Most settings in Zulip are just strings, but some are lists (etc.)
which you need to encode in the YAML file. For example,

- For `AUTHENTICATION_BACKENDS`, you enter `ZULIP_AUTH_BACKENDS` as a
  comma-separated list of the backend names
  (E.g. `"EmailAuthBackend,GitHubAuthBackend"`).

- LDAP authentication currently requires
  [`MANUAL_CONFIGURATION`](#manual-configuration) in order to encode
  the `LDAPSearch` logic, see below.

**Reducing RAM usage**. By default, the Zulip server automatically detect
whether the system has enough memory to run Zulip queue processors in the
higher-throughput but more multiprocess mode (or to save 1.5GiB of RAM with
the multi-threaded mode). This algorithm might see the host's memory, not the
docker container's memory. Set to `QUEUE_WORKERS_MULTIPROCESS` to `true` or
`false` to override the automatic calculation.

**SSL Certificates**. By default, the image will generate a self-signed certificate.
You can set `SSL_CERTIFICATE_GENERATION: "certbot"` within `docker-compose.yml`
to enable automatically-renewed Let's Encrypt certificates. By using certbot
here, you are agreeing to the [Let's Encrypt
ToS](https://community.letsencrypt.org/tos).

You can also provide an SSL certificate for your Zulip server by
putting it in `/opt/docker/zulip/zulip/certs/` (by default, the
`zulip` container startup script will generate a self-signed certificate and
install it in that directory).

**Reverse proxies**. To tell Zulip that it is behind a reverse proxy
or load balancer, you must set `LOADBALANCER_IPS` to a comma-separated
list of IPs or CIDR ranges. This will tell Zulip to pass the real IP
of the client, instead of the IP of the proxy itself, by [setting the
IPs][loadbalancer-ips] under `[loadbalancer]` in `zulip.conf`.

Your proxy must provide both `X-Forwarded-For` and
`X-Forwarded-Proto` headers. See the Zulip documentation for sample
[nginx][nginx-proxy], [Apache2][apache2-proxy], and
[HAProxy][haproxy-proxy] configurations, as well as notes for [other
proxies][other-proxy].

[loadbalancer-ips]: https://zulip.readthedocs.io/en/latest/production/reverse-proxies.html#configuring-zulip-to-trust-proxies
[nginx-proxy]: https://zulip.readthedocs.io/en/latest/production/reverse-proxies.html#nginx-configuration
[apache2-proxy]: https://zulip.readthedocs.io/en/latest/production/reverse-proxies.html#apache2-configuration
[haproxy-proxy]: https://zulip.readthedocs.io/en/latest/production/reverse-proxies.html#haproxy-configuration
[other-proxy]: https://zulip.readthedocs.io/en/latest/production/reverse-proxies.html#other-proxies

### Manual configuration

The way the environment variables configuration process described in
the last section works is that the `entrypoint.sh` script that runs
when the Docker image starts up will generate a
[Zulip settings.py file][server-settings] file based on your settings
every time you boot the container. This is convenient, in that you
only need to edit the `docker-compose.yml` file to configure your
Zulip server's settings.

An alternative approach is to set `MANUAL_CONFIGURATION: "True"` and
`LINK_SETTINGS_TO_DATA: "True"` in `docker-compose.yml`. If you do that, you
can provide a `settings.py` file and a `zulip-secrets.conf` file in
`/opt/docker/zulip/zulip/settings/etc-zulip/`, and the container will use those.

### Starting the server

You can boot your Zulip installation with:

```
docker-compose pull
docker-compose up
```

This will boot the 5 containers declared in `docker-compose.yml`. The
`docker-compose` command will print a bunch of output, and then
eventually hang once everything is happily booted, usually ending with
a bunch of lines like this:

```
rabbitmq_1   | =INFO REPORT==== 27-May-2018::23:26:58 ===
rabbitmq_1   | accepting AMQP connection <0.534.0> (172.18.0.3:49504
-> 172.18.0.5:5672)
```

You can inspect what containers are running in another shell with
`docker-compose ps` (remember to `cd` into the `docker-zulip`
directory first).

If you hit `Ctrl-C`, that will stop your Zulip server cluster. If
you'd prefer to have the containers run in the background, you can use
`docker-compose up -d`.

If you want to build the Zulip image yourself, you can do that by
running `docker-compose build`; see also
[the documentation on building a custom Git version version](UPGRADING.md#upgrading-from-a-git-repository).

### Connecting to your Zulip server

You can now connect to your Zulip server. For example, if you set
this up on a laptop with the default port mappings and
`SETTING_EXTERNAL_HOST`, typing `http://localhost/` will take you to
your server. Note that in this default scenario, (1) you'll have to
proceed past a self-signed SSL error, and (2) you won't be able to
login until you create an organization, but visiting the URL is a good
way to confirm that your networking configuration is working
correctly.

### Creating your organization

You can now follow the normal Zulip installer instructions for how to
[create a Zulip organization and log in][create-organization] to your
new Zulip server. You'll generate the realm creation link as follows:

```bash
docker-compose exec -u zulip zulip \
    "/home/zulip/deployments/current/manage.py generate_realm_creation_link"
```

But don't forget to review the [getting started][next-steps] links at
the end of the main installation guide.

[next-steps]: https://zulip.readthedocs.io/en/latest/production/install.html#getting-started-with-zulip

### Running management commands

From time to time, you'll need to attach a shell to the Zulip
container so that you can run `manage.py` commands, check logs, etc.
The following are helpful examples:

```bash
# Get a (root) shell in the container so you can access logs
docker-compose exec zulip bash
# Run a Zulip management command
docker-compose exec -u zulip zulip \
    "/home/zulip/deployments/current/manage.py list_realms"
```

Since that process for running management commands is a pain, we recommend
[using a wrapper script][wrapper-tool] for running management commands.

[wrapper-tool]: https://github.com/zulip/docker-zulip/wiki/Running-Management-Commands

### Using a custom certificate bundle for outgoing HTTP connections

If you are sitting behind a custom CA and want to build the Zulip
image yourself, special care is required.

The Zulip build process installs packages via `yarn` and `pip`, and
these need packages to be configured to use your custom CA
certificates. You will need to get your certificate bundle into the
docker image, either by adding a `COPY` somewhere or by replacing the
`FROM`s with a custom Ubuntu image that includes your bundle. The
recommended way is to have your own base image which has your bundle
ready at the default `/etc/ssl/certs/ca-certificates.crt`.

The next and last step is to set up the `CUSTOM_CA_CERTIFICATES`
argument in `docker-compose.yml` to point to your CA bundle, e.g.
to `/etc/ssl/certs/ca-certificates.crt`.

At this point you are ready to build Zulip.

### Upgrading

See the [separate upgrading document](UPGRADING.md) for upgrading
instructions.

## Running a Zulip server with Kubernetes

A Kubernetes pod file is in the `kubernetes/` folder; you can run it
with `kubectl create -f ./kubernetes/`.

You should read the `docker-compose` section above to understand how
this works, since it's a very similar setup. You'll want to clone
this repository, edit the `zulip-rc.yml` to configure the image, etc.

### Installing minikube for testing

The fastest way to get Kubernetes up and running for testing without
signing up for a cloud service is to install
[Minikube][install-minikube] on your system.

[install-minikube]: https://kubernetes.io/docs/tasks/tools/install-minikube/

### Helm charts

Read the [Helm Chart README](kubernetes/chart/zulip/README.md) to learn more
about installing Zulip on a Kubernetes cluster with Helm.

Feedback is welcome in the [helm-chart-thread]:
https://chat.zulip.org/#narrow/stream/21-provision-help/subject/K8.20and.20Helm/near/589098

### Scaling out and high availability

This image is not designed to make it easy to run multiple copies of
the `zulip` application server container (and you need to know a lot
about Zulip to do this sort of thing successfully). If you're
interested in running a high-availability Zulip installation, your best
bet is to get in touch with the Zulip team at `sales@zulip.com`.

## Networking and reverse proxy configuration

When running your container in production, you may want to put your
Zulip container behind an HTTP proxy.
[This wiki page][proxy-wiki-page] documents how to do this correctly
with `nginx`.

See also the
[Zulip documentation on reverse proxies][reverse-proxy-docs]

[proxy-wiki-page]: https://github.com/zulip/docker-zulip/wiki/Proxying-via-nginx-on-host-machine
[reverse-proxy-docs]: https://zulip.readthedocs.io/en/latest/production/reverse-proxies.html#reverse-proxies

By default, Zulip will only interact with user traffic over HTTPS.
However, if your networking environment is such that the Zulip server
is behind a load balancer and you need the Zulip server to respond
over HTTP, you can configure that via setting `DISABLE_HTTPS: "True"`
in the Docker environment (`docker-compose.yml`).

## Troubleshooting

Common issues include:

- Invalid configuration resulting in the `zulip` container not
  starting; check `docker-compose ps` to see if it started, and then
  read the logs for the Zulip container to see why it failed.
- A new Zulip setting not being passed through the Docker
  [entrypoint.sh script](/entrypoint.sh) properly. If you
  run into this sort of problem you can work around it by specifying a
  `ZULIP_CUSTOM_SETTINGS` with one setting per line below, but please
  report an issue so that we can fix this for everyone else.

## Community support

You can get community support and tell the developers about your
experiences using this project on
[#production-help](https://chat.zulip.org/#narrow/stream/31-production-help) on
[chat.zulip.org](https://chat.zulip.org/), the Zulip community server.

In late May 2018, we completed a complete rewrite of this project's
documentation, so we'd love any and all feedback!

## Contributing

We love community contributions, and respond quickly to issues and
PRs. Some particularly useful ways to contribute right now are:

- Contribute to this documentation by opening issues about what
  confused you or submitting pull requests!
- Reporting bugs or rough edges!

## Credits

Huge thanks to everyone who has contributed. Special thanks to
[Alexander Trost](http://github.com/galexrt/), who created
`docker-zulip` and did a huge amount of the early work required to
make a high-quality Docker image for Zulip possible.

[install-normal]: https://zulip.readthedocs.io/en/latest/production/install.html#installer-options
[outgoing-email]: https://zulip.readthedocs.io/en/latest/production/email.html
[server-settings]: https://zulip.readthedocs.io/en/latest/production/settings.html
[prod-settings-template]: https://github.com/zulip/zulip/blob/master/zproject/prod_settings_template.py
[create-organization]: http://zulip.readthedocs.io/en/latest/production/install.html#step-3-create-a-zulip-organization-and-log-in
