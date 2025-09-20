#!/bin/bash

# MISP Installation Script for Ubuntu 24.04 LTS
# Version: 1.0
# Author: MrAashish0x1
# Description: Automated MISP installation with comprehensive error handling

set -euo pipefail  # Strict error handling
IFS=$'\n\t'        # Set Internal Field Separator for safer looping

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m' # No Color

# Configuration variables
readonly MISP_INSTALLER_URL="https://raw.githubusercontent.com/MISP/MISP/refs/heads/2.5/INSTALL/INSTALL.ubuntu2404.sh"
readonly INSTALLER_SCRIPT="/tmp/INSTALL.sh"
readonly LOG_DIR="/var/log/misp-installer"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly LOG_FILE="${LOG_DIR}/misp_install_${TIMESTAMP}.log"
readonly CREDENTIALS_FILE="/root/misp_credentials.txt"

# Prerequisite packages
readonly PREREQUISITES=(
    "wget" "curl" "git" "gnupg" "software-properties-common"
    "apt-transport-https" "ca-certificates" "ufw" "net-tools"
    "jq" "bc" "unzip" "screen" "htop"
)

# Function to print colored output
print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }
print_success() { echo -e "${MAGENTA}[SUCCESS]${NC} $1"; }

# Function to log messages to file
log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
    echo -e "$message"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check internet connectivity
check_internet() {
    print_info "Checking internet connectivity..."
    if ! ping -c 2 -W 5 google.com >/dev/null 2>&1 && ! ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
        print_error "No internet connectivity detected"
        exit 1
    fi
    print_status "Internet connectivity verified"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root. Please use: sudo $0"
        exit 1
    fi
    print_status "Running with root privileges"
}

# Check system requirements
check_system() {
    print_info "Checking system requirements..."
    
    # Check if Ubuntu 24.04
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot determine OS distribution"
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "24.04" ]]; then
        print_error "This script is designed for Ubuntu 24.04 LTS only. Detected: $ID $VERSION_ID"
        exit 1
    fi
    
    # Check disk space (minimum 20GB recommended)
    local disk_space_kb
    disk_space_kb=$(df / | awk 'NR==2 {print $4}')
    local disk_space_gb
    disk_space_gb=$(echo "scale=2; $disk_space_kb / 1024 / 1024" | bc)
    
    if (( disk_space_kb < 10000000 )); then
        print_warning "Low disk space detected: ${disk_space_gb}GB (20GB+ recommended)"
    else
        print_status "Disk space: ${disk_space_gb}GB ✓"
    fi
    
    # Check memory (minimum 4GB recommended)
    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_gb
    total_mem_gb=$(echo "scale=2; $total_mem_kb / 1024 / 1024" | bc)
    
    if (( total_mem_kb < 3800000 )); then
        print_warning "Low memory detected: ${total_mem_gb}GB (4GB+ recommended)"
    else
        print_status "Memory: ${total_mem_gb}GB ✓"
    fi
    
    # Check CPU cores
    local cpu_cores
    cpu_cores=$(nproc)
    print_status "CPU Cores: $cpu_cores ✓"
    
    print_status "System requirements check completed"
}

# Install prerequisite packages
install_prerequisites() {
    print_info "Installing prerequisite packages..."
    
    local missing_packages=()
    
    for pkg in "${PREREQUISITES[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing_packages+=("$pkg")
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        print_info "Installing missing packages: ${missing_packages[*]}"
        if ! apt install -y "${missing_packages[@]}" >> "$LOG_FILE" 2>&1; then
            print_error "Failed to install prerequisite packages"
            exit 1
        fi
        print_status "Prerequisite packages installed"
    else
        print_status "All prerequisite packages already installed"
    fi
    
    # Configure firewall
    if ! ufw status | grep -q "Status: active"; then
        print_info "Configuring firewall..."
        ufw allow ssh >/dev/null 2>&1
        ufw allow http >/dev/null 2>&1
        ufw allow https >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        print_status "Firewall configured and enabled"
    fi
}

# Update and upgrade system
update_system() {
    print_info "Updating and upgrading system packages..."
    
    # Update package lists
    if ! apt update >> "$LOG_FILE" 2>&1; then
        print_error "Failed to update package lists"
        exit 1
    fi
    
    # Upgrade packages
    if ! DEBIAN_FRONTEND=noninteractive apt upgrade -y >> "$LOG_FILE" 2>&1; then
        print_error "Failed to upgrade system packages"
        exit 1
    fi
    
    # Clean up
    apt autoremove -y >> "$LOG_FILE" 2>&1
    apt autoclean >> "$LOG_FILE" 2>&1
    
    print_status "System updated and upgraded successfully"
}

