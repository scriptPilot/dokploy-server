# Dokploy Server

👨‍💻 Personal best practice and helper to **setup**, **backup** and **restore** a [Dokploy Server](https://dokploy.com/).

> The backup (hot db backup 🫢) and restoration (proper restart 🤔) could be improved.<br />
> I am happy about some good proposals / pull requests. 🧑‍💻

## Setup

1. Create a server with IP4, for example with [Hetzner](https://console.hetzner.cloud/), for less than 5€ per month.

2. Configure the server:

    Connect via SSH, change the initial password and remember the new one:

    ```bash
    ssh root@{server_ip}
    ```

    Install Dokploy:

    ```bash
    curl -sSL https://dokploy.com/install.sh | sh
    ```

    Exit the SSH connection:

    ```bash
    exit
    ```

    Open the Dokploy app, create a user and remember the password.

3. Configure Dokploy:

   Notifications

   - At the domain hoster, create an email account for `dokploy@{domain.tld}`.
   - In Dokploy, use this SMTP account to configure email notifications for all events.

   Web Server

   - At the domain hoster, create a DNS A record for `dokploy.{domain.tld}` and forward it to the `{server_ip}`.
   - In Dokploy, use this domain and the  email account for the Web Server and Let's Encrypt, activate HTTPS.

   Git

   - Connect to GitHub by creating a dedicated application like `Dokploy Server @ Hetzner` and grant access rights to it.

4. Transfer all projects to the new server:

   - Configure the project and related services.
   - Update the DNS A record with the new IP.
   - Test the app with `http` and `https`.
   - Test the app with and without `www`.

## Backup

1. Clone this repository and open it in the code editor.

2. Create an `.env` file with the backup settings:

    ```env
    BACKUP_SERVER_IP=1.2.3.4
    BACKUP_SERVER_PW=secret_password
    LOCAL_BACKUP_DIR=dokploy-backup-folder
    ````

3. Backup the Dokploy folder and all Docker volumes locally:

   ```bash
   make backup
   ```

## Restore

1. Run the backup script with `make backup`.

2. Extend the `.env` file with the restore settings:

    ```env
    RESTORE_SERVER_IP=1.2.3.4
    RESTORE_SERVER_PW=secret_password
    ````

3. Run the restore script:

    ```bash
    make restore
    ```

4. If the backup and restore IPs are different:

    - Update the IP address in Web Server > Server > Update IP.
    - Reconfigure Git providers if they were set up using IP addresses.
    - Update the DNS records to point to the new IP.

5. For each project:

    - Recreate Traefik.me domains if they are used.
    - Deploy the application manually.
    - Test the application.
