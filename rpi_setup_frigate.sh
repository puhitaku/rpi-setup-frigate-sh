#!/bin/bash

set -ueo pipefail

if [ -z ${FRIGATE_RTSP_PASSWORD:+x} ]; then
    echo "Please set FRIGATE_RTSP_PASSWORD and run me again."
    exit 1
fi

if [ -z ${TAILSCALE_HOST_URI:+x} ]; then
    echo "Please set TAILSCALE_HOST_URI and run me again."
	echo "Example: tailXXXXXX.ts.net"
    exit 1
fi

set -x

function log_section() {
    set +x
    echo
    echo "----------------------------------------"
    echo "$1"
    echo "----------------------------------------"
    echo
    set -x
}

function configure_system() {
    log_section "Configure System"
    sudo sed -iE 's/#MaxRetentionSec.*/MaxRetentionSec=3month/g' /etc/systemd/journald.conf
}

function install_tpu_driver() {
    log_section "Install TPU Driver"

    # Ref: https://coral.ai/docs/accelerator/get-started/
    echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" | sudo tee /etc/apt/sources.list.d/coral-edgetpu.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    sudo apt update
    sudo apt install libedgetpu1-std

    # Ref: https://github.com/tensorflow/tensorflow/issues/34135
    sudo usermod -aG plugdev pi
}

function install_docker() {
    log_section "Install Docker"

    # Add the key and the repository
    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install the package
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Verify that the installation is successful
    sudo docker run hello-world
}

function install_frigate() {
    log_section "Install Frigate"

    # Create directories
    mkdir -p ${HOME}/frigate/config
    mkdir -p ${HOME}/frigate/storage
    mkdir -p ${HOME}/frigate/certs

    # Increase GPU memory to 128 MB
    if ! grep -q '^gpu_mem' /boot/firmware/config.txt; then
        echo -e "\ngpu_mem=128" | sudo tee -a /boot/firmware/config.txt
    fi

    # Setup Docker Compose and let it autorun on boot
    # Ref: https://docs.frigate.video/frigate/installation/#docker
    cat <<- EOF > ${HOME}/docker-compose-frigate.yml
		version: "3.9"
		services:
		  frigate:
		    container_name: frigate
		    privileged: true # this may not be necessary for all setups
		    restart: unless-stopped
		    image: ghcr.io/blakeblackshear/frigate:stable
		    shm_size: "128mb" # update for your cameras based on calculation in the doc
		    devices:
		      - /dev/bus/usb:/dev/bus/usb # Passes the USB Coral, needs to be modified for other versions
		      # - /dev/apex_0:/dev/apex_0 # Passes a PCIe Coral, follow driver instructions here https://coral.ai/docs/m2/get-started/#2a-on-linux
		      # - /dev/video11:/dev/video11 # For Raspberry Pi 4B
		    volumes:
		      - /etc/localtime:/etc/localtime:ro
		      - ${HOME}/frigate/config:/config
		      - ${HOME}/frigate/storage:/media/frigate

		      # Optional: TLS certificate.
		      # You have to put privkey.pem and fullchain.pem in HOME/frigate/certs directory.
		      # Ref: https://docs.frigate.video/configuration/tls
		      # Ref: https://github.com/blakeblackshear/frigate/discussions/13973
		      # - ${HOME}/frigate/certs:/etc/letsencrypt/live/frigate:ro

		      # Optional: tmpfs to reduce I/O to the disk. It's 128MiB here while it's 1GB on the official doc.
		      - type: tmpfs 
		        target: /tmp/cache
		        tmpfs:
		          size: 134217728
		    ports:
		      - "8971:8971"
		      # - "443:8971"  # Uncomment here after issuing a valid TLS cert to enable access via 443.
		      # - "5000:5000" # Internal unauthenticated access. Expose carefully.
		      - "8554:8554" # RTSP feeds
		      - "8555:8555/tcp" # WebRTC over tcp
		      - "8555:8555/udp" # WebRTC over udp
		    environment:
		      FRIGATE_RTSP_PASSWORD: ${FRIGATE_RTSP_PASSWORD}
	EOF

    # Config for RPi + Coral + go2rtc + dummy camera.
    # Add configs as you need on the Web UI.
    cat <<- EOF > ${HOME}/frigate/config/config.yml
		mqtt:
		  enabled: false

		ffmpeg:
		  hwaccel_args: preset-rpi-64-h264

		go2rtc:
		  streams:
		    dummy_camera:
		      - rtsp://127.0.0.1:554/rtsp
		    candidates:
		      - stun:8555

		detectors:
		  coral:
		    type: edgetpu
		    device: usb

		logger:
		  default: info

		cameras:
		  dummy_camera: # <--- this will be changed to your actual camera later
		    enabled: false
		    ffmpeg:
		      inputs:
		        - path: rtsp://127.0.0.1:554/rtsp
		          roles:
		            - detect
		        - path: rtsp://127.0.0.1:554/rtsp
		          roles:
		            - record
		    #onvif:
		    #  host: 192.168.x.x
		    #  port: 2020
		    #  user: username
		    #  password: password

		record:
		  enabled: True
		  retain:
		    days: 31
		    mode: motion
		  events:
		    retain:
		      default: 30
		      mode: motion


		objects:
		  track:
		    - person
		    - bicycle 
		    - car

		review:
		  alerts:
		    labels:
		      - person
		      - bicycle 
		      - car
		  detections:
		    labels:
		      - person
		      - bicycle 
		      - car
	EOF

    # Let Docker Compose autorun on boot
    # Original: https://redj.hatenablog.com/entry/2020/02/11/142115
    cat <<- EOF | sudo tee /lib/systemd/system/docker-compose@.service
		[Unit]
		Description=%i managed by docker-compose
		Requires=docker.service

		[Service]
		Type=simple

		Environment=COMPOSE_FILE=${HOME}/docker-compose-%i.yml

		ExecStartPre=-/usr/bin/docker compose -f \${COMPOSE_FILE} down --volumes
		ExecStart=/usr/bin/docker compose -f \${COMPOSE_FILE} up
		ExecStop=/usr/bin/docker compose -f \${COMPOSE_FILE} down --volumes

		[Install]
		WantedBy=multi-user.target
	EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now docker-compose@frigate
}

function install_tailscale() {
    log_section "Install Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
}

function install_tailscale_cert_renewal() {
    log_section "Install Tailscale cert renewal"

	cat <<- EOF | sudo tee /etc/systemd/system/tailscale-cert.service
		[Unit]
		Description=Tailscale SSL Service Renewal
		After=network.target
		After=syslog.target

		[Service]
		Type=oneshot
		User=root
		Group=root
		WorkingDirectory=/etc/ssl/private/
		ExecStart=tailscale cert --cert-file ${HOME}/frigate/certs/fullchain.pem --key-file ${HOME}/frigate/certs/privkey.pem ${TAILSCALE_HOST_URI}

		[Install]
		WantedBy=multi-user.target
	EOF

	cat <<- EOF | sudo tee /etc/systemd/system/tailscale-cert.timer
		[Unit]
		Description=Renew Tailscale cert

		[Timer]
		OnCalendar=weekly
		Unit=%i.service
		Persistent=true

		[Install]
		WantedBy=timers.target
	EOF

    sudo systemctl daemon-reload
    sudo systemctl start --now tailscale-cert.service
}

function main() {
    configure_system
    install_tpu_driver
    install_docker
    install_frigate
    install_tailscale
    install_tailscale_cert_renewal
}

main 2>&1 | tee ~/setup.log