# Download MISP installer script
download_misp_installer() {
    print_info "Downloading MISP installation script..."
    
    local max_retries=5
    local retry_count=0
    
    # Remove any existing installer script
    rm -f "$INSTALLER_SCRIPT"
    
    while (( retry_count < max_retries )); do
        print_info "Download attempt $((retry_count + 1)) of $max_retries..."
        
        if wget --no-cache --timeout=30 --tries=3 -O "$INSTALLER_SCRIPT" \
           "$MISP_INSTALLER_URL" >> "$LOG_FILE" 2>&1; then
            break
        fi
        
        retry_count=$((retry_count + 1))
        print_warning "Download attempt $retry_count failed, retrying in 3 seconds..."
        sleep 3
    done
    
    if (( retry_count == max_retries )); then
        print_error "Failed to download MISP installation script after $max_retries attempts"
        exit 1
    fi
    
    # Verify the downloaded script
    if [[ ! -s "$INSTALLER_SCRIPT" ]]; then
        print_error "Downloaded script is empty"
        exit 1
    fi
    
    if ! grep -q -i "MISP\|install" "$INSTALLER_SCRIPT"; then
        print_error "Downloaded file doesn't appear to be a MISP installer"
        exit 1
    fi
    
    chmod +x "$INSTALLER_SCRIPT"
    print_status "MISP installation script downloaded and verified"
}

# Execute MISP installer
execute_misp_installer() {
    print_info "Starting MISP installation..."
    
    if [[ ! -f "$INSTALLER_SCRIPT" || ! -x "$INSTALLER_SCRIPT" ]]; then
        print_error "MISP installer script not found or not executable"
        exit 1
    fi
    
    print_warning "=================================================="
    print_warning "MISP installation will now begin."
    print_warning "This may take 30-60 minutes. Do not interrupt!"
    print_warning "Progress is being logged to: $LOG_FILE"
    print_warning "=================================================="
    
    # Execute the MISP installer script
    if ! script -q -c "bash $INSTALLER_SCRIPT" >> "$LOG_FILE" 2>&1; then
        local exit_code=$?
        print_error "MISP installation failed with exit code: $exit_code"
        
        # Provide helpful error analysis
        if grep -q "out of disk space" "$LOG_FILE"; then
            print_error "Installation failed due to insufficient disk space"
        elif grep -q "connection failed" "$LOG_FILE"; then
            print_error "Network connectivity issues during installation"
        elif grep -q "permission denied" "$LOG_FILE"; then
            print_error "Permission issues detected"
        fi
        
        print_info "Check the full log for details: $LOG_FILE"
        exit 1
    fi
    
    print_status "MISP installation script completed successfully"
}

# Configure system hosts file
configure_hosts() {
    print_info "Configuring system hosts file..."
    
    local ip_address
    ip_address=$(hostname -I | awk '{print $1}')
    
    if [[ -z "$ip_address" ]]; then
        print_error "Could not determine IP address"
        exit 1
    fi
    
    print_status "Detected IP address: $ip_address"
    
    # Backup original hosts file
    cp /etc/hosts "/etc/hosts.backup.${TIMESTAMP}"
    
    # Remove any existing misp.local entries
    sed -i '/misp\.local$/d' /etc/hosts
    
    # Add new entry
    echo "$ip_address misp.local" >> /etc/hosts
    
    # Verify the change
    if grep -q "$ip_address misp.local" /etc/hosts; then
        print_status "Hosts file configured successfully"
    else
        print_error "Failed to configure hosts file"
        exit 1
    fi
}

# Verify MISP installation
verify_installation() {
    print_info "Verifying MISP installation..."
    
    local verification_passed=true
    
    # Check if MISP web directory exists
    if [[ ! -d "/var/www/MISP" ]]; then
        print_error "MISP web directory not found"
        verification_passed=false
    fi
    
    # Check if Apache is running
    if ! systemctl is-active --quiet apache2; then
        print_error "Apache web server is not running"
        verification_passed=false
    fi
    
    # Check if database is running
    if ! systemctl is-active --quiet mysql && ! systemctl is-active --quiet mariadb; then
        print_error "Database service is not running"
        verification_passed=false
    fi
    
    # Check if services are enabled to start on boot
    if ! systemctl is-enabled --quiet apache2; then
        print_warning "Apache is not enabled to start on boot"
    fi
    
    if [[ "$verification_passed" == true ]]; then
        print_status "MISP installation verification passed"
    else
        print_error "MISP installation verification failed"
        exit 1
    fi
}

