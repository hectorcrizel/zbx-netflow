# Zabbix NetFlow Configuration Assistant

This project provides an automation script to configure a **NetFlow (nfdump)** collector and integrate it with **Zabbix Agent 2** on RHEL-based Linux distributions (CentOS, Rocky Linux, AlmaLinux).

## 🚀 Features

- **Automated Installation**: Installs `nfdump`, `zabbix-agent2`, and necessary dependencies.
- **Multiple Instances**: Uses systemd templates (`nfdump@.service`) to allow multiple collectors on the same server.
- **Zabbix Integration**: Automatically configures `UserParameters` to monitor:
  - Traffic in Bytes, Packets, and Flows.
  - Top Talkers (IPs generating the most traffic).
  - Detailed flow reports.
  - Merged host statistics.
- **Retention Management**: Configures a systemd timer and script for automatic cleanup of old captures (default 7 days).
- **Interactive UI**: Menu-driven interface using `whiptail`/`dialog`.

## 📋 Prerequisites

- Operating System: RHEL 8/9, Rocky Linux, AlmaLinux, or CentOS.
- Root access.
- Zabbix Agent 2 (the script can install it automatically).

## 🛠️ How to Use

1.  Clone this repository or download the `install.sh` script.
2.  Give it execution permission:
    ```bash
    chmod +x install.sh
    ```
3.  Run the script as root:
    ```bash
    sudo ./install.sh
    ```
4.  Follow the on-screen menu instructions to configure the Collector and the Zabbix Agent.

## 📊 Monitoring Items (Zabbix)

The script configures the following keys in Zabbix Agent 2:

- `netflow.bytes[window]`: Total bytes in the period (e.g., 300 for 5 min).
- `netflow.packets[window]`: Total packets.
- `netflow.flows[window]`: Total flows.
- `netflow.tophosts[direction,limit,window]`: Lists the top IPs.
- `netflow.report[window,limit]`: Detailed flow report.
- `netflow.hosts_merged[window,limit]`: Merged source/destination host stats.

## 📂 File Structure

- `/etc/nfdump/`: Instance configuration files.
- `/var/nfdump/profiles_data/`: Base directory for captures.
- `/usr/local/bin/`: Support scripts (`nfstat.sh`, `nf_top_hosts.sh`, etc.).
- `/etc/zabbix/zabbix_agent2.d/netflow.conf`: UserParameters configuration.

## ⚖️ License

This project is licensed under the MIT License.
