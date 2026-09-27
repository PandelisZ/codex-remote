# A throwaway Ubuntu box that behaves enough like a fresh cloud server — systemd, sshd,
# nothing else — to run Codex Remote's real bootstrap against in CI or on a laptop.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv openssh-server ca-certificates curl sudo \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /root/.ssh /run/sshd \
 && chmod 700 /root/.ssh \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
 && systemctl enable ssh

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