# Extract MISP credentials
extract_credentials() {
    print_info "Extracting MISP credentials..."
    
    local email="admin@admin.test"
    local password="admin"
    local db_password="NOT_FOUND"
    
    # Check common credential locations
    local credential_files=(
        "/var/www/MISP/app/Config/config.php"
        "/var/www/MISP/app/Config/database.php"
        "/root/misp_credentials.txt"
        "/home/*/misp_credentials.txt"
        "$LOG_FILE"
    )
    
    for file_pattern in "${credential_files[@]}"; do
        for file in $file_pattern; do
            if [[ -f "$file" ]]; then
                # Try to extract email
                if [[ "$email" == "admin@admin.test" ]]; then
                    local extracted_email
                    extracted_email=$(grep -i "email.*=" "$file" 2>/dev/null | head -1 | grep -Eo '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -1 || true)
                    [[ -n "$extracted_email" ]] && email="$extracted_email"
                fi
                
                # Try to extract password
                if [[ "$password" == "admin" ]]; then
                    local extracted_password
                    extracted_password=$(grep -i "password.*=" "$file" 2>/dev/null | grep -v "database\|db_" | head -1 | grep -Eo "'[^']+'" | sed "s/'//g" | head -1 || true)
                    [[ -n "$extracted_password" ]] && password="$extracted_password"
                fi
            fi
        done
    done
    
    # Create comprehensive credentials file
    cat > "$CREDENTIALS_FILE" << EOF
==============================================
MISP Installation Complete - Credentials
==============================================
Installation Date: $(date)
Installation Log: $LOG_FILE

Web Access:
- URL: https://misp.local
- URL: https://$(hostname -I | awk '{print $1}')
- Email: $email
- Password: $password

Database:
- Username: misp
- Password: $db_password
- Database: misp

System Information:
- IP Address: $(hostname -I | awk '{print $1}')
- Hostname: $(hostname)
- OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)

Important Notes:
1. CHANGE THE DEFAULT PASSWORD immediately after first login
2. Enable SSL/TLS in production environments
3. Configure regular backups
4. Review /var/www/MISP/app/Config/config.php for settings
5. Check $LOG_FILE for installation details

Next Steps:
1. Open https://misp.local in your browser
2. Login with the credentials above
3. Change the admin password
4. Review MISP documentation for configuration
==============================================
EOF
    
    print_status "Credentials saved to: $CREDENTIALS_FILE"
}

# Display completion message
show_completion() {
    echo -e "\n${MAGENTA}"
    echo "=============================================="
    echo "          MISP INSTALLATION COMPLETE          "
    echo "=============================================="
    echo -e "${NC}"
    
    print_success "MISP has been successfully installed!"
    print_info "Access URL: https://misp.local"
    print_info "Access URL: https://$(hostname -I | awk '{print $1}')"
    print_info "Credentials file: $CREDENTIALS_FILE"
    print_info "Installation log: $LOG_FILE"
    
    echo -e "\n${YELLOW}Important Next Steps:${NC}"
    echo "1. Open the URL in your web browser"
    echo "2. Login with the provided credentials"
    echo "3. CHANGE THE DEFAULT PASSWORD immediately"
    echo "4. Review the MISP documentation for configuration"
    
    echo -e "\n${GREEN}Installation completed at: $(date)${NC}"
}

# Main execution function
main() {
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Start logging
    echo "MISP Installation started at: $(date)" > "$LOG_FILE"
    log_message "Starting MISP installation process..."
    
    # Display welcome message
    echo -e "${CYAN}"
    echo "=============================================="
    echo "    MISP Automated Installation Script"
    echo "    For Ubuntu 24.04 LTS"
    echo "=============================================="
    echo -e "${NC}"
    
    # Execute installation steps
    check_root
    check_internet
    check_system
    install_prerequisites
    update_system
    download_misp_installer
    execute_misp_installer
    configure_hosts
    verify_installation
    extract_credentials
    
    # Final completion
    show_completion
    log_message "MISP installation completed successfully"
}

# Error handling and cleanup
handle_error() {
    local exit_code=$?
    local line_no=$1
    local command=$2
    
    print_error "Error occurred at line $line_no: $command"
    print_error "Exit code: $exit_code"
    print_info "Check the log file for details: $LOG_FILE"
    
    exit $exit_code
}

# Set trap for errors
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# Handle script termination
trap 'print_info "Script execution completed"; exit 0' EXIT

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi