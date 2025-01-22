#!/bin/bash

if [ "$DEBUG" = "true" ] || [ "$DEBUG" = "True" ]; then
    set -x
    set -o functrace
fi
set -e
shopt -s extglob

# DB aka Database
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_HOST_PORT="${DB_HOST_PORT:-5432}"
DB_NAME="${DB_NAME:-zulip}"
DB_USER="${DB_USER:-zulip}"
REMOTE_POSTGRES_SSLMODE="${REMOTE_POSTGRES_SSLMODE:-prefer}"
# RabbitMQ
SETTING_RABBITMQ_HOST="${SETTING_RABBITMQ_HOST:-127.0.0.1}"
SETTING_RABBITMQ_USER="${SETTING_RABBITMQ_USER:-zulip}"
export RABBITMQ_NODE="$SETTING_RABBITMQ_HOST"
# Redis
SETTING_RATE_LIMITING="${SETTING_RATE_LIMITING:-True}"
SETTING_REDIS_HOST="${SETTING_REDIS_HOST:-127.0.0.1}"
SETTING_REDIS_PORT="${SETTING_REDIS_PORT:-6379}"
# Memcached
if [ -z "$SETTING_MEMCACHED_LOCATION" ]; then
    SETTING_MEMCACHED_LOCATION="127.0.0.1:11211"
fi
# Nginx settings
DISABLE_HTTPS="${DISABLE_HTTPS:-false}"
NGINX_WORKERS="${NGINX_WORKERS:-2}"
NGINX_PROXY_BUFFERING="${NGINX_PROXY_BUFFERING:-off}"
NGINX_MAX_UPLOAD_SIZE="${NGINX_MAX_UPLOAD_SIZE:-80m}"
# Zulip certifcate parameters
SSL_CERTIFICATE_GENERATION="${SSL_CERTIFICATE_GENERATION:self-signed}"
# Zulip related settings
ZULIP_AUTH_BACKENDS="${ZULIP_AUTH_BACKENDS:-EmailAuthBackend}"
ZULIP_RUN_POST_SETUP_SCRIPTS="${ZULIP_RUN_POST_SETUP_SCRIPTS:-True}"
# Zulip user setup
FORCE_FIRST_START_INIT="${FORCE_FIRST_START_INIT:-False}"
# Auto backup settings
AUTO_BACKUP_ENABLED="${AUTO_BACKUP_ENABLED:-True}"
AUTO_BACKUP_INTERVAL="${AUTO_BACKUP_INTERVAL:-30 3 * * *}"
# Zulip configuration function specific variable(s)
SPECIAL_SETTING_DETECTION_MODE="${SPECIAL_SETTING_DETECTION_MODE:-}"
MANUAL_CONFIGURATION="${MANUAL_CONFIGURATION:-false}"
LINK_SETTINGS_TO_DATA="${LINK_SETTINGS_TO_DATA:-false}"
# entrypoint.sh specific variable(s)
SETTINGS_PY="/etc/zulip/settings.py"

