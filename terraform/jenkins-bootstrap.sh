#!/bin/bash
# Runs once, as root, on the first boot of the Jenkins instance (EC2 user_data).
# It installs everything we previously did by hand. Log: /var/log/jenkins-bootstrap.log
set -euxo pipefail
exec > >(tee -a /var/log/jenkins-bootstrap.log) 2>&1

# Java 21 (this Jenkins release refuses to start on Java 17), Git, Docker, Python for Ansible
dnf install -y java-21-amazon-corretto-devel fontconfig git docker python3.11 python3.11-pip

# Jenkins
curl -fsSL -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins

# /tmp is a small memory-backed disk here; Jenkins takes its node offline when it has under 1GB free.
mkdir -p /var/lib/jenkins/tmp
chown jenkins:jenkins /var/lib/jenkins/tmp
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<'OVERRIDE'
[Service]
Environment="JAVA_OPTS=-Djava.io.tmpdir=/var/lib/jenkins/tmp -Djava.awt.headless=true"
OVERRIDE
systemctl daemon-reload

# Docker, usable by the jenkins user
systemctl enable --now docker
usermod -aG docker jenkins

# Ansible in its own virtualenv, plus the Docker collection for the jenkins user
python3.11 -m venv /opt/ansible-venv
/opt/ansible-venv/bin/pip install ansible-core
ln -sf /opt/ansible-venv/bin/ansible-playbook /usr/local/bin/ansible-playbook
ln -sf /opt/ansible-venv/bin/ansible-galaxy /usr/local/bin/ansible-galaxy
sudo -u jenkins /usr/local/bin/ansible-galaxy collection install community.docker

systemctl enable --now jenkins
touch /var/log/jenkins-bootstrap.done
