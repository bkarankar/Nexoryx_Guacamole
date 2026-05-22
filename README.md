
# Nexoryx_Guacamole

Production-ready Apache Guacamole native installation automation for Ubuntu with Azure Entra ID SSO, MariaDB, Nginx HTTPS reverse proxy, and session recording support.

---

# Features

- Apache Guacamole 1.6.0
- Native guacd compilation
- MariaDB backend
- Azure Entra ID OpenID SSO
- Nginx HTTPS reverse proxy
- Session recording support
- Ubuntu automation
- Systemd service management
- OpenID authentication
- Production-ready deployment

---

# Stack

- Apache Guacamole
- guacd
- MariaDB
- Nginx
- OpenID Connect
- Azure Entra ID
- OpenSSL
- Ubuntu Linux

---

# Installation

## Clone Repository

```bash
git clone https://github.com/YOUR_USERNAME/Nexoryx_Guacamole.git

cd Nexoryx_Guacamole
```

## Run Installer

```bash
chmod +x install-guacamole-native-azure.sh

sudo bash install-guacamole-native-azure.sh
```

---

# Security Notice

The Azure Entra ID values used in this repository are dummy/sample placeholders only.

You MUST replace them with your own valid Azure Entra ID application details before deployment.

Example:

```bash
AZURE_TENANT_ID="your-real-tenant-id"
AZURE_CLIENT_ID="your-real-client-id"
```

Never commit real production secrets to GitHub repositories.

---

# Dummy Azure Variables

```bash
AZURE_TENANT_ID="${AZURE_TENANT_ID:-13d8c6f3-3245-6544-60d5-23df2e267adb}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-c37a000a-031e-4a91-a000-2ff4324295b6}"
```

These are NOT real production credentials.

---

# Architecture

Client Browser
      |
      v
Nginx HTTPS Reverse Proxy
      |
      v
Apache Guacamole
      |
      v
guacd Proxy Daemon
      |
      +---- MariaDB
      |
      +---- Azure Entra ID SSO

---

# Features Included

- Azure OpenID authentication
- Guacamole recording storage
- SSL certificate generation
- Automatic database setup
- Native guacd build
- Nginx reverse proxy
- Jakarta migration support

---

# License

MIT License