# BEGIN appRun functions
# === initialConfiguration ===
prepareDirectories() {
    mkdir -p "$DATA_DIR" "$DATA_DIR/backups" "$DATA_DIR/certs" "$DATA_DIR/letsencrypt" "$DATA_DIR/uploads"
    [ -e /etc/letsencrypt ] || ln -ns "$DATA_DIR/letsencrypt" /etc/letsencrypt
    echo "Preparing and linking the uploads folder ..."
    rm -rf /home/zulip/uploads
    ln -sfT "$DATA_DIR/uploads" /home/zulip/uploads
    chown zulip:zulip -R "$DATA_DIR/uploads"
    # Link settings folder
    if [ "$LINK_SETTINGS_TO_DATA" = "True" ] || [ "$LINK_SETTINGS_TO_DATA" = "true" ]; then
        # Create settings directories
        if [ ! -d "$DATA_DIR/settings" ]; then
            mkdir -p "$DATA_DIR/settings"
        fi
        if [ ! -d "$DATA_DIR/settings/etc-zulip" ]; then
            cp -rf /etc/zulip "$DATA_DIR/settings/etc-zulip"
        fi
        # Link /etc/zulip/ settings folder
        rm -rf /etc/zulip
        ln -sfT "$DATA_DIR/settings/etc-zulip" /etc/zulip
    fi
    echo "Prepared and linked the uploads directory."
}
setConfigurationValue() {
    if [ -z "$1" ]; then
        echo "No KEY given for setConfigurationValue."
        return 1
    fi
    if [ -z "$3" ]; then
        echo "No FILE given for setConfigurationValue."
        return 1
    fi
    local KEY="$1"
    local VALUE
    local FILE="$3"
    local TYPE="$4"
    if [ -z "$TYPE" ]; then
        case "$2" in
            [Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]|[Nn]one)
            TYPE="bool"
            ;;
            +([0-9]))
            TYPE="integer"
            ;;
            [\[\(]*[\]\)])
            TYPE="array"
            ;;
            ^\{)
            TYPE="object"
            ;;
            *)
            TYPE="string"
            ;;
        esac
    fi
    case "$TYPE" in
        emptyreturn)
        if [ -z "$2" ]; then
            return 0
        fi
        ;;
        literal)
        VALUE="$1"
        ;;
        bool|boolean|int|integer|array|object)
        VALUE="$KEY = $2"
        ;;
        string|*)
        VALUE="$KEY = '${2//\'/\'}'"
        ;;
    esac
    echo "$VALUE" >> "$FILE"
    echo "Setting key \"$KEY\", type \"$TYPE\" in file \"$FILE\"."
}
nginxConfiguration() {
    echo "Executing nginx configuration ..."
    sed -i "s/worker_processes .*/worker_processes $NGINX_WORKERS;/g" /etc/nginx/nginx.conf
    sed -i "s/client_max_body_size .*/client_max_body_size $NGINX_MAX_UPLOAD_SIZE;/g" /etc/nginx/nginx.conf
    sed -i "s/proxy_buffering .*/proxy_buffering $NGINX_PROXY_BUFFERING;/g" /etc/nginx/zulip-include/proxy_longpolling
    echo "Nginx configuration succeeded."
}
puppetConfiguration() {
    echo "Executing puppet configuration ..."

    if [ "$DISABLE_HTTPS" == "True" ] || [ "$DISABLE_HTTPS" == "true" ]; then
        echo "Disabling https in nginx."
        crudini --set /etc/zulip/zulip.conf application_server http_only true
    fi
    if [ "$QUEUE_WORKERS_MULTIPROCESS" == "True" ] || [ "$QUEUE_WORKERS_MULTIPROCESS" == "true" ]; then
        echo "Setting queue workers to run in multiprocess mode ..."
        crudini --set /etc/zulip/zulip.conf application_server queue_workers_multiprocess true
    elif [ "$QUEUE_WORKERS_MULTIPROCESS" == "False" ] || [ "$QUEUE_WORKERS_MULTIPROCESS" == "false" ]; then
        echo "Setting queue workers to run in multithreaded mode ..."
        crudini --set /etc/zulip/zulip.conf application_server queue_workers_multiprocess false
    fi

    if [ -n "$LOADBALANCER_IPS" ]; then
        echo "Setting IPs for load balancer"
        crudini --set /etc/zulip/zulip.conf loadbalancer ips "${LOADBALANCER_IPS}"
    fi

    /home/zulip/deployments/current/scripts/zulip-puppet-apply -f
}
configureCerts() {
    case "$SSL_CERTIFICATE_GENERATION" in
        self-signed)
            GENERATE_SELF_SIGNED_CERT="True"
            GENERATE_CERTBOT_CERT="False"
            ;;

        certbot)
            GENERATE_SELF_SIGNED_CERT="False"
            GENERATE_CERTBOT_CERT="True"
            ;;
        *)
            echo "Not requesting auto-generated self-signed certs."
            GENERATE_CERTBOT_CERT="False"
            GENERATE_SELF_SIGNED_CERT="False"
            ;;
    esac
    if [ ! -e "$DATA_DIR/certs/zulip.key" ] && [ ! -e "$DATA_DIR/certs/zulip.combined-chain.crt" ]; then

        if [ "$GENERATE_CERTBOT_CERT" = "True" ]; then
            # Zulip isn't yet running, so the certbot's challenge can't be met.
            # We'll schedule this for later.
            echo "Scheduling LetsEncrypt cert generation ..."
            GENERATE_CERTBOT_CERT_SCHEDULED=True

            # Generate self-signed certs just to get Zulip going.
            GENERATE_SELF_SIGNED_CERT=True
        fi

        if [ "$GENERATE_SELF_SIGNED_CERT" = "True" ]; then
            echo "Generating self-signed certificates ..."
            mkdir -p "$DATA_DIR/certs"
            /home/zulip/deployments/current/scripts/setup/generate-self-signed-cert "$SETTING_EXTERNAL_HOST"
            mv /etc/ssl/private/zulip.key "$DATA_DIR/certs/zulip.key"
            mv /etc/ssl/certs/zulip.combined-chain.crt "$DATA_DIR/certs/zulip.combined-chain.crt"
            echo "Self-signed certificate generation succeeded."
        else
            echo "Certificates already exist. No need to generate them. Continuing."
        fi
    fi
    if [ ! -e "$DATA_DIR/certs/zulip.key" ]; then
        echo "SSL private key zulip.key is not present in $DATA_DIR."
        echo "Certificates configuration failed."
        echo "Consider setting SSL_CERTIFICATE_GENERATION in the environment to auto-generate"
        exit 1
    fi
    if [ ! -e "$DATA_DIR/certs/zulip.combined-chain.crt" ]; then
        echo "SSL public key zulip.combined-chain.crt is not present in $DATA_DIR."
        echo "Certificates configuration failed."
        echo "Consider setting SSL_CERTIFICATE_GENERATION in the environment to auto-generate"
        exit 1
    fi
    ln -sfT "$DATA_DIR/certs/zulip.key" /etc/ssl/private/zulip.key
    ln -sfT "$DATA_DIR/certs/zulip.combined-chain.crt" /etc/ssl/certs/zulip.combined-chain.crt
    echo "Certificates configuration succeeded."
}
secretsConfiguration() {
    echo "Setting Zulip secrets ..."
    if [ ! -e "$DATA_DIR/zulip-secrets.conf" ]; then
        echo "Generating Zulip secrets ..."
        /root/zulip/scripts/setup/generate_secrets.py --production
        mv "/etc/zulip/zulip-secrets.conf" "$DATA_DIR/zulip-secrets.conf"
        ln -ns "$DATA_DIR/zulip-secrets.conf" "/etc/zulip/zulip-secrets.conf"
    else
        ln -nsf "$DATA_DIR/zulip-secrets.conf" "/etc/zulip/zulip-secrets.conf"
        echo "Generating Zulip secrets ..."
        /root/zulip/scripts/setup/generate_secrets.py --production
    fi
    echo "Secrets generation succeeded."
    local key
    for key in "${!SECRETS_@}"; do
        [[ "$key" == SECRETS_*([0-9A-Z_a-z-]) ]] || continue
        local SECRET_KEY="${key#SECRETS_}"
        local SECRET_VAR="${!key}"
        if [ -z "$SECRET_VAR" ]; then
            echo "Empty secret for key \"$SECRET_KEY\"."
        fi
        crudini --set "$DATA_DIR/zulip-secrets.conf" "secrets" "${SECRET_KEY}" "${SECRET_VAR}"
    done
    echo "Zulip secrets configuration succeeded."
}
databaseConfiguration() {
    echo "Setting database configuration ..."
    setConfigurationValue "REMOTE_POSTGRES_HOST" "$DB_HOST" "$SETTINGS_PY" "string"
    setConfigurationValue "REMOTE_POSTGRES_PORT" "$DB_HOST_PORT" "$SETTINGS_PY" "string"
    setConfigurationValue "REMOTE_POSTGRES_SSLMODE" "$REMOTE_POSTGRES_SSLMODE" "$SETTINGS_PY" "string"
    # The password will be set in secretsConfiguration
    echo "Database configuration succeeded."
}
authenticationBackends() {
    echo "Activating authentication backends ..."
    local FIRST=true
    local auth_backends
    IFS=, read -r -a auth_backends <<< "$ZULIP_AUTH_BACKENDS"
    for AUTH_BACKEND in "${auth_backends[@]}"; do
        if [ "$FIRST" = true ]; then
            setConfigurationValue "AUTHENTICATION_BACKENDS" "('zproject.backends.${AUTH_BACKEND//\'/\'}',)" "$SETTINGS_PY" "array"
            FIRST=false
        else
            setConfigurationValue "AUTHENTICATION_BACKENDS += ('zproject.backends.${AUTH_BACKEND//\'/\'}',)" "" "$SETTINGS_PY" "literal"
        fi
        echo "Adding authentication backend \"$AUTH_BACKEND\"."
    done
    echo "Authentication backend activation succeeded."
}
zulipConfiguration() {
    echo "Executing Zulip configuration ..."
    if [ -n "$ZULIP_CUSTOM_SETTINGS" ]; then
        echo -e "\n$ZULIP_CUSTOM_SETTINGS" >> "$SETTINGS_PY"
    fi
    local key
    for key in "${!SETTING_@}"; do
        [[ "$key" == SETTING_*([0-9A-Za-z_]) ]] || continue
        local setting_key="${key#SETTING_}"
        local setting_var="${!key}"
        local type="string"
        if [ -z "$setting_var" ]; then
            echo "Empty var for key \"$setting_key\"."
            continue
        fi
        # Zulip settings.py / zproject specific overrides here
        if [ "$setting_key" = "AUTH_LDAP_CONNECTION_OPTIONS" ] || \
           [ "$setting_key" = "AUTH_LDAP_GLOBAL_OPTIONS" ] || \
           [ "$setting_key" = "AUTH_LDAP_USER_SEARCH" ] || \
           [ "$setting_key" = "AUTH_LDAP_GROUP_SEARCH" ] || \
           [ "$setting_key" = "AUTH_LDAP_REVERSE_EMAIL_SEARCH" ] || \
           [ "$setting_key" = "AUTH_LDAP_USER_ATTR_MAP" ] || \
           [ "$setting_key" = "AUTH_LDAP_USER_FLAGS_BY_GROUP" ] || \
           [ "$setting_key" = "AUTH_LDAP_GROUP_TYPE" ] || \
           [ "$setting_key" = "AUTH_LDAP_ADVANCED_REALM_ACCESS_CONTROL" ] || \
           [ "$setting_key" = "LDAP_SYNCHRONIZED_GROUPS_BY_REALM" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_OIDC_ENABLED_IDPS" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_SAML_ENABLED_IDPS" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_SAML_ORG_INFO" ] || \
           { [ "$setting_key" = "LDAP_APPEND_DOMAIN" ] && [ "$setting_var" = "None" ]; } || \
           [ "$setting_key" = "SCIM_CONFIG" ] || \
           [ "$setting_key" = "SECURE_PROXY_SSL_HEADER" ] || \
           [[ "$setting_key" = "CSRF_"* ]] || \
           [ "$setting_key" = "REALM_HOSTS" ] || \
           [ "$setting_key" = "ALLOWED_HOSTS" ]; then
            type="array"
        fi
        if [ "$setting_key" = "SOCIAL_AUTH_SAML_ORG_INFO" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_SAML_TECHNICAL_CONTACT" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_SAML_SUPPORT_CONTACT" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_SAML_SECURITY_CONFIG" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_SAML_SP_EXTRA" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_SAML_SECURITY_CONFIG" ] || \
           [ "$setting_key" = "SOCIAL_AUTH_SAML_ENABLED_IDPS" ]; then
            type="object"
        fi
        if [ "$SPECIAL_SETTING_DETECTION_MODE" = "True" ] || [ "$SPECIAL_SETTING_DETECTION_MODE" = "true" ] || \
           [ "$type" = "string" ]; then
            type=""
        fi
        if [ "$setting_key" = "EMAIL_HOST_USER"  ] || \
           [ "$setting_key" = "EMAIL_HOST_PASSWORD" ]  || \
           [ "$setting_key" = "EXTERNAL_HOST" ]; then
            type="string"
        fi
        setConfigurationValue "$setting_key" "$setting_var" "$SETTINGS_PY" "$type"
    done
    if ! su zulip -c "/home/zulip/deployments/current/manage.py checkconfig"; then
        echo "Error in the Zulip configuration. Exiting."
        exit 1
    fi
    echo "Zulip configuration succeeded."
}
autoBackupConfiguration() {
    if [ "$AUTO_BACKUP_ENABLED" != "True" ] && [ "$AUTO_BACKUP_ENABLED" != "true" ]; then
        rm -f /etc/cron.d/autobackup
        echo "Auto backup is disabled. Continuing."
        return 0
    fi
    printf 'MAILTO=""\n%s cd /;/sbin/entrypoint.sh app:backup\n' "$AUTO_BACKUP_INTERVAL" > /etc/cron.d/autobackup
    echo "Auto backup enabled."
}
initialConfiguration() {
    echo "=== Begin Initial Configuration Phase ==="
    prepareDirectories
    puppetConfiguration
    nginxConfiguration
    configureCerts
    if [ "$MANUAL_CONFIGURATION" = "False" ] || [ "$MANUAL_CONFIGURATION" = "false" ]; then
        # Start with the settings template file.
        cp -a /home/zulip/deployments/current/zproject/prod_settings_template.py "$SETTINGS_PY"
        databaseConfiguration
        secretsConfiguration
        authenticationBackends
        zulipConfiguration
    fi
    autoBackupConfiguration
    echo "=== End Initial Configuration Phase ==="
}
# === bootstrappingEnvironment ===
waitingForDatabase() {
    local TIMEOUT=60
    echo "Waiting for database server to allow connections ..."
    while ! PGPASSWORD="${SECRETS_postgres_password?}" /usr/bin/pg_isready -h "$DB_HOST" -p "$DB_HOST_PORT" -U "$DB_USER" -t 1 >/dev/null 2>&1
    do
        if ! ((TIMEOUT--)); then
            echo "Could not connect to database server. Exiting."
            exit 1
        fi
        echo -n "."
        sleep 1
    done
}
zulipFirstStartInit() {
    echo "Executing Zulip first start init ..."
    if [ -e "$DATA_DIR/.initiated" ] && [ "$FORCE_FIRST_START_INIT" != "True" ] && [ "$FORCE_FIRST_START_INIT" != "true" ]; then
        echo "First Start Init not needed. Continuing."
        return 0
    fi
    local RETURN_CODE=0
    set +e
    su zulip -c /home/zulip/deployments/current/scripts/setup/initialize-database
    RETURN_CODE=$?
    if [[ $RETURN_CODE != 0 ]]; then
        echo "Zulip first start database initi failed in \"initialize-database\" exit code $RETURN_CODE. Exiting."
        exit $RETURN_CODE
    fi
    set -e
    touch "$DATA_DIR/.initiated"
    echo "Zulip first start init sucessful."
}
zulipMigration() {
    echo "Migrating Zulip to new version ..."
    set +e
    su zulip -c "/home/zulip/deployments/current/manage.py migrate --noinput"
    local RETURN_CODE=$?
    if [[ $RETURN_CODE != 0 ]]; then
        echo "Zulip migration failed with exit code $RETURN_CODE. Exiting."
        exit $RETURN_CODE
    fi
    set -e
    rm -rf "$DATA_DIR/.zulip-*"
    touch "$DATA_DIR/.zulip-$ZULIP_VERSION"
    echo "Zulip migration succeeded."
}
runPostSetupScripts() {
    echo "Post setup scripts execution ..."
    if [ "$ZULIP_RUN_POST_SETUP_SCRIPTS" != "True" ] && [ "$ZULIP_RUN_POST_SETUP_SCRIPTS" != "true" ]; then
        echo "Not running post setup scripts. ZULIP_RUN_POST_SETUP_SCRIPTS isn't true."
        return 0
    fi
    if [ ! -d "$DATA_DIR/post-setup.d/" ]; then
        echo "No post-setup.d folder found. Continuing."
        return 0
    fi
    if [ ! "$(ls "$DATA_DIR/post-setup.d/")" ]; then
        echo "No post setup scripts found in \"$DATA_DIR/post-setup.d/\"."
        return 0
    fi
    set +e
    for file in "$DATA_DIR"/post-setup.d/*; do
        if [ -x "$file" ]; then
            echo "Executing \"$file\" ..."
            bash -c "$file"
            echo "Executed \"$file\". Return code $?."
        else
            echo "Permissions denied for \"$file\". Please check the permissions. Exiting."
            exit 1
        fi
    done
    set -e
    echo "Post setup scripts execution succeeded."
}
function runCertbotAsNeeded() {
    if [ ! "$GENERATE_CERTBOT_CERT_SCHEDULED" = "True" ]; then
        echo "Certbot is not scheduled to run."
        return
    fi

    echo "Waiting for nginx to come online before generating certbot certificate ..."
    while ! curl -sk "$SETTING_EXTERNAL_HOST" >/dev/null 2>&1; do
        sleep 1;
    done

    echo "Generating LetsEncrypt/certbot certificate ..."

    # Remove the self-signed certs which were only needed to get Zulip going.
    rm -f "$DATA_DIR"/certs/zulip.key "$DATA_DIR"/certs/zulip.combined-chain.crt

    ln -sf /sbin/certbot-deploy-hook /etc/letsencrypt/renewal-hooks/deploy/docker-deploy-hook

    # Accept the terms of service automatically.
    /home/zulip/deployments/current/scripts/setup/setup-certbot \
        --agree-tos \
        --email="$SETTING_ZULIP_ADMINISTRATOR" \
        --skip-symlink \
        -- \
        "$SETTING_EXTERNAL_HOST"

    echo "LetsEncrypt cert generated."
}
bootstrappingEnvironment() {
    echo "=== Begin Bootstrap Phase ==="
    waitingForDatabase
    zulipFirstStartInit
    zulipMigration
    runPostSetupScripts
    # Hack: We run this in the background, since we need nginx to be
    # started before we can create the certificate.  See #142 for
    # details on how we can clean this up.
    runCertbotAsNeeded &
    echo "=== End Bootstrap Phase ==="
}
# END appRun functions
# BEGIN app functions
appRun() {
    initialConfiguration
    bootstrappingEnvironment
    echo "=== Begin Run Phase ==="
    echo "Starting Zulip using supervisor with \"/etc/supervisor/supervisord.conf\" config ..."
    echo ""
    exec supervisord -n -c "/etc/supervisor/supervisord.conf"
}
appInit() {
    echo "=== Running initial setup ==="
    initialConfiguration
    bootstrappingEnvironment
}
appManagePy() {
    COMMAND="$1"
    shift 1
    if [ -z "$COMMAND" ]; then
        echo "No command given for manage.py. Defaulting to \"shell\"."
        COMMAND="shell"
    fi
    echo "Running manage.py ..."
    set +e
    exec su zulip -c "/home/zulip/deployments/current/manage.py $(printf '%q ' "$COMMAND" "$@")"
}
appBackup() {
    echo "Starting backup process ..."
    local TIMESTAMP
    TIMESTAMP=$(date -u -Iseconds | tr ':' '_')
    if [ -d "/tmp/backup-$TIMESTAMP" ]; then
        echo "Temporary backup folder for \"$TIMESTAMP\" already exists. Aborting."
        echo "Backup process failed. Exiting."
        exit 1
    fi
    local BACKUP_FOLDER
    BACKUP_FOLDER="/tmp/backup-$TIMESTAMP)"
    mkdir -p "$BACKUP_FOLDER"
    waitingForDatabase
    pg_dump -h "$DB_HOST" -p "$DB_HOST_PORT" -U "$DB_USER" "$DB_NAME" > "$BACKUP_FOLDER/database-postgres.sql"
    tar -zcvf "$DATA_DIR/backups/backup-$TIMESTAMP.tar.gz" "$BACKUP_FOLDER/"
    rm -r "${BACKUP_FOLDER:?}/"
    echo "Backup process succeeded."
    exit 0
}
appRestore() {
    echo "Starting restore process ..."
    if [ -z "$(ls -A "$DATA_DIR/backups/")" ]; then
        echo "No backups to restore found in \"$DATA_DIR/backups/\"."
        echo "Restore process failed. Exiting."
        exit 1
    fi
    while true; do
        local backups=("$DATA_DIR"/backups/*)
        printf '|-> %s\n' "${backups[@]#"$DATA_DIR"/backups/}"
        echo "Please enter backup filename (full filename with extension): "
        read -r BACKUP_FILE
        if [ -z "$BACKUP_FILE" ]; then
            echo "Empty filename given. Please try again."
            echo ""
            continue
        fi
        if [ ! -e "$DATA_DIR/backups/$BACKUP_FILE" ]; then
            echo "File \"$BACKUP_FILE\" not found. Please try again."
            echo ""
        fi
        break
    done
    echo "File \"$BACKUP_FILE\" found."
    echo ""
    echo "==============================================================="
    echo "!! WARNING !! Your current data will be deleted!"
    echo "!! WARNING !! YOU HAVE BEEN WARNED! You can abort with \"CTRL+C\"."
    echo "!! WARNING !! Waiting 10 seconds before continuing ..."
    echo "==============================================================="
    echo ""
    local TIMEOUT
    for TIMEOUT in {10..1}; do
        echo "$TIMEOUT"
        sleep 1
    done
    echo "!! WARNING !! Starting restore process ... !! WARNING !!"
    waitingForDatabase
    tar -zxvf "$DATA_DIR/backups/$BACKUP_FILE" -C /tmp
    psql -h "$DB_HOST" -p "$DB_HOST_PORT" -U "$DB_USER" "$DB_NAME" < "/tmp/$(basename "$BACKUP_FILE" | cut -d. -f1)/database-postgres.sql"
    rm -r "/tmp/$(basename "$BACKUP_FILE" | cut -d. -f1)/"
    echo "Restore process succeeded. Exiting."
    exit 0
}
appCerts() {
    configureCerts
}
appHelp() {
    echo "Available commands:"
    echo "> app:help     - Show this help menu and exit"
    echo "> app:version  - Container Zulip server version"
    echo "> app:managepy - Run Zulip's manage.py script (defaults to \"shell\")"
    echo "> app:backup   - Create backups of Zulip instances"
    echo "> app:restore  - Restore backups of Zulip instances"
    echo "> app:certs    - Create self-signed certificates"
    echo "> app:run      - Run the Zulip server"
    echo "> app:init     - Run inital setup of Zulip server"
    echo "> [COMMAND]    - Run given command with arguments in shell"
}
appVersion() {
    echo "This container contains:"
    echo "> Zulip server $ZULIP_VERSION"
    echo "> Checksum: $ZULIP_CHECKSUM"
    exit 0
}
# END app functions

case "$1" in
    app:run)
        appRun
    ;;
    app:init)
        appInit
    ;;
    app:managepy)
        shift 1
        appManagePy "$@"
    ;;
    app:backup)
        appBackup
    ;;
    app:restore)
        appRestore
    ;;
    app:certs)
        appCerts
    ;;
    app:help)
        appHelp
    ;;
    app:version)
        appVersion
    ;;
    *)
        exec "$@" || appHelp
    ;;
esac
